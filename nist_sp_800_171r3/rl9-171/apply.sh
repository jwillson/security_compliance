#!/usr/bin/env bash
#
# Apply the NIST SP 800-171r3 overlay to the inventory.
#
#   ./apply.sh                      apply everything
#   ./apply.sh --tags 03.03         one family
#   ./apply.sh --tags 03.05.07      one requirement
#   ./apply.sh --check --diff       report drift without changing anything
#   ./apply.sh --limit rl9-cui-01   one host
#   ./apply.sh --reboot             apply, reboot the hosts that then report
#                                   "Reboot required: True" (a new kernel,
#                                   FIPS, audit rules), and apply again - what
#                                   `make all` does, so it ends settled
#                                   rather than with the kernel check failing
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
  if [[ -f inventory/kickstart.yml ]]; then
    echo "  the kickstart lab is in inventory/kickstart.yml: make apply / make verify" >&2
  else
    echo "  new lab VM:     make vm" >&2
  fi
  exit 1
}

# The role needs these collections; install them on first run.
if ! ansible-galaxy collection list 2>/dev/null | grep -q 'ansible.posix'; then
  echo "==> installing required Ansible collections"
  ansible-galaxy collection install -r requirements.yml
fi

. "$(dirname "${BASH_SOURCE[0]}")/lib/ssh-env.sh"
nist_seed_known_hosts

reboot=0 args=()
for a in "$@"; do if [[ "$a" == --reboot ]]; then reboot=1; else args+=("$a"); fi; done
log=$(mktemp); trap 'rm -f "$log"' EXIT
play() {
  echo "==> applying overlay $(awk '/^  version:/ {gsub(/"/,"",$2); print $2; exit}' catalog/overlay-rocky9.yml)"
  set +e; ansible-playbook site.yml ${args[@]+"${args[@]}"} 2>&1 | tee "$log"; rc=${PIPESTATUS[0]}; set -e
}
play
if (( reboot && rc == 0 )); then
  owed=$(awk '/^ok: \[/ {h=$2; gsub(/[][]/, "", h)} /Reboot required: True/ {print h}' "$log" | sort -u | paste -sd, -)
  if [[ -n "$owed" ]]; then
    echo "==> rebooting $owed, which reported a reboot owed, then applying again"
    ansible "$owed" -b -m ansible.builtin.reboot -a "reboot_timeout=900" </dev/null
    play
  fi
fi

# The role removes the weak DSA/ECDSA host keys (03.13.10), so a host trusted
# before the run presents a different key afterwards. Re-record it here, where
# the cause is known, rather than relaxing host key checking generally.
if [[ $rc -eq 0 ]]; then
  nist_refresh_known_hosts
fi
exit $rc
