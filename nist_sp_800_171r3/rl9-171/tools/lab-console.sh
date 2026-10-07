#!/usr/bin/env bash
#
# The serial console of a lab guest: the way in when SSH cannot be used - a
# firewall or sshd mistake, an account locked by faillock, a boot waiting for
# the LUKS passphrase (DEFECTS 7.20; RUNBOOK, "When you are locked out").
#
#   tools/lab-console.sh HOST        attach; leave with Ctrl+]
#
# Prints, before attaching, which account and which password file to use -
# never the password itself. Press Enter once attached to get a login prompt.
# The console is not SSH, so the key is not asked for, but faillock still
# counts: three wrong passwords lock the account for the ODP period.
#
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../lib/container.sh"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE/.." || exit 2
host=${1:?usage: tools/lab-console.sh HOST}
NIST_FOR_HOST=$host . lib/inventory-env.sh || exit 2
user=$(ansible-inventory --host "$host" 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin).get("ansible_user",""))' 2>/dev/null || true)
if [[ "$NIST_INVENTORY_KIND" == lab ]]; then pw="$PWD/.secrets/admin_password"; luks="$PWD/.secrets/luks_passphrase"
else pw="the vault: ./nist ansible-vault view ${NIST_VAULT#"$PWD/"} (ansible_password)"; luks="the same vault (nist_luks_passphrase)"; fi
cat <<MSG
==> $host serial console (leave with Ctrl+]; press Enter for a prompt)
    log in as:     ${user:-the admin account}
    password in:   $pw
    at boot, a LUKS prompt takes the passphrase in $luks
    three wrong passwords lock the account (faillock, 03.01.08)
MSG
exec virsh -c "$NIST_LIBVIRT_URI" console "$host"
