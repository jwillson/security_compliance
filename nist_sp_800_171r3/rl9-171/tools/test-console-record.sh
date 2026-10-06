#!/usr/bin/env bash
#
# tools/console-record.sh by behaviour (DEFECTS 7.34), in minutes rather than
# an install: a throwaway guest with no disk boots the Rocky boot ISO, whose
# firmware and GRUB menu print to the serial console within seconds. The
# recorder is started before the guest - so the first attempts meet a
# console that does not exist yet - and the guest is then restarted twice.
# The recording must hold a connected session for each of the three boots,
# each with that boot's own output. The guest is removed afterwards and
# tools/lab-residue.sh must find no orphan.
#
#   tools/test-console-record.sh
#
# Needs the boot ISO in the default pool (make vm stages it, or the spike
# uploads it) and the lab network.
#
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
cd "$ROOT" || exit 2
NAME=rl9-rectest-01 URI=qemu:///system ISO=/var/lib/libvirt/images/Rocky-9.8-x86_64-boot.iso
OUT="$ROOT/reports/runs/test-console-record-$(date -u +%Y%m%dT%H%M%SZ)"; mkdir -p "$OUT"
fails=0
ok()  { echo "PASS  $*"; }
bad() { echo "FAIL  $*"; fails=$((fails + 1)); }
V() { ./nist virsh -c "$URI" "$@"; }
V vol-path --pool default "$(basename "$ISO")" >/dev/null 2>&1 || { echo "error: $ISO is not in the default pool (make vm stages it)" >&2; exit 2; }
V dominfo "$NAME" >/dev/null 2>&1 && { echo "error: $NAME exists - remove it first" >&2; exit 2; }

cat > "$OUT/domain.xml" <<XML
<domain type='kvm'>
  <name>$NAME</name>
  <memory unit='MiB'>1024</memory>
  <vcpu>1</vcpu>
  <os firmware='efi'><type arch='x86_64' machine='q35'>hvm</type><boot dev='cdrom'/></os>
  <features><acpi/><smm state='on'/></features>
  <devices>
    <disk type='file' device='cdrom'><source file='$ISO'/><target dev='sda' bus='sata'/><readonly/></disk>
    <serial type='pty'><target port='0'/></serial>
    <console type='pty'><target type='serial' port='0'/></console>
  </devices>
</domain>
XML
cleanup() {
  kill "${rec:-}" 2>/dev/null; wait "${rec:-}" 2>/dev/null
  V destroy "$NAME" >/dev/null 2>&1; V undefine "$NAME" --nvram >/dev/null 2>&1
  sudo rm -f "/var/log/libvirt/qemu/$NAME.log"
  if ./tools/lab-residue.sh --orphans > "$OUT/residue.txt" 2>&1; then ok "nothing left behind"
  else bad "residue: $(grep orphan "$OUT/residue.txt" | head -3 | tr '\n' ' ')"; fi
  echo "==> $([ $fails -eq 0 ] && echo PASS || echo FAIL): console recording ($fails failed) - $OUT"
}
trap 'cleanup; exit $(( fails > 0 ))' EXIT

V define "$OUT/domain.xml" > /dev/null || { bad "define"; exit 1; }
./tools/console-record.sh "$NAME" "$OUT/console.log" 600 2> "$OUT/record.err" &
rec=$!
sleep 3                                 # the recorder is waiting before the guest exists
sessions() { grep -a -c 'Connected to domain' "$OUT/console.log" 2>/dev/null || echo 0; }
until_sessions() {                      # N: wait up to 90 s for N connected sessions with output after the Nth
  for _ in $(seq 1 45); do
    if (( $(sessions) >= $1 )) && (( $(awk -v n="$1" '/Connected to domain/ {c++} c >= n' "$OUT/console.log" | wc -c) > 200 )); then return 0; fi
    sleep 2
  done
  return 1
}
for boot in 1 2 3; do
  if (( boot == 1 )); then V start "$NAME" > /dev/null; else V destroy "$NAME" > /dev/null; V start "$NAME" > /dev/null; fi
  if until_sessions "$boot"; then ok "boot $boot recorded: a connected session, with that boot's output"
  else bad "boot $boot not recorded ($(sessions) sessions; $(tail -2 "$OUT/record.err" | tr '\n' ' '))"; fi
done
grep -aq -E 'GRUB|BdsDxe|Rocky' "$OUT/console.log" && ok "the firmware's and GRUB's output is in the recording" || bad "no firmware or GRUB output in the recording"
echo "    recorder: $(grep -c attach "$OUT/record.err") attaches, $(grep -c detach "$OUT/record.err") detaches"
