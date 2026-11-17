"""The lab's names in libvirt, and what its tools may touch (lib/lab-env.sh).

Alone on a hypervisor the lab is nist-lab, the pool `default`, rl9-* and
byo-*. With a namespace in lab.conf - a hypervisor shared with other
people's guests - everything of the lab carries it and its tools act on
nothing else (DEFECTS 7.45). The second half runs the real teardown, residue
and destroy scripts against a stand-in `virsh` that keeps a hypervisor's
state in files and records every call that would change it: a host with
another lab's guests, pools and look-alike volumes on it.

Run with `./nist make test`.
"""
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def sh(script, env=None, cwd=ROOT):
    """Run a bash snippet with lib/lab-env.sh's world: no lab.conf, no namespace."""
    e = {k: v for k, v in os.environ.items() if not k.startswith("NIST_")}
    e.update({"NIST_IN_CONTAINER": "1", "NIST_LIBVIRT_URI": "fake:///system",
              "NIST_LAB_CONF": "/nonexistent/lab.conf"})
    e.update(env or {})
    return subprocess.run(["bash", "-euo", "pipefail", "-c", script], cwd=cwd, env=e,
                          capture_output=True, text=True)


NAMES = '. lib/lab-env.sh; echo "$LAB_NS|$LAB_PREFIX|$LAB_NET|$LAB_BRIDGE|$LAB_POOL|$LAB_POOL_PATH"'


class Names(unittest.TestCase):
    def test_without_a_namespace_the_lab_keeps_its_names(self):
        self.assertEqual(sh(NAMES).stdout.strip(), "||nist-lab|virbr17|default|")

    def test_a_namespace_names_the_guests_the_network_its_bridge_and_a_pool(self):
        r = sh(NAMES, {"NIST_LAB_NS": "sc"})
        self.assertEqual(r.stdout.strip(), "sc|sc-|sc-lab|sc-br0|sc|/var/lib/libvirt/images/sc")

    def test_the_network_keeps_its_subnet_and_takes_the_namespaces_names(self):
        xml = sh(". lib/lab-env.sh; lab_network_xml", {"NIST_LAB_NS": "sc"}).stdout
        self.assertIn("<name>sc-lab</name>", xml)
        self.assertIn("<bridge name='sc-br0'", xml)
        self.assertIn("<domain name='sc-lab'", xml)
        self.assertIn("<ip address='192.168.171.1'", xml)
        self.assertNotIn("<name>nist-lab</name>", xml)
        plain = sh(". lib/lab-env.sh; lab_network_xml").stdout
        self.assertEqual(plain, (ROOT / "vm/nist-lab-network.xml").read_text())

    def test_another_definition_is_taken_as_it_is(self):
        # tools/test-lab-network.sh's throwaway copy: its own names, namespace or not.
        with tempfile.NamedTemporaryFile("w", suffix=".xml") as f:
            f.write("<network>\n  <name>throwaway</name>\n  <bridge name='virbr9'/>\n</network>\n")
            f.flush()
            r = sh(NAMES, {"NIST_LAB_NS": "sc", "NIST_LAB_NETWORK_XML": f.name})
        self.assertEqual(r.stdout.strip().split("|")[2:4], ["throwaway", "virbr9"])

    def test_a_lab_name_carries_the_prefix_and_nothing_else_is_one(self):
        probe = '. lib/lab-env.sh; for n in "$@"; do lab_guest_name "$n" && echo "$n"; done; true'
        names = ["rl9-cui-01", "byo-rl9-02", "ptest-fedora", "sc-rl9-cui-01", "sc-byo-log-01",
                 "fleet-vm1", "store-1", "rl9", "sc-store"]
        got = sh(f"set -- {' '.join(names)}; {probe}").stdout.split()
        self.assertEqual(got, ["rl9-cui-01", "byo-rl9-02", "ptest-fedora"])
        got = sh(f"set -- {' '.join(names)}; {probe}", {"NIST_LAB_NS": "sc"}).stdout.split()
        self.assertEqual(got, ["sc-rl9-cui-01", "sc-byo-log-01"])

    def test_in_a_namespace_a_guest_must_be_named_into_it(self):
        ok = sh(". lib/lab-env.sh; lab_name_ok sc-rl9-cui-02", {"NIST_LAB_NS": "sc"})
        self.assertEqual(ok.returncode, 0)
        no = sh(". lib/lab-env.sh; lab_name_ok rl9-cui-02", {"NIST_LAB_NS": "sc"})
        self.assertNotEqual(no.returncode, 0)
        self.assertIn("starts with sc-", no.stderr)
        self.assertEqual(sh(". lib/lab-env.sh; lab_name_ok anything").returncode, 0)


