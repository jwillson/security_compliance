#!/usr/bin/env bash
#
# Run two versions of the assessor against the same hosts, back to back, and
# compare every check. This is how an assessor change is accepted (TASKS.md,
# "How work arrives"): the hosts do not change between the two runs, so any
# difference is the assessor's, not the host's.
#
#   tools/assessor-parity.sh BASE_REF NEW_REF [--host NAME]
#   tools/assessor-parity.sh main origin/claude/some-branch
#   tools/assessor-parity.sh main HEAD --host byo-rl9-01
#
# Read-only on the hosts: it runs ./verify.sh from each ref, which copies that
# ref's audit/ files to /opt/nist-assess and runs them there. Each ref is
# checked out into a temporary worktree; the live inventory/hosts.yml is
# copied in, because it is gitignored. Source the lab's env.sh first.
# Exit 0 when nothing differs, 1 when something does, 2 on usage error.
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
REPO="$(git -C "$ROOT" rev-parse --show-toplevel)"
SUB="${ROOT#"$REPO"/}"

[[ $# -ge 2 ]] || { sed -n '3,16p' "$0"; exit 2; }
BASE=$1 NEW=$2; shift 2
VERIFY_ARGS=("$@")
. "$ROOT/lib/inventory-env.sh" || exit 2
[[ -f "$NIST_INVENTORY" ]] || { echo "error: no inventory at $NIST_INVENTORY" >&2; exit 2; }

WORK=$(mktemp -d)
cleanup() {
  for w in base new; do
    [[ -d "$WORK/$w" ]] && git -C "$REPO" worktree remove --force "$WORK/$w" >/dev/null 2>&1
  done
  rm -rf "$WORK"
}
trap cleanup EXIT

run() {   # label ref
  local label=$1 ref=$2
  git -C "$REPO" worktree add -q --detach "$WORK/$label" "$ref"
  # Both ways, so a ref from before NIST_INVENTORY existed (which reads
  # ansible.cfg's inventory/hosts.yml) assesses the same hosts.
  cp "$NIST_INVENTORY" "$WORK/$label/$SUB/inventory/hosts.yml"
  echo "==> $label: $ref ($(git -C "$REPO" rev-parse --short "$ref"))"
  # verify.sh exits non-zero whenever a host has a deviation; that is
  # expected here, and the reports are what is compared.
  (cd "$WORK/$label/$SUB" && ./verify.sh ${VERIFY_ARGS[@]+"${VERIFY_ARGS[@]}"} >/dev/null 2>&1) || true
  ls "$WORK/$label/$SUB"/reports/*.json >/dev/null 2>&1 \
    || { echo "error: $label produced no reports" >&2; exit 2; }
}

run base "$BASE"
run new "$NEW"

python3 - "$WORK/base/$SUB/reports" "$WORK/new/$SUB/reports" <<'PY'
import json, sys
from pathlib import Path

def load(d):
    out = {}
    for p in sorted(Path(d).glob("*.json")):
        host = p.name.rsplit("-", 1)[0]
        data = json.loads(p.read_text())
        checks = [c for r in data["requirements"] for c in r.get("checks", [])]
        out[host] = (
            data["summary"],
            {c["id"]: c["status"] for c in checks},
            {r["id"]: r["status"] for r in data["requirements"]},
            # The assertion and what was seen, too: a status alone hides a
            # check whose assertion changed and still passes (issue #13).
            {c["id"]: (c.get("expected", ""), c.get("evidence", "")) for c in checks},
        )
    return out

base, new = load(sys.argv[1]), load(sys.argv[2])
differs = False
for host in sorted(set(base) | set(new)):
    if host not in base or host not in new:
        print(f"{host}: assessed by only one side"); differs = True; continue
    (bs, bc, br, bx), (ns, nc, nr, nx) = base[host], new[host]
    dc = [(k, bc.get(k), nc.get(k)) for k in sorted(set(bc) | set(nc)) if bc.get(k) != nc.get(k)]
    dr = [(k, br.get(k), nr.get(k)) for k in sorted(set(br) | set(nr)) if br.get(k) != nr.get(k)]
    fmt = lambda s: f"{s['pass']}/{s['manual']}/{s['fail']}/{s['not_applicable']} err={s['error']}"
    print(f"{host}: base {fmt(bs)}  new {fmt(ns)}  "
          f"checks differing {len(dc)}/{len(set(bc) | set(nc))}  "
          f"requirements differing {len(dr)}/{len(set(br) | set(nr))}")
    for k, a, b in dc:
        print(f"    check        {k:40s} {a} -> {b}")
    for k, a, b in dr:
        print(f"    requirement  {k:40s} {a} -> {b}")
    # Same status, different assertion: listed, and a difference. Evidence
    # varies run to run (times, counts), so it is only counted.
    same = [k for k in set(bc) & set(nc) if bc[k] == nc[k]]
    da = sorted(k for k in same if bx[k][0] != nx[k][0])
    de = sum(1 for k in same if bx[k][1] != nx[k][1])
    for k in da:
        print(f"    assertion    {k:40s} {bx[k][0]!r} -> {nx[k][0]!r} (status {bc[k]} both)")
    if de:
        print(f"    evidence differs on {de} check(s) with the same status (informational)")
    differs |= bool(dc or dr or da)
print("PARITY" if not differs else "DIFFERENCES FOUND")
sys.exit(1 if differs else 0)
PY
