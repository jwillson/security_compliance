#!/usr/bin/env bash
#
# What an installer said before it stopped (DEFECTS 7.30). Read-only.
#
#   tools/install-log.sh NAME          the lab guest NAME's newest install, as
#                                      vm/build-vm.sh recorded its console:
#                                      reports/runs/build-NAME-UTC/console.log
#   tools/install-log.sh FILE          any console log
#
# vm/build-vm.sh records the installer's console (tools/console-record.sh)
# and calls this when an install stops. It runs in the control-plane
# container. The cause is rarely in the last lines: when anaconda gives
# up, the console ends in a page of systemd shutdown messages. So the log is
# cut where the shutdown began, and from what came before it this prints the
# lines that name a fault - anaconda's and dracut's errors, a kickstart it
# refused, a traceback, a repository or a name it could not reach - then the
# last lines before the shutdown, for context. Terminal escapes are removed.
#
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../lib/container.sh"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
arg=${1:-}
[[ -n "$arg" ]] || { sed -n '3,15p' "$0"; exit 2; }
log=$arg
if [[ "$arg" != */* && ! -f "$arg" ]]; then
  log=$(ls -td "$ROOT"/reports/runs/build-"$arg"-*/ 2>/dev/null | head -1)console.log
fi
text=$(cat "$log" 2>/dev/null) || { echo "error: cannot read $log (no recorded install of $arg?)" >&2; exit 1; }
text=$(sed -e 's/\x1b\[[0-9;?]*[A-Za-z]//g' -e 's/\x1b[()][A-Za-z0-9]//g' -e 's/\r//g' <<<"$text")

# Where the shutdown began: the first of these, else the end of the log.
cut=$(grep -n -m1 -E 'System is going down|Reached target .*(Halt|Power-Off|Reboot|Shutdown)|systemd-shutdown\[|Stopping .*Anaconda|reboot: (System halted|Power down|Restarting)' <<<"$text" | cut -d: -f1)
before=$text
[[ -n "$cut" ]] && before=$(head -n $((cut - 1)) <<<"$text")
total=$(wc -l <<<"$text")

echo "== $log: $total lines${cut:+, the shutdown began at line $cut}"
grep -q -E 'reboot: (System halted|Power down)' <<<"$text" \
  && echo "== the installer halted itself: anaconda gave up - its reason is among the lines below"
echo "-- what named a fault before that:"
faults=$(grep -n -i -E 'traceback|error|fatal|fail|could not|couldn.t|cannot|unable to|timed out|timeout|not found|refused|denied|no route|name resolution|kickstart|pane is dead|emergency|dracut-initqueue.*(warn|timeout)|anaconda.*(exit|stop|abort)|out of memory|oom' <<<"$before" \
  | grep -v -i -E 'error[_-]?(log|ratelimit)|errors=remount|on.?error|ignore.?errors|ERST|AER:|no error|hkdf' | tail -n 40)
if [[ -n "$faults" ]]; then sed 's/^/    /' <<<"$faults"; else echo "    (none matched)"; fi
echo "-- the last lines before it:"
tail -n 15 <<<"$before" | sed 's/^/    /'
