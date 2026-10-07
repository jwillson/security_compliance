#!/usr/bin/env bash
#
# A throwaway control host of another distribution, to prove the labs run
# there (DEFECTS 7.21): the stock cloud image, 14 GiB, 4 vCPU, nested
# virtualisation, on its own small network so the lab it builds inside has
# nist-lab's subnet to itself.
#
#   vm/portability-host.sh build   rocky9|fedora
#   vm/portability-host.sh destroy rocky9|fedora
#   vm/portability-host.sh address rocky9|fedora
#
# The guest is ptest-DISTRO, user `ptest` with the operator's key
# ($NIST_BYO_KEY.pub, default ~/.ssh/id_rsa.pub) and passwordless sudo - a
# test workstation, not a lab target; nothing hardens it. Its network is
# nist-ptest (virbr180, 192.168.180.0/24, NAT). Images are downloaded once,
# checked against the distribution's published SHA-256, and kept as a volume
# in the default pool; each guest's disk is a clone of it. It runs in the
# control-plane container, through the libvirt socket (TASKS C5).
# tools/portability-run.sh drives it. `destroy` removes the guest and its
# volumes, and the network and the image once no ptest guest is left; make
# teardown removes them too.
#
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../lib/container.sh"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
V=(virsh -c "$NIST_LIBVIRT_URI")
POOL=default
KEY="${NIST_BYO_KEY:-$HOME/.ssh/id_rsa}"
NET=nist-ptest BRIDGE=virbr180 SUBNET=192.168.180
say() { echo "==> $*"; }
die() { echo "error: $*" >&2; exit 1; }

cmd=${1:-}; distro=${2:-}
[[ "$cmd" =~ ^(build|destroy|address)$ && "$distro" =~ ^(rocky9|fedora)$ ]] || { sed -n '3,20p' "$0"; exit 2; }
name=ptest-$distro

image_url() {   # the current cloud image and its checksum file
  case $distro in
    rocky9)
      echo "https://dl.rockylinux.org/pub/rocky/9/images/x86_64/Rocky-9-GenericCloud-Base.latest.x86_64.qcow2"
      echo "https://dl.rockylinux.org/pub/rocky/9/images/x86_64/CHECKSUM" ;;   # as vm/byo-guest.sh checks it
    fedora)
      # The newest release with a Cloud image, read from the mirror rather
      # than a build number written here.
      local base=https://dl.fedoraproject.org/pub/fedora/linux/releases rel sums f
      for rel in $(curl -fsSL "$base/" | grep -oE 'href="[0-9]+/"' | grep -oE '[0-9]+' | sort -rn | head -4); do
        sums=$(curl -fsSL "$base/$rel/Cloud/x86_64/images/" 2>/dev/null | grep -oE 'Fedora-Cloud-[0-9]+-[0-9.]+-x86_64-CHECKSUM' | head -1) || true
        [[ -n "$sums" ]] || continue
        f=$(curl -fsSL "$base/$rel/Cloud/x86_64/images/$sums" | grep -oE 'Fedora-Cloud-Base-Generic-[0-9]+-[0-9.]+\.x86_64\.qcow2' | head -1)
        [[ -n "$f" ]] && { echo "$base/$rel/Cloud/x86_64/images/$f"; echo "$base/$rel/Cloud/x86_64/images/$sums"; return; }
      done
      die "no Fedora Cloud image found under $base" ;;
  esac
}

ensure_network() {
  "${V[@]}" net-info "$NET" >/dev/null 2>&1 && { "${V[@]}" net-start "$NET" >/dev/null 2>&1 || true; return; }
  say "defining $NET ($SUBNET.0/24)"
  "${V[@]}" net-define /dev/stdin >/dev/null <<XML
<network><name>$NET</name><forward mode='nat'/><bridge name='$BRIDGE' stp='on' delay='0'/>
  <ip address='$SUBNET.1' netmask='255.255.255.0'><dhcp><range start='$SUBNET.100' end='$SUBNET.200'/></dhcp></ip>
</network>
XML
  "${V[@]}" net-start "$NET" >/dev/null
}

upload() {   # FILE VOLUME into the pool
  local size; size=$(stat -c %s "$1")
  "${V[@]}" vol-delete --pool "$POOL" "$2" >/dev/null 2>&1 || true
  "${V[@]}" vol-create-as "$POOL" "$2" "$size" --format raw >/dev/null && "${V[@]}" vol-upload --pool "$POOL" "$2" "$1" \
    || die "could not upload $1 into pool $POOL"
}

address() {
  "${V[@]}" domifaddr "$name" --source lease 2>/dev/null | awk '/ipv4/ && !f {split($4,a,"/"); print a[1]; f=1}'
}

