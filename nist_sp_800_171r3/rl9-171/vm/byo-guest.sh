#!/usr/bin/env bash
#
# Build a "bring your own" Rocky 9 guest for the lab: a stock GenericCloud
# image and cloud-init, deliberately NOT the kickstart. It stands in for a
# host this toolkit did not build (TASKS/DEFECTS Phase 2), so nothing here
# may pre-harden it.
#
#   vm/byo-guest.sh build NAME --ip IP [--role cui|log] [--data-disk GB]
#                               [--tpm] [--user NAME]...
#   vm/byo-guest.sh check NAME      read-only: what the guest provides
#   vm/byo-guest.sh destroy NAME    domain, disks, snapshots, DHCP pin,
#                                   inventory entry, known_hosts lines
#
#   --data-disk GB  a second disk carrying volume group vg_sys with all of it
#                   free, as an installer sized for data would leave it. The
#                   role's LUKS path (03.08.09 / 03.13.08) needs >= 3 GB free.
#   --tpm           a TPM 2.0 (swtpm), so the role's clevis tpm2 bind runs.
#   --user NAME     an extra ordinary interactive account (repeatable), for
#                   anything that loops over accounts (6b.4).
#
# Every guest gets `byoadmin` (wheel, sudo asks for a password, key from
# $NIST_BYO_KEY.pub). Secrets live in the lab directory, never in the repo:
#   $NIST_BYO_LAB (default ~/.local/share/nist-byo-lab)
#     byoadmin_password         sudo + the SSH second factor after 03.05.03
#     NAME/USER_password        each --user account's password
#     NAME/{user-data,meta-data,seed.iso,ip}   this guest's cloud-init seed
# A build ends by adding the host to inventory/hosts.yml (--connection byo),
# minting its TLS certificate into $NIST_PKI_DIR when that is set, and saving
# a "fresh" snapshot (vm/byo-snapshot.sh) to revert to.
#
# Host prerequisites, each checked or fixed here rather than by hand:
#   libvirt qemu:///system, network nist-lab (vm/nist-lab-network.xml),
#   virt-install, cloud-localds, qemu-img, passwordless sudo for the image
#   directory; swtpm + swtpm-tools for --tpm.
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
LAB="${NIST_BYO_LAB:-$HOME/.local/share/nist-byo-lab}"
KEY="${NIST_BYO_KEY:-$HOME/.ssh/id_rsa}"
IMAGES=/var/lib/libvirt/images
BASE="$IMAGES/rocky9-genericcloud-base.qcow2"
IMAGE_URL="https://dl.rockylinux.org/pub/rocky/9/images/x86_64"
IMAGE_NAME="Rocky-9-GenericCloud-Base.latest.x86_64.qcow2"
NET=nist-lab
VIRSH=(virsh -c qemu:///system)
SSH=(ssh -i "$KEY" -o BatchMode=yes -o ConnectTimeout=5
     -o StrictHostKeyChecking=accept-new)

die()  { echo "error: $*" >&2; exit 1; }
say()  { echo "==> $*"; }

usage() { sed -n '3,33p' "$0"; exit "${1:-0}"; }

# virt-install imports gi from the system Python. A PATH that puts another
# python3 first (linuxbrew, pyenv, a venv) breaks it with "No module named
# 'gi'", so it is always run under /usr/bin/python3.
virt_install() { /usr/bin/python3 /usr/bin/virt-install "$@"; }

guest_ip() { cat "$LAB/$1/ip" 2>/dev/null || die "no $LAB/$1/ip - was $1 built by this script?"; }

# ---------------------------------------------------------------------------
# swtpm: libvirt runs the emulator as swtpm_user (default tss), but Ubuntu's
# package leaves the local CA directory owned by another user, so the first
# vTPM fails at "Need read/write rights on statedir /var/lib/swtpm-localca
# for user tss". Fixed here, once, and said out loud.
# ---------------------------------------------------------------------------
ensure_swtpm() {
  command -v swtpm_setup >/dev/null || die "--tpm needs swtpm and swtpm-tools"
  local user dir=/var/lib/swtpm-localca owner
  # qemu.conf may not exist at all (it does not on this Ubuntu laptop); then
  # libvirt uses its compiled-in default, tss.
  user=$(sudo sed -n 's/^[[:space:]]*swtpm_user[[:space:]]*=[[:space:]]*"\(.*\)"/\1/p' \
           /etc/libvirt/qemu.conf 2>/dev/null | tail -1 || true)
  user=${user:-tss}
  owner=$(sudo stat -c %U "$dir" 2>/dev/null || echo missing)
  if [[ "$owner" != "$user" ]]; then
    say "swtpm: $dir is owned by $owner, libvirt runs swtpm as $user - fixing"
    sudo install -d -m 0750 -o "$user" -g root "$dir"
  fi
}

ensure_base() {
  sudo test -f "$BASE" && return 0
  say "fetching $IMAGE_NAME and verifying its checksum"
  local tmp; tmp=$(mktemp -d); trap 'rm -rf "$tmp"' RETURN
  curl -fsSL --retry 3 -o "$tmp/$IMAGE_NAME" "$IMAGE_URL/$IMAGE_NAME"
  curl -fsSL --retry 3 -o "$tmp/CHECKSUM" "$IMAGE_URL/CHECKSUM"
  (cd "$tmp" && grep "($IMAGE_NAME)" CHECKSUM \
     | sed 's/SHA256 (\(.*\)) = \(.*\)/\2  \1/' | sha256sum -c -)
  sudo install -m 0644 -o libvirt-qemu -g kvm "$tmp/$IMAGE_NAME" "$BASE"
}

ensure_lab() {
  install -d -m 0700 "$LAB"
  [[ -f "$KEY.pub" ]] || die "no public key at $KEY.pub (set NIST_BYO_KEY)"
  if [[ ! -f "$LAB/byoadmin_password" ]]; then
    say "generating $LAB/byoadmin_password"
    (umask 077; python3 -c 'import secrets,string;a=string.ascii_letters+string.digits;print("".join(secrets.choice(a) for _ in range(24)))' \
       > "$LAB/byoadmin_password")
  fi
}

randpw() { python3 -c 'import secrets,string;a=string.ascii_letters+string.digits;print("".join(secrets.choice(a) for _ in range(24)))'; }

# ---------------------------------------------------------------------------
write_seed() {   # NAME DIR DATA_GB USERS...
  local name=$1 dir=$2 data_gb=$3; shift 3
  local key hash; key=$(cat "$KEY.pub"); hash=$(openssl passwd -6 "$(cat "$LAB/byoadmin_password")")
  {
    cat <<EOF
#cloud-config
# $name: a stock Rocky 9 GenericCloud guest, built by vm/byo-guest.sh and
# deliberately NOT by vm/build-vm.sh - the "host you already have" case.
# Key login from the operator's key, sudo that asks for a password.
hostname: $name
fqdn: $name.nist-lab
manage_etc_hosts: true
users:
  - name: byoadmin
    groups: [wheel]
    shell: /bin/bash
    lock_passwd: false
    passwd: "$hash"
    sudo: "ALL=(ALL) ALL"
    ssh_authorized_keys:
      - $key
EOF
    local u pw
    for u in "$@"; do
      pw="$dir/${u}_password"
      [[ -f "$pw" ]] || (umask 077; randpw > "$pw")
      cat <<EOF
  - name: $u
    shell: /bin/bash
    lock_passwd: false
    passwd: "$(openssl passwd -6 "$(cat "$pw")")"
EOF
    done
    cat <<EOF
ssh_pwauth: true
disable_root: true
growpart:
  mode: auto
  devices: ["/"]
package_update: false
EOF
    if (( data_gb > 0 )); then
      cat <<'EOF'
packages: [lvm2]
runcmd:
  # A volume group with all of its space free, as an installer sized for data
  # would leave it. Nothing is carved here: the role creates its own volumes.
  - [sh, -c, 'vgs vg_sys >/dev/null 2>&1 || { pvcreate -y /dev/vdb && vgcreate vg_sys /dev/vdb; }']
EOF
    fi
  } > "$dir/user-data"
  printf 'instance-id: %s\nlocal-hostname: %s\n' "$name" "$name" > "$dir/meta-data"
  python3 -c 'import sys,yaml; yaml.safe_load(open(sys.argv[1]))' "$dir/user-data" \
    || die "generated user-data is not valid YAML"
  cloud-localds "$dir/seed.iso" "$dir/user-data" "$dir/meta-data"
}

wait_ready() {   # IP
  local ip=$1 i
  say "waiting for $ip: SSH, then cloud-init's boot-finished marker"
  # First boot is slow: a login can authenticate and then stall until logind
  # and cloud-init settle, so each probe has its own timeout. boot-finished is
  # world-readable; `cloud-init status` is not, for an unprivileged user.
  for i in $(seq 1 120); do
    if timeout 20 "${SSH[@]}" "byoadmin@$ip" 'test -f /var/lib/cloud/instance/boot-finished' 2>/dev/null; then
      say "ready after ~$((i * 5))s"; return 0
    fi
    sleep 5
  done
  die "$ip did not finish first boot in 10 minutes"
}

cmd_build() {
  local name="" ip="" role=cui data_gb=0 tpm=0 users=()
  name=${1:-}; [[ -n "$name" && "$name" != -* ]] || usage 1; shift
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --ip) ip=$2; shift 2 ;;
      --role) role=$2; shift 2 ;;
      --data-disk) data_gb=$2; shift 2 ;;
      --tpm) tpm=1; shift ;;
      --user) users+=("$2"); shift 2 ;;
      *) die "unknown option $1" ;;
    esac
  done
  [[ "$ip" =~ ^192\.168\.171\.([0-9]+)$ ]] || die "--ip must be on nist-lab (192.168.171.0/24)"
  [[ "$role" == cui || "$role" == log ]] || die "--role is cui or log"
  "${VIRSH[@]}" dominfo "$name" >/dev/null 2>&1 && die "$name exists (vm/byo-guest.sh destroy $name first)"

  # The MAC is derived from the address, so a rebuild gets the same pin.
  local last=${BASH_REMATCH[1]} mac dir="$LAB/$name"
  mac=$(printf '52:54:00:17:ab:%02x' "$last")

  # dnsmasq will not hand a pinned address to a new MAC while an unexpired
  # lease holds it for another: the guest silently gets a different address
  # and the wait below times out. Deriving the MAC from the address avoids
  # this for rebuilds; a guest built any other way can still leave one.
  # A lease held by a MAC that no defined guest has belongs to a guest that is
  # gone (the hand-built byo-log-01 had a random MAC): wait out its expiry -
  # at most the network's lease time, an hour - rather than stop. A lease held
  # by a live guest is a real conflict.
  local held owner
  held_by() { "${VIRSH[@]}" net-dhcp-leases "$NET" | awk -v ip="$ip/24" -v mac="$mac" \
                '$5 == ip && $3 != mac {print $3, $1 "T" $2}'; }
  held=$(held_by)
  if [[ -n "$held" ]]; then
    owner=$(for d in $("${VIRSH[@]}" list --all --name); do
              "${VIRSH[@]}" domiflist "$d" 2>/dev/null | grep -qi " ${held%% *}\$" && echo "$d"
            done)
    [[ -z "$owner" ]] || die "$ip is leased to ${held%% *} (guest $owner) until ${held#* }; pick another --ip"
    say "$ip is leased to ${held%% *}, a guest that no longer exists, until ${held#* }; waiting for it to expire"
    local i; for i in $(seq 1 130); do [[ -z "$(held_by)" ]] && break; sleep 30; done
    [[ -z "$(held_by)" ]] || die "the lease on $ip did not expire"
  fi

  ensure_lab; ensure_base
  (( tpm )) && ensure_swtpm
  install -d -m 0700 "$dir"; echo "$ip" > "$dir/ip"
  say "cloud-init seed in $dir"
  write_seed "$name" "$dir" "$data_gb" ${users[@]+"${users[@]}"}

  say "disks"
  sudo qemu-img create -q -f qcow2 -b "$BASE" -F qcow2 "$IMAGES/$name.qcow2" 20G
  sudo install -m 0644 -o libvirt-qemu -g kvm "$dir/seed.iso" "$IMAGES/$name-seed.iso"
  local disks=(--disk "path=$IMAGES/$name.qcow2,bus=virtio")
  if (( data_gb > 0 )); then
    sudo qemu-img create -q -f qcow2 "$IMAGES/$name-data.qcow2" "${data_gb}G"
    disks+=(--disk "path=$IMAGES/$name-data.qcow2,bus=virtio")
  fi

  say "DHCP pin $mac -> $ip"
  "${VIRSH[@]}" net-update "$NET" add ip-dhcp-host \
    "<host mac='$mac' name='$name' ip='$ip'/>" --live --config

  # Same firmware as the original BYO guests: q35, UEFI with Secure Boot
  # (PCR 7, which the role's clevis tpm2 bind seals to, measures it).
  # `hd` first: without a boot order the firmware may try network boot before
  # the disk, which cost ~10 minutes of a silent first boot on 2026-09-25.
  # The serial console is logged so a slow or failed boot can be read, not
  # guessed at: /var/log/libvirt/qemu/NAME-serial.log.
  local extra=()
  (( tpm )) && extra+=(--tpm "model=tpm-crb,backend.type=emulator,backend.version=2.0")
  say "defining $name"
  virt_install --connect qemu:///system --name "$name" --memory 3072 --vcpus 2 \
    --osinfo rocky9 --import --noautoconsole --machine q35 \
    --boot "hd,loader=/usr/share/OVMF/OVMF_CODE_4M.ms.fd,loader.readonly=yes,loader.type=pflash,loader.secure=yes,nvram.template=/usr/share/OVMF/OVMF_VARS_4M.ms.fd" \
    --features smm.state=on \
    "${disks[@]}" \
    --disk "path=$IMAGES/$name-seed.iso,device=cdrom,bus=sata" \
    --network "network=$NET,mac=$mac,model=virtio" \
    ${extra[@]+"${extra[@]}"} \
    --graphics none --serial "pty,log.file=/var/log/libvirt/qemu/$name-serial.log" \
    --console pty,target_type=serial

  ssh-keygen -R "$ip" >/dev/null 2>&1 || true
  wait_ready "$ip"

  say "inventory"
  (cd "$ROOT" && ./tools/inventory.py add "$name" --ip "$ip" --user byoadmin \
                   --role "$role" --connection byo --key "$KEY")
  if [[ -n "${NIST_PKI_DIR:-}" ]]; then
    say "TLS certificate in $NIST_PKI_DIR"
    (cd "$ROOT" && ./tools/lab-pki.sh -d "$NIST_PKI_DIR" "$name=$ip")
  fi

  "$HERE/byo-snapshot.sh" save "$name" fresh
  cmd_check "$name"
}

