#!/usr/bin/env bash
#
# The lab-in-container spike (DEFECTS 7.34): can the control-plane container
# (./nist) build a lab guest on this host's libvirt through its socket alone -
# no sudo, no host file written by the container?
#
#   tools/spike-container-libvirt.sh            run it; the guest is removed after
#   tools/spike-container-libvirt.sh --keep     leave rl9-spike-01 up to inspect
#
# Three unknowns, each a check:
#   1. socket   virsh inside reaches qemu:///system as you (your libvirt group
#               carried in), and sees KVM with UEFI
#   2. install  the boot ISO is uploaded into the default pool (vol-upload),
#               the repo's copy shown inside at the pool's path, so
#               virt-install reads kernel and initrd from it and the host's
#               qemu boots the same path as the CD-ROM; the kickstart is
#               injected and the injected initrd uploaded by virt-install
#               itself; the disk is created in the pool. A fresh install of
#               the real kickstart, the runtime image from the CD-ROM
#               (inst.stage2), to SSH on the installed guest
#   3. console  tools/console-record.sh (virsh console under util-linux
#               script, inside) records the installer's console and, after
#               its reboot, the installed system's - what the install watcher
#               needs, without the host's root-only serial log, which
#               libvirt truncates at every start
# Then the guest, its disk, NVRAM, TPM state, the uploaded ISO and the logs are
# removed, and tools/lab-residue.sh must find no orphan. Evidence is kept in
# reports/runs/spike-container-libvirt-UTC/. Exit 0 only if every check passes.
#
# Needs: ./nist (podman or docker), the lab network (vm/lab-network.sh
# ensure), make iso and make secrets done. The host reads its own serial log
# with sudo, only to compare.
#
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
cd "$ROOT" || exit 2
keep=0; [[ "${1:-}" == --keep ]] && keep=1
URI=qemu:///system NAME=rl9-spike-01 POOL=default
ISO=iso/Rocky-9.8-x86_64-boot.iso VOL=spike-Rocky-9.8-x86_64-boot.iso
MIRROR="${NIST_ROCKY_MIRROR:-https://dl.rockylinux.org/pub/rocky/9}"
OUT="$ROOT/reports/runs/spike-container-libvirt-$(date -u +%Y%m%dT%H%M%SZ)"; mkdir -p "$OUT"
SERIAL=/var/log/libvirt/qemu/$NAME-serial.log
fails=0
ok()  { echo "PASS  $*" | tee -a "$OUT/summary.txt"; }
bad() { echo "FAIL  $*" | tee -a "$OUT/summary.txt"; fails=$((fails + 1)); }
say() { echo "==> $(date -u +%H:%M) $*" | tee -a "$OUT/summary.txt"; }
V() { ./nist virsh -c "$URI" "$@"; }

[[ -f "$ISO" ]] || { echo "error: $ISO missing (make iso)" >&2; exit 2; }
[[ -f .secrets/id_rsa.pub && -f .secrets/admin_password_hash ]] || { echo "error: .secrets missing (make secrets)" >&2; exit 2; }
V dominfo "$NAME" >/dev/null 2>&1 && { echo "error: $NAME exists - a spike left behind; remove it first" >&2; exit 2; }

cleanup() {
  (( keep )) && { say "kept $NAME (--keep); remove: ./nist virsh -c $URI undefine $NAME --nvram --tpm --remove-all-storage"; return; }
  say "removing $NAME and what it left"
  [[ -n "${cs_pid:-}" ]] && kill "$cs_pid" 2>/dev/null
  V destroy "$NAME" >/dev/null 2>&1
  V undefine "$NAME" --nvram --tpm --remove-all-storage >/dev/null 2>&1
  V vol-delete --pool "$POOL" "$VOL" >/dev/null 2>&1
  sudo rm -f "$SERIAL" "/var/log/libvirt/qemu/$NAME.log" "/var/log/libvirt/qemu/$NAME-swtpm.log"
  if ./tools/lab-residue.sh --orphans > "$OUT/residue.txt" 2>&1; then ok "nothing left behind (tools/lab-residue.sh --orphans)"
  else bad "residue after cleanup: $(grep orphan "$OUT/residue.txt" | head -3 | tr '\n' ' ')"; fi
}
trap 'cleanup; echo "==> $([ $fails -eq 0 ] && echo PASS || echo FAIL): the lab-in-container spike ($fails failed) - $OUT"; exit $(( fails > 0 ))' EXIT

say "building the control-plane image with the libvirt client"
./nist --rebuild true > "$OUT/build.log" 2>&1 || { bad "the image builds (build.log)"; exit 1; }

# --- 1. socket ---------------------------------------------------------------
say "1. the socket"
u=$(V uri 2>&1)
caps=$(V domcapabilities --virttype kvm 2>&1)
if [[ "$u" == "$URI" ]] && grep -q "<value>efi</value>" <<<"$caps"; then
  ok "virsh inside reaches $URI as $(id -un), no sudo; KVM with UEFI"
else bad "socket: uri='$u'; $(tail -2 <<<"$caps" | tr '\n' ' ')"; fi

