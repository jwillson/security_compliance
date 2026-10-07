#!/usr/bin/env bash
#
# Can this host run the lab? Read-only (DEFECTS 7.19; TASKS C4).
#
#   vm/host-check.sh [kickstart|byo|all]      default all
#
# The tool runs in its container (./nist checks for podman or docker), so the
# host needs only the hypervisor - and this asks the hypervisor itself,
# through its socket, rather than looking for programs:
#   - libvirt's system instance answers, as you, without sudo;
#   - QEMU with KVM behind it;
#   - UEFI firmware with Secure Boot (the role seals to PCR 7, the Secure
#     Boot state) - what libvirt's domain capabilities offer;
#   - an emulated TPM (swtpm) for the guests that seal to one;
#   - memory for the guests the lab runs: kickstart 4 GiB each (the CUI host,
#     then the collector), BYO 3 GiB each (two CUI hosts and a collector).
# Missing pieces are named with the host's package command (apt, dnf or
# pacman, from the host's /etc/os-release). Exits 1 if anything required is
# missing. Installs nothing. dnsmasq, which libvirt runs for the lab network,
# is reported by vm/lab-network.sh when the network cannot start.
#
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../lib/container.sh"
lab=${1:-all}
[[ "$lab" =~ ^(kickstart|byo|all)$ ]] || { sed -n '3,21p' "$0"; exit 2; }
V=(virsh -c "$NIST_LIBVIRT_URI")
fails=0
ok()   { echo "  ok    $*"; }
bad()  { echo "  FAIL  $*"; fails=$((fails + 1)); }
note() { echo "  note  $*"; }
# shellcheck disable=SC1091
. /host/etc/os-release 2>/dev/null || true
case " ${ID:-} ${ID_LIKE:-} " in
  *" debian "*|*" ubuntu "*) pkgs="sudo apt install qemu-system-x86 libvirt-daemon-system swtpm swtpm-tools ovmf dnsmasq-base" ;;
  *" rhel "*|*" fedora "*|*" centos "*) pkgs="sudo dnf install qemu-kvm libvirt swtpm swtpm-tools edk2-ovmf dnsmasq" ;;
  *" arch "*) pkgs="sudo pacman -S --needed qemu-full libvirt swtpm edk2-ovmf dnsmasq" ;;
  *) pkgs="" ;;
esac
echo "== $(hostname): ${PRETTY_NAME:-unknown OS}, checking for the $lab lab, through $NIST_LIBVIRT_URI"

if ! "${V[@]}" uri >/dev/null 2>&1; then
  bad "libvirt does not answer at $NIST_LIBVIRT_URI as $(id -un). Start it on the host - \
'sudo systemctl enable --now libvirtd' (one daemon: Ubuntu, Debian) or \
'sudo systemctl enable --now virtqemud.socket virtnetworkd.socket virtstoraged.socket' (RHEL 9, Fedora) - \
and be in its group: sudo usermod -aG libvirt $(id -un), then log in again"
  [[ -n "$pkgs" ]] && echo "== install: $pkgs"
  exit 1
fi
ok "libvirt answers as $(id -un), without sudo"

caps=$("${V[@]}" domcapabilities --virttype kvm --arch x86_64 --machine q35 2>/dev/null)
if [[ -z "$caps" ]]; then
  bad "libvirt has no QEMU/KVM: install QEMU, enable VT-x/AMD-V in the firmware, load kvm_intel or kvm_amd"
else
  ok "QEMU with KVM"
  if grep -A3 "<enum name='secure'>" <<<"$caps" | grep -q '<value>yes</value>'; then ok "UEFI firmware with Secure Boot"
  else bad "no UEFI firmware with Secure Boot (OVMF/edk2 with its secure-boot build)"; fi
  if grep -A12 "<tpm supported='yes'>" <<<"$caps" | grep -q '<value>emulator</value>'; then ok "an emulated TPM for the guests (swtpm)"
  else bad "no emulated TPM: install swtpm and swtpm-tools"; fi
fi

pool=$("${V[@]}" pool-dumpxml default 2>/dev/null | sed -n 's:.*<path>\(.*\)</path>.*:\1:p' | head -1)
if [[ -n "$pool" ]]; then ok "storage pool default ($pool)"
else bad "no storage pool 'default': sudo virsh pool-define-as default dir --target /var/lib/libvirt/images; sudo virsh pool-autostart default; sudo virsh pool-start default"; fi

need_mb=0
[[ "$lab" == kickstart || "$lab" == all ]] && need_mb=$((need_mb + 2 * 4096))
[[ "$lab" == byo || "$lab" == all ]] && need_mb=$((need_mb + 3 * 3072))
avail_mb=$("${V[@]}" nodememstats 2>/dev/null | awk '/^(free|buffers|cached)/ {kb += $3} END {print int(kb / 1024)}')
if (( avail_mb >= need_mb )); then ok "memory: ${avail_mb} MiB available, ${need_mb} MiB for every guest of the $lab lab"
elif (( avail_mb >= 4096 )); then note "memory: ${avail_mb} MiB available, ${need_mb} MiB for every guest at once - build them one by one"
else bad "memory: ${avail_mb} MiB available; one guest needs 3-4 GiB"; fi

if (( fails )); then
  [[ -n "$pkgs" ]] && echo "== install: $pkgs"
  echo "== $fails problem(s): this host cannot run the $lab lab yet"; exit 1
fi
echo "== this host can run the $lab lab"