cmd_check() {
  local name=${1:?name}; local ip; ip=$(guest_ip "$name")
  say "$name ($ip)"
  # Through ansible, not ssh: the inventory carries the second factor and
  # become, so this works on a stock guest and on a hardened one alike.
  # Read-only.
  local probe; probe=$(mktemp); trap 'rm -f "$probe"' RETURN
  cat > "$probe" <<'EOF'
#!/bin/bash
echo "release       $(cat /etc/rocky-release)"
echo "openssh       $(rpm -q --qf '%{VERSION}' openssh-server)"
echo "accounts      $(awk -F: '($3>=1000 && $3!=65534 && $7 !~ /(nologin|false)$/){printf "%s ", $1}' /etc/passwd)"
echo "vg_sys free   $(vgs --noheadings --units g -o vg_free vg_sys 2>/dev/null | tr -d ' ' || echo none)"
echo "tpm           $( [ -e /dev/tpmrm0 ] && echo present || echo none)"
sb=$(od -An -t u1 /sys/firmware/efi/efivars/SecureBoot-* 2>/dev/null | awk '{print $NF}')
echo "secure boot   $( [ "$sb" = 1 ] && echo enabled || echo "disabled/unknown")"
echo "fips          $(cat /proc/sys/crypto/fips_enabled 2>/dev/null)"
EOF
  (cd "$ROOT" && ansible "$name" -b -m ansible.builtin.script -a "$probe" -o 2>/dev/null) \
    | python3 -c 'import json,re,sys
for l in sys.stdin:
    m = re.search(r"=> (\{.*\})\s*$", l)
    print((json.loads(m.group(1)).get("stdout") or json.loads(m.group(1)).get("msg","")).strip() if m else l.rstrip())'
}

