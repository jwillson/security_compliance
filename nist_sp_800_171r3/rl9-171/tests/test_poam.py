"""Unit tests for roles/nist_800_171/files/nist_poam.py. Run with `make test`."""
import importlib.util
import json
import os
import stat
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
_spec = importlib.util.spec_from_file_location("nist_poam", ROOT / "roles/nist_800_171/files/nist_poam.py")
poam = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(poam)


def req(rid, status, disposition="technical", residual="", failed=()):
    checks = [{"id": c, "description": f"{c} description", "status": "FAIL"} for c in failed]
    checks.append({"id": "ok", "description": "fine", "status": "PASS"})
    return {"id": rid, "title": f"title {rid}", "status": status,
            "disposition": disposition, "residual": residual, "checks": checks}


def assessment(*reqs, at=None, scope="all requirements", unsupported=None):
    at = at or datetime.now(timezone.utc)
    meta = {"assessed_at": at.isoformat(), "scope": scope}
    if unsupported:
        meta["unsupported"] = unsupported
    return {"assessment": meta, "requirements": list(reqs)}


FAILING = req("03.04.06", "FAIL", failed=("cm-06-tmp-separate",))
PARTIAL = req("03.15.02", "MANUAL", "partial", residual="Threats and roles are\n authored by the owner.")
ORG = req("03.02.01", "NOT_APPLICABLE", "organizational")
PASSING = req("03.01.11", "PASS")


def keyed(rows):
    return {(r["Requirement"], r["Kind"], r["Status"]): r for r in rows}


class Findings(unittest.TestCase):
    def test_a_failing_requirement_is_a_deviation_named_by_its_failed_checks(self):
        f = poam.findings(assessment(FAILING))
        self.assertEqual(f[("03.04.06", "deviation")]["weakness"], "cm-06-tmp-separate description")

    def test_a_partial_requirement_is_a_residual_carrying_the_overlay_text(self):
        f = poam.findings(assessment(PARTIAL))
        self.assertEqual(f[("03.15.02", "residual")]["weakness"],
                         "Threats and roles are authored by the owner.")

    def test_a_failing_partial_requirement_is_both(self):
        both = req("03.08.09", "FAIL", "partial", residual="Backups off site.", failed=("x",))
        self.assertEqual(set(poam.findings(assessment(both))),
                         {("03.08.09", "deviation"), ("03.08.09", "residual")})

    def test_organizational_and_passing_requirements_are_not_items(self):
        self.assertEqual(poam.findings(assessment(ORG, PASSING)), {})


