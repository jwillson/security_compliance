#!/usr/bin/env bash
#
# Build a kickstart-lab guest: the Rocky Linux 9 CUI reference VM, or the log
# collector. Installed exactly as a bare-metal machine is - from its own
# install ISO (install/iso.sh), booted as a plain CD-ROM - so the lab proves
# the media an operator puts on a BMC (TASKS C5). The install-time controls
# come with it (partition layout, FIPS, minimal package set); the role is
# applied afterwards by make apply.
#
#   ./build-vm.sh                 build the CUI reference VM
#   ./build-vm.sh --role log      build the log collector (03.03.05c)
#   ./build-vm.sh --name rl9-cui-02 --disk-gb 60
#   ./build-vm.sh --destroy       remove the VM and everything it left in libvirt
#
# It runs in the control-plane container, through the host's libvirt socket:
# the ISO goes into the default pool (vol-upload), the disk is a pool volume
# with a serial the kickstart names it by (/dev/disk/by-id/virtio-NAME), and
# the console is recorded by tools/console-record.sh - no sudo, no host file.
# The ISO carries the admin password's hash, so it is ejected and its volume
# deleted once the guest has installed.
#
# The install is watched, not waited on forever (DEFECTS 7.17): if the
# console prints nothing new for NIST_INSTALL_STALL_MIN minutes (default 20),
# or the installer halts itself (7.30), or the install passes
# NIST_INSTALL_TIMEOUT_MIN (default 120), the build stops with what the
# installer said (tools/install-log.sh) and leaves the VM up to inspect.
# NIST_ROCKY_MIRROR replaces the mirror. The lab network is created if
# missing (vm/lab-network.sh).
#
# Hosts are added to the kickstart lab's inventory, inventory/kickstart.yml,
# rather than replacing it, so a second VM does not evict the first.
# tools/inventory.py owns that file and points the CUI hosts at the
# collector once one exists.
#
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../lib/container.sh"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
cd "$ROOT"

VM_NAME=""
VM_ROLE="cui"
# Install-time memory, not steady-state. A collector needs far less RAM than
# this to run, but the Rocky 9 installer does not: it unpacks a large initrd
# and the stage-2 squashfs into RAM before it writes anything. At virt-install's
# computed minimum (3072) the install hung at firmware with an idle CPU, zero
# disk writes and a silent serial console. 4096 is the value that installs.
# A collector is trimmed back to VM_RUNTIME_RAM_MB once the install is done.
VM_RAM_MB=4096
# Steady-state allocation for a collector, applied after the install. maxmem
# is left alone, so `virsh setmem` can raise it again.
VM_RUNTIME_RAM_MB=2048
VM_VCPUS=2
VM_DISK_GB=40
ADMIN_USER="cuiadmin"
VM_NETWORK="nist-lab"
POOL=default
SECRETS="$ROOT/.secrets"
# Every guest this builds is a kickstart-lab host: its inventory is that
# lab's own, whoever runs this - make or a person (DEFECTS 7.33).
export NIST_INVENTORY="${NIST_INVENTORY:-inventory/kickstart.yml}"
DESTROY=0
V=(virsh -c "$NIST_LIBVIRT_URI")

die() { echo "error: $*" >&2; exit 1; }
log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --name)     VM_NAME="$2"; shift 2 ;;
    --role)     VM_ROLE="$2"; shift 2 ;;
    --ram-mb)   VM_RAM_MB="$2"; shift 2 ;;
    --vcpus)    VM_VCPUS="$2"; shift 2 ;;
    --disk-gb)  VM_DISK_GB="$2"; shift 2 ;;
    --mirror)   export NIST_ROCKY_MIRROR="$2"; shift 2 ;;
    --destroy)  DESTROY=1; shift ;;
    -h|--help)  sed -n '2,33p' "$0"; exit 0 ;;
    *)          die "unknown argument: $1" ;;
  esac
done

case "$VM_ROLE" in
  cui) : "${VM_NAME:=rl9-cui-01}" ;;
  log) : "${VM_NAME:=rl9-log-01}" ;;
  *)   die "unknown role: $VM_ROLE (expected cui or log)" ;;
esac
[[ "$VM_NAME" =~ ^[a-z0-9][a-z0-9-]{0,19}$ ]] || die "'$VM_NAME' is not a guest name (letters, digits, hyphens; 20 at most - it is the disk's serial)"
ISO_VOL="$VM_NAME-install.iso"

