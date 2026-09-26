#!/usr/bin/env python3
"""03.12.02 Plan of Action and Milestones: a register that persists.

    nist_poam.py --assessment FILE --register FILE [--snapshot-dir DIR]
                 [--today YYYY-MM-DD] [--max-age-hours N]

Merges the latest assessment into a POA&M register kept across runs. The
generator used to write a fresh dated file each time, so whatever the owner
entered - completion dates, responsible party, resources, milestones - was
never carried into the next one, and a resolved item simply vanished
(DEFECTS 6.6). Now:

  * a requirement that FAILs (or ERRORs) is a `deviation` item - the host is
    wrong; its weakness is the failing checks;
  * a requirement classed `partial` is a `residual` item - the host does its
    part, and what the organization still owes is the overlay's residual
    text (the overlay's 03.12.02 host_scope always promised these; the old
    generator emitted only FAILs - DEFECTS 6.7);
  * purely organizational requirements are not items here: they have no host
    part, and the register of what they need is organizational-requirements.md.

Merging, by requirement and kind, never by rewriting:

  * the owner's columns are carried forward on every run;
  * an active item (Open, or Risk Accepted by the owner) is updated in place;
  * a deviation that no longer fails is Closed with the date and reason -
    kept, not deleted; if it fails again later it is a new item;
  * a residual is closed by the owner (Closed or Risk Accepted), since the
    host can never evidence it; the generator reopens nothing the owner closed,
    and closes a residual itself only if the requirement stops being partial.

The register is written atomically at mode 0600, and a dated snapshot of it
is kept for the record. An assessment older than --max-age-hours is refused:
merging stale results would close items that are still open.

Stdlib only; tests in tests/test_poam.py.
"""
from __future__ import annotations

import argparse
import csv
import json
import os
import sys
from datetime import date, datetime, timezone

FIELDS = [
    "POAM ID", "Requirement", "Title", "Kind", "Weakness", "Source",
    "First Observed", "Status", "Closed On", "Closure",
    "Scheduled Completion", "Responsible Party", "Resources Required",
    "Milestones", "Owner Notes",
]
OWNER_FIELDS = ["Scheduled Completion", "Responsible Party", "Resources Required",
                "Milestones", "Owner Notes"]
OPEN, CLOSED, ACCEPTED = "Open", "Closed", "Risk Accepted"
ACTIVE = (OPEN, ACCEPTED)
DEVIATION, RESIDUAL = "deviation", "residual"


def findings(assessment: dict) -> dict:
    """{(requirement, kind): {title, weakness, source}} from one assessment."""
    found = {}
    for r in assessment.get("requirements", []):
        rid, title = r.get("id", ""), r.get("title", "")
        if r.get("status") in ("FAIL", "ERROR"):
            bad = [c for c in r.get("checks", []) if c.get("status") in ("FAIL", "ERROR")]
            weakness = "; ".join(c.get("description") or c.get("id", "") for c in bad) or title
            found[(rid, DEVIATION)] = {"title": title, "weakness": weakness[:500],
                                       "source": "Automated assessment (nist-assess)"}
        if r.get("disposition") == "partial":
            residual = " ".join((r.get("residual") or "").split()) or "Organizational evidence required"
            found[(rid, RESIDUAL)] = {"title": title, "weakness": residual[:500],
                                      "source": "Overlay residual (organizational obligation)"}
    return found


def _new_id(rid: str, kind: str, today: str, taken: set) -> str:
    base = f"{rid}-{'D' if kind == DEVIATION else 'R'}-{today.replace('-', '')}"
    pid, n = base, 2
    while pid in taken:
        pid, n = f"{base}-{n}", n + 1
    return pid


