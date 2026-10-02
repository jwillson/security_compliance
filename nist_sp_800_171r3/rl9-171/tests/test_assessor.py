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

    def test_weak_ssh_macs_fail(self):
        for cid in ("ia-04-sshd-macs", "sc-15-ssh-macs"):
            for weak in ("hmac-sha1-etm@openssh.com", "umac-64@openssh.com", "umac-64-etm@openssh.com",
                         "hmac-sha1", "hmac-md5"):
                with self.subTest(cid=cid, mac=weak):
                    self.assertEqual(self.status(cid, self.SSHD,
                                     f"'macs hmac-sha2-512,{weak},hmac-sha2-256'"), "FAIL")
            with self.subTest(cid=cid, mac="approved"):
                self.assertEqual(self.status(cid, self.SSHD,
                                 "'macs hmac-sha2-256-etm@openssh.com,hmac-sha2-512'"), "PASS")

    REPOS = "dnf -q repolist --enabled"

    def test_only_the_named_repositories_pass(self):
        for cid in ("sa-02-no-unsupported-repos", "sr-03-no-unauthorized-repos"):
            with self.subTest(cid):
                self.assertEqual(self.status(cid, self.REPOS, "-e 'repo id\\nbaseos x\\nappstream x\\nextras x'"), "PASS")
                self.assertEqual(self.status(cid, self.REPOS, "-e 'repo id\\nbaseos-evil x'"), "FAIL")
                self.assertEqual(self.status(cid, self.REPOS, "-e 'repo id\\nrocky-mirror x'"), "FAIL")

    def test_journal_retention_must_be_the_odp(self):
        reads = "systemd-analyze cat-config systemd/journald.conf 2>/dev/null"
        days = self.odp["audit_retention_days"]
        self.assertEqual(self.status("ir-02-journald-retention", reads, "'#MaxRetentionSec='"), "FAIL")
        self.assertEqual(self.status("ir-02-journald-retention", reads,
                                     f"-e '#MaxRetentionSec=\\nMaxRetentionSec={days}day'"), "PASS")

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


class CollectorReceiving(unittest.TestCase):
    """au-05-collector-receiving against a fake collector tree (issue #10).

    It passed on an audit-shaped line in any file, of any age, under any
    directory - so a line typed with `logger` into a stale file passed.
    """

    @classmethod
    def setUpClass(cls):
        import yaml
        cls.check = next(c for c in yaml.safe_load((ROOT / "audit/checks.yml").read_text())["checks"]
                         if c["id"] == "au-05-collector-receiving")

    def status(self, files):
        import os, time
        with tempfile.TemporaryDirectory() as d:
            remote = Path(d, "remote")
            for rel, age_days in files:
                f = remote / rel
                f.parent.mkdir(parents=True, exist_ok=True)
                f.write_text("Oct  1 byo-rl9-01 audispd[9]: node=x type=SYSCALL msg=audit(1.2:3): arch=c000003e\n")
                t = time.time() - age_days * 86400
                os.utime(f, (t, t))
            Path(d, "collector.conf").write_text("x")
            Path(d, "status").write_text(f"directory={remote}\n")
            check = dict(self.check)
            cmd = check["command"]
            for real in ("/etc/rsyslog.d/10-nist-collector.conf", "/etc/nist-800-171/log-collector-status"):
                self.assertIn(real, cmd)
            check["command"] = (cmd.replace("/etc/rsyslog.d/10-nist-collector.conf", f"{d}/collector.conf")
                                   .replace("/etc/nist-800-171/log-collector-status", f"{d}/status"))
            return na.Runner({}).run(check)["status"]

    def test_a_recent_audit_trail_from_a_peer_passes(self):
        self.assertEqual(self.status([("byo-rl9-01/audispd.log", 0)]), "PASS")

    def test_an_audit_line_in_another_file_does_not(self):
        self.assertEqual(self.status([("byo-rl9-01/logger.log", 0)]), "FAIL")

    def test_a_stale_trail_does_not(self):
        self.assertEqual(self.status([("byo-rl9-01/audispd.log", 3)]), "FAIL")

    def test_an_unattributed_sender_does_not(self):
        self.assertEqual(self.status([("unknown-10.0.0.9/audispd.log", 0)]), "FAIL")