build() {
  [[ -f "$KEY.pub" ]] || die "no public key at $KEY.pub (set NIST_BYO_KEY)"
  "${V[@]}" dominfo "$name" >/dev/null 2>&1 && die "$name exists (vm/portability-host.sh destroy $distro first)"
  [[ "$(cat /sys/module/kvm_intel/parameters/nested /sys/module/kvm_amd/parameters/nested 2>/dev/null | head -1)" =~ ^(Y|1)$ ]] \
    || die "nested virtualisation is off on this host (kvm_intel/kvm_amd nested=1)"
  local urls url sums base cache work seed
  mapfile -t urls < <(image_url); url=${urls[0]}; sums=${urls[1]}
  base=$(basename "$url"); cache="ptest-base-$distro.qcow2"
  if ! "${V[@]}" vol-info --pool "$POOL" "$cache" >/dev/null 2>&1; then
    say "downloading $base"
    work=$(mktemp -d)
    curl -fL --retry 3 -o "$work/$base" "$url"
    curl -fsSL -o "$work/CHECKSUM" "$sums"
    want=$(grep -E "^SHA256 \($base\)" "$work/CHECKSUM" | awk '{print $NF}')
    [[ -n "$want" ]] || die "no SHA-256 for $base in $(basename "$sums")"
    echo "$want  $work/$base" | sha256sum -c --quiet - || die "$base does not match its published SHA-256"
    upload "$work/$base" "$cache"; rm -rf "$work"
    "${V[@]}" pool-refresh "$POOL" >/dev/null
  fi
  ensure_network
  say "disk for $name (80 GiB), a clone of the image"
  "${V[@]}" vol-clone --pool "$POOL" "$cache" "$name.qcow2" >/dev/null
  "${V[@]}" vol-resize --pool "$POOL" "$name.qcow2" 80G >/dev/null
  seed=$(mktemp -d)
  cat > "$seed/user-data" <<EOF
#cloud-config
hostname: $name
users:
  - name: ptest
    groups: [wheel]
    sudo: "ALL=(ALL) NOPASSWD:ALL"
    shell: /bin/bash
    ssh_authorized_keys: ["$(cat "$KEY.pub")"]
growpart: {mode: auto, devices: ["/"]}
resize_rootfs: true
EOF
  printf 'instance-id: %s\nlocal-hostname: %s\n' "$name" "$name" > "$seed/meta-data"
  xorriso -as mkisofs -quiet -output "$seed/seed.iso" -volid cidata -joliet -rock "$seed/user-data" "$seed/meta-data"
  upload "$seed/seed.iso" "$name-seed.iso"; rm -rf "$seed"
  say "defining $name: 14 GiB, 4 vCPU, nested"
  virt-install --connect "$NIST_LIBVIRT_URI" --name "$name" --memory 14336 --vcpus 4 \
    --cpu host-passthrough --osinfo linux2022 --import --noautoconsole \
    --disk "vol=$POOL/$name.qcow2,bus=virtio" --disk "vol=$POOL/$name-seed.iso,device=cdrom" \
    --network "network=$NET,model=virtio" --graphics none \
    --console pty,target_type=serial >/dev/null
  local i ip=""
  for i in $(seq 1 60); do ip=$(address); [[ -n "$ip" ]] && break; sleep 5; done
  [[ -n "$ip" ]] || die "$name has no address after 5 minutes (./tools/lab-console.sh $name)"
  for i in $(seq 1 60); do
    ssh -i "$KEY" -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 \
      "ptest@$ip" 'test -f /var/lib/cloud/instance/boot-finished' 2>/dev/null && { say "$name ready at $ip"; return 0; }
    sleep 5
  done
  die "$name did not finish cloud-init (./tools/lab-console.sh $name)"
}

destroy() {
  "${V[@]}" destroy "$name" >/dev/null 2>&1 || true
  "${V[@]}" undefine "$name" --nvram >/dev/null 2>&1 || "${V[@]}" undefine "$name" >/dev/null 2>&1 || true
  "${V[@]}" vol-delete --pool "$POOL" "$name.qcow2" >/dev/null 2>&1 || true
  "${V[@]}" vol-delete --pool "$POOL" "$name-seed.iso" >/dev/null 2>&1 || true
  say "removed $name"
  if ! "${V[@]}" list --all --name | grep -q '^ptest-'; then
    "${V[@]}" net-destroy "$NET" >/dev/null 2>&1 || true
    "${V[@]}" net-undefine "$NET" >/dev/null 2>&1 || true
    local v; for v in $("${V[@]}" vol-list --pool "$POOL" 2>/dev/null | awk '$1 ~ /^ptest-base-/ {print $1}'); do
      "${V[@]}" vol-delete --pool "$POOL" "$v" >/dev/null 2>&1 || true
    done
    say "removed $NET and the cached images"
  fi
}

case $cmd in
  build) build ;;
  destroy) destroy ;;
  address) address ;;
esac