class Setting(unittest.TestCase):
    def conf(self, text, env=None):
        with tempfile.NamedTemporaryFile("w", suffix=".conf") as f:
            f.write(text)
            f.flush()
            e = {"NIST_LAB_CONF": f.name}
            e.update(env or {})
            return sh(NAMES, e)

    def test_the_file_sets_it_with_nothing_exported(self):
        r = self.conf("# this hypervisor is shared\nnamespace = sc   # with the cluster\n\n")
        self.assertEqual(r.stdout.split("|")[0], "sc")
        self.assertEqual(self.conf("namespace=lab2").stdout.split("|")[0], "lab2")

    def test_a_file_with_no_setting_is_no_namespace(self):
        self.assertEqual(self.conf("# nothing here\n").stdout.strip(), "||nist-lab|virbr17|default|")

    def test_a_line_not_understood_stops_everything(self):
        # A setting misread would be a lab built under the wrong names.
        for text in ("namespase = sc\n", "namespace sc\n", "namespace = sc\npool = other\n"):
            r = self.conf(text)
            self.assertEqual(r.returncode, 2, text)
            self.assertIn("not understood", r.stderr)
            self.assertEqual(r.stdout, "")

    def test_the_environment_overrides_the_file_for_the_tests(self):
        self.assertEqual(self.conf("namespace = sc\n", {"NIST_LAB_NS": "t1"}).stdout.split("|")[0], "t1")
        self.assertEqual(self.conf("namespace = sc\n", {"NIST_LAB_NS": ""}).stdout.split("|")[0], "")

    def test_a_namespace_that_cannot_name_things_is_refused(self):
        # Upper case, too long for a disk serial and a bridge name, a digit
        # first, and the lab's own unnamespaced network name.
        for ns in ("SC", "toolong", "9x", "a-b", "a b", "nist", "s/c"):
            r = sh(NAMES, {"NIST_LAB_NS": ns})
            self.assertEqual(r.returncode, 2, ns)
            self.assertEqual(r.stdout, "", ns)
        for ns in ("s", "sc", "lab2", "abcdef"):
            self.assertEqual(sh(NAMES, {"NIST_LAB_NS": ns}).returncode, 0, ns)

    def test_the_longest_names_still_fit(self):
        # build-vm.sh takes 20 characters (the disk's serial); an interface
        # name 15.
        r = sh(NAMES, {"NIST_LAB_NS": "abcdef"}).stdout.strip().split("|")
        self.assertLessEqual(len(r[1] + "rl9-cui-01"), 20)
        self.assertLessEqual(len(r[1] + "rl9-log-01"), 20)
        self.assertLessEqual(len(r[3]), 15)