if [[ $DESTROY -eq 1 ]]; then
  # Only a lab guest: a domain attached to nist-lab, or one already gone (its
  # inventory entry and host key are still cleaned up). `--name` took any
  # libvirt domain - a typo, a personal VM - and removed it with all its
  # storage (issue #6).
  if "${V[@]}" dominfo "$VM_NAME" >/dev/null 2>&1 &&
     ! "${V[@]}" domiflist "$VM_NAME" 2>/dev/null | awk '$3=="nist-lab" {f=1} END {exit !f}'; then
    die "'$VM_NAME' is not attached to nist-lab, so it is not a lab guest; refusing to destroy it"
  fi
  log "destroying $VM_NAME"
  # Everything the guest has in libvirt (DEFECTS 7.18): the domain, its disk
  # and install ISO volumes, UEFI variables and TPM state; then its host key
  # and inventory entry. (libvirt's own per-domain log in /var/log/libvirt
  # stays with libvirt, rotated by it.)
  ip=$("$ROOT/tools/inventory.py" show 2>/dev/null | awk -v n="$VM_NAME" '$1==n {print $2}')
  "${V[@]}" destroy "$VM_NAME" >/dev/null 2>&1 || true
  "${V[@]}" undefine "$VM_NAME" --nvram --tpm --remove-all-storage >/dev/null 2>&1 \
    || "${V[@]}" undefine "$VM_NAME" --nvram --remove-all-storage >/dev/null 2>&1 || true
  "${V[@]}" vol-delete --pool "$POOL" "$VM_NAME.qcow2" >/dev/null 2>&1 || true
  "${V[@]}" vol-delete --pool "$POOL" "$ISO_VOL" >/dev/null 2>&1 || true
  [[ -n "$ip" && -f "$SECRETS/known_hosts" ]] && ssh-keygen -R "$ip" -f "$SECRETS/known_hosts" >/dev/null 2>&1 || true
  "$ROOT/tools/inventory.py" remove "$VM_NAME" >/dev/null 2>&1 || true
  log "destroyed"
  exit 0
fi

# --- preflight ---------------------------------------------------------------
[[ -d "$SECRETS" ]] || die "missing $SECRETS (run make secrets)"
for f in admin_password_hash id_rsa id_rsa.pub; do
  [[ -f "$SECRETS/$f" ]] || die "missing $SECRETS/$f"
done
[[ -f iso/Rocky-9.8-x86_64-boot.iso ]] || die "boot ISO not found: iso/Rocky-9.8-x86_64-boot.iso (run make iso)"
# The lab network: nothing created it on a new host, so the build failed or
# hung there (DEFECTS 7.17). Only what is missing is done.
"$HERE/lab-network.sh" ensure
# The inventory takes this host before the install, not after it (DEFECTS 7.31).
"$ROOT/tools/inventory.py" check "$VM_NAME" || die "nothing installed: $NIST_INVENTORY is not this lab's - \
the kickstart lab's own is inventory/kickstart.yml, used unless NIST_INVENTORY names another"
"${V[@]}" dominfo "$VM_NAME" >/dev/null 2>&1 && die "domain $VM_NAME already exists - run '$0 --name $VM_NAME --destroy' first"
pool_path=$("${V[@]}" pool-dumpxml "$POOL" 2>/dev/null | sed -n 's:.*<path>\(.*\)</path>.*:\1:p' | head -1)
[[ -n "$pool_path" ]] || die "no storage pool '$POOL' in $NIST_LIBVIRT_URI"

# --- the install media: this guest's own ISO ----------------------------------
OUT="$ROOT/reports/runs/build-$VM_NAME-$(date -u +%Y%m%dT%H%M%SZ)"; mkdir -p "$OUT"
"$ROOT/install/iso.sh" "$VM_NAME" --disk "/dev/disk/by-id/virtio-$VM_NAME" --console ttyS0 \
  --user "$ADMIN_USER" --key "$SECRETS/id_rsa.pub" --hash-file "$SECRETS/admin_password_hash" \
  --out "$OUT/install.iso" || die "the install ISO was not built"
size=$(stat -c %s "$OUT/install.iso")
"${V[@]}" vol-delete --pool "$POOL" "$ISO_VOL" >/dev/null 2>&1 || true
"${V[@]}" vol-create-as "$POOL" "$ISO_VOL" "$size" --format raw >/dev/null \
  && "${V[@]}" vol-upload --pool "$POOL" "$ISO_VOL" "$OUT/install.iso" \
  || die "could not upload the install ISO into pool $POOL"
rm -f "$OUT/install.iso"
log "install ISO in pool $POOL as $ISO_VOL"

