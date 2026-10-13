#!/usr/bin/env bash
#
# Does a new lab guest's firmware reach GRUB (DEFECTS 7.42)? Boot the Rocky
# boot ISO from a CD-ROM on BUS, N times, press Enter at GRUB so it reads the
# kernel and initrd, and count the boots that never got there or that qemu did
# not survive (libvirt: shut off, reason "crashed").
#
#   tools/test-cdrom-boot.sh BUS N [OPTIONS]      BUS: sata or scsi
#     --no-tpm        no emulated TPM            --no-nic   no NIC on nist-lab
#     --tpm-tis       tpm-tis, not tpm-crb       --wait S   wait S s for GRUB (100)
#     --reuse         one guest booted N times, so only boot 1 is a first boot
#     --fresh-tpm     each boot a fresh TPM state, the firmware variables kept
#     --fresh-nvram   each boot fresh firmware variables, the TPM state kept
#
# What it found on the Ubuntu laptop, 2026-10-13 (qemu 1:10.2.1+ds-1ubuntu3.2,
# OVMF 2025.11-3ubuntu7.3, swtpm 0.10.1): with a TPM, a new guest's firmware
# hangs before its boot manager, printing nothing, on about half of first
# boots - sata 7/10, scsi 7/10, tpm-tis 6/8, no NIC 3/6, still hung after
# 300 s - and not without one (0/6). Fresh variables with the TPM state kept:
# 3/6; a fresh TPM state with the variables kept: 0/6; a guest's later boots
# after a hung first one: 7/7. On a SATA CD-ROM, qemu then segfaulted in its
# ATAPI emulation a minute in (three builds; systemd-coredump). vm/build-vm.sh
# therefore puts the ISO on virtio-scsi and, when the firmware hangs, boots
# the same guest again on the variables it has.
#
# Each guest is like a lab guest (q35, Secure Boot firmware, TPM, a NIC on
# nist-lab, no disk), removed afterwards; tools/lab-residue.sh must then find
# no orphan. Needs the boot ISO (./nist make iso). Runs in the control-plane
# container.
#
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../lib/container.sh"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
cd "$ROOT" || exit 2
bus=${1:-}; n=${2:-10}; shift 2 2>/dev/null || true
tpm=1 nic=1 tpm_model=tpm-crb wait=100 reuse=0
while (( $# )); do
  case $1 in --no-tpm) tpm=0 ;; --no-nic) nic=0 ;; --tpm-tis) tpm_model=tpm-tis ;; --wait) wait=$2; shift ;; --reuse) reuse=1 ;; --fresh-tpm) reuse=2 ;; --fresh-nvram) reuse=3 ;;
    *) echo "unknown option $1" >&2; exit 2 ;; esac; shift
done
[[ "$bus" =~ ^(sata|scsi)$ && "$n" =~ ^[0-9]+$ ]] || { sed -n '3,14p' "$0"; exit 2; }
NAME=rl9-cdtest-01 VOL=rl9-cdtest-01-boot.iso ISOFILE=iso/Rocky-9.8-x86_64-boot.iso
OUT="$ROOT/reports/runs/test-cdrom-boot-$bus$( ((tpm)) || echo -notpm)$( ((nic)) || echo -nonic)$( [[ $tpm_model == tpm-tis ]] && echo -tis)$(case $reuse in 1) echo -reuse;; 2) echo -freshtpm;; 3) echo -freshnvram;; esac)-$(date -u +%Y%m%dT%H%M%SZ)"; mkdir -p "$OUT"
V() { virsh -c "$NIST_LIBVIRT_URI" "$@"; }
[[ -f "$ISOFILE" ]] || { echo "error: no $ISOFILE (./nist make iso)" >&2; exit 2; }
V dominfo "$NAME" >/dev/null 2>&1 && { echo "error: $NAME exists - remove it first" >&2; exit 2; }

V vol-delete --pool default "$VOL" >/dev/null 2>&1
V vol-create-as default "$VOL" "$(stat -c %s "$ISOFILE")" --format raw >/dev/null \
  && V vol-upload --pool default "$VOL" "$ISOFILE" || { echo "error: could not upload the boot ISO" >&2; exit 2; }