class Merge(unittest.TestCase):
    def first(self):
        return poam.merge([], poam.findings(assessment(FAILING, PARTIAL)), "2026-09-26")

    def test_a_first_run_opens_one_item_per_finding(self):
        rows = self.first()
        self.assertEqual({r["POAM ID"] for r in rows},
                         {"03.04.06-D-20260926", "03.15.02-R-20260926"})
        self.assertTrue(all(r["Status"] == "Open" and r["First Observed"] == "2026-09-26" for r in rows))

    def test_the_owners_columns_survive_the_next_run(self):
        rows = self.first()
        for r in rows:
            r.update({"Scheduled Completion": "2026-12-01", "Responsible Party": "ops",
                      "Resources Required": "a disk", "Milestones": "m1", "Owner Notes": "n"})
        again = poam.merge(rows, poam.findings(assessment(FAILING, PARTIAL)), "2026-09-27")
        self.assertEqual(len(again), 2)
        for r in again:
            self.assertEqual((r["Scheduled Completion"], r["Responsible Party"], r["Owner Notes"]),
                             ("2026-12-01", "ops", "n"))
            self.assertEqual(r["First Observed"], "2026-09-26")

    def test_a_resolved_deviation_is_closed_and_kept(self):
        rows = poam.merge(self.first(), poam.findings(assessment(PARTIAL)), "2026-10-01")
        closed = keyed(rows)[("03.04.06", "deviation", "Closed")]
        self.assertEqual(closed["Closed On"], "2026-10-01")
        self.assertIn("passes", closed["Closure"])
        self.assertEqual(len(rows), 2)

    def test_a_deviation_that_fails_again_is_a_new_item(self):
        rows = poam.merge(self.first(), poam.findings(assessment(PARTIAL)), "2026-10-01")
        rows = poam.merge(rows, poam.findings(assessment(FAILING, PARTIAL)), "2026-10-05")
        ids = sorted(r["POAM ID"] for r in rows if r["Requirement"] == "03.04.06")
        self.assertEqual(ids, ["03.04.06-D-20260926", "03.04.06-D-20261005"])

    def test_a_residual_the_owner_closed_is_not_reopened(self):
        rows = self.first()
        keyed(rows)[("03.15.02", "residual", "Open")].update(Status="Closed", Closure="SSP approved")
        rows = poam.merge(rows, poam.findings(assessment(FAILING, PARTIAL)), "2026-09-27")
        residuals = [r for r in rows if r["Kind"] == "residual"]
        self.assertEqual([(r["Status"], r["Closure"]) for r in residuals], [("Closed", "SSP approved")])

    def test_a_risk_accepted_deviation_stays_accepted_while_it_fails(self):
        rows = self.first()
        keyed(rows)[("03.04.06", "deviation", "Open")]["Status"] = "Risk Accepted"
        rows = poam.merge(rows, poam.findings(assessment(FAILING, PARTIAL)), "2026-09-27")
        deviations = [r for r in rows if r["Kind"] == "deviation"]
        self.assertEqual([r["Status"] for r in deviations], ["Risk Accepted"])

    def test_a_residual_closes_itself_only_when_no_longer_partial(self):
        rows = poam.merge(self.first(), poam.findings(assessment(FAILING)), "2026-09-27")
        closed = keyed(rows)[("03.15.02", "residual", "Closed")]
        self.assertIn("no longer classed partial", closed["Closure"])

    def test_ids_stay_unique_within_a_day(self):
        rows = poam.merge(self.first(), poam.findings(assessment(PARTIAL)), "2026-09-26")
        rows = poam.merge(rows, poam.findings(assessment(FAILING, PARTIAL)), "2026-09-26")
        ids = [r["POAM ID"] for r in rows]
        self.assertEqual(len(ids), len(set(ids)))


class Scope(unittest.TestCase):
    """A scoped assessment closed every item outside its scope, and a residual
    it closed was never reopened (review 2026-09-26)."""

    def first(self):
        return poam.merge([], poam.findings(assessment(FAILING, PARTIAL)), "2026-09-26")

    def test_a_family_run_is_refused(self):
        with self.assertRaises(poam.RegisterError):
            poam.check_assessment(assessment(PASSING, scope="03.05"))

    def test_an_unsupported_run_is_refused(self):
        with self.assertRaises(poam.RegisterError):
            poam.check_assessment(assessment(PASSING, unsupported=["not running as root"]))

    def test_a_full_run_is_accepted(self):
        poam.check_assessment(assessment(PASSING))

    def test_an_item_not_looked_at_is_left_open(self):
        a = assessment(PASSING)          # says nothing about 03.04.06 or 03.15.02
        rows = poam.merge(self.first(), poam.findings(a), "2026-10-01", poam.assessed(a))
        self.assertEqual([r["Status"] for r in rows], ["Open", "Open"])

    def test_an_item_looked_at_and_passing_is_closed(self):
        a = assessment(req("03.04.06", "PASS"), PARTIAL)
        rows = poam.merge(self.first(), poam.findings(a), "2026-10-01", poam.assessed(a))
        closed = keyed(rows)[("03.04.06", "deviation", "Closed")]
        self.assertTrue(closed["Closure"].startswith("auto: "))

    def test_a_residual_the_generator_closed_reopens_when_partial_again(self):
        rows = poam.merge(self.first(), poam.findings(assessment(FAILING, req("03.15.02", "PASS"))), "2026-10-01")
        self.assertEqual(keyed(rows)[("03.15.02", "residual", "Closed")]["Closure"],
                         "auto: the requirement is no longer classed partial")
        rows = poam.merge(rows, poam.findings(assessment(FAILING, PARTIAL)), "2026-10-05")
        self.assertIn(("03.15.02", "residual", "Open"), keyed(rows))

    def test_a_residual_the_owner_closed_stays_closed(self):
        rows = self.first()
        keyed(rows)[("03.15.02", "residual", "Open")].update(Status="Closed", Closure="SSP approved")
        rows = poam.merge(rows, poam.findings(assessment(FAILING, PARTIAL)), "2026-10-05")
        self.assertNotIn(("03.15.02", "residual", "Open"), keyed(rows))


