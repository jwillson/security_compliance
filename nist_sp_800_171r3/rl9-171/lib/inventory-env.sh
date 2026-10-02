# Sourced by apply.sh, verify.sh and the tools that reach hosts.
#
# One workstation can drive more than one lab - the kickstart lab (hosts built
# by vm/build-vm.sh, credentials in .secrets/) and the BYO lab (hosts you
# already have, credentials from the operator) - and the two must not share an
# inventory: each has its own collector, its own CA and its own second SSH
# factor. NIST_INVENTORY selects the inventory file (default
# inventory/hosts.yml); exporting ANSIBLE_INVENTORY from it makes every
# ansible and ansible-inventory call follow.
#
# NIST_INVENTORY_KIND is derived from the inventory, never assumed:
#   lab    every host connects with the .secrets/ key (tools/inventory.py
#          --connection lab); .secrets/askpass.sh is the second factor
#   byo    no host uses the .secrets/ key; the operator's SSH_ASKPASS is
#   empty  no hosts yet
# An inventory that mixes the two is refused: one SSH_ASKPASS cannot serve
# both, and handing a host the other lab's password is a failed
# authentication - a faillock strike (03.01.08) on every connection.

NIST_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NIST_INVENTORY="${NIST_INVENTORY:-inventory/hosts.yml}"
case "$NIST_INVENTORY" in
  /*) ;;
  *)  NIST_INVENTORY="$NIST_ROOT/$NIST_INVENTORY" ;;
esac
export NIST_INVENTORY
export ANSIBLE_INVENTORY="$NIST_INVENTORY"

# Without ansible-inventory the kind below reads "empty" and verify.sh went
# on to a Python traceback and "no hosts in group cui_hosts" (issue #14).
command -v ansible-inventory >/dev/null 2>&1 || {
  echo "error: ansible-inventory is not on PATH - install ansible-core, or source your lab's tools.sh/env.sh" >&2
  return 2 2>/dev/null || exit 2
}

NIST_INVENTORY_KIND="$(
  [ -f "$NIST_INVENTORY" ] || { echo empty; exit 0; }
  ansible-inventory --list 2>/dev/null | python3 -c '
import json, sys
try:
    hv = json.load(sys.stdin).get("_meta", {}).get("hostvars", {})
except Exception:
    print("empty"); sys.exit(0)
kinds = {"lab" if ".secrets/" in str(v.get("ansible_ssh_private_key_file", "")) else "byo"
         for v in hv.values()}
print("empty" if not kinds else kinds.pop() if len(kinds) == 1 else "mixed")
')"
export NIST_INVENTORY_KIND

if [ "$NIST_INVENTORY_KIND" = mixed ]; then
  echo "error: $NIST_INVENTORY mixes kickstart-lab hosts (.secrets/ key) and hosts" >&2
  echo "  you brought. Each needs its own second SSH factor, and a wrong one is a" >&2
  echo "  faillock strike. Keep them in separate inventories and pick one with" >&2
  echo "  NIST_INVENTORY (docs/LAB.md)." >&2
  return 1 2>/dev/null || exit 1
fi

# A lab inventory takes its secrets from .secrets/. The role reads
# NIST_PKI_DIR, NIST_GRUB_PASSWORD and NIST_LUKS_PASSPHRASE from the
# environment first - right for a real deployment - so in a shell where the
# BYO lab's env.sh was sourced, a kickstart run would quietly be given the
# other lab's CA, GRUB password and LUKS passphrase. Refused unless meant.
if [ "$NIST_INVENTORY_KIND" = lab ] && [ -z "${NIST_ALLOW_ENV_SECRETS:-}" ]; then
  _set=""
  for _v in NIST_PKI_DIR NIST_GRUB_PASSWORD NIST_LUKS_PASSPHRASE; do
    [ -n "${!_v:-}" ] && _set="$_set $_v"
  done
  if [ -n "$_set" ]; then
    echo "error: $NIST_INVENTORY holds kickstart-lab hosts, which take their secrets" >&2
    echo "  from .secrets/, but this shell sets:$_set" >&2
    echo "  (the BYO lab's env.sh sets them). Use a fresh shell for this lab, or set" >&2
    echo "  NIST_ALLOW_ENV_SECRETS=1 if these values are really meant for it." >&2
    return 1 2>/dev/null || exit 1
  fi
fi
