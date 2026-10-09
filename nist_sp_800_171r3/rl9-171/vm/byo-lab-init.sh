#!/usr/bin/env bash
#
# Create the BYO lab's operator directory, $NIST_BYO_LAB (default
# ~/.local/share/nist-byo-lab), and the lab inventory's vault (DEFECTS 7.16,
# issue #15; TASKS C3, C4). Run once on a workstation, before
# vm/byo-guest.sh build.
#
#   vm/byo-lab-init.sh
#
# Creates only what is missing and never overwrites a secret, so it is safe on
# a lab already in use. The lab's secrets are random, written 0600, never
# printed, and live only here:
#   byoadmin_password   sudo on every BYO guest, and the SSH second factor
#   grub_password       the GRUB superuser's (03.10.07)
#   luks_passphrase     the CUI volumes' (03.08.09)
#   vault_password      unlocks inventory/hosts.vault.yml, the vault the tools
#                       read those three from (written by tools/vault.sh)
# and env.sh, which holds no secret: it names the vault password file
# (NIST_VAULT_PASSWORD_FILE), the lab's PKI directory and the inventory, for a
# shell that runs the BYO lab. Guests get the operator's own RSA key,
# $NIST_BYO_KEY (default ~/.ssh/id_rsa) - RSA, since the FIPS policy refuses
# ed25519 (README).
#
# Retired, and removed from a lab directory made before (TASKS C4): the
# Ansible venv, its collections and tools.sh - the tool runs in its container,
# which carries the pinned Ansible - and the askpass scripts, now that ansible
# answers the SSH password factor itself.
#
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../lib/container.sh"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
LAB="${NIST_BYO_LAB:-$HOME/.local/share/nist-byo-lab}"
say() { echo "==> $*"; }
made() { echo "    created $1"; }

install -d -m 0700 "$LAB" "$LAB/pki"
umask 077

secret() {   # name length
  [[ -s "$LAB/$1" ]] && return 0
  head -c 64 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c "$2" > "$LAB/$1"
  made "$1 (random, 0600)"
}
say "secrets in $LAB"
secret byoadmin_password 24
secret grub_password 24
secret luks_passphrase 32
secret vault_password 32

# The lab's vault: the same secrets, encrypted, where every tool reads them.
# tools/vault.sh takes them from files named for it, staged in the
# container's own RAM.
vault="$ROOT/inventory/hosts.vault.yml"
if [[ ! -f "$vault" ]]; then
  stage=$(mktemp -d -p /dev/shm)
  cp "$LAB/byoadmin_password" "$stage/admin_password"
  cp "$LAB/grub_password" "$stage/grub_password"
  cp "$LAB/luks_passphrase" "$stage/luks_passphrase"
  NIST_VAULT_PASSWORD_FILE="$LAB/vault_password" "$ROOT/tools/vault.sh" inventory/hosts.yml --from "$stage" >/dev/null
  rm -rf "$stage"
  made "inventory/hosts.vault.yml (ansible-vault; its password in $LAB/vault_password)"
fi

# env.sh: paths only, no secret. Rewritten each time: it once exported the
# secrets themselves.
cat > "$LAB/env.sh" <<EOF
# Source from nist_sp_800_171r3/rl9-171 before the tools, for the BYO lab.
# Written by vm/byo-lab-init.sh. It holds no secret: it names where they are.
export NIST_INVENTORY=inventory/hosts.yml
export NIST_VAULT_PASSWORD_FILE=$LAB/vault_password
export NIST_PKI_DIR=$LAB/pki
EOF
chmod 600 "$LAB/env.sh"
say "env.sh: the inventory, the vault password file and the PKI directory - no secrets"

for old in venv collections tools.sh askpass.sh wrongpass.sh; do
  if [[ -e "$LAB/$old" ]]; then rm -rf "${LAB:?}/$old"; echo "    removed $old (retired: the tool runs in its container)"; fi
done

key="${NIST_BYO_KEY:-$HOME/.ssh/id_rsa}"
[[ -f "$key.pub" ]] || echo "note: no $key.pub - create an RSA key (./nist ssh-keygen -t rsa -b 3072) or set NIST_BYO_KEY before ./nist byo-guest build"
say "done: source $LAB/env.sh, then ./nist byo-guest build NAME --ip 192.168.171.N"
