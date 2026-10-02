#!/usr/bin/env bash
#
# Prove, by behaviour, that an idle SSH session is ended (03.01.11 / 03.13.09).
# TMOUT only ends an idle bash prompt, so each mode runs something else and
# times how long the host lets the session live.
#
#   tools/ssh-idle-test.sh HOST [LIMIT_SECONDS]            a silent program
#   tools/ssh-idle-test.sh HOST [LIMIT_SECONDS] --output   a program printing
#
# silent (default)  `sleep LIMIT+300` with no terminal: no traffic at all, so
#                   sshd's ChannelTimeout must close it (DEFECTS 6b.3). PASS
#                   when it ends within LIMIT+90 s and not before LIMIT.
# --output          a terminal session printing the date every 10 s with
#                   nobody typing: ChannelTimeout counts that output as
#                   activity, so only logind's StopIdleSessionSec, which
#                   judges a terminal by its last input, can end it (issue
#                   #9). logind checks on a timer, so the session may live up
#                   to about twice the limit: PASS when it ends after LIMIT
#                   and within 2*LIMIT+90 s; the time is reported either way.
#
# LIMIT_SECONDS defaults to the overlay's session_timeout_seconds. Client
# keepalives are off, so nothing but the session itself keeps it open. Source
# the lab's env.sh first (the second SSH factor). Read-only on the host.
#
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
cd "$ROOT" || exit 2

host=${1:?usage: tools/ssh-idle-test.sh HOST [LIMIT_SECONDS] [--output]}; shift
mode=silent limit=""
for a in "$@"; do
  case "$a" in --output) mode=output ;; *) limit=$a ;; esac
done
[[ -n "$limit" ]] || limit=$(python3 -c "import yaml; print(yaml.safe_load(open('catalog/overlay-rocky9.yml'))['odp']['session_timeout_seconds'])")

hv() { ansible-inventory --host "$host" 2>/dev/null | python3 -c "import json,sys,os; print(os.path.expanduser(json.load(sys.stdin).get('$1','')))"; }
ip=$(hv ansible_host); user=$(hv ansible_user); key=$(hv ansible_ssh_private_key_file)
[[ -n "$ip" ]] || { echo "error: $host is not in the inventory" >&2; exit 2; }
err=$(mktemp); trap 'rm -f "$err"' EXIT

if [[ $mode == silent ]]; then
  upper=$((limit + 90))
  echo "==> $host ($ip): idle session running 'sleep $((limit + 300))'; expecting sshd to close it at ~${limit}s"
  start=$SECONDS
  ssh -i "$key" -o ServerAliveInterval=0 -o ConnectTimeout=10 "$user@$ip" "sleep $((limit + 300))" \
    </dev/null >/dev/null 2>"$err"
  rc=$?
else
  upper=$((2 * limit + 90))
  run=$((2 * limit + 600))
  echo "==> $host ($ip): terminal session printing every 10s, no input; expecting logind to stop it after ${limit}s (by ${upper}s)"
  start=$SECONDS
  # -tt: a terminal, as a person has; stdin is /dev/null, so nothing is typed.
  ssh -tt -i "$key" -o ServerAliveInterval=0 -o ConnectTimeout=10 "$user@$ip" \
    "end=\$((SECONDS + $run)); while [ \$SECONDS -lt \$end ]; do date; sleep 10; done" \
    </dev/null >/dev/null 2>"$err"
  rc=$?
fi
elapsed=$((SECONDS - start))
last=$(tail -1 "$err" 2>/dev/null)

echo "    session ended after ${elapsed}s, ssh exit $rc${last:+ ($last)}"
if (( elapsed >= limit && elapsed <= upper )); then
  echo "PASS: the idle session ($mode) was ended at ${elapsed}s (limit ${limit}s)"
elif (( elapsed < limit )); then
  echo "FAIL: the session ended before the limit - something else closed it"; exit 1
else
  echo "FAIL: the session outlived ${upper}s - nothing ended it"; exit 1
fi