cmd_destroy() {
  local name=${1:?name} ip="" mac
  ip=$(cat "$LAB/$name/ip" 2>/dev/null || true)
  # The domain may already be gone (a half-built or half-destroyed guest);
  # destroy still removes whatever files, pin and entries are left.
  mac=$("${VIRSH[@]}" domiflist "$name" 2>/dev/null | awk '/nist-lab/ {print $5}' || true)
  # No domain means no MAC to read; derive it the way build does.
  if [[ -z "$mac" && "$ip" =~ \.([0-9]+)$ ]]; then mac=$(printf '52:54:00:17:ab:%02x' "${BASH_REMATCH[1]}"); fi
  say "destroying $name"
  "${VIRSH[@]}" destroy "$name" >/dev/null 2>&1 || true
  "${VIRSH[@]}" undefine "$name" --nvram --tpm >/dev/null 2>&1 \
    || "${VIRSH[@]}" undefine "$name" --nvram >/dev/null 2>&1 || true
  # The globs must expand as root: the operator cannot list $IMAGES, so an
  # unprivileged shell leaves them literal and `rm -f` silently matches
  # nothing (the first destroy left four snapshot files behind, TPM state
  # included).
  sudo bash -c 'cd "$1" && rm -rf -- "$2.qcow2" "$2-data.qcow2" "$2-seed.iso" \
                  "$2".*.qcow2 "$2"-data.*.qcow2 "$2".*.nvram "$2".*.tpm' _ "$IMAGES" "$name"
  [[ -n "$mac" && -n "$ip" ]] && "${VIRSH[@]}" net-update "$NET" delete ip-dhcp-host \
    "<host mac='$mac' name='$name' ip='$ip'/>" --live --config >/dev/null 2>&1 || true
  (cd "$ROOT" && ./tools/inventory.py remove "$name") 2>/dev/null || true
  [[ -n "$ip" ]] && ssh-keygen -R "$ip" >/dev/null 2>&1 || true
  # The seed and the per-guest passwords stay in $LAB/$name, so a rebuild
  # reuses the same passwords. Remove that directory by hand to forget them.
  if [[ -d "$LAB/$name" ]]; then say "gone (kept $LAB/$name)"; else say "gone"; fi
}

case "${1:-}" in
  build)   shift; cmd_build "$@" ;;
  check)   shift; cmd_check "$@" ;;
  destroy) shift; cmd_destroy "$@" ;;
  -h|--help|"") usage 0 ;;
  *) usage 1 ;;
esac
