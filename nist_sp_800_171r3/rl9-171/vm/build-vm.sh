#!/usr/bin/env bash
#
# Build the Rocky Linux 9 CUI reference VM from the kickstart.
#
# Produces an unattended install with the install-time controls already in
# place (partition layout, FIPS, minimal package set). The Ansible role is
# applied afterwards by ../apply.sh.
#
#   ./build-vm.sh                 build the CUI reference VM
#   ./build-vm.sh --role log      build the log collector (03.03.05c)
#   ./build-vm.sh --name rl9-cui-02 --disk-gb 60
#   ./build-vm.sh --destroy       remove the VM and its disk
#
# Hosts are added to inventory/hosts.yml rather than replacing it, so a
# second VM does not evict the first. tools/inventory.py owns that file and
# points the CUI hosts at the collector once one exists.
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

VM_NAME=""
VM_ROLE="cui"
# Install-time memory, not steady-state. A collector needs far less RAM than
# this to run, but the Rocky 9 network installer does not: it unpacks a large
# initrd and the stage-2 squashfs into RAM before it writes anything. Asking
# for less makes virt-install override it up to its computed minimum (3072),
# and at that minimum the install hung at firmware with an idle CPU, zero
# disk writes and a silent serial console. 4096 is the value that installs.
# A collector is trimmed back to VM_RUNTIME_RAM_MB once the install is done.
VM_RAM_MB=4096
# Steady-state allocation for a collector, applied after the install. It only
# receives and stores records; holding the installer's footprint for the life
# of the guest costs host RAM for nothing. maxmem is left alone, so `virsh
# setmem` can raise it again without redefining the domain.
VM_RUNTIME_RAM_MB=2048
VM_VCPUS=2
VM_DISK_GB=40
MIRROR="https://dl.rockylinux.org/pub/rocky/9"
ADMIN_USER="cuiadmin"
VM_NETWORK="nist-lab"
LIBVIRT_URI="qemu:///system"
ISO="$ROOT/iso/Rocky-9.8-x86_64-boot.iso"
SECRETS="$ROOT/.secrets"
DESTROY=0
: "${IMAGE_DIR:=/var/lib/libvirt/images}"

die() { echo "error: $*" >&2; exit 1; }
log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --name)     VM_NAME="$2"; shift 2 ;;
    --role)     VM_ROLE="$2"; shift 2 ;;
    --ram-mb)   VM_RAM_MB="$2"; shift 2 ;;
    --vcpus)    VM_VCPUS="$2"; shift 2 ;;
    --disk-gb)  VM_DISK_GB="$2"; shift 2 ;;
    --mirror)   MIRROR="$2"; shift 2 ;;
    --iso)      ISO="$2"; shift 2 ;;
    --destroy)  DESTROY=1; shift ;;
    -h|--help)  sed -n '2,17p' "$0"; exit 0 ;;
    *)          die "unknown argument: $1" ;;
  esac
done

case "$VM_ROLE" in
  cui) : "${VM_NAME:=rl9-cui-01}" ;;
  log) : "${VM_NAME:=rl9-log-01}" ;;
  *)   die "unknown role: $VM_ROLE (expected cui or log)" ;;
esac

DISK_PATH="$IMAGE_DIR/${VM_NAME}.qcow2"

if [[ $DESTROY -eq 1 ]]; then
  log "destroying $VM_NAME"
  sudo virsh -c "$LIBVIRT_URI" destroy "$VM_NAME" 2>/dev/null || true
  sudo virsh -c "$LIBVIRT_URI" undefine "$VM_NAME" --nvram --remove-all-storage 2>/dev/null || true
  sudo rm -f "$DISK_PATH"
  "$ROOT/tools/inventory.py" remove "$VM_NAME" >/dev/null 2>&1 || true
  log "destroyed"
  exit 0
fi

# --- preflight ---------------------------------------------------------------
[[ -f "$ISO" ]] || die "boot ISO not found: $ISO (run make iso)"
[[ -d "$SECRETS" ]] || die "missing $SECRETS (run make secrets)"
for f in admin_password_hash id_rsa.pub; do
  [[ -f "$SECRETS/$f" ]] || die "missing $SECRETS/$f"
done
command -v virt-install >/dev/null || die "virt-install not installed"
command -v swtpm >/dev/null || die "swtpm not installed (needed for the vTPM)"

if sudo virsh -c "$LIBVIRT_URI" dominfo "$VM_NAME" >/dev/null 2>&1; then
  die "domain $VM_NAME already exists - run '$0 --destroy' first"
fi

