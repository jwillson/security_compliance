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

  * the owner's columns are carried forward on every run, and so is any
    column the owner added to the file;
  * an active item (Open, or Risk Accepted by the owner) is updated in place;
  * a deviation is Closed with the date and reason - kept, not deleted - only
    when the assessment looked at its requirement and it no longer fails; if
    it fails again later it is a new item;
  * a residual is closed by the owner (Closed or Risk Accepted), since the
    host can never evidence it; the generator reopens nothing the owner
    closed, and closes a residual itself only if the requirement stops being
    partial. A closure the generator made is marked "auto:" in the Closure
    column so that it, and only it, is reopened if the finding returns.

Only a complete, supported assessment is merged: one scoped to a family or a
requirement says nothing about the items outside it, and an assessment the
assessor marked unsupported describes the wrong system. Both are refused, as
is an assessment older than --max-age-hours: merging stale results would
close items that are still open.

The register is read as the owner may have saved it (a UTF-8 byte-order mark
from a spreadsheet is tolerated); a file whose header lacks any of the
generator's columns is refused rather than rewritten, since the rewrite would
lose the owner's rows. Unknown Status values and duplicate active items are
refused for the same reason. The register is written atomically at mode
0600 under a lock, the previous copy kept beside it as poam.csv.bak, and a
dated snapshot of it is kept for the record.

Stdlib only; tests in tests/test_poam.py.
"""
from __future__ import annotations

import argparse
import csv
import fcntl
import json
import os
import shutil
import sys
import tempfile
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
STATUSES = (OPEN, ACCEPTED, CLOSED)
DEVIATION, RESIDUAL = "deviation", "residual"
AUTO = "auto: "                      # prefix of a closure the generator made
FULL_SCOPE = "all requirements"      # what nist-assess records for a full run


class RegisterError(Exception):
    """The register or the assessment cannot be merged safely."""


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


def assessed(assessment: dict) -> set:
    """The requirements the assessment looked at, whatever it found."""
    return {r.get("id", "") for r in assessment.get("requirements", [])}


def check_assessment(assessment: dict) -> None:
    """Refuse an assessment that cannot close items honestly."""
    meta = assessment.get("assessment", {})
    scope = meta.get("scope", FULL_SCOPE)
    if scope != FULL_SCOPE:
        raise RegisterError(
            f"the assessment covers only {scope!r}: an item outside it would be "
            "closed as passing when it was not looked at - run nist-assess with no "
            "--family or --requirement")
    if meta.get("unsupported"):
        raise RegisterError(
            "the assessment is marked unsupported (" + "; ".join(meta["unsupported"])
            + "): it describes the wrong system")


def _new_id(rid: str, kind: str, today: str, taken: set) -> str:
    base = f"{rid}-{'D' if kind == DEVIATION else 'R'}-{today.replace('-', '')}"
    pid, n = base, 2
    while pid in taken:
        pid, n = f"{base}-{n}", n + 1
    return pid


def check_rows(rows: list[dict]) -> None:
    """Refuse a register the merge rules cannot apply to."""
    bad = sorted({row.get("Status", "") for row in rows} - set(STATUSES))
    if bad:
        raise RegisterError(
            f"unknown Status value(s) {bad}: the register accepts {list(STATUSES)} "
            "exactly - an item with another status would be neither updated nor closed")
    seen = set()
    for row in rows:
        key = (row.get("Requirement", ""), row.get("Kind", ""))
        if row.get("Status") in ACTIVE:
            if key in seen:
                raise RegisterError(
                    f"two active items for {key[0]} ({key[1]}): close or merge one of them")
            seen.add(key)


def merge(rows: list[dict], found: dict, today: str, looked_at: set | None = None) -> list[dict]:
    """The register after this assessment. Never drops a row or a column.

    looked_at: the requirements the assessment examined. An active item whose
    requirement is not among them is left as it is; None means every
    requirement (the caller vouched for a full assessment)."""
    rows = [dict(row) for row in rows]
    for row in rows:
        for f in FIELDS:
            row.setdefault(f, "")
    check_rows(rows)
    taken = {row["POAM ID"] for row in rows}
    active = {(row["Requirement"], row["Kind"]): row for row in rows if row["Status"] in ACTIVE}
    owner_closed_residuals = {row["Requirement"] for row in rows
                              if row["Kind"] == RESIDUAL and row["Status"] == CLOSED
                              and not row["Closure"].startswith(AUTO)}

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
        if looked_at is not None and key[0] not in looked_at:
            continue                                   # not examined: nothing is known
        row["Status"], row["Closed On"] = CLOSED, today
        row["Closure"] = AUTO + ("resolved: the requirement passes the assessment"
                                 if row["Kind"] == DEVIATION else
                                 "the requirement is no longer classed partial")

    order = {OPEN: 0, ACCEPTED: 1, CLOSED: 2}
    rows.sort(key=lambda r: (order.get(r["Status"], 3), r["Requirement"], r["Kind"], r["POAM ID"]))
    return rows


def columns(rows: list[dict]) -> list[str]:
    """The generator's columns, then any the owner added, in first-seen order."""
    extra = []
    for row in rows:
        for k in row:
            if k not in FIELDS and k not in extra and k is not None:
                extra.append(k)
    return FIELDS + extra


def load(path: str) -> list[dict]:
    if not os.path.exists(path):
        return []
    # utf-8-sig: a spreadsheet that saved "CSV UTF-8" put a byte-order mark
    # before the first column name, which then read as "﻿POAM ID" and
    # every ID was rewritten empty.
    with open(path, newline="", encoding="utf-8-sig") as fh:
        reader = csv.DictReader(fh)
        header = reader.fieldnames or []
        missing = [f for f in FIELDS if f not in header]
        if missing:
            raise RegisterError(
                f"{path} lacks the column(s) {missing}: it is not a register this "
                "generator wrote, or it was saved with another delimiter; refusing to "
                "rewrite it (restore it from the last snapshot or poam.csv.bak)")
        rows = list(reader)
    for row in rows:
        row.pop(None, None)          # cells beyond the header, which DictReader keys None
    return rows


def save(rows: list[dict], path: str, backup: bool = False) -> None:
    """Write atomically at 0600, durably, under a lock shared with other runs."""
    d = os.path.dirname(os.path.abspath(path))
    with open(os.path.join(d, ".poam.lock"), "w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if backup and os.path.exists(path):
            shutil.copy2(path, path + ".bak")
        fd, tmp = tempfile.mkstemp(prefix=".poam-", suffix=".tmp", dir=d)
        try:
            with os.fdopen(fd, "w", newline="") as fh:
                w = csv.DictWriter(fh, fieldnames=columns(rows), extrasaction="raise")
                w.writeheader()
                w.writerows(rows)
                fh.flush()
                os.fsync(fh.fileno())
            os.chmod(tmp, 0o600)
            os.replace(tmp, path)
        except BaseException:
            try:
                os.unlink(tmp)
            except OSError:
                pass
            raise
        dfd = os.open(d, os.O_RDONLY)
        try:
            os.fsync(dfd)
        finally:
            os.close(dfd)


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

    try:
        check_assessment(assessment)
        rows = merge(load(args.register), findings(assessment), args.today, assessed(assessment))
        save(rows, args.register, backup=True)
    except RegisterError as e:
        print(f"refusing: {e}", file=sys.stderr)
        return 2
    except (OSError, csv.Error) as e:
        print(f"cannot read or write the register: {e}", file=sys.stderr)
        return 2
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