# ---------------------------------------------------------------------------
# A stand-in virsh: the hypervisor's state in files under $FAKE, and every
# call that would change it appended to $FAKE/calls.
FAKE_VIRSH = r'''#!/usr/bin/env bash
[[ "${1:-}" == -c ]] && shift 2
cmd=${1:-}; shift || true
S=$FAKE
rec() { echo "$cmd $*" >> "$S/calls"; }
has() { grep -q "^$2 " "$S/$1" 2>/dev/null || grep -qx "$2" "$S/$1" 2>/dev/null; }
drop() { sed -i "/^$2\( \|$\)/d" "$S/$1"; }
pool_arg() { local p=""; while (( $# )); do [[ "$1" == --pool ]] && { p=$2; break; }; shift; done; echo "$p"; }
last() { echo "${@: -1}"; }
case $cmd in
  uri) echo "fake:///system" ;;
  list) awk '{print $1}' "$S/domains" ;;
  dominfo|domstate) has domains "$1" || exit 1; echo "shut off" ;;
  domiflist) has domains "$1" || exit 1
    echo " Interface   Type      Source     Model    MAC"; echo "------"
    awk -v d="$1" '$1==d {print " vnet0       network   " $2 "   virtio   " $3}' "$S/domains" ;;
  domblklist|domifaddr|net-dhcp-leases) : ;;
  destroy) rec "$@" ;;
  undefine) rec "$@"; has domains "$1" || exit 1; drop domains "$1"
    # --remove-all-storage takes the guest's own volumes with it
    [[ " $* " == *" --remove-all-storage "* ]] && for f in "$S"/vols/*; do sed -i "/^$1[.-]/d" "$f"; done; true ;;
  pool-list) awk '{print $1}' "$S/pools" ;;
  pool-info) has pools "$1" || exit 1
    awk -v p="$1" '$1==p {print "State:          " $3; print "Autostart:      " $4}' "$S/pools" ;;
  pool-dumpxml) has pools "$1" || exit 1
    awk -v p="$1" '$1==p {print "<pool><target><path>" $2 "</path></target></pool>"}' "$S/pools" ;;
  pool-refresh) : ;;
  pool-define-as) rec "$@"; echo "$1 $4 inactive no" >> "$S/pools"; : > "$S/vols/$1" ;;
  pool-build) rec "$@" ;;
  pool-start) rec "$@"; sed -i "s/^\($1 [^ ]*\) inactive /\1 running /" "$S/pools" ;;
  pool-autostart) rec "$@"; sed -i "s/^\($1 [^ ]* [^ ]*\) no$/\1 yes/" "$S/pools" ;;
  pool-destroy|pool-delete) rec "$@" ;;
  pool-undefine|pool-create-as) rec "$@"; [[ $cmd == pool-undefine ]] && { drop pools "$1"; rm -f "$S/vols/$1"; }; true ;;
  vol-list) p=$(pool_arg "$@"); has pools "$p" || exit 1
    echo " Name   Path   Type   Capacity   Allocation"; echo "------"
    awk -v p="$p" '{print " " $1 "   /x/" p "/" $1 "   file   1.00 GiB   1.00 GiB"}' "$S/vols/$p" ;;
  vol-info) p=$(pool_arg "$@"); grep -qx "$(last "$@")" "$S/vols/$p" 2>/dev/null ;;
  vol-delete) rec "$@"; p=$(pool_arg "$@"); v=$(last "$@")
    grep -qx "$v" "$S/vols/$p" 2>/dev/null || exit 1; sed -i "/^$v$/d" "$S/vols/$p" ;;
  net-info) has nets "$1" || exit 1; echo "Active:         yes"; echo "Autostart:      yes" ;;
  net-dumpxml) has nets "$1" || exit 1; echo "<network><name>$1</name></network>" ;;
  net-destroy) rec "$@" ;;
  net-undefine) rec "$@"; has nets "$1" || exit 1; drop nets "$1" ;;
  net-update) rec "$@" ;;
  *) echo "UNHANDLED $cmd $*" >> "$S/calls"; exit 1 ;;
esac
'''

# A hypervisor someone else runs a lab on: their guests on their networks and
# in their pools - one of them with a name the lab's scripts use, and their
# pools holding a boot ISO and a base image named exactly as the lab's are.
THEIRS = {
    "domains": ["fleet-vm1 default 52:54:00:aa:bb:01",
                "store-1 uplink 52:54:00:aa:bb:02",
                "rl9-cui-01 default 52:54:00:aa:bb:03"],
    "nets": ["default", "uplink"],
    "pools": ["default /var/lib/libvirt/images running yes", "fleet /srv/fleet running yes"],
    "vols": {"default": ["Rocky-9.8-x86_64-boot.iso", "rocky9-genericcloud-base.qcow2",
                         "rl9-cui-01.qcow2", "fleet-vm1.qcow2"],
             "fleet": ["byo-data.qcow2", "store-1.qcow2"]},
}
OURS = {
    "domains": ["sc-rl9-cui-01 sc-lab 52:54:00:11:22:01",
                "sc-rl9-log-01 sc-lab 52:54:00:11:22:02",
                "sc-byo-rl9-01 sc-lab 52:54:00:17:ab:8d"],
    "nets": ["sc-lab"],
    "pools": ["sc /var/lib/libvirt/images/sc running yes"],
    "vols": {"sc": ["sc-rl9-cui-01.qcow2", "sc-rl9-log-01.qcow2", "sc-byo-rl9-01.qcow2",
                    "sc-byo-rl9-01-seed.iso", "rocky9-genericcloud-base.qcow2"]},
}


