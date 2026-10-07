# shellcheck shell=bash
# Sourced by apply.sh and verify.sh.
#
# 03.05.03 Multi-factor authentication: a hardened host requires
# `AuthenticationMethods publickey,password`. The key is the possession factor;
# the knowledge factor is the account's password, which ansible answers
# itself from ansible_password - the lab's .secrets/admin_password, or the
# inventory's vault (TASKS C3) - handing it to ssh through shared memory. So
# the automation authenticates with two factors like any other operator, and
# no askpass script or environment variable carries the password.
#
# OpenSSH refuses to send a password to a host whose key it has not verified
# ("Password authentication is disabled to avoid man-in-the-middle attacks"),
# so known_hosts must be populated first. That is a protection, not an
# obstacle - it stops the knowledge factor leaking to an impostor.
#
# Both follow the inventory selected by NIST_INVENTORY (lib/inventory-env.sh),
# not the existence of .secrets/. They used to: once .secrets/ existed, every
# host - including one you brought, with its own password - was offered the
# kickstart lab's password as its second factor, a failed authentication and
# a faillock strike (03.01.08) on every connection.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT_DIR/lib/inventory-env.sh" || return 1 2>/dev/null || exit 1

# A direct ssh (tools/lab-ssh.sh, tools/console.py) has no ansible to answer
# for it: this writes a one-run askpass for HOST into the container's own
# /dev/shm, printing the password ansible_password gives that host, and
# echoes its path.
nist_askpass_for() {
  local f pw
  # Rendered by ansible (a lab host's is a lookup, a vault's is encrypted);
  # debug runs on the controller and connects to nothing.
  pw=$(ansible "$1" -m ansible.builtin.debug -a 'msg={{ ansible_password | default("") }}' -o 2>/dev/null \
       | python3 -c 'import json,sys; l=sys.stdin.read(); print(json.loads(l.split("=>",1)[1]).get("msg",""), end="")') || return 1
  [ -n "$pw" ] || return 1
  f=$(mktemp -p /dev/shm nist-askpass.XXXXXX)
  printf '#!/bin/sh\ncat <<"EOF"\n%s\nEOF\n' "$pw" > "$f"; chmod 700 "$f"
  echo "$f"
}

# "address<TAB>known_hosts file" for every cui_hosts member: the file its own
# connection names (UserKnownHostsFile in ansible_ssh_common_args - the lab's
# .secrets/known_hosts), else the operator's ~/.ssh/known_hosts.
nist_host_known_hosts() {
  ansible-inventory --list 2>/dev/null | ROOT_DIR="$ROOT_DIR" python3 -c '
import json, os, re, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
hv = d.get("_meta", {}).get("hostvars", {})
for h in d.get("cui_hosts", {}).get("hosts", []):
    v = hv.get(h, {})
    # The inventory holds the unrendered template, spaces included, so it is
    # rendered before the path is read.
    args = str(v.get("ansible_ssh_common_args", "")).replace("{{ playbook_dir }}", os.environ["ROOT_DIR"])
    m = re.search(r"UserKnownHostsFile=(\S+)", args)
    f = m.group(1) if m else os.path.expanduser("~/.ssh/known_hosts")
    addr = v.get("ansible_host", h)
    print(f"{addr}\t{f}")
'

}

# Record the host key of every inventory host that is not already known.
nist_seed_known_hosts() {
  local h kh
  while IFS=$'\t' read -r h kh; do
    [ -n "$h" ] || continue
    mkdir -p "$(dirname "$kh")"; touch "$kh"; chmod 600 "$kh"
    # Already trusted? Leave it alone - a changed key should raise an error,
    # not be silently re-accepted.
    ssh-keygen -F "$h" -f "$kh" >/dev/null 2>&1 && continue
    ssh-keyscan -H "$h" >> "$kh" 2>/dev/null
  done < <(nist_host_known_hosts)
}

# Re-record host keys after the role has deliberately rotated them.
#
# 03.13.10 removes the weak DSA and ECDSA host keys, so a host trusted before
# apply presents a different key afterwards and strict checking rejects it.
# That rejection is correct; this function exists so the *known* cause is
# handled explicitly rather than by disabling host key checking everywhere.
# It is called only after a successful apply - never before one, and never by
# verify.sh, where an unexpected key change must still be an error.
nist_refresh_known_hosts() {
  local h kh
  while IFS=$'\t' read -r h kh; do
    [ -n "$h" ] && [ -f "$kh" ] || continue
    ssh-keygen -R "$h" -f "$kh" >/dev/null 2>&1
    ssh-keyscan -H "$h" >> "$kh" 2>/dev/null
    chmod 600 "$kh"
  done < <(nist_host_known_hosts)
}
