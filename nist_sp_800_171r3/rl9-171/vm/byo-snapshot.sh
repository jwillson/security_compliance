#!/usr/bin/env bash
#
# Save or revert a lab guest by copying its files, for guests where libvirt
# snapshots do not work: `virsh snapshot-create-as` refuses a UEFI guest with
# raw NVRAM ("internal snapshots ... require QCOW2 nvram format"; DEFECTS 3.1).
#
#   vm/byo-snapshot.sh save   NAME LABEL    shut down, copy, start again
#   vm/byo-snapshot.sh revert NAME LABEL    stop, copy back, start, wait for SSH
#   vm/byo-snapshot.sh list   [NAME]
#
# A snapshot is every file the guest's state lives in:
#   each disk (not the cloud-init cdrom)  -> <disk>.LABEL.qcow2
#   the UEFI variable store                -> NAME.LABEL.nvram
#   the vTPM state, when it has one        -> NAME.LABEL.tpm/
# The TPM state matters: a LUKS volume bound with clevis tpm2 cannot be
# unlocked after a revert that restores the disk but not the TPM it was
# sealed to. Names are compatible with the original byo-rl9-01.{fresh,hardened}
# copies. Labels in use: fresh (right after cloud-init), hardened (applied,
# rebooted, settled).
#
set -euo pipefail

IMAGES=/var/lib/libvirt/images
LAB="${NIST_BYO_LAB:-$HOME/.local/share/nist-byo-lab}"
KEY="${NIST_BYO_KEY:-$HOME/.ssh/id_rsa}"
VIRSH=(virsh -c qemu:///system)

die() { echo "error: $*" >&2; exit 1; }
say() { echo "==> $*"; }

disks() {   # file-backed disks, not cdroms
  "${VIRSH[@]}" domblklist "$1" --details | awk '$1=="file" && $2=="disk" {print $4}'
}
nvram() {
  "${VIRSH[@]}" dumpxml "$1" | grep -oP '(?<=<nvram)[^>]*>\K[^<]+' | head -1
}
tpmdir() {  # libvirt keeps swtpm state per domain UUID
  local uuid; uuid=$("${VIRSH[@]}" domuuid "$1")
  sudo test -d "/var/lib/libvirt/swtpm/$uuid" && echo "/var/lib/libvirt/swtpm/$uuid" || true
}
snap_of() { echo "${1%.qcow2}.$2.qcow2"; }

stop() {
  [[ "$("${VIRSH[@]}" domstate "$1")" == "shut off" ]] && return 0
  "${VIRSH[@]}" shutdown "$1" >/dev/null
  local i; for i in $(seq 1 60); do
    [[ "$("${VIRSH[@]}" domstate "$1")" == "shut off" ]] && return 0; sleep 2
  done
  say "$1 did not shut down cleanly in 2 minutes; forcing it off"
  "${VIRSH[@]}" destroy "$1" >/dev/null
}

wait_ssh() {
  local ip; ip=$(cat "$LAB/$1/ip" 2>/dev/null || true)
  [[ -n "$ip" ]] || { say "no $LAB/$1/ip; not waiting for SSH"; return 0; }
  local i; for i in $(seq 1 60); do
    timeout 20 ssh -i "$KEY" -o BatchMode=yes -o ConnectTimeout=5 "byoadmin@$ip" true 2>/dev/null \
      && { say "$1 up, SSH answering"; return 0; }
    sleep 5
  done
  die "$1 did not answer SSH within 5 minutes"
}

cmd_save() {
  local name=${1:?name} label=${2:?label} d t nv
  stop "$name"
  for d in $(disks "$name"); do sudo cp --sparse=always -f "$d" "$(snap_of "$d" "$label")"; done
  nv=$(nvram "$name"); [[ -n "$nv" ]] && sudo cp -f "$nv" "$IMAGES/$name.$label.nvram"
  t=$(tpmdir "$name")
  if [[ -n "$t" ]]; then
    sudo rm -rf "$IMAGES/$name.$label.tpm"; sudo cp -a "$t" "$IMAGES/$name.$label.tpm"
  fi
  "${VIRSH[@]}" start "$name" >/dev/null
  say "saved $name as '$label'${t:+ (with TPM state)}"
  wait_ssh "$name"
}

cmd_revert() {
  local name=${1:?name} label=${2:?label} d s t nv
  for d in $(disks "$name"); do
    s=$(snap_of "$d" "$label"); sudo test -f "$s" || die "no snapshot $s"
  done
  "${VIRSH[@]}" destroy "$name" >/dev/null 2>&1 || true
  for d in $(disks "$name"); do sudo cp --sparse=always -f "$(snap_of "$d" "$label")" "$d"; done
  nv=$(nvram "$name"); [[ -n "$nv" ]] && sudo cp -f "$IMAGES/$name.$label.nvram" "$nv"
  t=$(tpmdir "$name")
  if [[ -n "$t" ]]; then
    sudo test -d "$IMAGES/$name.$label.tpm" || die "$name has a TPM but '$label' saved none"
    sudo rm -rf "$t"; sudo cp -a "$IMAGES/$name.$label.tpm" "$t"
  fi
  "${VIRSH[@]}" start "$name" >/dev/null
  say "reverted $name to '$label'"
  wait_ssh "$name"
}

cmd_list() {
  sudo ls -1 "$IMAGES" | grep -E "^${1:-[^.]+}(-data)?\.[a-z0-9-]+\.(qcow2|nvram|tpm)$" \
    | sed -E 's/^([^.]+)\.([^.]+)\.(.*)$/\1  \2  \3/' | sort
}

case "${1:-}" in
  save)   shift; cmd_save "$@" ;;
  revert) shift; cmd_revert "$@" ;;
  list)   shift; cmd_list "$@" ;;
  *) sed -n '3,20p' "$0"; exit 1 ;;
esac
