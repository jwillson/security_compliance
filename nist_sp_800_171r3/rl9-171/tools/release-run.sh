#!/usr/bin/env bash
#
# The release gate (TASKS.md R3): one lab, from a clean state, every host
# cycled at one commit, and a summary the CHANGELOG quotes.
#
#   tools/release-run.sh byo [--rebuild]   after: source $NIST_BYO_LAB/env.sh
#   tools/release-run.sh LAB --reverify RUN_DIR
#   tools/release-run.sh kickstart    in a fresh shell: source $NIST_BYO_LAB/tools.sh
#
# Each lab's inventory is its own and chosen here - inventory/kickstart.yml or
# inventory/hosts.yml - unless NIST_INVENTORY names another (DEFECTS 7.33).
#
# Clean state first:
#   byo        each guest reverted to its `fresh` snapshot - the stock image
#              just after cloud-init. A guest with none is destroyed and
#              rebuilt by vm/byo-guest.sh from the shape in BYO_SPEC below,
#              which saves one. --rebuild rebuilds every guest that way, so
#              nothing from an older build survives: the release run of
#              2026-09-26 found byo-rl9-01's hand-made `fresh` snapshot held a
#              password rotated away the next day (DEFECTS 6b.12). A rebuild
#              of a guest whose lease a different MAC holds waits it out.
#   kickstart  both VMs destroyed and reinstalled by vm/build-vm.sh, then
#              `make pki` (existing certificates are kept: rsyslog checks the
#              name, and a rebuild keeps the name).
# Then tools/harden-cycle.sh on the collector, then on each CUI host (which
# admits the host to the collector), then one more verify of every host so
# the collector is assessed with every forwarder sending to it.
#
# A host passes when its cycle completed, the dry run after settling reported
# changed=0, and its final assessment has no FAIL and no ERROR except those
# listed in EXPECTED_FAIL - the documented retrofit limits (DEFECTS 2.2),
# nothing else. The run refuses a worktree with changes: its result is for a
# commit. Everything lands in reports/runs/release-LAB-COMMIT-UTC/ (gitignored);
# summary.md there is what the CHANGELOG's "Proven at this release" quotes.
#
# --reverify RUN_DIR repeats only the final assessment, at the current commit,
# on the hosts RUN_DIR cycled, reusing its cycle results: for a commit after
# RUN_DIR's that changes no role, playbook, overlay or lab script - a check
# corrected, say - so the hosts it hardened are still what the role would
# make. It refuses if any of those changed since RUN_DIR's commit, and the
# summary names both commits. Read-only on the hosts.
#
# This destroys and rebuilds lab guests. Never point it at an inventory of
# hosts you did not build for the lab.
#
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
cd "$ROOT"
lab=${1:-}; rebuild=0; reverify=""
[[ "${2:-}" == --rebuild && "$lab" == byo ]] && rebuild=1
[[ "${2:-}" == --reverify && -d "${3:-}" ]] && reverify=$(cd "$3" && pwd)
[[ "$lab" == byo || "$lab" == kickstart ]] && [[ -z "${2:-}" || $rebuild == 1 || -n "$reverify" ]] || { sed -n '3,45p' "$0"; exit 2; }
if [[ -z "${NIST_INVENTORY:-}" ]]; then
  if [[ "$lab" == kickstart ]]; then export NIST_INVENTORY=inventory/kickstart.yml
  else export NIST_INVENTORY=inventory/hosts.yml; fi
fi
. lib/ssh-env.sh || exit 2
# An empty inventory is right where the run builds the guests itself - BYO
# with --rebuild, kickstart always: after `make teardown` that is exactly
# what there is, and refusing it made a rebuild from nothing impossible
# (DEFECTS 7.25).
case "$lab" in
  byo)       [[ "$NIST_INVENTORY_KIND" == byo || ( "$NIST_INVENTORY_KIND" == empty && $rebuild == 1 ) ]] \
               || { echo "error: $NIST_INVENTORY is not a BYO inventory (empty is accepted with --rebuild)" >&2; exit 2; } ;;
  kickstart) [[ "$NIST_INVENTORY_KIND" == lab || "$NIST_INVENTORY_KIND" == empty ]] \
               || { echo "error: $NIST_INVENTORY is not a kickstart inventory" >&2; exit 2; } ;;
esac

