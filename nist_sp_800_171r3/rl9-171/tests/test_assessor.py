"""Unit tests for audit/nist-assess.

The checks run real commands through bash, as they do on a host, so no tool
is mocked: a failing command is `exit 3`, a missing one is a name that does
not exist. Run with `make test`.
"""
import argparse
import importlib.machinery
import importlib.util
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ASSESSOR = ROOT / "audit/nist-assess"

_loader = importlib.machinery.SourceFileLoader("nist_assess", str(ASSESSOR))
_spec = importlib.util.spec_from_loader("nist_assess", _loader)
na = importlib.util.module_from_spec(_spec)
_loader.exec_module(na)

MISSING = "nist-test-no-such-tool"


def run(odp=None, **check):
    check.setdefault("id", "t")
    check.setdefault("description", "test check")
    return na.Runner(odp or {}).run(check)


class AbsenceAssertions(unittest.TestCase):
    """expect_empty and expect_no_match pass on nothing - so must be gated."""

    def test_empty_output_from_a_clean_command_passes(self):
        self.assertEqual(run(command="true", expect_empty=True)["status"], "PASS")

    def test_empty_output_from_a_failed_command_is_error(self):
        r = run(command="echo 'metadata unavailable' >&2; exit 3", expect_empty=True)
        self.assertEqual(r["status"], "ERROR")
        self.assertIn("exit status 3", r["evidence"])
        self.assertIn("metadata unavailable", r["evidence"])

    def test_no_match_on_a_failed_command_is_error(self):
        # sshd -T on a broken config: nothing printed, so no weak cipher seen.
        r = run(command="exit 255", expect_no_match="3des|-cbc")
        self.assertEqual(r["status"], "ERROR")

    def test_declared_ok_rc_admits_that_status(self):
        # grep finding nothing exits 1: the clean result for an absence check.
        r = run(command="exit 1", expect_empty=True, ok_rc=[0, 1])
        self.assertEqual(r["status"], "PASS")

    def test_status_outside_ok_rc_is_error(self):
        r = run(command="exit 2", expect_empty=True, ok_rc=[0, 1])
        self.assertEqual(r["status"], "ERROR")

    def test_a_deviation_stays_a_fail_whatever_the_status(self):
        # find | head -20 dies of SIGPIPE when there are many findings; the
        # output still shows the host is wrong.
        r = run(command="echo /tmp/world-writable; exit 141", expect_empty=True)
        self.assertEqual(r["status"], "FAIL")


class MissingCommands(unittest.TestCase):
    """A tool that is not installed observed nothing."""

    def test_exit_127_is_error(self):
        r = run(command=MISSING, expect_empty=True)
        self.assertEqual(r["status"], "ERROR")
        self.assertIn("command unavailable", r["evidence"])

    def test_not_found_text_matching_the_pattern_is_error(self):
        # ac-16-bluetooth-module matched /not found/ against bash's own
        # "modprobe: command not found".
        r = run(command=f"{MISSING} -n -v bluetooth 2>&1 | head -1",
                expect_match="(install /bin/false|not found|blacklist)")
        self.assertEqual(r["status"], "ERROR")

    def test_not_found_masked_by_a_fallback_is_error(self):
        r = run(command=f"{MISSING} | grep -c x || echo 0", expect_int="== 0")
        self.assertEqual(r["status"], "ERROR")

    def test_not_found_inside_a_function_is_error(self):
        # bash names the source "environment" there rather than the shell.
        r = run(command=f"f() {{ {MISSING}; }}; f; true", expect_empty=True)
        self.assertEqual(r["status"], "ERROR")

    def test_optional_component_degrades_to_manual(self):
        r = run(command=f"{MISSING} --version", expect_output="present",
                manual_if_absent=True)
        self.assertEqual(r["status"], "MANUAL")


class OtherAssertions(unittest.TestCase):

    def test_output_match(self):
        self.assertEqual(run(command="echo yes", expect_output="yes")["status"], "PASS")
        self.assertEqual(run(command="echo no", expect_output="yes")["status"], "FAIL")

    def test_counts_are_gated_only_when_they_opt_in(self):
        # A zero from a command that failed.
        self.assertEqual(run(command="echo 0; exit 1", expect_int="== 0",
                             ok_rc=[0])["status"], "ERROR")
        self.assertEqual(run(command="echo 0; exit 1",
                             expect_int="== 0")["status"], "PASS")

    def test_odp_values_expand_into_the_assertion(self):
        r = run(odp={"lockout_attempts": 3}, command="echo 3",
                expect_int="<= {odp.lockout_attempts}")
        self.assertEqual(r["status"], "PASS")
        self.assertEqual(r["expected"], "value <= 3")

    def test_unknown_odp_is_error(self):
        r = run(command="echo {odp.nope}", expect_output="x")
        self.assertEqual(r["status"], "ERROR")

    def test_malformed_regex_is_error_not_a_crash(self):
        r = run(command="echo x", expect_match="(unclosed")
        self.assertEqual(r["status"], "ERROR")
        self.assertIn("malformed pattern", r["evidence"])

    def test_locale_and_path_are_fixed(self):
        r = run(command='echo "$LC_ALL $PATH"', expect_match=r"^C /usr/local/sbin:")
        self.assertEqual(r["status"], "PASS")