class GrubChecks(unittest.TestCase):
    """The 03.10.07 checks against a fake /boot (issue #8)."""

    STUB = "search --no-floppy --fs-uuid --set=dev x\nset prefix=($dev)/grub2\nconfigfile $prefix/grub.cfg\n"
    STOCK = "### BEGIN /etc/grub.d/01_users ###\nif [ -f ${prefix}/user.cfg ]; then\n  source ${prefix}/user.cfg\n  if [ -n \"${GRUB2_PASSWORD}\" ]; then\n    set superusers=\"root\"\n    export superusers\n    password_pbkdf2 root ${GRUB2_PASSWORD}\n  fi\nfi\n"
    HASH = "grub.pbkdf2.sha512.10000." + "AB" * 32 + "." + "CD" * 64

    @classmethod
    def setUpClass(cls):
        import yaml
        cls.checks = {c["id"]: c for c in yaml.safe_load((ROOT / "audit/checks.yml").read_text())["checks"]}

    def status(self, cid, grub_cfg, user_cfg=None, efi_cfg=None, entries=()):
        with tempfile.TemporaryDirectory() as d:
            b = Path(d, "boot")
            (b / "grub2").mkdir(parents=True)
            (b / "grub2/grub.cfg").write_text(grub_cfg)
            if user_cfg is not None:
                (b / "grub2/user.cfg").write_text(user_cfg)
            if efi_cfg is not None:
                (b / "efi/EFI/rocky").mkdir(parents=True)
                (b / "efi/EFI/rocky/grub.cfg").write_text(efi_cfg)
            (b / "loader/entries").mkdir(parents=True)
            for i, e in enumerate(entries):
                (b / f"loader/entries/e{i}.conf").write_text(e)
            check = dict(self.checks[cid])
            self.assertIn("/boot/", check["command"])
            check["command"] = check["command"].replace("/boot/", f"{b}/")
            return na.Runner({}).run(check)["status"]

    def test_stock_user_cfg_password_passes(self):
        self.assertEqual(self.status("pe-07-grub-password", self.STOCK, f"GRUB2_PASSWORD={self.HASH}\n",
                                     self.STUB), "PASS")

    def test_a_commented_inline_hash_does_not(self):
        cfg = f"# password_pbkdf2 root {self.HASH}\n"
        self.assertEqual(self.status("pe-07-grub-password", cfg, None, self.STUB), "FAIL")

    def test_an_inline_hash_without_superusers_does_not(self):
        cfg = f"password_pbkdf2 root {self.HASH}\n"
        self.assertEqual(self.status("pe-07-grub-password", cfg, None, self.STUB), "FAIL")
        cfg = f"set superusers=\"root\"\npassword_pbkdf2 root {self.HASH}\n"
        self.assertEqual(self.status("pe-07-grub-password", cfg, None, self.STUB), "PASS")

    def test_a_full_efi_config_is_what_grub_reads(self):
        # The EFI grub.cfg is a full configuration with no password: GRUB never
        # reads /boot/grub2/grub.cfg, whatever that file says.
        self.assertEqual(self.status("pe-07-grub-password", self.STOCK, f"GRUB2_PASSWORD={self.HASH}\n",
                                     "menuentry 'x' { linux /vmlinuz }\n"), "FAIL")

    def test_every_boot_entry_must_be_unrestricted(self):
        ok = "title x\nlinux /vmlinuz\ngrub_arg --unrestricted\n"
        bad = "title y\nlinux /vmlinuz\n"
        self.assertEqual(self.status("pe-07-boot-entries-unrestricted", self.STOCK, entries=[ok, ok]), "PASS")
        self.assertEqual(self.status("pe-07-boot-entries-unrestricted", self.STOCK, entries=[ok, bad]), "FAIL")
        self.assertEqual(self.status("pe-07-boot-entries-unrestricted", self.STOCK, entries=[]), "FAIL")


class KeyOnDisk(unittest.TestCase):
    """mp-09-luks-no-key-on-disk against fake /etc and /root (issue #11).

    systemd-cryptsetup also loads /etc/cryptsetup-keys.d/<volume>.key when
    crypttab says "none", which the check never looked at.
    """

    @classmethod
    def setUpClass(cls):
        import yaml
        cls.check = next(c for c in yaml.safe_load((ROOT / "audit/checks.yml").read_text())["checks"]
                         if c["id"] == "mp-09-luks-no-key-on-disk")

    def status(self, crypttab, files=()):
        with tempfile.TemporaryDirectory() as d:
            Path(d, "etc").mkdir(); Path(d, "root").mkdir()
            Path(d, "etc/crypttab").write_text(crypttab)
            for f in files:
                Path(d, f).parent.mkdir(parents=True, exist_ok=True)
                Path(d, f).write_text("key")
            check = dict(self.check)
            check["command"] = check["command"].replace("/etc/", f"{d}/etc/").replace("/root/", f"{d}/root/")
            return na.Runner({}).run(check)["status"]

    TPM = "cui_data /dev/vg_sys/lv_cui none luks,discard\n"

    def test_tpm_unlock_and_no_key_passes(self):
        self.assertEqual(self.status(self.TPM), "PASS")

    def test_a_key_named_in_crypttab_fails(self):
        self.assertEqual(self.status("cui_data /dev/vg_sys/lv_cui /root/.luks-key luks\n",
                                     ["root/.luks-key"]), "FAIL")

    def test_a_key_systemd_would_load_from_cryptsetup_keys_d_fails(self):
        self.assertEqual(self.status(self.TPM, ["etc/cryptsetup-keys.d/cui_data.key"]), "FAIL")

if __name__ == "__main__":
    unittest.main()