ISO=$(V vol-path --pool default "$VOL")
ctl=""; [[ $bus == scsi ]] && ctl="<controller type='scsi' model='virtio-scsi'/>"
cat > "$OUT/domain.xml" <<XML
<domain type='kvm'>
  <name>$NAME</name>
  <memory unit='MiB'>2048</memory>
  <vcpu>2</vcpu>
  <os firmware='efi'>
    <type arch='x86_64' machine='q35'>hvm</type>
    <firmware><feature enabled='yes' name='secure-boot'/><feature enabled='yes' name='enrolled-keys'/></firmware>
    <boot dev='cdrom'/>
  </os>
  <features><acpi/><smm state='on'/></features>
  <cpu mode='host-passthrough'/>
  <devices>
    $ctl
    <disk type='file' device='cdrom'><driver name='qemu' type='raw'/><source file='$ISO'/><target dev='sda' bus='$bus'/><readonly/></disk>
    $( (( nic )) && echo "<interface type='network'><source network='nist-lab'/><model type='virtio'/></interface>")
    $( (( tpm )) && echo "<tpm model='$tpm_model'><backend type='emulator' version='2.0'/></tpm>")
    <serial type='pty'><target port='0'/></serial>
    <console type='pty'><target type='serial' port='0'/></console>
  </devices>
</domain>
XML
undefine() { V undefine "$NAME" --nvram --tpm >/dev/null 2>&1 || V undefine "$NAME" --nvram >/dev/null 2>&1; }
cleanup() {
  V destroy "$NAME" >/dev/null 2>&1; undefine
  V vol-delete --pool default "$VOL" >/dev/null 2>&1
  ./tools/lab-residue.sh --orphans > "$OUT/residue.txt" 2>&1 || echo "WARN  residue: see $OUT/residue.txt"
}
trap cleanup EXIT

# Every boot is a new guest's first: all three crashes were, when the firmware
# meets its devices with a fresh variable store - so the guest is defined
# afresh each time, with a TPM and a NIC on nist-lab, as vm/build-vm.sh makes it.
crashed=0 booted=0
for i in $(seq 1 "$n"); do
  if (( ! reuse || i == 1 )); then
    V define "$OUT/domain.xml" >/dev/null || { echo "error: define failed ($OUT/domain.xml)" >&2; exit 1; }
  fi
  V start "$NAME" >/dev/null
  log="$OUT/boot-$i.log"
  # The firmware probes the CD-ROM, then GRUB's menu; Enter, and GRUB reads
  # vmlinuz and initrd from it. In the failed builds the firmware printed
  # nothing for about a minute and qemu died at 60-70 s, before the firmware's
  # boot manager - so the wait for GRUB is long, and a firmware that never
  # reaches it is a failure too.
  timeout $(( wait + 50 )) script -qfc "virsh -c '$NIST_LIBVIRT_URI' console --force $NAME" "$log" </dev/null >/dev/null 2>&1 &
  rec=$!
  started=$SECONDS grub=0
  while (( SECONDS - started < wait )); do
    grep -aq 'GRUB' "$log" 2>/dev/null && { grub=1; break; }
    [[ "$(V domstate "$NAME" 2>/dev/null)" == running ]] || break
    sleep 1
  done
  if (( grub )); then
    V send-key "$NAME" KEY_ENTER >/dev/null 2>&1
    for _ in $(seq 1 30); do [[ "$(V domstate "$NAME" 2>/dev/null)" == running ]] || break; sleep 1; done
  fi
  kill "$rec" 2>/dev/null; wait "$rec" 2>/dev/null
  state=$(V domstate "$NAME" --reason 2>/dev/null)
  t=$(( SECONDS - started ))
  if [[ "$state" == *crashed* ]]; then crashed=$((crashed + 1)); echo "boot $i: qemu crashed at ${t}s ($state)"
  elif (( ! grub )); then crashed=$((crashed + 1)); echo "boot $i: no GRUB after ${t}s ($state)"
  else booted=$((booted + 1)); echo "boot $i: GRUB at $(( t - 30 ))s or so, then survived 30 s of reading the CD ($state)"; fi
  V destroy "$NAME" >/dev/null 2>&1
  case $reuse in
    0) undefine ;;
    2) V undefine "$NAME" --keep-nvram --tpm >/dev/null && V define "$OUT/domain.xml" >/dev/null ;;
    3) V undefine "$NAME" --nvram --keep-tpm >/dev/null && V define "$OUT/domain.xml" >/dev/null ;;
  esac
done
echo "==> $bus CD-ROM, tpm=$tpm ($tpm_model) nic=$nic: $crashed of $n boots failed - $OUT"
(( crashed == 0 ))
