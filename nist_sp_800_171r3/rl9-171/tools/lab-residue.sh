#!/usr/bin/env bash
#
# List everything the labs leave on this host (DEFECTS 7.18). Read-only.
#
#   tools/lab-residue.sh            what exists, grouped; exit 0
#   tools/lab-residue.sh --orphans  only what belongs to no defined guest;
#                                   exit 1 if there is any
#
# A lab guest is a libvirt domain attached to the lab network, or one whose
# name a lab script uses (rl9-*, byo-*). Looked for: the domains and the
# network; disks, snapshots and staged ISOs in the image directory; UEFI
# variable stores; TPM state; the logs libvirt keeps per domain. The
# operator-side inputs -
# .secrets/, the BYO lab directory, the downloaded ISO - are not residue and
# are not listed.
#
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
V=(sudo virsh -c qemu:///system)
IMAGES=/var/lib/libvirt/images NVRAM=/var/lib/libvirt/qemu/nvram
SWTPM=/var/lib/libvirt/swtpm QLOG=/var/log/libvirt/qemu
NET=$(sed -n 's:.*<name>\(.*\)</name>.*:\1:p' "$HERE/../vm/nist-lab-network.xml" | head -1)
orphans=0; only_orphans=0
[[ "${1:-}" == --orphans ]] && only_orphans=1

lab_name() { [[ "$1" =~ ^(rl9|byo|ptest)- ]]; }
domains=$("${V[@]}" list --all --name 2>/dev/null | awk 'NF' | sort)
lab_domains=$(for d in $domains; do
  if lab_name "$d" || "${V[@]}" domiflist "$d" 2>/dev/null | awk -v n="$NET" '$3==n {f=1} END {exit !f}'; then echo "$d"; fi
done)
defined() { grep -qx -- "$1" <<<"$lab_domains"; }
uuids=$(for d in $lab_domains; do "${V[@]}" domuuid "$d" 2>/dev/null; done)
all_uuids=$(for d in $domains; do "${V[@]}" domuuid "$d" 2>/dev/null; done)

show() {   # kind item owner(empty = orphan)
  if [[ -z "$3" ]]; then orphans=$((orphans + 1)); printf '  %-10s %s  (orphan)\n' "$1" "$2"
  elif (( ! only_orphans )); then printf '  %-10s %s  (%s)\n' "$1" "$2" "$3"; fi
}
owner_of_file() {   # base name -> the lab domain it belongs to, or empty
  local f=$1 d
  for d in $lab_domains; do [[ "$f" == "$d".* || "$f" == "$d"-* || "$f" == "$d"_* ]] && { echo "$d"; return; }; done
}

echo "== lab residue on $(hostname)"
for d in $lab_domains; do show domain "$d" "$("${V[@]}" domstate "$d" 2>/dev/null)"; done
if "${V[@]}" net-info "$NET" >/dev/null 2>&1; then
  show network "$NET" "$([ -n "$lab_domains" ] && echo "in use" || echo "no guest left")"
fi
"${V[@]}" net-info nist-ptest >/dev/null 2>&1 && show network nist-ptest "vm/portability-host.sh"
for f in $(sudo ls "$IMAGES" 2>/dev/null); do
  case "$f" in
    Rocky-*.iso) show iso "$IMAGES/$f" "staged by build-vm.sh" ;;
    rocky9-genericcloud-base.qcow2) show base "$IMAGES/$f" "BYO base image" ;;
    ptest-base-*.qcow2) show base "$IMAGES/$f" "portability test image" ;;
    *) lab_name "$f" || continue; show disk "$IMAGES/$f" "$(owner_of_file "$f")" ;;
  esac
done
for f in $(sudo ls "$NVRAM" 2>/dev/null); do
  lab_name "$f" || continue; show nvram "$NVRAM/$f" "$(owner_of_file "$f")"
done
for u in $(sudo ls "$SWTPM" 2>/dev/null); do
  if grep -qx -- "$u" <<<"$uuids"; then (( only_orphans )) || show tpm "$SWTPM/$u" "lab guest"
  elif ! grep -qx -- "$u" <<<"$all_uuids"; then show tpm "$SWTPM/$u" ""; fi
done
for f in $(sudo ls "$QLOG" 2>/dev/null); do
  lab_name "$f" || continue; show log "$QLOG/$f" "$(owner_of_file "$f")"
done
(( orphans )) && echo "== $orphans orphan(s): residue of guests that no longer exist" || echo "== no orphans"
(( only_orphans && orphans )) && exit 1
exit 0
