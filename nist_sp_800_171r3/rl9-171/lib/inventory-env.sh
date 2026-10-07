# shellcheck shell=bash
# Sourced by apply.sh, verify.sh and the tools that reach hosts.
#
# One workstation can drive more than one lab - the kickstart lab (hosts built
# by vm/build-vm.sh, credentials in .secrets/) and the BYO lab (hosts you
# already have, credentials from the operator) - and the two must not share an
# inventory: each has its own collector, its own CA and its own second SSH
# factor. Each lab's tools choose its inventory (DEFECTS 7.33): the
# kickstart lab's - make, vm/build-vm.sh - inventory/kickstart.yml; hosts you
# bring and the BYO lab inventory/hosts.yml, the default here. A tool that
# names one host sets NIST_FOR_HOST, and the inventory listing it is taken.
# NIST_INVENTORY overrides all of it. Exporting ANSIBLE_INVENTORY from it
# makes every ansible and ansible-inventory call follow.
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
if [ -z "${NIST_INVENTORY:-}" ] && [ -n "${NIST_FOR_HOST:-}" ]; then
  # inventory.py writes each host as a 4-space key under cui_hosts.hosts.
  for _inv in inventory/kickstart.yml inventory/hosts.yml; do
    grep -q "^    ${NIST_FOR_HOST}:" "$NIST_ROOT/$_inv" 2>/dev/null && { NIST_INVENTORY=$_inv; break; }
  done
  unset _inv
fi
NIST_INVENTORY="${NIST_INVENTORY:-inventory/hosts.yml}"
case "$NIST_INVENTORY" in
  /*) ;;
  *)  NIST_INVENTORY="$NIST_ROOT/$NIST_INVENTORY" ;;
esac
export NIST_INVENTORY
export ANSIBLE_INVENTORY="$NIST_INVENTORY"
[ -f "$NIST_INVENTORY" ] && python3 "$NIST_ROOT/tools/inventory.py" tidy

# Secrets (TASKS C3): an ansible-vault file beside the inventory,
# inventory/NAME.vault.yml (tools/vault.sh writes it), holding the admin
# password - sudo's and the SSH password factor, which ansible answers itself
# - the GRUB password and the LUKS passphrase as group variables. It is a
# second inventory source, so every ansible call decrypts it. The vault
# password comes from NIST_VAULT_PASSWORD_FILE (a file, or an executable that
# prints it - a password manager) or is asked for once, without echo, and
# kept for this run in the container's own /dev/shm, which goes with it.
# No password is ever exported or typed on a command line.
NIST_VAULT="${NIST_INVENTORY%.yml}.vault.yml"
export NIST_VAULT
if [ -f "$NIST_VAULT" ]; then
  if [ -n "${NIST_VAULT_PASSWORD_FILE:-}" ]; then
    export ANSIBLE_VAULT_PASSWORD_FILE="$NIST_VAULT_PASSWORD_FILE"
  elif [ -z "${ANSIBLE_VAULT_PASSWORD_FILE:-}" ]; then
    if [ ! -t 0 ]; then
      echo "error: $NIST_VAULT is locked and there is no terminal to ask for its" >&2
      echo "  password: run interactively, or set NIST_VAULT_PASSWORD_FILE" >&2
      return 1 2>/dev/null || exit 1
    fi
    _vp=$(mktemp -p /dev/shm nist-vault.XXXXXX)
    IFS= read -rsp "vault password for $(basename "$NIST_VAULT"): " _pw </dev/tty; echo >&2
    printf '%s' "$_pw" > "$_vp"; unset _pw
    export ANSIBLE_VAULT_PASSWORD_FILE="$_vp"
    unset _vp
  fi
  export ANSIBLE_INVENTORY="$NIST_INVENTORY,$NIST_VAULT"
fi

# Without ansible-inventory the kind below reads "empty" and verify.sh went
# on to a Python traceback and "no hosts in group cui_hosts" (issue #14).
command -v ansible-inventory >/dev/null 2>&1 || {
  echo "error: ansible-inventory is not on PATH - this runs in the control-plane image (./nist)" >&2
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