# qemu runs as an unprivileged user that cannot traverse $HOME, so an ISO kept
# in the project tree is unreadable to it. Stage it into the libvirt image
# directory, which qemu can always read.
if [[ "$ISO" != "$IMAGE_DIR"/* ]]; then
  STAGED="$IMAGE_DIR/$(basename "$ISO")"
  if ! sudo test -f "$STAGED" || \
     [[ "$(stat -c %s "$ISO")" != "$(sudo stat -c %s "$STAGED" 2>/dev/null || echo 0)" ]]; then
    log "staging ISO into $IMAGE_DIR (qemu cannot read it under \$HOME)"
    sudo cp -f "$ISO" "$STAGED"
    sudo chmod 0644 "$STAGED"
  fi
  ISO="$STAGED"
fi

# UEFI firmware: a presence check only - `virt-install --boot uefi` lets
# libvirt pick the image from its firmware descriptors. Paths differ by
# distro; Ubuntu ships only the 4 MB build (OVMF_CODE_4M.fd), which the list
# lacked until the kickstart lab was first built on an Ubuntu workstation.
OVMF=""
for c in /usr/share/edk2/x64/OVMF_CODE.4m.fd \
         /usr/share/edk2/ovmf/OVMF_CODE.fd \
         /usr/share/edk2-ovmf/x64/OVMF_CODE.fd \
         /usr/share/OVMF/OVMF_CODE_4M.fd \
         /usr/share/OVMF/OVMF_CODE.fd; do
  [[ -f "$c" ]] && { OVMF="$c"; break; }
done
[[ -n "$OVMF" ]] || die "no OVMF firmware found - install edk2-ovmf"

# --- render the kickstart ----------------------------------------------------
OVERLAY_VERSION="$(awk '/^  version:/ {gsub(/"/,"",$2); print $2; exit}' "$ROOT/catalog/overlay-rocky9.yml")"

KS_OUT="$(mktemp -t rl9-cui-XXXXXX.ks)"
trap 'rm -f "$KS_OUT"' EXIT

python3 - "$HERE/kickstart/rl9-cui.ks.j2" "$KS_OUT" <<PY
import sys
src, dst = sys.argv[1], sys.argv[2]
subs = {
    "@@MIRROR@@":           """$MIRROR""",
    "@@HOSTNAME@@":         """$VM_NAME""",
    "@@ADMIN_USER@@":       """$ADMIN_USER""",
    "@@ADMIN_HASH@@":       open("""$SECRETS/admin_password_hash""").read().strip(),
    "@@SSH_PUBKEY@@":       open("""$SECRETS/id_rsa.pub""").read().strip(),
    "@@DISK@@":             "vda",
    "@@OVERLAY_VERSION@@":  """$OVERLAY_VERSION""",
}
text = open(src).read()
for k, v in subs.items():
    text = text.replace(k, v)
import re
# Ignore comment lines; only unresolved substitutions in live config matter.
left = [l for l in text.splitlines()
        if re.search(r"@@[A-Z_]+@@", l) and not l.lstrip().startswith("#")]
if left:
    sys.exit("unsubstituted placeholders:\n" + "\n".join(left))
open(dst, "w").write(text)
PY
log "kickstart rendered ($(wc -l < "$KS_OUT") lines, overlay $OVERLAY_VERSION)"

# A kickstart syntax error costs a full install cycle to discover, so validate
# it up front with the real parser. Rocky 9's pykickstart is authoritative;
# skip silently if no container runtime is available.
if command -v podman >/dev/null 2>&1; then
  log "validating kickstart syntax (pykickstart, RHEL9 dialect)"
  if ! podman run --rm -v "$KS_OUT:/tmp/candidate.ks:ro,Z" rockylinux:9 \
        bash -c 'dnf -q -y install pykickstart >/dev/null 2>&1 &&
                 ksvalidator -v RHEL9 /tmp/candidate.ks' 2>&1 | tee /dev/stderr | grep -q .; then
    log "kickstart syntax OK"
  else
    die "kickstart failed validation (see errors above)"
  fi
fi

# --- build -------------------------------------------------------------------
log "creating $VM_NAME: ${VM_VCPUS} vCPU, ${VM_RAM_MB} MB RAM, ${VM_DISK_GB} GB disk"
log "installing from $MIRROR (unattended, expect 15-25 min)"

sudo virt-install \
  --connect "$LIBVIRT_URI" \
  --name "$VM_NAME" \
  --memory "$VM_RAM_MB" \
  --vcpus "$VM_VCPUS" \
  --cpu host-passthrough \
  --machine q35 \
  --boot uefi \
  --tpm backend.type=emulator,backend.version=2.0,model=tpm-crb \
  --disk "path=$DISK_PATH,size=$VM_DISK_GB,format=qcow2,bus=virtio,cache=none,discard=unmap" \
  --network network=$VM_NETWORK,model=virtio \
  --graphics none \
  --console pty,target_type=serial \
  --os-variant rocky9 \
  --location "$ISO" \
  --initrd-inject "$KS_OUT" \
  --extra-args "inst.ks=file:/$(basename "$KS_OUT") inst.repo=$MIRROR/BaseOS/x86_64/os/ inst.text ip=dhcp console=ttyS0,115200n8" \
  --noautoconsole \
  --wait -1

log "install finished; waiting for the VM to boot"

# virt-install --wait returns when the domain shuts down after install. The
# kickstart ends with `reboot`, so the domain should come back up on its own;
# start it if libvirt left it down.
for _ in $(seq 1 30); do
  state="$(sudo virsh -c "$LIBVIRT_URI" domstate "$VM_NAME" 2>/dev/null || echo unknown)"
  [[ "$state" == "running" ]] && break
  sudo virsh -c "$LIBVIRT_URI" start "$VM_NAME" >/dev/null 2>&1 || true
  sleep 5
done

log "resolving guest address"
IP=""
for _ in $(seq 1 60); do
  IP="$(sudo virsh -c "$LIBVIRT_URI" domifaddr "$VM_NAME" --source lease 2>/dev/null \
        | awk '/ipv4/ {split($4,a,"/"); print a[1]; exit}')"
  [[ -n "$IP" ]] && break
  sleep 5
done
[[ -n "$IP" ]] || die "could not determine the guest IP; check 'virsh console $VM_NAME'"

log "guest is at $IP"

# --- register in the Ansible inventory ---------------------------------------
# Adds or updates this host; other hosts already there are left alone. A log
# host additionally becomes the collector every CUI host forwards to.
"$ROOT/tools/inventory.py" add "$VM_NAME" --ip "$IP" --user "$ADMIN_USER" --role "$VM_ROLE"
log "inventory now:"
"$ROOT/tools/inventory.py" show

log "waiting for SSH"
for _ in $(seq 1 60); do
  if ssh -i "$SECRETS/id_rsa" -o StrictHostKeyChecking=yes \
         -o UserKnownHostsFile="$SECRETS/known_hosts" -o ConnectTimeout=5 \
         -o BatchMode=yes "$ADMIN_USER@$IP" true 2>/dev/null; then
    log "SSH is up"
    break
  fi
  sleep 5
done

# The forwarding advice only applies when there is no collector yet.
if [[ "$VM_ROLE" == "log" ]]; then
  NEXT_HINT="
  This host receives forwarded audit records. ./apply.sh configures both
  halves: every CUI host forwards, and this one listens. Then 03.03.05c is
  verified rather than reported MANUAL:

             ./verify.sh --requirement 03.03.05
"
elif "$ROOT/tools/inventory.py" show 2>/dev/null | grep -q ' log '; then
  NEXT_HINT=""
else
  NEXT_HINT="
  A single CUI host cannot exercise audit-record forwarding (03.03.05c):
  there is nowhere to forward to, so the assessor reports it MANUAL. Build
  the collector and re-apply to close that:

             ./vm/build-vm.sh --role log
             ./apply.sh
"
fi

# Give back the memory the installer needed and the guest does not.
if [[ "$VM_ROLE" == "log" && "$VM_RUNTIME_RAM_MB" -lt "$VM_RAM_MB" ]]; then
  log "trimming $VM_NAME to ${VM_RUNTIME_RAM_MB} MB (the installer needed ${VM_RAM_MB})"
  sudo virsh -c "$LIBVIRT_URI" setmem "$VM_NAME" "${VM_RUNTIME_RAM_MB}M" \
    --config --live 2>/dev/null || log "could not trim memory; leaving at ${VM_RAM_MB} MB"
fi

cat <<DONE

  VM:        $VM_NAME  (role: $VM_ROLE)
  Address:   $IP
  User:      $ADMIN_USER  (password in .secrets/admin_password)
  SSH:       bash -c '. lib/ssh-env.sh; ssh -i .secrets/id_rsa \\
               -o UserKnownHostsFile=.secrets/known_hosts $ADMIN_USER@$IP'
  Console:   sudo virsh -c $LIBVIRT_URI console $VM_NAME

  A plain \`ssh\` works now and stops working after ./apply.sh: 03.05.03
  requires publickey AND password, and only lib/ssh-env.sh supplies the
  second factor. Otherwise OpenSSH asks you for $ADMIN_USER's password
  (it is in .secrets/admin_password).

  Next:      ./apply.sh          apply the 800-171r3 overlay
             ./verify.sh         assess the host against all 97 requirements
$NEXT_HINT
DONE
