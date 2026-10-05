#!/usr/bin/env bash
#
# Remove both labs from this host, leaving nothing behind (DEFECTS 7.18).
#
#   vm/lab-teardown.sh          list what goes, ask, remove   (make teardown)
#   vm/lab-teardown.sh --yes    without asking
#
# Every lab guest - BYO (vm/byo-guest.sh destroy), kickstart
# (vm/build-vm.sh --destroy) and portability test host
# (vm/portability-host.sh destroy, with its network and images) - with its disks, snapshots, UEFI variables, TPM
# state, DHCP pin, libvirt logs, host key and inventory entry; the stand-in
# SIEM and its podman network; the lab network; the staged boot ISO and the
# cached BYO base image in the libvirt image directory; the per-guest
# cloud-init seeds in the BYO lab directory. Then tools/lab-residue.sh must
# find nothing, or this exits 1 saying what is left.
#
# Kept, because they are inputs rather than residue and a rebuild needs them:
# .secrets/ (the kickstart lab's key and passwords), iso/ (the downloaded
# ISO), and the BYO lab directory's secrets and tooling. Remove those by hand
# only if you mean never to rebuild: rm -rf .secrets iso "$NIST_BYO_LAB".
#
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
cd "$ROOT" || exit 2
V=(sudo virsh -c qemu:///system)
LAB="${NIST_BYO_LAB:-$HOME/.local/share/nist-byo-lab}"
NET=$(sed -n 's:.*<name>\(.*\)</name>.*:\1:p' vm/nist-lab-network.xml | head -1)
say() { echo "==> $*"; }

guests=$(for d in $("${V[@]}" list --all --name 2>/dev/null); do
  if [[ "$d" =~ ^(rl9|byo|ptest)- ]] || "${V[@]}" domiflist "$d" 2>/dev/null | awk -v n="$NET" '$3==n {f=1} END {exit !f}'; then echo "$d"; fi
done | sort)

echo "This removes both labs from $(hostname):"
echo "  guests:  ${guests:-none}" | tr '\n' ' '; echo
echo "  and the lab network, the stand-in SIEM, the staged ISO, the BYO base image."
echo "  Kept: .secrets/, iso/, and the secrets and tooling in $LAB."
if [[ "${1:-}" != --yes ]]; then
  read -r -p "Type 'teardown' to go on: " answer
  [[ "$answer" == teardown ]] || { echo "nothing removed"; exit 1; }
fi

for g in $guests; do
  if [[ "$g" == ptest-* ]]; then
    say "$g (portability test host)"; ./vm/portability-host.sh destroy "${g#ptest-}" || true
  elif [[ "$g" == byo-* ]]; then
    say "$g (BYO)"; ./vm/byo-guest.sh destroy "$g" || true
    sudo rm -rf "${LAB:?}/$g"            # its cloud-init seed and passwords
  else
    role=cui; [[ "$g" == *log* ]] && role=log
    # The destroy reads the guest's address from the inventory that holds it
    # (to forget its host key) and then removes its entry there.
    inv=inventory/hosts.yml
    for i in inventory/kickstart.yml inventory/hosts.yml; do
      [[ -f "$i" ]] && NIST_INVENTORY="$i" ./tools/inventory.py show 2>/dev/null | awk -v n="$g" '$1==n {f=1} END {exit !f}' && { inv=$i; break; }
    done
    say "$g (kickstart, $inv)"
    NIST_INVENTORY="$inv" ./vm/build-vm.sh --name "$g" --role "$role" --destroy || true
  fi
done

[[ -x vm/siem-container.sh ]] && command -v podman >/dev/null 2>&1 && { say "stand-in SIEM"; ./vm/siem-container.sh down || true; }
say "lab network"; ./vm/lab-network.sh destroy || true
say "staged ISO, BYO base image, orphaned logs"
sudo bash -c 'rm -f /var/lib/libvirt/images/Rocky-*-boot.iso /var/lib/libvirt/images/rocky9-genericcloud-base.qcow2
              rm -f /var/log/libvirt/qemu/rl9-*.log /var/log/libvirt/qemu/byo-*.log'

echo
./tools/lab-residue.sh
left=$(./tools/lab-residue.sh | grep -c '^  ')
if (( left > 0 )); then echo "==> FAIL: $left item(s) left behind" >&2; exit 1; fi
echo "==> PASS: nothing of the labs is left on $(hostname)"
