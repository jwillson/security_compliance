#!/usr/bin/env python3
"""
Validate that the catalog, the overlay, and the checks agree.

Run this after editing any of them. It is the guard against the failure mode
that matters most here: a requirement silently losing its coverage.
"""
import json
import re
import sys
from collections import Counter
from pathlib import Path

try:
    import yaml
except ImportError:
    sys.exit("error: PyYAML required (pip install pyyaml)")

ROOT = Path(__file__).resolve().parent.parent
ASSERTIONS = {"expect_rc", "expect_output", "expect_match",
              "expect_no_match", "expect_empty", "expect_int"}
# Everything else a check may carry. An unknown key is almost always a typo
# of one of these - `manual_if_abesnt` - and the assessor would ignore it.
CHECK_KEYS = ASSERTIONS | {"id", "description", "command",
                           "manual_if_absent", "ok_rc"}
INT_OPS = {"==", "!=", "<=", ">=", "<", ">"}
ODP_REF = re.compile(r"\{odp\.([a-z0-9_]+)\}")


def expand(text, odp):
    """Substitute {odp.name} as the assessor does; unknown names are left."""
    return ODP_REF.sub(lambda m: str(odp.get(m.group(1), m.group(0))), str(text))


def validate(catalog, overlay, checks):
    """Return (errors, warnings, stats) for one catalog/overlay/checks triple."""
    errors, warnings = [], []

    active = {r["id"] for r in catalog["requirements"] if not r["withdrawn"]}
    mapped = [r["id"] for r in overlay["requirements"]]
    mapped_set = set(mapped)

    # 1. Every active requirement is mapped exactly once.
    for rid in sorted(active - mapped_set):
        errors.append(f"requirement {rid} has no overlay entry")
    for rid in sorted(mapped_set - active):
        errors.append(f"overlay entry {rid} is not an active requirement")
    for rid in sorted({r for r in mapped if mapped.count(r) > 1}):
        errors.append(f"overlay entry {rid} appears more than once")

    # 2. Every non-organizational requirement names tasks and checks.
    for req in overlay["requirements"]:
        if req["disposition"] == "organizational":
            if not req.get("rationale"):
                errors.append(f"{req['id']} is organizational but has no rationale")
            if req.get("checks"):
                errors.append(f"{req['id']} is organizational but declares checks")
            continue
        if not req.get("tasks"):
            errors.append(f"{req['id']} names no task file")
        if not req.get("checks"):
            errors.append(f"{req['id']} declares no checks")
        if not req.get("host_scope"):
            errors.append(f"{req['id']} has no host_scope description")
        if req["disposition"] == "partial" and not req.get("residual"):
            errors.append(f"{req['id']} is partial but does not state the residual")
        # The converse of the rule above. A residual names what the
        # organization still owes, which is the definition of partial; a
        # technical entry that carries one would report PASS next to prose
        # conceding non-compliance.
        if req["disposition"] == "technical" and req.get("residual"):
            errors.append(f"{req['id']} is technical but states a residual "
                          "(a residual is what makes a requirement partial)")
        if req["disposition"] not in ("technical", "partial", "organizational"):
            errors.append(f"{req['id']} has unknown disposition {req['disposition']!r}")

    # 3. Check definitions are well-formed and 1:1 with what the overlay declares.
    odp = overlay.get("odp", {})
    defined = {}
    for c in checks["checks"]:
        cid = c["id"]
        if cid in defined:
            errors.append(f"check {cid} is defined more than once")
        defined[cid] = c
        for key in sorted(set(c) - CHECK_KEYS):
            errors.append(f"check {cid} has unknown key {key!r}")
        forms = ASSERTIONS & set(c)
        if len(forms) != 1:
            errors.append(f"check {cid} declares {len(forms)} assertions (need exactly 1)")
        if not c.get("description"):
            errors.append(f"check {cid} has no description")
        if not c.get("command"):
            errors.append(f"check {cid} has no command")
        if len(forms) == 1:
            errors.extend(assertion_errors(c, forms.pop(), odp))

    declared = {cid for r in overlay["requirements"] for cid in r.get("checks", [])}
    for cid in sorted(declared - set(defined)):
        errors.append(f"check {cid} is referenced but not defined")
    for cid in sorted(set(defined) - declared):
        warnings.append(f"check {cid} is defined but never referenced")

    # 4. ODP references in checks resolve, and every machine ODP is asserted.
    #
    # Asserted means the value reaches the comparison: it appears in the
    # command or the assertion of a check some requirement runs. A mention in
    # a description, or in a check nothing references, asserts nothing.
    asserted = set()
    for c in checks["checks"]:
        blob = " ".join(str(v) for k, v in c.items() if k != "id")
        for key in ODP_REF.findall(blob):
            if key not in odp:
                errors.append(f"check {c['id']} references unknown ODP {key!r}")
        if c["id"] not in declared:
            continue
        form = next(iter(ASSERTIONS & set(c)), None)
        for field in ("command", form):
            if field:
                asserted.update(ODP_REF.findall(str(c.get(field, ""))))
    # A machine ODP exists so the role applies it and a check asserts it. One
    # no check reads can change without anything failing, so it is either dead
    # or a policy value that belongs in odp_organizational.
    for key in odp:
        if key not in asserted:
            errors.append(f"machine ODP {key!r} is asserted by no check")

    # 5. Task files named by the overlay exist.
    for req in overlay["requirements"]:
        t = req.get("tasks")
        if t and not (ROOT / "roles/nist_800_171" / t).is_file():
            errors.append(f"{req['id']} names missing task file {t}")

    # 6. The organizational ODP register is well-formed.
    #
    # These are documentation, not configuration: nothing reads them to
    # configure a host and no check asserts them. The guard is therefore that
    # each one is attributable - it names a real requirement and does not
    # shadow a machine ODP, which would leave two answers to the same question.
    org_odp = overlay.get("odp_organizational", [])
    seen_org = set()
    for entry in org_odp:
        oid = entry.get("id")
        if not oid:
            errors.append("an odp_organizational entry has no id")
            continue
        if oid in seen_org:
            errors.append(f"organizational ODP {oid!r} is defined more than once")
        seen_org.add(oid)
        if oid in odp:
            errors.append(f"organizational ODP {oid!r} shadows a machine ODP of "
                          "the same name")
        for field in ("requirement", "parameter", "value"):
            if not entry.get(field):
                errors.append(f"organizational ODP {oid!r} has no {field}")
        rid = entry.get("requirement")
        if rid and rid not in active:
            errors.append(f"organizational ODP {oid!r} names {rid}, which is not "
                          "an active requirement")

    stats = {
        "active": len(active),
        "withdrawn": catalog["counts"]["withdrawn"],
        "disposition": Counter(r["disposition"] for r in overlay["requirements"]),
        "defined": len(defined),
        "declared": len(declared),
        "odp": len(odp),
        "org_odp": len(org_odp),
        "org_odp_requirements": len({e.get("requirement") for e in org_odp}),
    }
    return errors, warnings, stats