class RequirementStatus(unittest.TestCase):
    """How check results roll up into a requirement."""

    def assess(self, disposition):
        overlay = {
            "meta": {"baseline": "b", "name": "n", "version": "0"},
            "requirements": [{"id": "03.99.01", "disposition": disposition,
                              "checks": ["ok"], "rationale": "r"}],
        }
        catalog = {"requirements": [{"id": "03.99.01", "title": "T"}]}
        checks = {"ok": {"id": "ok", "description": "d", "command": "echo 1",
                         "expect_output": "1"}}
        args = argparse.Namespace(requirement=None, family=None, verbose=False)
        return na.assess(overlay, catalog, checks, args)["requirements"][0]["status"]

    def test_technical_with_every_check_passing_is_pass(self):
        self.assertEqual(self.assess("technical"), "PASS")

    def test_partial_never_reports_pass(self):
        self.assertEqual(self.assess("partial"), "MANUAL")

    def test_organizational_is_not_applicable(self):
        self.assertEqual(self.assess("organizational"), "NOT_APPLICABLE")

    def test_unknown_disposition_does_not_fall_through_to_pass(self):
        self.assertEqual(self.assess("techincal"), "ERROR")


class SupportedPlatform(unittest.TestCase):

    def reasons(self, text, euid=0):
        with tempfile.NamedTemporaryFile("w", suffix="os-release") as fh:
            fh.write(text)
            fh.flush()
            return na.unsupported_reasons(Path(fh.name), euid=euid)

    def test_rocky_9_as_root_is_supported(self):
        self.assertEqual(self.reasons(
            'ID="rocky"\nID_LIKE="rhel centos fedora"\nVERSION_ID="9.6"\n'), [])

    def test_rhel_9_is_supported(self):
        self.assertEqual(self.reasons('ID="rhel"\nVERSION_ID="9.4"\n'), [])

    def test_rocky_8_is_not(self):
        self.assertEqual(len(self.reasons(
            'ID="rocky"\nID_LIKE="rhel centos fedora"\nVERSION_ID="8.10"\n')), 1)

    def test_ubuntu_is_not(self):
        self.assertEqual(len(self.reasons(
            'ID=ubuntu\nID_LIKE=debian\nVERSION_ID="24.04"\n'
            'PRETTY_NAME="Ubuntu 24.04"\n')), 1)

    def test_non_root_is_not(self):
        r = self.reasons('ID="rocky"\nID_LIKE="rhel"\nVERSION_ID="9.6"\n', euid=1000)
        self.assertEqual(len(r), 1)
        self.assertIn("root", r[0])

    def test_refuses_to_run_where_unsupported(self):
        if not na.unsupported_reasons():
            self.skipTest("this machine is a supported target")
        p = subprocess.run([sys.executable, str(ASSESSOR), "--requirement", "03.01.01"],
                           capture_output=True, text=True)
        self.assertNotEqual(p.returncode, 0)
        self.assertIn("refusing to assess", p.stderr)



