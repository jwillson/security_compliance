#!/usr/bin/env bash
#
# The 03.10.07 pre-flight by behaviour (DEFECTS 7.6, issue #8): with a boot
# entry that is not marked --unrestricted, the role must not set the GRUB
# password, must say why, and pe-07-boot-entries-unrestricted must fail.
#
#   tools/rehearse-grub-preflight.sh HOST
#
# Adds /boot/loader/entries/zz-nist-preflight-test.conf - a copy of the
# default entry without its `grub_arg` line, never the default and never
# booted - applies --tags 03.10.07 with the password removed from user.cfg
# first (so the role would set it), then puts user.cfg back and removes the
# entry, whatever happened. Lab hosts only. Source the lab's env.sh first.
#
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE/.." || exit 2
. lib/ssh-env.sh || exit 2
nist_seed_known_hosts
host=${1:?usage: tools/rehearse-grub-preflight.sh HOST}
fails=0
ok()  { echo "PASS  $*"; }
bad() { echo "FAIL  $*"; fails=$((fails + 1)); }
remote() { ansible "$host" -b -m ansible.builtin.shell -a "$1" </dev/null 2>/dev/null | sed 1d; }
T=/boot/loader/entries/zz-nist-preflight-test.conf
restore() {
  remote "rm -f $T; [ -f /root/.nist-user.cfg.bak ] && mv -f /root/.nist-user.cfg.bak /boot/grub2/user.cfg; true" >/dev/null
}
trap restore EXIT

echo "==> $host: a test entry without --unrestricted; the password moved aside"
remote "d=\$(grubby --default-kernel); e=\$(grep -l \"^linux.*\$(basename \$d)\" /boot/loader/entries/*.conf | head -1);
        grep -v '^grub_arg' \"\$e\" | sed 's/^title .*/title nist preflight test - never boot this/' > $T;
        cp -p /boot/grub2/user.cfg /root/.nist-user.cfg.bak && : > /boot/grub2/user.cfg; ls $T" | sed 's/^/    /'

out=$(./apply.sh --limit "$host" --tags 03.10.07 </dev/null 2>&1)
grep -q 'Not setting the GRUB superuser password' <<<"$out" && ok "the role declined to set the password, naming the entry" \
  || bad "the role did not decline"
# ansible.cfg hides skipped tasks, so the evidence is the file: still empty.
empty=$(remote "test -s /boot/grub2/user.cfg && echo set || echo empty")
[[ "$empty" == *empty* ]] && ok "the password was not set (user.cfg left empty)" || bad "user.cfg was written"

./verify.sh --host "$host" --requirement 03.10.07 </dev/null > /dev/null 2>&1
j=$(ls -t reports/"$host"-*.json | head -1)
st=$(python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(next(c['status'] for r in d['requirements'] for c in r['checks'] if c['id']=='pe-07-boot-entries-unrestricted'))" "$j")
[[ "$st" == FAIL ]] && ok "pe-07-boot-entries-unrestricted reports it" || bad "pe-07-boot-entries-unrestricted: $st"

restore; trap - EXIT
# Captured, not piped to grep -q: under pipefail grep -q's early exit fails
# the pipeline with verify.sh's SIGPIPE.
after=$(./verify.sh --host "$host" --requirement 03.10.07 </dev/null 2>&1)
grep -q ', 0 failed' <<<"$after" && ok "restored: 03.10.07 verifies with nothing failed" \
  || bad "03.10.07 does not verify after restoring"
echo "==> $([ $fails -eq 0 ] && echo PASS || echo FAIL): GRUB pre-flight on $host ($fails failed)"
exit $(( fails > 0 ))
