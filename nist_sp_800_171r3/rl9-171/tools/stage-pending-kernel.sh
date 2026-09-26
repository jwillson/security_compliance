#!/usr/bin/env bash
#
# Put a lab host in the state dnf-automatic leaves it in: a newer kernel
# installed and set as the default, an older one still running. Used to prove
# that apply.sh reports the reboot that is owed (DEFECTS 6b.10) - it used to
# say "Reboot required: False" in exactly this state.
#
#   tools/stage-pending-kernel.sh HOST
#
# Boots the newest-but-one installed kernel once, then sets the newest as the
# default again, as `dnf install kernel` would have. Needs two installed
# kernels. Source the lab's env.sh first. The host keeps working throughout;
# the next reboot (e.g. by tools/harden-cycle.sh) boots the newest kernel.
#
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE/.."
# ssh-env, not just inventory-env: this script runs ansible itself (the reboot), and once 03.05.03 is applied every connection needs the second
# factor - for a lab inventory only ssh-env supplies it - and a host key
# already known (a kickstart host is new until seeded).
. lib/ssh-env.sh || exit 2
nist_seed_known_hosts
host=${1:?usage: tools/stage-pending-kernel.sh HOST}

sh() { ansible "$host" -b -m ansible.builtin.shell -a "$1" 2>/dev/null | sed 1d; }

mapfile -t k < <(sh "rpm -q --last kernel | awk '{print \$1}' | sed 's/^kernel-//'")
(( ${#k[@]} >= 2 )) || { echo "error: $host has ${#k[@]} kernel(s); two are needed" >&2; exit 1; }
newest=${k[0]} older=${k[1]}
echo "==> $host: newest $newest, booting $older once"
sh "grubby --set-default /boot/vmlinuz-$older" >/dev/null
# Both streams redirected: ansible refuses a non-blocking stderr, which this
# script's pipes can hand it ("Ansible requires blocking IO").
ansible "$host" -b -m ansible.builtin.reboot -a reboot_timeout=900 >/dev/null 2>&1
sh "grubby --set-default /boot/vmlinuz-$newest" >/dev/null
echo "==> running $(sh 'uname -r'); default $(sh 'grubby --default-kernel')"
