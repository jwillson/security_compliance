#!/usr/bin/env bash
#
# Record a guest's serial console through libvirt, across its restarts (the
# lab-in-container spike, DEFECTS 7.34). Read-only.
#
#   tools/console-record.sh NAME FILE [SECONDS]    default 7200; URI from
#                                                   NIST_LIBVIRT_URI, else qemu:///system
#
# Existing tools: `virsh console`, given the terminal it insists on by
# util-linux `script`. Appends everything the guest prints to FILE, and a line
# per attach and detach to stderr. Runs in the control-plane container
# (re-entering itself through ./nist): it needs only the libvirt socket, not
# the host's root-only serial log, which libvirt truncates at every start.
#
# Each session is watched every two seconds: one that ends - a console asked
# for before the guest's terminal exists fails ("PTY device is not yet
# assigned") - is simply tried again, and one is ended when the guest's
# domain id changes (libvirt gives each start a new one): on a restart virsh
# console stayed attached to the stopped guest. The terminal's input is a pipe that
# stays open and carries nothing - at end of input `script` would pass an EOF,
# a Ctrl-D, to the guest. A client must keep reading: one that attached and
# never read let the serial buffer fill, and the guest's kernel froze.
#
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -n "${NIST_IN_CONTAINER:-}" ]] || exec "$HERE/../nist" "$0" "$@"
name=${1:?usage: tools/console-record.sh NAME FILE [SECONDS]} file=${2:?usage: tools/console-record.sh NAME FILE [SECONDS]}
end=$(( SECONDS + ${3:-7200} ))
uri=${NIST_LIBVIRT_URI:-qemu:///system}
domid() { virsh -c "$uri" domid "$name" 2>/dev/null | awk 'NF {print $1; exit}'; }
note() { echo "$(date -u +%T) $*" >&2; }
# A session, children first: SIGKILL to `script` alone left its virsh behind,
# still holding the console, and the next session's attach hung on it.
endtree() { local c; for c in $(ps -o pid= --ppid "$1" 2>/dev/null); do endtree "$c"; done; kill -KILL "$1" 2>/dev/null; }

trap '[[ -n "${sid:-}" ]] && endtree "$sid"; exit 0' TERM INT
while (( SECONDS < end )); do
  id=$(domid)
  if [[ -z "$id" || "$id" == "-" ]]; then sleep 2; continue; fi    # not defined, or not running
  note "attach, domain id $id"
  script -q -f -a -c "virsh -c $uri console --force $name" "$file" < <(exec sleep "${3:-7200}") > /dev/null 2>&1 &
  sid=$!
  # Watch the session by its own pid. /proc says when it has ended - also
  # when it is an unreaped child, which kill -0 still reports alive - and a
  # new domain id ends it, with everything it started (endtree). Not
  # pkill -f: a pattern also matched the shell that ran it.
  while :; do
    sleep 2
    st=$(awk '{print $3}' "/proc/$sid/stat" 2>/dev/null)
    [[ -z "$st" || "$st" == Z ]] && break
    # virsh gone, script still there: with its input a pipe that stays open,
    # script waits for that to end rather than for its child, so a console
    # that failed at once (the PTY not yet assigned) left a session that
    # recorded nothing and was never retried. Its exited child is a zombie
    # script has not reaped, so a child in state Z does not count; nor does
    # the sleep feeding its input, forked before script and so its child too.
    [[ -n "$(ps -o stat=,comm= --ppid "$sid" 2>/dev/null | awk '$1 !~ /^Z/ && $2 != "sleep"')" ]] \
      || { endtree "$sid"; break; }
    [[ "$(domid)" == "$id" ]] || { endtree "$sid"; break; }
  done
  wait "$sid" 2>/dev/null
  note "detach, domain id $id"
done