def merge(rows: list[dict], found: dict, today: str) -> list[dict]:
    """The register after this assessment. Never drops a row."""
    rows = [{f: row.get(f, "") for f in FIELDS} for row in rows]
    taken = {row["POAM ID"] for row in rows}
    active = {(row["Requirement"], row["Kind"]): row for row in rows if row["Status"] in ACTIVE}
    owner_closed_residuals = {row["Requirement"] for row in rows
                              if row["Kind"] == RESIDUAL and row["Status"] == CLOSED}

    for key, f in found.items():
        rid, kind = key
        row = active.get(key)
        if row is not None:
            row["Title"], row["Weakness"], row["Source"] = f["title"], f["weakness"], f["source"]
            continue
        if kind == RESIDUAL and rid in owner_closed_residuals:
            continue                                   # the owner closed it, with evidence
        pid = _new_id(rid, kind, today, taken)
        taken.add(pid)
        rows.append({**{fld: "" for fld in FIELDS},
                     "POAM ID": pid, "Requirement": rid, "Title": f["title"], "Kind": kind,
                     "Weakness": f["weakness"], "Source": f["source"],
                     "First Observed": today, "Status": OPEN})

    for key, row in active.items():
        if key in found:
            continue
        row["Status"], row["Closed On"] = CLOSED, today
        row["Closure"] = ("resolved: the requirement passes the assessment"
                          if row["Kind"] == DEVIATION else
                          "the requirement is no longer classed partial")

    order = {OPEN: 0, ACCEPTED: 1, CLOSED: 2}
    rows.sort(key=lambda r: (order.get(r["Status"], 3), r["Requirement"], r["Kind"], r["POAM ID"]))
    return rows


def load(path: str) -> list[dict]:
    if not os.path.exists(path):
        return []
    with open(path, newline="") as fh:
        return list(csv.DictReader(fh))


def save(rows: list[dict], path: str) -> None:
    tmp = f"{path}.tmp"
    old = os.umask(0o077)
    try:
        with open(tmp, "w", newline="") as fh:
            w = csv.DictWriter(fh, fieldnames=FIELDS, extrasaction="ignore")
            w.writeheader()
            w.writerows(rows)
        os.chmod(tmp, 0o600)
        os.replace(tmp, path)
    finally:
        os.umask(old)


def assessment_age_hours(assessment: dict, now: datetime) -> float:
    stamp = assessment.get("assessment", {}).get("assessed_at", "")
    try:
        then = datetime.fromisoformat(stamp)
    except ValueError:
        return float("inf")
    if then.tzinfo is None:
        then = then.replace(tzinfo=timezone.utc)
    return (now - then).total_seconds() / 3600


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--assessment", required=True)
    ap.add_argument("--register", required=True)
    ap.add_argument("--snapshot-dir")
    ap.add_argument("--today", default=date.today().isoformat())
    ap.add_argument("--max-age-hours", type=float, default=24.0)
    args = ap.parse_args(argv)

    try:
        with open(args.assessment) as fh:
            assessment = json.load(fh)
    except (OSError, ValueError) as e:
        print(f"no usable assessment at {args.assessment}: {e} - run nist-assess first", file=sys.stderr)
        return 1
    age = assessment_age_hours(assessment, datetime.now(timezone.utc))
    if age > args.max_age_hours:
        print(f"refusing: the assessment is {age:.0f} h old (limit {args.max_age_hours:.0f} h); "
              "merging it would close items that are still open - run nist-assess first",
              file=sys.stderr)
        return 1

    rows = merge(load(args.register), findings(assessment), args.today)
    save(rows, args.register)
    if args.snapshot_dir:
        save(rows, os.path.join(args.snapshot_dir, f"poam-{args.today.replace('-', '')}.csv"))

    def count(kind, status):
        return sum(1 for r in rows if r["Kind"] == kind and r["Status"] == status)
    print(f"{count(DEVIATION, OPEN)} open deviation(s), {count(RESIDUAL, OPEN)} open residual(s), "
          f"{sum(1 for r in rows if r['Status'] == ACCEPTED)} risk-accepted, "
          f"{sum(1 for r in rows if r['Status'] == CLOSED)} closed; register {args.register}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