# --- install ---------------------------------------------------------------------
OSINFO=rhel9.0
virt-install --osinfo list 2>/dev/null | grep -qw rocky9 && OSINFO=rocky9
log "creating $VM_NAME: ${VM_VCPUS} vCPU, ${VM_RAM_MB} MB RAM, ${VM_DISK_GB} GB disk"
log "installing from ${NIST_ROCKY_MIRROR:-https://dl.rockylinux.org/pub/rocky/9} (unattended, expect 15-25 min)"
CONSOLE="$OUT/console.log"
STALL_MIN="${NIST_INSTALL_STALL_MIN:-20}"
LIMIT_MIN="${NIST_INSTALL_TIMEOUT_MIN:-120}"
"$ROOT/tools/console-record.sh" "$VM_NAME" "$CONSOLE" $(( LIMIT_MIN * 60 + 600 )) 2> "$OUT/console-record.err" &
rec=$!
virt-install --connect "$NIST_LIBVIRT_URI" --name "$VM_NAME" \
  --memory "$VM_RAM_MB" --vcpus "$VM_VCPUS" --cpu host-passthrough --machine q35 \
  --boot "uefi,firmware.feature0.name=secure-boot,firmware.feature0.enabled=yes,firmware.feature1.name=enrolled-keys,firmware.feature1.enabled=yes" \
  --tpm backend.type=emulator,backend.version=2.0,model=tpm-crb \
  --disk "pool=$POOL,size=$VM_DISK_GB,format=qcow2,bus=virtio,serial=$VM_NAME,cache=none,discard=unmap" \
  --cdrom "$pool_path/$ISO_VOL" \
  --network "network=$VM_NETWORK,model=virtio" --graphics none \
  --console pty,target_type=serial --os-variant "$OSINFO" \
  --noautoconsole --wait -1 > "$OUT/virt-install.log" 2>&1 &
vi_pid=$!
log "watching the install: the console is recorded in $CONSOLE"
started=$SECONDS last_size=-1 last_change=$SECONDS why=""
while kill -0 "$vi_pid" 2>/dev/null; do
  sleep 30
  size=$(stat -c %s "$CONSOLE" 2>/dev/null || echo 0)
  if [[ "$size" != "$last_size" ]]; then last_size=$size; last_change=$SECONDS; fi
  # The kickstart ends with `reboot`; an installer that halts or powers off
  # has given up, and qemu stays up with nothing more to say (DEFECTS 7.30).
  if grep -aqE 'reboot: (System halted|Power down)' "$CONSOLE" 2>/dev/null; then
    why="the installer halted itself after $(( (SECONDS - started) / 60 )) minutes, before installing: anaconda gave up"; break
  fi
  if (( SECONDS - last_change > STALL_MIN * 60 )); then
    why="the installer's console printed nothing for ${STALL_MIN} minutes"; break
  fi
  if (( SECONDS - started > LIMIT_MIN * 60 )); then
    why="the install has run for more than ${LIMIT_MIN} minutes"; break
  fi
done
if [[ -n "$why" ]]; then
  kill "$vi_pid" 2>/dev/null || true; kill "$rec" 2>/dev/null || true
  echo "error: $why. What the installer said (tools/install-log.sh $CONSOLE):" >&2
  "$ROOT/tools/install-log.sh" "$CONSOLE" 2>&1 | sed 's/^/  /' >&2
  cat >&2 <<EOF
If an error above names the kickstart, a disk or a package, that is the
cause. Otherwise run tools/diagnose-lab-net.sh: it tests each layer between a
guest and the mirror and names the one that fails.
The VM is left running to inspect:  ./tools/lab-console.sh $VM_NAME
Remove it afterwards:               $0 --name $VM_NAME --role $VM_ROLE --destroy
EOF
  exit 1
fi
wait "$vi_pid" || { cat "$OUT/virt-install.log" >&2; kill "$rec" 2>/dev/null; die "virt-install failed (its log: $OUT/virt-install.log)"; }
log "install finished; waiting for the VM to boot"

# virt-install restarts the guest after its install; start it if it did not.
for _ in $(seq 1 30); do
  state="$("${V[@]}" domstate "$VM_NAME" 2>/dev/null || echo unknown)"
  [[ "$state" == "running" ]] && break
  "${V[@]}" start "$VM_NAME" >/dev/null 2>&1 || true
  sleep 5