class OwnerEdits(unittest.TestCase):
    """The owner edits the register in a spreadsheet; the next run must not
    destroy what they saved (review 2026-09-26)."""

    def rows(self):
        return poam.merge([], poam.findings(assessment(FAILING, PARTIAL)), "2026-09-26")

    def test_a_byte_order_mark_does_not_erase_the_ids(self):
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "poam.csv")
            poam.save(self.rows(), path)
            with open(path, "rb") as fh:
                body = fh.read()
            with open(path, "wb") as fh:
                fh.write(b"\xef\xbb\xbf" + body)            # "CSV UTF-8" from a spreadsheet
            rows = poam.load(path)
            self.assertEqual(sorted(r["POAM ID"] for r in rows),
                             ["03.04.06-D-20260926", "03.15.02-R-20260926"])

    def test_a_column_the_owner_added_is_kept(self):
        rows = self.rows()
        for r in rows:
            r["Cost"] = "12"
        again = poam.merge(rows, poam.findings(assessment(FAILING, PARTIAL)), "2026-09-27")
        self.assertEqual([r["Cost"] for r in again], ["12", "12"])
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "poam.csv")
            poam.save(again, path)
            self.assertEqual(poam.load(path)[0]["Cost"], "12")
            self.assertEqual(poam.columns(again), poam.FIELDS + ["Cost"])

    def test_a_file_missing_a_column_is_refused_not_rewritten(self):
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "poam.csv")
            with open(path, "w") as fh:
                fh.write("POAM ID;Requirement;Title\n1;03.04.06;t\n")    # another delimiter
            with self.assertRaises(poam.RegisterError):
                poam.load(path)

    def test_an_unknown_status_is_refused(self):
        rows = self.rows()
        rows[0]["Status"] = "In Progress"
        with self.assertRaises(poam.RegisterError):
            poam.merge(rows, {}, "2026-09-27")

    def test_two_active_items_for_one_finding_are_refused(self):
        rows = self.rows() + self.rows()
        with self.assertRaises(poam.RegisterError):
            poam.merge(rows, {}, "2026-09-27")

    def test_the_previous_register_is_kept_as_a_backup(self):
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "poam.csv")
            poam.save(self.rows(), path)
            before = open(path).read()
            poam.save(poam.merge(self.rows(), {}, "2026-10-01"), path, backup=True)
            self.assertEqual(open(path + ".bak").read(), before)
            self.assertNotEqual(open(path).read(), before)
            self.assertEqual([f for f in os.listdir(d) if f.startswith(".poam-")], [])


class Files(unittest.TestCase):
    def test_the_register_round_trips_and_is_private(self):
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "poam.csv")
            rows = poam.merge([], poam.findings(assessment(FAILING, PARTIAL)), "2026-09-26")
            poam.save(rows, path)
            self.assertEqual(stat.S_IMODE(os.stat(path).st_mode), 0o600)
            self.assertEqual(poam.load(path), rows)

    def run_main(self, a):
        with tempfile.TemporaryDirectory() as d:
            ap, reg = os.path.join(d, "a.json"), os.path.join(d, "poam.csv")
            with open(ap, "w") as fh:
                json.dump(a, fh)
            rc = poam.main(["--assessment", ap, "--register", reg, "--snapshot-dir", d])
            return rc, os.path.exists(reg), sorted(os.listdir(d))

    def test_main_writes_the_register_and_a_dated_snapshot(self):
        rc, exists, files = self.run_main(assessment(FAILING, PARTIAL))
        self.assertEqual((rc, exists), (0, True))
        self.assertTrue(any(f.startswith("poam-") and f.endswith(".csv") for f in files))

    def test_main_refuses_a_stale_assessment(self):
        stale = assessment(PASSING, at=datetime.now(timezone.utc) - timedelta(hours=48))
        rc, exists, _ = self.run_main(stale)
        self.assertEqual((rc, exists), (1, False))

    def test_main_refuses_a_scoped_assessment(self):
        rc, exists, _ = self.run_main(assessment(PASSING, scope="03.05"))
        self.assertEqual((rc, exists), (2, False))


if __name__ == "__main__":
    unittest.main()
