#!/usr/bin/env bash
#
# Write an inventory's secrets into its ansible-vault file (TASKS C3).
#
#   tools/vault.sh [INVENTORY]     default inventory/hosts.yml -> inventory/hosts.vault.yml
#   tools/vault.sh INVENTORY --force   replace an existing vault
#   tools/vault.sh INVENTORY --from DIR   automation: the secrets from DIR's files
#       admin_password, grub_password, luks_passphrase (optional), and the vault
#       password from NIST_VAULT_PASSWORD_FILE - nothing asked
#
# Asks, without echo and twice each: the admin account's password (sudo, and
# the SSH password factor of 03.05.03, which ansible answers itself), the
# GRUB superuser password (03.10.07) and the LUKS passphrase (03.08.09; leave
# it empty and the encrypted volumes are skipped and reported). Then the
# vault password, unless NIST_VAULT_PASSWORD_FILE names a file or a script
# that prints it (a password manager). The values travel only through pipes
# - never a command line, never the environment, never a file in the clear -
# into `ansible-vault encrypt`, and land as group variables in an AES-256
# vault beside the inventory, which every tool then reads as a second
# inventory source (lib/inventory-env.sh). Git ignores inventory/*.yml.
#
# To read it back: ./nist ansible-vault view inventory/hosts.vault.yml
#
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../lib/container.sh"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
inv=${1:-inventory/hosts.yml}; force=0 from=""
[[ "${2:-}" == --force ]] && force=1
[[ "${2:-}" == --from && -d "${3:-}" ]] && { from=$3; force=1; }
[[ "$inv" == *.yml && "$inv" != *.vault.yml ]] || { sed -n '3,26p' "$0"; exit 2; }
vault="${inv%.yml}.vault.yml"
[[ -e "$vault" && $force -eq 0 ]] && { echo "error: $vault exists (--force to replace it)" >&2; exit 1; }
[[ -n "$from" || -t 0 ]] || { echo "error: needs a terminal to ask for the secrets (or --from DIR)" >&2; exit 2; }

ask() {   # PROMPT [optional] -> the value on stdout; asked twice, never echoed
  local a b
  while :; do
    IFS= read -rsp "$1: " a </dev/tty; echo >&2
    [[ -z "$a" && "${2:-}" == optional ]] && { printf ''; return; }
    [[ -n "$a" ]] || { echo "  empty - again" >&2; continue; }
    [[ "$a" != *$'\n'* ]] || { echo "  no newlines - again" >&2; continue; }
    IFS= read -rsp "$1 (again): " b </dev/tty; echo >&2
    [[ "$a" == "$b" ]] && { printf '%s' "$a"; return; }
    echo "  they differ - again" >&2
  done
}

if [[ -n "$from" ]]; then
  [[ -n "${NIST_VAULT_PASSWORD_FILE:-}" ]] || { echo "error: --from needs NIST_VAULT_PASSWORD_FILE" >&2; exit 2; }
  admin=$(cat "$from/admin_password"); grub=$(cat "$from/grub_password")
  luks=$(cat "$from/luks_passphrase" 2>/dev/null || true)
else
  admin=$(ask "admin account password (sudo and SSH)")
  grub=$(ask "GRUB superuser password")
  luks=$(ask "LUKS passphrase (empty: no encrypted volumes)" optional)
fi
if [[ -n "${NIST_VAULT_PASSWORD_FILE:-}" ]]; then vpf=$NIST_VAULT_PASSWORD_FILE
else
  vpf=$(mktemp -p /dev/shm nist-vault.XXXXXX)   # the container's own RAM, gone with it
  ask "vault password" > "$vpf"
fi

# YAML from Python (quoting done right), the values on its stdin, one per line.
umask 077
printf '%s\n%s\n%s\n' "$admin" "$grub" "$luks" | python3 -c '
import sys, yaml
admin, grub, luks = (sys.stdin.readline().rstrip("\n") for _ in range(3))
v = {"ansible_become_password": admin, "ansible_password": admin, "nist_grub_password": grub}
if luks:
    v["nist_luks_passphrase"] = luks
sys.stdout.write("# Written by tools/vault.sh: the secrets of %s.\n" % sys.argv[1])
yaml.safe_dump({"all": {"vars": v}}, sys.stdout, default_flow_style=False)
' "$inv" | ansible-vault encrypt --vault-password-file "$vpf" --output "$vault" - 2>/dev/null
unset admin grub luks
chmod 600 "$vault"
echo "==> wrote $vault (ansible-vault, AES-256); the tools ask for its password when they need it"
