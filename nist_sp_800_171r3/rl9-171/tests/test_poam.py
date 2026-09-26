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


def assessment(*reqs, at=None):
    at = at or datetime.now(timezone.utc)
    return {"assessment": {"assessed_at": at.isoformat()}, "requirements": list(reqs)}


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


if __name__ == "__main__":
    unittest.main()
