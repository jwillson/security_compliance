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

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Only when the lab's askpass helper is actually present. A host brought by
# the operator supplies its own credentials through the inventory, and
# forcing a non-existent SSH_ASKPASS on that case turns a working key-only
# login into an opaque preauth failure.
if [ -x "$ROOT_DIR/.secrets/askpass.sh" ]; then
  export SSH_ASKPASS="$ROOT_DIR/.secrets/askpass.sh"
  export SSH_ASKPASS_REQUIRE=force
fi

# known_hosts likewise: the lab keeps its own, an operator's host uses theirs.
NIST_KNOWN_HOSTS="$ROOT_DIR/.secrets/known_hosts"
[ -d "$ROOT_DIR/.secrets" ] || NIST_KNOWN_HOSTS="${HOME}/.ssh/known_hosts"

# Record the host key of every inventory host that is not already known.
nist_seed_known_hosts() {
  local kh="$NIST_KNOWN_HOSTS"
  mkdir -p "$(dirname "$kh")"
  touch "$kh"
  chmod 600 "$kh"

  local hosts
  hosts="$(ansible-inventory --list 2>/dev/null | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
hv = d.get("_meta", {}).get("hostvars", {})
for h in d.get("cui_hosts", {}).get("hosts", []):
    print(hv.get(h, {}).get("ansible_host", h))
' 2>/dev/null)"

  local h
  for h in $hosts; do
    # Already trusted? Leave it alone - a changed key should raise an error,
    # not be silently re-accepted.
    ssh-keygen -F "$h" -f "$kh" >/dev/null 2>&1 && continue
    ssh-keyscan -H "$h" >> "$kh" 2>/dev/null
  done
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
  local kh="$NIST_KNOWN_HOSTS"
  [ -f "$kh" ] || return 0

  local hosts
  hosts="$(ansible-inventory --list 2>/dev/null | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
hv = d.get("_meta", {}).get("hostvars", {})
for h in d.get("cui_hosts", {}).get("hosts", []):
    print(hv.get(h, {}).get("ansible_host", h))
' 2>/dev/null)"

  local h
  for h in $hosts; do
    ssh-keygen -R "$h" -f "$kh" >/dev/null 2>&1
    ssh-keyscan -H "$h" >> "$kh" 2>/dev/null
  done
  chmod 600 "$kh"
}
