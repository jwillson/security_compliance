#!/usr/bin/env bash
#
# SSH to a hardened lab host the way apply.sh does (DEFECTS 7.20).
#
#   tools/lab-ssh.sh HOST                an interactive shell
#   tools/lab-ssh.sh HOST COMMAND...     run one command and return
#
# A hardened host wants both factors - your key, then the account's password
# (03.05.03) - from a host whose key is already trusted, over an RSA key (the
# FIPS policy refuses ed25519). This reads the address, user, key and
# known_hosts file for HOST from whichever lab's inventory lists it (the
# kickstart lab's or the BYO lab's, lib/inventory-env.sh; NIST_INVENTORY to
# choose another), records the host key if it is new, and supplies the
# password factor the way lib/ssh-env.sh does for every tool - so nothing is
# typed, and nothing wrong is offered: three failed attempts lock the account
# (03.01.08). `sudo` on the host asks for the same password.
#
# For the BYO lab, source $NIST_BYO_LAB/env.sh first (it sets the askpass).
# When SSH cannot reach the host at all, use tools/lab-console.sh.
#
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE/.." || exit 2
host=${1:?usage: tools/lab-ssh.sh HOST [COMMAND...]}; shift
NIST_FOR_HOST=$host . lib/ssh-env.sh || exit 2
read -r addr user key kh < <(ansible-inventory --host "$host" 2>/dev/null | ROOT="$PWD" python3 -c '
import json, os, re, sys
try:
    v = json.load(sys.stdin)
except ValueError:
    sys.exit(0)
render = lambda s: os.path.expanduser(str(s).replace("{{ playbook_dir }}", os.environ["ROOT"]))
args = render(v.get("ansible_ssh_common_args", ""))
m = re.search(r"UserKnownHostsFile=(\S+)", args)
print(v.get("ansible_host", ""), v.get("ansible_user", ""),
      render(v.get("ansible_ssh_private_key_file", "~/.ssh/id_rsa")),
      m.group(1) if m else os.path.expanduser("~/.ssh/known_hosts"))')
[[ -n "${addr:-}" ]] || { echo "error: $host is not in $NIST_INVENTORY" >&2; exit 2; }
mkdir -p "$(dirname "$kh")"; touch "$kh"; chmod 600 "$kh"
ssh-keygen -F "$addr" -f "$kh" >/dev/null 2>&1 || ssh-keyscan -H "$addr" >> "$kh" 2>/dev/null
exec ssh -i "$key" -o UserKnownHostsFile="$kh" -o StrictHostKeyChecking=yes \
  -o PreferredAuthentications=publickey,password -o NumberOfPasswordPrompts=1 \
  "$user@$addr" "$@"