class RealChecks(unittest.TestCase):
    """The shipped check definitions, against the value a defective host shows.

    Only the part of a command that reads the host is replaced - the check's
    own logic and assertion run as written - so each test fails on a check
    that would pass the defect (issue #9: ClientAliveInterval 0 and TMOUT 0
    passed, because "<= ODP" admits 0).
    """

    @classmethod
    def setUpClass(cls):
        import yaml
        cls.checks = {c["id"]: c for c in yaml.safe_load((ROOT / "audit/checks.yml").read_text())["checks"]}
        cls.odp = yaml.safe_load((ROOT / "catalog/overlay-rocky9.yml").read_text())["odp"]

    def status(self, cid, reads, value):
        check = dict(self.checks[cid])
        self.assertIn(reads, check["command"], f"{cid} no longer reads the host with {reads!r}")
        check["command"] = check["command"].replace(reads, f"echo {value}")
        return na.Runner(self.odp).run(check)["status"]

    SSHD = "sshd -T 2>/dev/null"
    LOGIN = "env -i HOME=/var/empty bash --login -c 'echo \"$TMOUT\"' 2>/dev/null"

    def test_clientalive_interval_zero_fails(self):
        for cid in ("ac-11-ssh-clientalive-interval", "ma-05-ssh-idle-terminate", "sc-09-clientalive-interval"):
            with self.subTest(cid):
                self.assertEqual(self.status(cid, self.SSHD, "clientaliveinterval 0"), "FAIL")
                self.assertEqual(self.status(cid, self.SSHD,
                                 f"clientaliveinterval {self.odp['ssh_client_alive_interval']}"), "PASS")

    def test_tmout_zero_or_unset_fails(self):
        for cid in ("ac-10-tmout-set", "ac-11-tmout-set", "sc-09-tmout"):
            with self.subTest(cid):
                self.assertEqual(self.status(cid, self.LOGIN, "0"), "FAIL")
                self.assertEqual(self.status(cid, self.LOGIN, "''"), "FAIL")
                self.assertEqual(self.status(cid, self.LOGIN, "900"), "PASS")
                self.assertEqual(self.status(cid, self.LOGIN, "3600"), "FAIL")


class AgingChecks(unittest.TestCase):
    """The account-aging checks against a fake /etc/passwd and /etc/shadow.

    Issue #12: the inactivity check accepted 99999 (any non-empty value), and
    the automation account - exempted by the owner (ODP-REVIEW I2) - must be
    skipped only when the role has declared it in aging-exempt.
    """

    @classmethod
    def setUpClass(cls):
        import yaml
        cls.checks = {c["id"]: c for c in yaml.safe_load((ROOT / "audit/checks.yml").read_text())["checks"]}
        cls.odp = yaml.safe_load((ROOT / "catalog/overlay-rocky9.yml").read_text())["odp"]

    def status(self, cid, shadow_fields, exempt=""):
        with tempfile.TemporaryDirectory() as d:
            Path(d, "passwd").write_text("alice:x:1000:1000::/home/alice:/bin/bash\n")
            Path(d, "shadow").write_text("alice:$6$x:" + shadow_fields + "\n")
            Path(d, "exempt").write_text(exempt)
            check = dict(self.checks[cid])
            cmd = check["command"]
            for real in ("/etc/passwd", "/etc/shadow", "/etc/nist-800-171/aging-exempt"):
                self.assertIn(real, cmd, f"{cid} no longer reads {real}")
            check["command"] = (cmd.replace("/etc/passwd", f"{d}/passwd")
                                   .replace("/etc/shadow", f"{d}/shadow")
                                   .replace("/etc/nist-800-171/aging-exempt", f"{d}/exempt"))
            return na.Runner(self.odp).run(check)["status"]

    def test_inactivity_must_be_the_odp(self):
        ok = f"20000:1:60:7:{self.odp['account_inactivity_days']}::"
        self.assertEqual(self.status("ac-01-inactive-users", ok), "PASS")
        self.assertEqual(self.status("ac-01-inactive-users", "20000:1:60:7:99999::"), "FAIL")
        self.assertEqual(self.status("ac-01-inactive-users", "20000:1:60:7:::"), "FAIL")
        self.assertEqual(self.status("ac-01-inactive-users", f"::60:7:{self.odp['account_inactivity_days']}::"), "FAIL")

    def test_a_declared_exemption_is_skipped_and_only_that(self):
        never = "20000:1:99999:7:::"
        self.assertEqual(self.status("ac-01-inactive-users", never), "FAIL")
        self.assertEqual(self.status("ac-01-inactive-users", never, "alice  # automation account\n"), "PASS")
        self.assertEqual(self.status("ac-01-inactive-users", never, "# alice\nbob\n"), "FAIL")
        self.assertEqual(self.status("ia-12-no-never-expire", never), "FAIL")
        self.assertEqual(self.status("ia-12-no-never-expire", never, "alice\n"), "PASS")

    def test_an_exempt_password_older_than_the_maximum_age_fails(self):
        import time
        today = int(time.time() // 86400)
        mx = self.odp["password_max_age"]
        fresh = f"{today - mx + 1}:1::7:::"
        stale = f"{today - mx - 1}:1::7:::"
        self.assertEqual(self.status("ia-12-exempt-rotated", fresh, "alice\n"), "PASS")
        self.assertEqual(self.status("ia-12-exempt-rotated", stale, "alice\n"), "FAIL")
        self.assertEqual(self.status("ia-12-exempt-rotated", "::::::", "alice\n"), "FAIL")
        self.assertEqual(self.status("ia-12-exempt-rotated", stale, ""), "PASS")

if __name__ == "__main__":
    unittest.main()