# --- 2. install --------------------------------------------------------------
say "2. a fresh install through the socket"
pool_path=$(V pool-dumpxml "$POOL" 2>/dev/null | sed -n 's:.*<path>\(.*\)</path>.*:\1:p' | head -1)
size=$(stat -c %s "$ISO")
if V vol-create-as "$POOL" "$VOL" "$size" --format raw > "$OUT/upload.log" 2>&1 \
   && V vol-upload --pool "$POOL" "$VOL" "$ROOT/$ISO" >> "$OUT/upload.log" 2>&1; then
  got=$(V vol-info --pool "$POOL" "$VOL" --bytes 2>/dev/null | awk '/^Capacity/ {print $2}')
  [[ "$got" == "$size" ]] && ok "the ISO uploaded into pool $POOL ($pool_path/$VOL, $size bytes)" || bad "uploaded ISO is $got bytes, not $size"
else bad "ISO upload (upload.log): $(tail -2 "$OUT/upload.log" | tr '\n' ' ')"; fi

# The installer's runtime image from the CD-ROM, by its label (DEFECTS 7.32).
label=$(./nist xorriso -indev "$ROOT/$ISO" -pvd_info 2>/dev/null | sed -n 's/^Volume Id *: *//p' | head -1)
# The kickstart, rendered as for every install (install/render-kickstart.sh),
# in the container.
./nist install/render-kickstart.sh --out "$OUT/ks.cfg" --name "$NAME" --disk vda --user cuiadmin \
  --hash-file .secrets/admin_password_hash --pubkey-file .secrets/id_rsa.pub --mirror "$MIRROR"

# tools/console-record.sh, in the container: virsh console under script,
# re-attached at each start of the guest (tested by tools/test-console-record.sh).
./tools/console-record.sh "$NAME" "$OUT/console-stream.log" 7200 2> "$OUT/console-stream.err" &
cs_pid=$!
say "installing $NAME (expect 15-25 min); runtime image from LABEL=$label"
NIST_CONTAINER_MOUNTS="-v $ROOT/$ISO:$pool_path/$VOL:ro" timeout 7200 ./nist virt-install \
  --connect "$URI" --name "$NAME" --memory 4096 --vcpus 2 --cpu host-passthrough --machine q35 \
  --boot uefi --tpm backend.type=emulator,backend.version=2.0,model=tpm-crb \
  --disk "pool=$POOL,size=40,format=qcow2,bus=virtio,cache=none,discard=unmap" \
  --network network=nist-lab,model=virtio --graphics none \
  --serial "pty,log.file=$SERIAL" --console pty,target_type=serial --os-variant rocky9 \
  --location "$pool_path/$VOL" --initrd-inject "$OUT/ks.cfg" \
  --extra-args "inst.ks=file:/ks.cfg inst.repo=$MIRROR/BaseOS/x86_64/os/ ${label:+inst.stage2=hd:LABEL=$label} inst.text ip=dhcp console=ttyS0,115200n8" \
  --noautoconsole --wait -1 > "$OUT/virt-install.log" 2>&1
vi_rc=$?
# The evidence is the recording: libvirt truncates the host's serial log each
# time the domain starts, so after the installer's reboot it holds nothing of
# the install (the first run of this check read it, and failed a good install).
cs="$OUT/console-stream.log"
if (( vi_rc == 0 )) && grep -aq "Kernel command line: inst.ks=file:/ks.cfg" "$cs" \
   && grep -aq "inst.stage2=hd:LABEL=" "$cs" && ! grep -aq curl_fetch "$cs"; then
  ok "virt-install inside installed $NAME: kickstart injected, runtime image from the CD-ROM"
else bad "install: virt-install rc=$vi_rc (virt-install.log: $(tail -2 "$OUT/virt-install.log" | tr '\n' ' '))"; fi

ip=""
for _ in $(seq 1 60); do
  ip=$(V domifaddr "$NAME" --source lease 2>/dev/null | awk '/ipv4/ {split($4, a, "/"); print a[1]; exit}')
  [[ -n "$ip" ]] && break; sleep 5
done
ssh_ok=0
for _ in $(seq 1 60); do
  [[ -n "$ip" ]] || break
  if ./nist ssh -i .secrets/id_rsa -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/tmp/spike_known_hosts \
       -o BatchMode=yes -o ConnectTimeout=5 "cuiadmin@$ip" true > /dev/null 2>&1; then ssh_ok=1; break; fi
  sleep 5
done
(( ssh_ok )) && ok "SSH to the installed $NAME ($ip) from inside" || bad "no SSH to $NAME (${ip:-no address})"

# --- 3. console --------------------------------------------------------------
say "3. the console, recorded through the socket"
sleep 20; kill "$cs_pid" 2>/dev/null; wait "$cs_pid" 2>/dev/null; cs_pid=""
sudo cat "$SERIAL" > "$OUT/serial-host.log" 2>/dev/null
sessions=$(grep -a -c 'Connected to domain' "$cs")
after=$(awk '/Connected to domain/ {n++} n >= 2' "$cs" | wc -c)
if grep -aq "reboot: Restarting system" "$cs" && (( sessions >= 2 )); then
  ok "tools/console-record.sh recorded the installer to its reboot and re-attached to the installed system ($sessions sessions; $after bytes from that boot; the host's log, truncated at each start, $(wc -c < "$OUT/serial-host.log"))"
else bad "console recording: $sessions session(s), $(wc -c < "$cs") bytes (console-stream.err: $(tail -3 "$OUT/console-stream.err" | tr '\n' ' '))"; fi
