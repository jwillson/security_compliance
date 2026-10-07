#!/usr/bin/env bash
#
# Remove both labs and rebuild them from nothing, with the scripts alone - the
# proof that this runs on a host as it comes, with the hypervisor and podman
# or docker and nothing else (DEFECTS 7.17-7.19; TASKS C6).
#
#   tools/lab-from-scratch.sh --yes                destroys every lab guest first
#   tools/lab-from-scratch.sh --yes --from STEP    resume at STEP (teardown,
#       kickstart-all, kickstart-collector, byo-init, byo-release), skipping
#       the steps before it and the teardown - after a failure fixed in place,
#       so what already passed is not rebuilt; the earlier steps' logs are in
#       the run that failed
#
# 1. make teardown; tools/lab-residue.sh must then find nothing - no guest,
#    no network, no disk, no log.
# 2. make all for the kickstart lab (host-check, catalog, secrets, ISO, the
#    CUI VM - creating the lab network - apply, verify); make vm-log; apply
#    and verify again so the CUI host forwards to the collector.
# 3. The BYO lab: vm/byo-lab-init.sh, then tools/release-run.sh byo
#    (builds the three guests from the stock image and cycles them).
# Each step's log is in reports/runs/from-scratch-UTC/. Exit 0 only if every
# step succeeds. Each lab's tools pick its own inventory - the kickstart lab
# inventory/kickstart.yml, the BYO lab inventory/hosts.yml (docs/LAB.md,
# "Two labs on one workstation").
#
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../lib/container.sh"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
cd "$ROOT" || exit 2
[[ "${1:-}" == --yes ]] || { sed -n '3,24p' "$0"; echo "(pass --yes: it destroys every lab guest)"; exit 2; }
from=teardown; [[ "${2:-}" == --from && -n "${3:-}" ]] && from=$3
started=0
LAB="${NIST_BYO_LAB:-$HOME/.local/share/nist-byo-lab}"
OUT="$ROOT/reports/runs/from-scratch-$(date -u +%Y%m%dT%H%M%SZ)"; mkdir -p "$OUT"
say() { echo "==> $(date -u +%H:%M) $*" | tee -a "$OUT/summary.txt"; }
step() {   # name command... (in the control-plane container, as everything)
  local name=$1; shift
  [[ "$name" == "$from" ]] && started=1
  (( started )) || { say "$name: skipped (--from $from)"; return 0; }
  say "$name"
  # Each step in a shell of its own, so one lab's environment (the BYO
  # lab's env.sh) does not reach the next.
  if env -u NIST_INVENTORY -u NIST_VAULT_PASSWORD_FILE -u NIST_PKI_DIR NIST_BYO_LAB="$LAB" \
       bash -c "$*" </dev/null > "$OUT/$name.log" 2>&1; then
    say "  ok"
  else
    say "  FAILED (see $OUT/$name.log)"; tail -15 "$OUT/$name.log" | sed 's/^/    /' | tee -a "$OUT/summary.txt"; exit 1
  fi
}

step teardown "./vm/lab-teardown.sh --yes"
step kickstart-all "make all"
step kickstart-collector "make vm-log && make pki && make apply && make verify"
step byo-init "./vm/byo-lab-init.sh"
step byo-release "source $LAB/env.sh && ./tools/release-run.sh byo"
say "residue now:"; ./tools/lab-residue.sh | tee -a "$OUT/summary.txt"
say "PASS: both labs rebuilt from nothing by the scripts"
