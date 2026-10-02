#!/usr/bin/env bash
#
# LUKS passphrase rotation by behaviour (DEFECTS 7.14, issue #11):
# rotate-luks-passphrase.yml from the lab passphrase to a random one, again
# (must report no change), checking the new one opens each volume and the old
# one does not, and that the TPM binding still unlocks; then back to the lab
# passphrase, so the lab's stored copy stays the right one.
#
#   tools/rehearse-luks-rotation.sh HOST      a guest with LUKS volumes (byo-rl9-02)
#
# The random passphrase exists only in this script's environment. Source the
# BYO lab's env.sh first.
#
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE/.." || exit 2
. lib/ssh-env.sh || exit 2
host=${1:?usage: tools/rehearse-luks-rotation.sh HOST}
LAB=${NIST_BYO_LAB:-$HOME/.local/share/nist-byo-lab}
lab_pw=${NIST_LUKS_PASSPHRASE:-$(cat "$LAB/luks_passphrase")}
tmp_pw=$(head -c 24 /dev/urandom | base64 | tr -d '/+=\n')
fails=0
ok()  { echo "PASS  $*"; }
bad() { echo "FAIL  $*"; fails=$((fails + 1)); }
remote() { ansible "$host" -b -m ansible.builtin.shell -a "$1" </dev/null 2>/dev/null | sed 1d; }
rotate() {   # from to -> the recap line
  NIST_LUKS_PASSPHRASE="$1" NIST_LUKS_NEW_PASSPHRASE="$2" \
    ansible-playbook rotate-luks-passphrase.yml --limit "$host" </dev/null 2>&1 | grep -E "^$host +:" | sed 's/  */ /g'
}
tpm_ok() { remote "for v in lv_cui lv_backup; do d=/dev/vg_sys/\$v; s=\$(clevis luks list -d \$d | awk -F: '/tpm2/ {print \$1; exit}'); clevis luks pass -d \$d -s \$s >/dev/null && echo tpm-ok; done" | grep -c tpm-ok; }

r=$(rotate "$lab_pw" "$tmp_pw")
[[ "$r" == *failed=0* && "$r" == *changed=1* ]] && ok "rotated both volumes: $r" || bad "rotation: $r"
r=$(rotate "$lab_pw" "$tmp_pw")
[[ "$r" == *failed=0* && "$r" == *changed=0* ]] && ok "a second run changes nothing: $r" || bad "second run: $r"
[[ $(tpm_ok) -eq 2 ]] && ok "the TPM still unlocks both volumes" || bad "the TPM binding no longer unlocks"
r=$(rotate "$tmp_pw" "$lab_pw")
[[ "$r" == *failed=0* && "$r" == *changed=1* ]] && ok "rotated back to the lab passphrase: $r" || bad "rotating back: $r"
out=$(NIST_LUKS_PASSPHRASE="$lab_pw" ./verify.sh --host "$host" --requirement 03.08.09 </dev/null 2>&1)
grep -q ', 0 failed' <<<"$out" && ok "03.08.09 verifies with nothing failed" || bad "03.08.09 does not verify"
left=$(remote "ls /run/nist-luks-old /run/nist-luks-new 2>/dev/null || true")
[[ -z "$left" ]] && ok "nothing staged is left in /run" || bad "left in /run: $left"
echo "==> $([ $fails -eq 0 ] && echo PASS || echo FAIL): LUKS passphrase rotation on $host ($fails failed)"
exit $(( fails > 0 ))
