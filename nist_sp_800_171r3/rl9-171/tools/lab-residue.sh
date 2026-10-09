#!/usr/bin/env bash
#
# List everything the labs leave on this host (DEFECTS 7.18). Read-only.
#
#   tools/lab-residue.sh            what exists, grouped; exit 0
#   tools/lab-residue.sh --orphans  only what belongs to no defined guest;
#                                   exit 1 if there is any
#
# A lab guest is a libvirt domain attached to the lab network, or one whose
# name a lab script uses (rl9-*, byo-*). Looked for, through the libvirt
# socket in the control-plane container: the domains and the networks, and
# every volume in libvirt's pools - disks, install and seed ISOs, base images.
# A guest's UEFI variables and TPM state go with `undefine --nvram --tpm`,
# and libvirt keeps its own per-domain logs, rotated by it; neither is in a
# pool, and neither is looked for here (TASKS C5). The operator-side inputs -
# .secrets/, the BYO lab directory, the downloaded ISO - are not residue and
# are not listed.
#
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../lib/container.sh"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
V=(virsh -c "$NIST_LIBVIRT_URI")
NET=$(sed -n 's:.*<name>\(.*\)</name>.*:\1:p' "$HERE/../vm/nist-lab-network.xml" | head -1)
orphans=0; only_orphans=0
[[ "${1:-}" == --orphans ]] && only_orphans=1

lab_name() { [[ "$1" =~ ^(rl9|byo|ptest)- ]]; }
domains=$("${V[@]}" list --all --name 2>/dev/null | awk 'NF' | sort)
lab_domains=$(for d in $domains; do
  if lab_name "$d" || "${V[@]}" domiflist "$d" 2>/dev/null | awk -v n="$NET" '$3==n {f=1} END {exit !f}'; then echo "$d"; fi
done)

show() {   # kind item owner(empty = orphan)
  if [[ -z "$3" ]]; then orphans=$((orphans + 1)); printf '  %-10s %s  (orphan)\n' "$1" "$2"
  elif (( ! only_orphans )); then printf '  %-10s %s  (%s)\n' "$1" "$2" "$3"; fi
}
owner_of() {   # volume name -> the lab domain it belongs to, or empty
  local f=$1 d
  for d in $lab_domains; do [[ "$f" == "$d".* || "$f" == "$d"-* || "$f" == "$d"_* ]] && { echo "$d"; return; }; done
}

echo "== lab residue in $NIST_LIBVIRT_URI"
for d in $lab_domains; do show domain "$d" "$("${V[@]}" domstate "$d" 2>/dev/null)"; done
if "${V[@]}" net-info "$NET" >/dev/null 2>&1; then
  show network "$NET" "$([ -n "$lab_domains" ] && echo "in use" || echo "no guest left")"
fi
"${V[@]}" net-info nist-ptest >/dev/null 2>&1 && show network nist-ptest "vm/portability-host.sh"
for pool in $("${V[@]}" pool-list --name 2>/dev/null); do
  for f in $("${V[@]}" vol-list --pool "$pool" 2>/dev/null | awk 'NR > 2 && NF {print $1}'); do
    case "$f" in
      Rocky-*-boot.iso) show iso "$pool/$f" "staged by an older build-vm.sh; ./nist teardown removes it" ;;
      rocky9-genericcloud-base.qcow2) show base "$pool/$f" "BYO base image" ;;
      ptest-base-*.qcow2) show base "$pool/$f" "portability test image" ;;
      *) lab_name "$f" || continue; show volume "$pool/$f" "$(owner_of "$f")" ;;
    esac
  done
done
(( orphans )) && echo "== $orphans orphan(s): residue of guests that no longer exist" || echo "== no orphans"
(( only_orphans && orphans )) && exit 1
exit 0