def assertion_errors(check, form, odp):
    """Errors the assessor would otherwise only meet mid-run on a host."""
    cid, value = check["id"], check[form]
    errors = []
    if form in ("expect_match", "expect_no_match"):
        try:
            re.compile(expand(value, odp))
        except re.error as exc:
            errors.append(f"check {cid} {form} is not a valid regex: {exc}")
    elif form == "expect_int":
        op, _, rhs = expand(value, odp).partition(" ")
        if op not in INT_OPS or not re.fullmatch(r"-?\d+", rhs):
            errors.append(f"check {cid} expect_int {value!r} is not '<op> <integer>'")
    elif form == "expect_empty" and value is not True:
        errors.append(f"check {cid} expect_empty must be true")
    elif form == "expect_rc" and not isinstance(value, int):
        errors.append(f"check {cid} expect_rc must be an integer")

    if "ok_rc" in check:
        rcs = check["ok_rc"]
        if form == "expect_rc":
            errors.append(f"check {cid} carries ok_rc, which expect_rc already decides")
        elif (not isinstance(rcs, list) or not rcs
              or not all(isinstance(r, int) and not isinstance(r, bool)
                         and 0 <= r <= 255 for r in rcs)):
            errors.append(f"check {cid} ok_rc must be a list of exit statuses")
    return errors


def main():
    catalog = json.loads((ROOT / "catalog/requirements.json").read_text())
    overlay = yaml.safe_load((ROOT / "catalog/overlay-rocky9.yml").read_text())
    checks = yaml.safe_load((ROOT / "audit/checks.yml").read_text())

    errors, warnings, s = validate(catalog, overlay, checks)
    disp = s["disposition"]

    print(f"catalog   {s['active']} active requirements ({s['withdrawn']} withdrawn)")
    print(f"overlay   {disp['technical']} technical, {disp['partial']} partial, "
          f"{disp['organizational']} organizational")
    print(f"checks    {s['defined']} defined, {s['declared']} referenced")
    print(f"odp       {s['odp']} enforced by the host, {s['org_odp']} organizational "
          f"across {s['org_odp_requirements']} requirements")

    for w in warnings:
        print(f"  warn:  {w}")
    for e in errors:
        print(f"  ERROR: {e}")

    if errors:
        print(f"\n{len(errors)} error(s)")
        return 1
    print("\nvalidation passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
