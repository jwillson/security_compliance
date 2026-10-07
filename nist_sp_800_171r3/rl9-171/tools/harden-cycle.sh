#!/usr/bin/env bash
#
# One full hardening cycle on one host, recorded: the sequence every claim in
# the READMEs rests on (TASKS.md R3), run the same way every time.
#
#   tools/harden-cycle.sh HOST [--no-probe]
#
#   1  probe before      tools/probe.sh 6b-evidence (read-only)
#   2  dry run           apply.sh --check --diff        must not fail
#   3  apply             apply.sh                       must not fail
#   4  admit to collector  if HOST forwards: the collector's 03.03.05 tasks,
#                        so its permitted-peer list names HOST (it is built
#                        from cui_hosts when the collector is applied)
#   5  reboot            when step 3 reported "Reboot required: True"
#   6  apply again       settles what only a boot changes
#   7  dry run again     expected changed=0 (idempotence)
#   8  verify            verify.sh --host HOST
#   9  probe after       and the difference from step 1
#
# Everything is written to reports/runs/HOST-UTC/ (gitignored), and a summary
# is printed at the end. Source the lab's env.sh first. For a BYO inventory,
# NIST_LUKS_PASSPHRASE is taken from $NIST_BYO_LAB/luks_passphrase when unset,
# so a host with a volume group gets its LUKS volumes (03.08.09 / 03.13.08).
#
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
LAB="${NIST_BYO_LAB:-$HOME/.local/share/nist-byo-lab}"
cd "$ROOT"
# ssh-env, not just inventory-env: this script runs ansible itself (probes,
# the reboot), and once 03.05.03 is applied every connection needs the second
# factor - for a lab inventory only ssh-env supplies it - and a host key
# already known (a kickstart host is new until seeded).
. lib/ssh-env.sh || exit 2
nist_seed_known_hosts

host=${1:-}; shift || true
probe=1
while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-probe) probe=0; shift ;;
    *) echo "error: unknown option $1" >&2; exit 2 ;;
  esac
done
[[ -n "$host" ]] || { sed -n '3,25p' "$0"; exit 2; }

inv() {   # print a host variable from the inventory, or nothing
  ansible-inventory --host "$1" 2>/dev/null | python3 -c "import json,sys; print(json.load(sys.stdin).get('$2',''))"
}
[[ -n "$(inv "$host" ansible_host)" ]] || { echo "error: $host is not in $NIST_INVENTORY" >&2; exit 2; }

RUN="$ROOT/reports/runs/$host-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$RUN"
SUMMARY="$RUN/summary.txt"
say() { echo "==> $*" | tee -a "$SUMMARY"; }
recap() { grep -E "^$host +:" "$1" | tail -1 | sed 's/  */ /g'; }
die() { say "STOPPED: $*"; echo "logs: $RUN"; exit 1; }

# Only for hosts you brought: a lab inventory's role reads .secrets/luks_passphrase
# itself, and handing it the BYO lab's passphrase would mix the two labs.
if [[ "$NIST_INVENTORY_KIND" == byo && -z "${NIST_LUKS_PASSPHRASE:-}" && -f "$LAB/luks_passphrase" ]]; then
  NIST_LUKS_PASSPHRASE=$(cat "$LAB/luks_passphrase"); export NIST_LUKS_PASSPHRASE
  say "NIST_LUKS_PASSPHRASE taken from $LAB/luks_passphrase"
fi
say "cycle on $host ($(inv "$host" ansible_host)) at $(git rev-parse --short HEAD)$(git diff --quiet HEAD -- . || echo '+uncommitted'); logs in $RUN"

step() {  # name logfile command...   -> returns the command's status
  local name=$1 log=$2; shift 2
  local t0=$SECONDS
  "$@" > "$log" 2>&1; local rc=$?
  say "$(printf '%-18s rc=%-3s %4ss  %s' "$name" "$rc" "$((SECONDS - t0))" "$(recap "$log")")"
  return $rc
}

(( probe )) && step "probe before" "$RUN/probe-before.txt" ./tools/probe.sh 6b-evidence "$host"

step "dry run" "$RUN/1-check.log" ./apply.sh --check --diff --limit "$host" \
  || die "the dry run failed; see 1-check.log"

step "apply" "$RUN/2-apply.log" ./apply.sh --limit "$host" \
  || die "the apply failed; see 2-apply.log"
reboot=$(grep -oE 'Reboot required: (True|False)' "$RUN/2-apply.log" | tail -1 | awk '{print $3}')
say "reboot required: ${reboot:-unknown}"

collector=$(inv "$host" nist_log_collector); collector=${collector%%:*}
if [[ -n "$collector" ]]; then
  cname=$(ansible-inventory --list 2>/dev/null | python3 -c "
import json,sys; d=json.load(sys.stdin); hv=d.get('_meta',{}).get('hostvars',{})
print(next((h for h,v in hv.items() if v.get('ansible_host')=='$collector'),''))")
  if [[ -n "$cname" ]]; then
    step "admit to $cname" "$RUN/3-collector.log" ./apply.sh --limit "$cname" --tags 03.03.05 \
      || die "re-applying the collector's 03.03.05 tasks failed; see 3-collector.log"
  else
    say "collector $collector is not an inventory host; its permitted peers are not managed here"
  fi
fi

if [[ "$reboot" == True ]]; then
  step "reboot" "$RUN/4-reboot.log" ansible "$host" -b -m ansible.builtin.reboot -a "reboot_timeout=900" \
    || die "the reboot did not complete; see 4-reboot.log"
fi

step "apply again" "$RUN/5-apply.log" ./apply.sh --limit "$host" \
  || die "the second apply failed; see 5-apply.log"

step "dry run again" "$RUN/6-check.log" ./apply.sh --check --diff --limit "$host" \
  || die "the second dry run failed; see 6-check.log"
changed=$(recap "$RUN/6-check.log" | grep -oE 'changed=[0-9]+' | cut -d= -f2)
if [[ "$changed" == 0 ]]; then say "idempotent: changed=0"
else say "NOT idempotent: the dry run after settling reports changed=${changed:-?} (see 6-check.log)"; fi

step "verify" "$RUN/7-verify.log" ./verify.sh --host "$host"
grep -E '^\s+[0-9]+ (satisfied|partially|not satisfied|organizational)|requirements assessed' "$RUN/7-verify.log" \
  | sed 's/^ */    /' | tee -a "$SUMMARY"
json=$(grep -oE 'reports/[^ ]+\.json' "$RUN/7-verify.log" | tail -1)
[[ -n "$json" ]] && cp "$json" "$RUN/" && say "assessment: $json"
./verify.sh --host "$host" --failed-only > "$RUN/7-failed.txt" 2>&1 || true

if (( probe )); then
  step "probe after" "$RUN/probe-after.txt" ./tools/probe.sh 6b-evidence "$host"
  # Evidence lines only: on a fresh host sudo's first-use lecture lands in the
  # first probe's output.
  ev() { sed 's/^[^ ]* *//' "$1" | grep -E '^6b\.'; }
  diff <(ev "$RUN/probe-before.txt") <(ev "$RUN/probe-after.txt") > "$RUN/probe.diff" || true
  say "evidence that changed: $(grep -c '^>' "$RUN/probe.diff") lines (probe.diff)"
fi

say "done; logs in $RUN"
