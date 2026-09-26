# Sourced by apply.sh and verify.sh.
#
# 03.05.03 Multi-factor authentication: a hardened host requires
# `AuthenticationMethods publickey,password`. The key is the possession factor;
# SSH_ASKPASS supplies the knowledge factor, so the automation authenticates
# with two factors like any other operator rather than the control being
# switched off for it.
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

# The knowledge factor. A lab inventory's hosts were built with the lab admin
# password, so the lab askpass supplies it; for hosts you brought, the
# operator's own SSH_ASKPASS is left alone (unset, a key-only login still
# works until 03.05.03 is applied).
if [ "$NIST_INVENTORY_KIND" = lab ]; then
  if [ ! -x "$ROOT_DIR/.secrets/askpass.sh" ]; then
    echo "error: $NIST_INVENTORY holds lab hosts but .secrets/askpass.sh is missing (make secrets)" >&2
    return 1 2>/dev/null || exit 1
  fi
  export SSH_ASKPASS="$ROOT_DIR/.secrets/askpass.sh"
  export SSH_ASKPASS_REQUIRE=force
fi

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
    m = re.search(r"UserKnownHostsFile=(\S+)", str(v.get("ansible_ssh_common_args", "")))
    f = m.group(1).replace("{{ playbook_dir }}", os.environ["ROOT_DIR"]) if m \
        else os.path.expanduser("~/.ssh/known_hosts")
    print(f"{v.get(\"ansible_host\", h)}\t{f}")
' 2>/dev/null
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
