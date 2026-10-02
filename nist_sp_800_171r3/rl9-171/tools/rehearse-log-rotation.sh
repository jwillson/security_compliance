#!/usr/bin/env bash
#
# Log rotation by behaviour (DEFECTS 7.9): what the calendar does on the 1st
# of the month, done now. Requires: no configuration error, logrotate.service
# succeeding, and btmp, wtmp and messages recreated 0600 after a forced
# rotation; then 03.14.08 verifies with nothing failed.
#
#   tools/rehearse-log-rotation.sh HOST
#
# A forced rotation is what the timer would do anyway, sooner: nothing is
# lost, the rotated files stay. Source the lab's env.sh first.
#
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE/.." || exit 2
. lib/ssh-env.sh || exit 2
host=${1:?usage: tools/rehearse-log-rotation.sh HOST}
fails=0
ok()  { echo "PASS  $*"; }
bad() { echo "FAIL  $*"; fails=$((fails + 1)); }
remote() { ansible "$host" -b -m ansible.builtin.shell -a "$1" </dev/null 2>/dev/null | sed 1d; }

errs=$(remote "logrotate --debug /etc/logrotate.conf 2>&1 | grep '^error:' || true")
[[ -z "$errs" ]] && ok "logrotate reports no configuration error" || bad "configuration errors: ${errs:0:200}"
res=$(remote "systemctl start logrotate.service; systemctl show logrotate.service -p Result --value")
[[ "$res" == *success* ]] && ok "logrotate.service ran: Result=success" || bad "logrotate.service: ${res:0:120}"
remote "logrotate -f /etc/logrotate.d/btmp; logrotate -f /etc/logrotate.d/wtmp; logrotate -f /etc/logrotate.d/rsyslog; echo done" >/dev/null
modes=$(remote "stat -c '%n %a' /var/log/btmp /var/log/wtmp /var/log/messages")
echo "$modes" | sed 's/^/    /'
[[ $(grep -c ' 600$' <<<"$modes") -eq 3 ]] && ok "btmp, wtmp and messages recreated 0600" || bad "a rotated file was recreated with a wider mode"
out=$(./verify.sh --host "$host" --requirement 03.14.08 </dev/null 2>&1)
grep -q ', 0 failed' <<<"$out" && ok "03.14.08 verifies with nothing failed" || bad "03.14.08 does not verify"
echo "==> $([ $fails -eq 0 ] && echo PASS || echo FAIL): log rotation on $host ($fails failed)"
exit $(( fails > 0 ))
