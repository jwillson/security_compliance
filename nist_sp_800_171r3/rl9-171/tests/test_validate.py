"""Unit tests for tools/validate.py. Run with `make test`."""
import copy
import importlib.util
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
_spec = importlib.util.spec_from_file_location("validate", ROOT / "tools/validate.py")
validate_mod = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(validate_mod)

CATALOG = {
    "requirements": [{"id": "03.01.08", "title": "Unsuccessful Logon Attempts",
                      "withdrawn": False}],
    "counts": {"withdrawn": 0},
}
OVERLAY = {
    "requirements": [{"id": "03.01.08", "disposition": "technical",
                      "tasks": "tasks/ac.yml", "checks": ["lockout"],
                      "host_scope": "faillock"}],
    "odp": {"lockout_attempts": 3},
}
CHECKS = {"checks": [{
    "id": "lockout", "description": "faillock deny equals the ODP",
    "command": "grep -oP '(?<=^deny=).*' /etc/security/faillock.conf",
    "expect_int": "== {odp.lockout_attempts}",
}]}


def errors(overlay=None, checks=None):
    return validate_mod.validate(copy.deepcopy(CATALOG),
                                 overlay or copy.deepcopy(OVERLAY),
                                 checks or copy.deepcopy(CHECKS))[0]


def with_check(**changes):
    checks = copy.deepcopy(CHECKS)
    checks["checks"][0].update(changes)
    for key, value in changes.items():
        if value is None:
            del checks["checks"][0][key]
    return checks


class OdpCoverage(unittest.TestCase):

    def test_baseline_fixture_is_clean(self):
        self.assertEqual(errors(), [])

    def test_a_mention_in_the_description_asserts_nothing(self):
        e = errors(checks=with_check(
            expect_int="== 3",
            description="faillock deny equals {odp.lockout_attempts}"))
        self.assertIn("machine ODP 'lockout_attempts' is asserted by no check", e)

    def test_a_check_no_requirement_runs_asserts_nothing(self):
        checks = with_check(expect_int="== 3")
        checks["checks"].append({"id": "dead", "description": "never run",
                                 "command": "echo {odp.lockout_attempts}",
                                 "expect_output": "{odp.lockout_attempts}"})
        e = errors(checks=checks)
        self.assertIn("machine ODP 'lockout_attempts' is asserted by no check", e)

    def test_unknown_odp_anywhere_is_an_error(self):
        e = errors(checks=with_check(description="see {odp.nonexistent}"))
        self.assertTrue(any("unknown ODP 'nonexistent'" in x for x in e))


class CheckShape(unittest.TestCase):

    def test_invalid_regex_is_caught_before_a_host_run(self):
        e = errors(checks=with_check(expect_int=None, expect_match="(unclosed"))
        self.assertTrue(any("not a valid regex" in x for x in e), e)

    def test_regex_is_compiled_after_odp_expansion(self):
        e = errors(checks=with_check(expect_int=None,
                                     expect_match="^deny={odp.lockout_attempts}$"))
        self.assertEqual(e, [])

    def test_malformed_expect_int(self):
        for spec in ("=> 3", "== three", "==3"):
            e = errors(checks=with_check(expect_int=spec))
            self.assertTrue(any("is not '<op> <integer>'" in x for x in e), spec)

    def test_unknown_key_is_a_typo(self):
        e = errors(checks=with_check(manual_if_abesnt=True))
        self.assertIn("check lockout has unknown key 'manual_if_abesnt'", e)

    def test_expect_empty_must_be_true(self):
        e = errors(checks=with_check(expect_int=None, expect_empty=False))
        self.assertIn("check lockout expect_empty must be true", e)

    def test_ok_rc_must_be_exit_statuses(self):
        for bad in ([], [0, "1"], [256], 0, [True]):
            e = errors(checks=with_check(ok_rc=bad))
            self.assertTrue(any("ok_rc must be a list" in x for x in e), bad)
        self.assertEqual(errors(checks=with_check(ok_rc=[0, 1])), [])

    def test_ok_rc_and_expect_rc_do_not_mix(self):
        e = errors(checks=with_check(expect_int=None, expect_rc=0, ok_rc=[0]))
        self.assertTrue(any("expect_rc already decides" in x for x in e), e)


class Dispositions(unittest.TestCase):

    def test_technical_may_not_carry_a_residual(self):
        overlay = copy.deepcopy(OVERLAY)
        overlay["requirements"][0]["residual"] = "the organization still owes"
        self.assertTrue(any("technical but states a residual" in x
                            for x in errors(overlay=overlay)))

    def test_partial_must_state_its_residual(self):
        overlay = copy.deepcopy(OVERLAY)
        overlay["requirements"][0]["disposition"] = "partial"
        self.assertTrue(any("partial but does not state the residual" in x
                            for x in errors(overlay=overlay)))


class Repository(unittest.TestCase):
    """The tracked catalog, overlay and checks themselves."""

    def test_repository_validates(self):
        self.assertEqual(validate_mod.main(), 0)


if __name__ == "__main__":
    unittest.main()
