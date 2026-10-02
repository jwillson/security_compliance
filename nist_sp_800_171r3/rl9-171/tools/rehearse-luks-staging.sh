#!/usr/bin/env bash
#
# Where the LUKS key goes while the volumes are created (DEFECTS 7.7, issue
# #11): on a host with a TPM and Secure Boot on it must be staged in RAM
# (/run/nist-luks-key), used to format, open and bind, then removed - never
# written to /root/.luks-key.
#
#   tools/rehearse-luks-staging.sh HOST
#
# Reverts HOST to its `fresh` snapshot (a volume group, no LUKS yet), applies
# --tags 03.08.09, watches for /root/.luks-key while the apply runs, then
# verifies 03.08.09 and reverts to `hardened`. Needs a guest built with
# --data-disk and --tpm (byo-rl9-02). Source the BYO lab's env.sh first.
#
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE/.." || exit 2
. lib/ssh-env.sh || exit 2
host=${1:?usage: tools/rehearse-luks-staging.sh HOST}
LAB=${NIST_BYO_LAB:-$HOME/.local/share/nist-byo-lab}
[[ -n "${NIST_LUKS_PASSPHRASE:-}" ]] || { NIST_LUKS_PASSPHRASE=$(cat "$LAB/luks_passphrase"); export NIST_LUKS_PASSPHRASE; }
fails=0
ok()  { echo "PASS  $*"; }
bad() { echo "FAIL  $*"; fails=$((fails + 1)); }
remote() { ansible "$host" -b -m ansible.builtin.shell -a "$1" </dev/null 2>/dev/null | sed 1d; }

echo "==> $host: revert to fresh"
./vm/byo-snapshot.sh revert "$host" fresh >/dev/null 2>&1 || { echo "revert failed"; exit 1; }
nist_seed_known_hosts

RUN=reports/runs/luks-staging-$host-$(date -u +%Y%m%dT%H%M%SZ); mkdir -p "$RUN"
echo "==> apply --tags 03.08.09, watching for a key on disk (log: $RUN/apply.log)"
./apply.sh --limit "$host" --tags 03.08.09 </dev/null > "$RUN/apply.log" 2>&1 &
apply=$!
seen=""
while kill -0 "$apply" 2>/dev/null; do
  # `|| true`: a failed ad-hoc command echoes its own command line, which
  # names both paths and reads as if they existed.
  r=$(remote "ls /root/.luks-key /run/nist-luks-key 2>/dev/null || true" | tr '\n' ' ')
  [[ "$r" == */root/.luks-key* ]] && { seen="$seen disk"; echo "$(date -u +%T) $r" >> "$RUN/seen.txt"; }
  [[ "$r" == */run/nist-luks-key* ]] && seen="$seen ram"
  sleep 3
done
wait "$apply"; rc=$?
recap=$(grep -E "^$host +:" "$RUN/apply.log" | sed 's/  */ /g')
[[ $rc -eq 0 ]] && ok "the apply completed: $recap" \
  || { bad "the apply failed: $recap"; grep -E '^(fatal|failed):' "$RUN/apply.log" | cut -c1-300 | sed 's/^/      /'; }
[[ "$seen" != *disk* ]] && ok "/root/.luks-key never appeared" || bad "the key was written to disk"
[[ "$seen" == *ram* ]] && ok "the key was staged in RAM (/run/nist-luks-key)" \
  || echo "      (the RAM copy was not caught between polls - it lives only for format, open and bind)"
left=$(remote "ls /root/.luks-key /run/nist-luks-key 2>/dev/null; grep -c ' none luks' /etc/crypttab || true")
[[ "$left" == 2 ]] && ok "no key left anywhere; crypttab opens both volumes from the TPM" || bad "left behind: $left"
out=$(./verify.sh --host "$host" --requirement 03.08.09 </dev/null 2>&1)
grep -q ', 0 failed' <<<"$out" && ok "03.08.09 verifies with nothing failed" || bad "03.08.09 does not verify"

echo "==> $host: back to hardened"
./vm/byo-snapshot.sh revert "$host" hardened >/dev/null 2>&1 || bad "revert to hardened failed"
echo "==> $([ $fails -eq 0 ] && echo PASS || echo FAIL): LUKS key staging on $host ($fails failed)"
exit $(( fails > 0 ))
