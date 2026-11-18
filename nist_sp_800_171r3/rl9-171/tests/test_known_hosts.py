"""How a host key is recorded and forgotten (lib/known-hosts.sh; DEFECTS 7.53).

ssh-keyscan prints a comment line for each key type it asks a host for, and
ssh-keygen -R leaves those lines when it removes the host's keys. The tools
appended the scan as it came, so every scan left its comments for good: 2 430
of the 2 720 lines of one workstation's ~/.ssh/known_hosts. These run the
real functions with the real ssh-keygen and a stand-in ssh-keyscan that
prints what the real one does.

Run with `./nist make test`.
"""
import os
import re
import stat
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
LAB = "192.168.171.101"
OTHER = "192.168.171.141"


class KnownHosts(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="nist-kh-"))
        self.addCleanup(lambda: subprocess.run(["rm", "-rf", str(self.tmp)]))
        subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(self.tmp / "key")], check=True)
        key = (self.tmp / "key.pub").read_text().split()[1]
        # What ssh-keyscan -H HOST prints: a comment per key type, then the key.
        scan = self.tmp / "bin" / "ssh-keyscan"
        scan.parent.mkdir()
        scan.write_text(f"""#!/bin/sh
host=$2
echo "# $host:22 SSH-2.0-OpenSSH_9.9"
echo "$host ssh-ed25519 {key}"
echo "# $host:22 SSH-2.0-OpenSSH_9.9"
echo "# $host:22 SSH-2.0-OpenSSH_9.9"
""")
        scan.chmod(0o755)
        self.kh = self.tmp / "known_hosts"
        self.env = dict(os.environ, PATH=f"{scan.parent}:{os.environ['PATH']}")

    def sh(self, script):
        r = subprocess.run(["bash", "-euo", "pipefail", "-c", f". lib/known-hosts.sh; {script}"],
                           cwd=ROOT, env=self.env, capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stderr)
        return r

    def known(self, host):
        return subprocess.run(["ssh-keygen", "-F", host, "-f", str(self.kh)], capture_output=True).returncode == 0

    def test_a_scan_records_the_key_and_no_comment(self):
        self.sh(f"nist_keyscan {LAB} {self.kh}")
        self.assertTrue(self.known(LAB))
        self.assertEqual([l for l in self.kh.read_text().splitlines() if l.startswith("#")], [])

    def test_a_host_that_does_not_answer_is_not_an_error(self):
        # Nothing but comments, or nothing at all: grep finds no key line.
        (self.tmp / "bin" / "ssh-keyscan").write_text("#!/bin/sh\nexit 1\n")
        self.sh(f"nist_keyscan {LAB} {self.kh}")
        self.assertEqual(self.kh.read_text(), "")

    def test_forgetting_a_host_takes_its_key_and_the_comments_older_scans_left(self):
        # The file as the tools left it before: scans appended whole.
        self.kh.write_text("# a note of the operator's own\n")
        for host in (LAB, OTHER, LAB):
            self.sh(f"ssh-keyscan -H {host} >> {self.kh}")
        self.kh.chmod(0o600)
        self.assertEqual(self.kh.read_text().count(f"# {LAB}:22"), 6)
        self.sh(f"nist_forget_host {LAB} {self.kh}")
        text = self.kh.read_text()
        self.assertFalse(self.known(LAB))
        self.assertNotIn(f"# {LAB}:", text)
        # The other host and the operator's own comment are as they were.
        self.assertTrue(self.known(OTHER))
        self.assertEqual(text.count(f"# {OTHER}:22"), 3)
        self.assertIn("# a note of the operator's own", text)
        self.assertEqual(stat.S_IMODE(self.kh.stat().st_mode), 0o600)
        self.assertEqual(sorted(p.name for p in self.tmp.iterdir()), ["bin", "key", "key.pub", "known_hosts"])

    def test_ssh_keygen_alone_leaves_the_comments(self):
        # Why nist_forget_host exists: what the tools ran before it.
        for _ in range(2):
            self.sh(f"ssh-keyscan -H {LAB} >> {self.kh}")
        subprocess.run(["ssh-keygen", "-R", LAB, "-f", str(self.kh)], capture_output=True, check=True)
        self.assertFalse(self.known(LAB))
        self.assertEqual(self.kh.read_text().count(f"# {LAB}:22"), 6)

    def test_an_address_that_begins_another_is_not_taken_for_it(self):
        self.sh(f"ssh-keyscan -H 192.168.171.10 >> {self.kh}; ssh-keyscan -H {LAB} >> {self.kh}")
        self.sh(f"nist_forget_host 192.168.171.10 {self.kh}")
        self.assertTrue(self.known(LAB))
        self.assertEqual(self.kh.read_text().count(f"# {LAB}:22"), 3)

    def test_forgetting_in_a_file_that_is_not_there_is_nothing(self):
        self.sh(f"nist_forget_host {LAB} {self.tmp}/none")
        self.assertFalse((self.tmp / "none").exists())

    def test_the_inventory_forgets_the_comments_with_the_key(self):
        sys.path.insert(0, str(ROOT / "tools"))
        import importlib.machinery
        import importlib.util
        loader = importlib.machinery.SourceFileLoader("nist_inventory", str(ROOT / "tools/inventory.py"))
        inv = importlib.util.module_from_spec(importlib.util.spec_from_loader("nist_inventory", loader))
        loader.exec_module(inv)
        home = self.tmp / "home"
        (home / ".ssh").mkdir(parents=True)
        kh = home / ".ssh" / "known_hosts"
        self.kh = kh
        for host in (LAB, OTHER):
            self.sh(f"ssh-keyscan -H {host} >> {kh}")
        old = os.environ.get("HOME")
        os.environ["HOME"] = str(home)
        self.addCleanup(lambda: os.environ.__setitem__("HOME", old) if old is not None else os.environ.pop("HOME"))
        inv.forget_host_key(LAB, "byo")
        self.assertFalse(self.known(LAB))
        self.assertNotIn(f"# {LAB}:", kh.read_text())
        self.assertTrue(self.known(OTHER))
        self.assertEqual(kh.read_text().count(f"# {OTHER}:22"), 3)

    def test_no_tool_appends_a_scan_as_it_comes(self):
        # Every scan goes through nist_keyscan: the one place that drops the comments.
        raw = []
        for p in [*ROOT.glob("*.sh"), *ROOT.glob("lib/*.sh"), *ROOT.glob("vm/*.sh"),
                  *ROOT.glob("tools/*.sh"), *ROOT.glob("install/*.sh"), ROOT / "nist"]:
            if p.name == "known-hosts.sh":
                continue
            for n, line in enumerate(p.read_text().splitlines(), 1):
                if re.search(r"^[^#]*\bssh-keyscan\b", line):
                    raw.append(f"{p.relative_to(ROOT)}:{n}")
        self.assertEqual(raw, [])


if __name__ == "__main__":
    unittest.main()