class Hypervisor(unittest.TestCase):
    """The lab's scripts, copied out of the repository, against the stand-in."""

    def setUp(self):
        self.dir = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.dir, ignore_errors=True)
        self.tool = self.dir / "tool"
        for d in ("vm", "tools", "lib"):
            shutil.copytree(ROOT / d, self.tool / d, ignore=shutil.ignore_patterns("__pycache__"))
        (self.tool / "inventory").mkdir()
        self.fake = self.dir / "fake"
        (self.fake / "vols").mkdir(parents=True)
        (self.fake / "bin").mkdir()
        (self.fake / "calls").write_text("")
        virsh = self.fake / "bin" / "virsh"
        virsh.write_text(FAKE_VIRSH)
        virsh.chmod(0o755)
        self.state(THEIRS, OURS)

    def state(self, *parts):
        doms, nets, pools, vols = [], [], [], {}
        for p in parts:
            doms += p["domains"]; nets += p["nets"]; pools += p["pools"]
            vols.update(p["vols"])
        (self.fake / "domains").write_text("".join(d + "\n" for d in doms))
        (self.fake / "nets").write_text("".join(n + "\n" for n in nets))
        (self.fake / "pools").write_text("".join(p + "\n" for p in pools))
        for pool, names in vols.items():
            (self.fake / "vols" / pool).write_text("".join(n + "\n" for n in names))

    def run_tool(self, script, *args, ns="sc"):
        env = {"FAKE": str(self.fake), "PATH": f"{self.fake / 'bin'}:{os.environ['PATH']}",
               "NIST_BYO_LAB": str(self.dir / "byo-lab"), "HOME": str(self.dir / "home")}
        if ns is not None:
            env["NIST_LAB_NS"] = ns
        e = {k: v for k, v in os.environ.items() if not k.startswith("NIST_")}
        e.update({"NIST_IN_CONTAINER": "1", "NIST_LIBVIRT_URI": "fake:///system",
                  "NIST_LAB_CONF": "/nonexistent/lab.conf"})
        e.update(env)
        return subprocess.run([str(self.tool / script), *args], cwd=self.tool, env=e,
                              capture_output=True, text=True, stdin=subprocess.DEVNULL)

    def calls(self):
        return [c for c in (self.fake / "calls").read_text().splitlines() if c]

    def left(self, name):
        return (self.fake / name).read_text().split("\n")[:-1]

    def assert_theirs_untouched(self):
        self.assertEqual([d for d in self.left("domains") if not d.startswith("sc-")], THEIRS["domains"])
        self.assertEqual([n for n in self.left("nets") if n != "sc-lab"], THEIRS["nets"])
        for pool, names in THEIRS["vols"].items():
            self.assertEqual(self.left(f"vols/{pool}"), names, pool)
        for c in self.calls():
            self.assertNotIn("UNHANDLED", c)
            words = c.split()
            # Every changing call names something in the namespace: a guest
            # or network sc-*, or the pool sc.
            ours = any(w.startswith("sc-") or w == "sc" for w in words[1:])
            self.assertTrue(ours, f"a call outside the namespace: {c}")
            for theirs in ("fleet-vm1", "store-1", "default", "fleet", "uplink"):
                self.assertNotIn(theirs, words, c)

    def test_teardown_in_a_namespace_removes_the_lab_and_nothing_else(self):
        r = self.run_tool("vm/lab-teardown.sh", "--yes")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("PASS: nothing of the labs is left", r.stdout)
        self.assertEqual([d for d in self.left("domains") if d.startswith("sc-")], [])
        self.assertNotIn("sc-lab", self.left("nets"))
        self.assertFalse(any(p.startswith("sc ") for p in self.left("pools")), "the lab's pool is gone")
        self.assert_theirs_untouched()

    def test_teardown_keeps_a_pool_that_holds_what_is_not_the_labs(self):
        with open(self.fake / "vols" / "sc", "a") as f:
            f.write("someone-elses.img\n")
        r = self.run_tool("vm/lab-teardown.sh", "--yes")
        self.assertEqual(r.returncode, 1, r.stdout + r.stderr)
        self.assertIn("someone-elses.img", r.stdout)
        self.assertEqual(self.left("vols/sc"), ["someone-elses.img"])
        self.assertTrue(any(p.startswith("sc ") for p in self.left("pools")))
        self.assert_theirs_untouched()

    def test_residue_in_a_namespace_lists_only_the_lab(self):
        r = self.run_tool("tools/lab-residue.sh")
        self.assertEqual(r.returncode, 0, r.stderr)
        for theirs in ("fleet-vm1", "store-1", "default/", "fleet/", "rl9-cui-01  "):
            self.assertNotIn(theirs, r.stdout.replace("sc-rl9-cui-01", ""))
        for ours in ("sc-rl9-cui-01", "sc-byo-rl9-01", "sc-lab", "sc/rocky9-genericcloud-base.qcow2"):
            self.assertIn(ours, r.stdout)
        self.assertEqual(self.calls(), [])

    def test_without_a_namespace_every_pool_is_searched_for_the_labs_names(self):
        # What the lab does on a host it has to itself - and why it must be
        # given a namespace on any other: the other lab's guest named
        # rl9-cui-01 and its boot ISO and base image are taken for the lab's.
        r = self.run_tool("tools/lab-residue.sh", ns=None)
        for taken in ("rl9-cui-01", "default/Rocky-9.8-x86_64-boot.iso",
                      "default/rocky9-genericcloud-base.qcow2", "fleet/byo-data.qcow2"):
            self.assertIn(taken, r.stdout)

    def test_destroy_refuses_a_guest_outside_the_namespace(self):
        for script, args in (("vm/build-vm.sh", ["--name", "fleet-vm1", "--destroy"]),
                             ("vm/build-vm.sh", ["--name", "rl9-cui-01", "--destroy"]),
                             ("vm/byo-guest.sh", ["destroy", "store-1"])):
            r = self.run_tool(script, *args)
            self.assertNotEqual(r.returncode, 0, script)
            self.assertIn("starts with sc-", r.stderr)
        self.assertEqual(self.calls(), [])

    def test_destroy_refuses_a_guest_named_into_the_namespace_but_not_on_its_network(self):
        with open(self.fake / "domains", "a") as f:
            f.write("sc-not-ours default 52:54:00:aa:bb:09\n")
        r = self.run_tool("vm/build-vm.sh", "--name", "sc-not-ours", "--destroy")
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("not attached to sc-lab", r.stderr)
        r = self.run_tool("vm/byo-guest.sh", "destroy", "sc-not-ours")
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("refusing to touch it", r.stderr)
        self.assertEqual(self.calls(), [])

    def test_without_a_namespace_destroy_still_refuses_what_is_not_on_the_lab_network(self):
        r = self.run_tool("vm/build-vm.sh", "--name", "fleet-vm1", "--destroy", ns=None)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("not attached to nist-lab", r.stderr)
        self.assertEqual(self.calls(), [])

    def test_the_namespaces_pool_is_made_through_libvirt_and_default_never_is(self):
        self.state(THEIRS)                                  # no lab yet
        probe = ". lib/container.sh; . lib/lab-env.sh; lab_pool_ensure"
        script = self.tool / "probe.sh"
        script.write_text("#!/usr/bin/env bash\nset -euo pipefail\ncd \"$(dirname \"$0\")\"\n" + probe + "\n")
        script.chmod(0o755)
        r = self.run_tool("probe.sh")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.calls(), ["pool-define-as sc dir --target /var/lib/libvirt/images/sc",
                                        "pool-build sc", "pool-start sc", "pool-autostart sc"])
        (self.fake / "calls").write_text("")
        self.assertEqual(self.run_tool("probe.sh").returncode, 0)   # there already: nothing to do
        self.assertEqual(self.calls(), [])
        # Without a namespace the pool is the host's `default`: used, never made.
        (self.fake / "pools").write_text("fleet /srv/fleet running yes\n")
        r = self.run_tool("probe.sh", ns=None)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("no storage pool 'default'", r.stderr)
        self.assertEqual(self.calls(), [])

    def test_a_portability_host_is_not_built_in_a_namespace(self):
        r = self.run_tool("vm/portability-host.sh", "build", "rocky9")
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("shared hypervisor", r.stderr)
        self.assertEqual(self.calls(), [])


if __name__ == "__main__":
    unittest.main()