# Hosts, collector first, and how each BYO guest is rebuilt when it has no
# `fresh` snapshot (docs/LAB.md, BYO guests).
declare -A BYO_SPEC=(
  [byo-log-01]="--ip 192.168.171.101 --role log"
  [byo-rl9-01]="--ip 192.168.171.141"
  [byo-rl9-02]="--ip 192.168.171.144 --data-disk 10 --tpm --user cuiuser1"
)
# Failures a host is expected to show, by check id (DEFECTS 2.2): byo-rl9-01
# has one root filesystem and no volume group; byo-rl9-02 has a volume group
# but no separate /tmp. Anything else failing fails the release. Since 1.0.1
# mp-09-luks-tpm-bound and sc-08-luks-cipher fail on a host with no LUKS
# device at all, where they passed vacuously before (issues #4, #11).
declare -A EXPECTED_FAIL=(
  [byo-rl9-01]="cm-06-mount-options cm-06-tmp-separate ac-18-luks-root-or-data mp-03-luks-present mp-09-luks-cipher mp-09-luks-tpm-bound sc-08-luks-cipher sc-08-luks-encrypted"
  [byo-log-01]="cm-06-mount-options cm-06-tmp-separate ac-18-luks-root-or-data mp-03-luks-present mp-09-luks-cipher mp-09-luks-tpm-bound sc-08-luks-cipher sc-08-luks-encrypted"
  [byo-rl9-02]="cm-06-mount-options cm-06-tmp-separate"
)
case "$lab" in
  byo)       hosts=(byo-log-01 byo-rl9-01 byo-rl9-02) ;;
  kickstart) hosts=(rl9-log-01 rl9-cui-01) ;;
esac

if [[ -n "$(git status --porcelain)" ]]; then
  echo "error: the worktree has changes; a release run is for a commit" >&2
  git status --short >&2; exit 2
fi
commit=$(git rev-parse --short HEAD)
if [[ -n "$reverify" ]]; then
  cycled=$(basename "$reverify" | sed -E "s/^release-$lab-([0-9a-f]+)-.*/\1/")
  [[ "$cycled" =~ ^[0-9a-f]+$ ]] || { echo "error: $reverify is not a release-$lab run" >&2; exit 2; }
  # What makes a host what it is: the role, the playbooks and what they read,
  # the overlay (ODP values), and the scripts that build and connect to it.
  other=$(git diff --relative --name-only "$cycled" HEAD -- . \
            | grep -E '^(roles/|catalog/|vm/|lib/|inventory/|site\.yml|guard-target\.yml|rotate-luks-passphrase\.yml|requirements\.yml|ansible\.cfg|apply\.sh)' || true)
  [[ -z "$other" ]] || { echo "error: what hardens a host changed since $cycled; run the full release instead:" >&2; echo "$other" >&2; exit 2; }
fi
OUT="$ROOT/reports/runs/release-$lab-$commit-$(date -u +%Y%m%dT%H%M%SZ)$([[ -n "$reverify" ]] && echo -reverify)"
mkdir -p "$OUT"
LOG="$OUT/run.log"
say() { echo "==> $*" | tee -a "$LOG"; }
die() { say "STOPPED: $*"; exit 1; }
say "release run, $lab lab, at $commit ($(git log -1 --format=%cI HEAD)); in $OUT"

# ---- clean state -------------------------------------------------------------
if [[ -n "$reverify" ]]; then
  say "re-verifying the hosts cycled at $cycled ($reverify)"
  cp "$reverify"/cycle-*.out "$reverify"/cycle-*.rc "$OUT"/
elif [[ "$lab" == byo ]]; then
  for h in "${hosts[@]}"; do
    if (( ! rebuild )) && ./vm/byo-snapshot.sh list "$h" 2>/dev/null | grep -qE "^$h +fresh +qcow2"; then
      say "$h: revert to fresh"
      ./vm/byo-snapshot.sh revert "$h" fresh >> "$OUT/clean-$h.log" 2>&1 || die "revert $h failed (clean-$h.log)"
    else
      say "$h: $( (( rebuild )) && echo "--rebuild" || echo "no fresh snapshot"); destroy and rebuild (${BYO_SPEC[$h]})"
      { ./vm/byo-guest.sh destroy "$h" && ./vm/byo-guest.sh build "$h" ${BYO_SPEC[$h]}; } \
        >> "$OUT/clean-$h.log" 2>&1 || die "rebuild $h failed (clean-$h.log)"
    fi
  done
