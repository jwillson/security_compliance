#!/usr/bin/env bash
#
# Apply the NIST SP 800-171r3 overlay to the inventory.
#
#   ./apply.sh                      apply everything
#   ./apply.sh --tags 03.03         one family
#   ./apply.sh --tags 03.05.07      one requirement
#   ./apply.sh --check --diff       report drift without changing anything
#   ./apply.sh --limit rl9-cui-01   one host
#
# NIST_INVENTORY picks the inventory (default inventory/hosts.yml): one per
# lab, see lib/inventory-env.sh.
#
# Any additional arguments are passed through to ansible-playbook.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

. lib/inventory-env.sh || exit 1
[[ -f "$NIST_INVENTORY" ]] || {
  echo "error: no inventory at $NIST_INVENTORY." >&2
  echo "  existing host:  cp inventory/hosts.yml.example inventory/hosts.yml && edit" >&2
  echo "  new lab VM:     make vm" >&2
  exit 1
}

# The role needs these collections; install them on first run.
if ! ansible-galaxy collection list 2>/dev/null | grep -q 'ansible.posix'; then
  echo "==> installing required Ansible collections"
  ansible-galaxy collection install -r requirements.yml
fi

. "$(dirname "${BASH_SOURCE[0]}")/lib/ssh-env.sh"
nist_seed_known_hosts

echo "==> applying overlay $(awk '/^  version:/ {gsub(/"/,"",$2); print $2; exit}' catalog/overlay-rocky9.yml)"
ansible-playbook site.yml "$@"
rc=$?

# The role removes the weak DSA/ECDSA host keys (03.13.10), so a host trusted
# before the run presents a different key afterwards. Re-record it here, where
# the cause is known, rather than relaxing host key checking generally.
if [[ $rc -eq 0 ]]; then
  nist_refresh_known_hosts
fi
exit $rc