done
# The install media holds the admin password's hash: out, and gone. (The awk
# here, as everywhere a virsh listing is read under pipefail, reads to the end:
# one that exited at its match left virsh writing into a closed pipe, and its
# SIGPIPE ended this script without a word, the guest installed but never
# registered.)
cd_dev=$("${V[@]}" domblklist "$VM_NAME" --details 2>/dev/null | awk '$2=="cdrom" && !f {print $3; f=1}')
[[ -n "$cd_dev" ]] && "${V[@]}" change-media "$VM_NAME" "$cd_dev" --eject --live --config >/dev/null 2>&1 || true
"${V[@]}" vol-delete --pool "$POOL" "$ISO_VOL" >/dev/null 2>&1 && log "install ISO ejected and deleted"

log "resolving guest address"
IP=""
for _ in $(seq 1 60); do
  IP="$("${V[@]}" domifaddr "$VM_NAME" --source lease 2>/dev/null | awk '/ipv4/ && !f {split($4,a,"/"); print a[1]; f=1}')"
  [[ -n "$IP" ]] && break
  sleep 5
done
[[ -n "$IP" ]] || die "could not determine the guest IP (./tools/lab-console.sh $VM_NAME)"
log "guest is at $IP"

# --- register in the Ansible inventory ---------------------------------------
"$ROOT/tools/inventory.py" add "$VM_NAME" --ip "$IP" --user "$ADMIN_USER" --role "$VM_ROLE"
log "inventory now:"
"$ROOT/tools/inventory.py" show

# A freshly installed guest has a new host key. DHCP hands addresses out
# again, so an entry recorded for this address belongs to a guest that no
# longer exists: forget it, then record this guest's key once its sshd
# answers (DEFECTS 7.24).
touch "$SECRETS/known_hosts"; chmod 600 "$SECRETS/known_hosts"
ssh-keygen -R "$IP" -f "$SECRETS/known_hosts" >/dev/null 2>&1 || true
log "waiting for SSH"
ssh_up=0
for _ in $(seq 1 60); do
  if ! ssh-keygen -F "$IP" -f "$SECRETS/known_hosts" >/dev/null 2>&1; then
    ssh-keyscan -H "$IP" 2>/dev/null >> "$SECRETS/known_hosts" || true
  fi
  if ssh -i "$SECRETS/id_rsa" -o StrictHostKeyChecking=yes \
         -o UserKnownHostsFile="$SECRETS/known_hosts" -o ConnectTimeout=5 \
         -o BatchMode=yes "$ADMIN_USER@$IP" true 2>/dev/null; then
    log "SSH is up"; ssh_up=1
    break
  fi
  sleep 5
done
kill "$rec" 2>/dev/null || true
(( ssh_up )) || die "no SSH to $ADMIN_USER@$IP after 5 minutes (./tools/lab-console.sh $VM_NAME)"

# The forwarding advice only applies when there is no collector yet.
if [[ "$VM_ROLE" == "log" ]]; then
  NEXT_HINT="
  This host receives forwarded audit records. make pki && make apply
  configures both halves: every CUI host forwards, and this one listens.
  Then 03.03.05c is verified rather than reported MANUAL:

             make verify
"
elif "$ROOT/tools/inventory.py" show 2>/dev/null | grep -q ' log '; then
  NEXT_HINT=""
else
  NEXT_HINT="
  A single CUI host cannot exercise audit-record forwarding (03.03.05c):
  there is nowhere to forward to, so the assessor reports it MANUAL. Build
  the collector and re-apply to close that:

             make vm-log && make pki && make apply
"
fi

# Give back the memory the installer needed and the guest does not.
if [[ "$VM_ROLE" == "log" && "$VM_RUNTIME_RAM_MB" -lt "$VM_RAM_MB" ]]; then
  log "trimming $VM_NAME to ${VM_RUNTIME_RAM_MB} MB (the installer needed ${VM_RAM_MB})"
  "${V[@]}" setmem "$VM_NAME" "${VM_RUNTIME_RAM_MB}M" --config --live >/dev/null 2>&1 \
    || log "could not trim memory; leaving at ${VM_RAM_MB} MB"
fi

cat <<DONE

  VM:        $VM_NAME  (role: $VM_ROLE)
  Address:   $IP
  User:      $ADMIN_USER  (password in .secrets/admin_password)
  Inventory: $NIST_INVENTORY
  SSH:       ./tools/lab-ssh.sh $VM_NAME      (both factors, as apply does)
  Console:   ./tools/lab-console.sh $VM_NAME  (when SSH cannot reach it)
  Install:   $OUT (its console, recorded)

  Once hardened, 03.05.03 requires publickey AND password; tools/lab-ssh.sh
  supplies both, a plain \`ssh\` only the key.

  Next:      make apply          apply the 800-171r3 overlay
             make verify         assess the host against all 97 requirements
$NEXT_HINT
DONE