else
  for h in "${hosts[@]}"; do
    role=cui; [[ "$h" == *log* ]] && role=log
    say "$h: destroy and reinstall (--role $role)"
    { ./vm/build-vm.sh --role "$role" --name "$h" --destroy && ./vm/build-vm.sh --role "$role" --name "$h"; } \
      >> "$OUT/clean-$h.log" 2>&1 || die "reinstall $h failed (clean-$h.log)"
  done
  make pki >> "$OUT/clean-pki.log" 2>&1 || die "make pki failed (clean-pki.log)"
fi
nist_seed_known_hosts >> "$LOG" 2>&1

# ---- one cycle per host --------------------------------------------------------
for h in "${hosts[@]}"; do
  [[ -n "$reverify" ]] && continue
  say "$h: harden-cycle"
  ./tools/harden-cycle.sh "$h" > "$OUT/cycle-$h.out" 2>&1
  echo $? > "$OUT/cycle-$h.rc"
  grep -E '^==> (reboot required|idempotent|NOT idempotent|STOPPED)' "$OUT/cycle-$h.out" | sed 's/^/    /' | tee -a "$LOG"
done

# ---- final assessment of every host, and the verdict --------------------------
fails=0
{
  echo "# Release run: $lab lab at $commit"
  echo
  echo "Commit \`$(git rev-parse HEAD)\`, run $(date -u +%Y-%m-%dT%H:%MZ). Clean state:"
  [[ -n "$reverify" ]] && echo "Hardened and cycled at \`$cycled\` ($(basename "$reverify")); only the final assessment is from this commit, which changes no role, playbook or lab script since."
  [[ "$lab" == byo ]] && echo "BYO guests $( (( rebuild )) && echo "rebuilt from" || echo "reverted to or rebuilt as") stock GenericCloud." \
                      || echo "kickstart VMs reinstalled."
  echo
  echo "| Host | Release, kernel | Satisfied / partial / not / org. | Checks run, failed | changed=0 | Unexpected failures |"
  echo "| --- | --- | --- | --- | --- | --- |"
} > "$OUT/summary.md"
for h in "${hosts[@]}"; do
  ./verify.sh --host "$h" > "$OUT/verify-$h.log" 2>&1
  json=$(grep -oE 'reports/[^ ]+\.json' "$OUT/verify-$h.log" | tail -1)
  [[ -n "$json" ]] && cp "$json" "$OUT/final-$h.json"
  idem=no; grep -q '^==> idempotent: changed=0' "$OUT/cycle-$h.out" && idem=yes
  rc=$(cat "$OUT/cycle-$h.rc")
  row=$(python3 - "$OUT/final-$h.json" "$h" "$idem" "${EXPECTED_FAIL[$h]:-}" <<'PY'
import json, sys
path, host, idem, expected = sys.argv[1], sys.argv[2], sys.argv[3], set(sys.argv[4].split())
try:
    d = json.load(open(path))
except Exception:
    print(f"| {host} | no assessment | | | {idem} | NO-REPORT |"); sys.exit()
s, a = d["summary"], d["assessment"]
bad = sorted({c["id"] for r in d["requirements"] for c in r.get("checks", [])
              if c["status"] in ("FAIL", "ERROR")} - expected)
print(f"| {host} | {a['release'].replace('Rocky Linux release ', '')}, {a['kernel']} "
      f"| {s['pass']} / {s['manual']} / {s['fail'] + s['error']} / {s['not_applicable']} "
      f"| {s['checks_run']}, {s['checks_failed']} | {idem} | {' '.join(bad) or 'none'} |")
PY
)
  echo "$row" >> "$OUT/summary.md"
  [[ "$rc" == 0 && "$idem" == yes && "$row" == *"| none |" ]] || fails=$((fails + 1))
done
{
  echo
  [[ $fails -eq 0 ]] && echo "**PASS** — every host cycled, settled at changed=0, and failed only where expected." \
                     || echo "**FAIL** — $fails host(s) did not; see the logs beside this file."
} >> "$OUT/summary.md"
cat "$OUT/summary.md" | tee -a "$LOG"
exit $(( fails > 0 ))
