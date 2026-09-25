#!/usr/bin/env bash
#
# Prove, by behaviour, that sshd ends an idle session that is not at a shell
# prompt (03.01.11 / 03.13.09, DEFECTS 6b.3). TMOUT only ends an idle bash
# prompt; this opens a session running a silent foreground program and times
# how long sshd lets it live.
#
#   tools/ssh-idle-test.sh HOST [LIMIT_SECONDS]
#
# LIMIT_SECONDS defaults to the overlay's session_timeout_seconds. The session
# runs `sleep LIMIT+300`, so it outlives the limit by five minutes unless sshd
# closes it. Client keepalives are off, so nothing but the session's own
# (absent) traffic can keep it open. PASS when it ends within LIMIT+90 s and
# not before LIMIT. Source the lab's env.sh first (the second SSH factor).
# Read-only on the host.
#
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
cd "$ROOT"

host=${1:?usage: tools/ssh-idle-test.sh HOST [LIMIT_SECONDS]}
limit=${2:-$(python3 -c "import yaml; print(yaml.safe_load(open('catalog/overlay-rocky9.yml'))['odp']['session_timeout_seconds'])")}

hv() { ansible-inventory --host "$host" 2>/dev/null | python3 -c "import json,sys,os; print(os.path.expanduser(json.load(sys.stdin).get('$1','')))"; }
ip=$(hv ansible_host); user=$(hv ansible_user); key=$(hv ansible_ssh_private_key_file)
[[ -n "$ip" ]] || { echo "error: $host is not in the inventory" >&2; exit 2; }

echo "==> $host ($ip): idle session running 'sleep $((limit + 300))'; expecting sshd to close it at ~${limit}s"
start=$SECONDS
ssh -i "$key" -o ServerAliveInterval=0 -o ConnectTimeout=10 "$user@$ip" "sleep $((limit + 300))" \
  </dev/null >/dev/null 2>"${TMPDIR:-/tmp}/ssh-idle-test.$$"
rc=$?
elapsed=$((SECONDS - start))
err=$(tail -1 "${TMPDIR:-/tmp}/ssh-idle-test.$$" 2>/dev/null); rm -f "${TMPDIR:-/tmp}/ssh-idle-test.$$"

echo "    session ended after ${elapsed}s, ssh exit $rc${err:+ ($err)}"
if (( elapsed >= limit && elapsed <= limit + 90 )); then
  echo "PASS: sshd closed the idle session at ${elapsed}s (limit ${limit}s)"
elif (( elapsed < limit )); then
  echo "FAIL: the session ended before the limit - something else closed it"; exit 1
else
  echo "FAIL: the session outlived the limit by $((elapsed - limit))s - sshd did not close it"; exit 1
fi
