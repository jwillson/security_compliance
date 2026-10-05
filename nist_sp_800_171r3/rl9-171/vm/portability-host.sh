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
# nist-ptest (virbr180, 192.168.180.0/24, NAT). Images are downloaded once to
# the libvirt image directory, checked against the distribution's published
# SHA-256, and copied for each guest. tools/portability-run.sh drives it.
# `destroy` removes the guest, its disk and logs, and the network once no
# ptest guest is left; make teardown removes them too.
#
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
V=(sudo virsh -c qemu:///system)
IMAGES=/var/lib/libvirt/images
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

address() {
  "${V[@]}" domifaddr "$name" --source lease 2>/dev/null | awk '/ipv4/ {split($4,a,"/"); print a[1]; exit}'
}

build() {
  [[ -f "$KEY.pub" ]] || die "no public key at $KEY.pub (set NIST_BYO_KEY)"
  "${V[@]}" dominfo "$name" >/dev/null 2>&1 && die "$name exists (vm/portability-host.sh destroy $distro first)"
  [[ "$(cat /sys/module/kvm_intel/parameters/nested /sys/module/kvm_amd/parameters/nested 2>/dev/null | head -1)" =~ ^(Y|1)$ ]] \
    || die "nested virtualisation is off on this host (kvm_intel/kvm_amd nested=1)"
  local urls url sums base cache work seed
  mapfile -t urls < <(image_url); url=${urls[0]}; sums=${urls[1]}
  base=$(basename "$url"); cache="$IMAGES/ptest-base-$distro.qcow2"
  if ! sudo test -f "$cache"; then
    say "downloading $base"
    work=$(mktemp -d)
    curl -fL --retry 3 -o "$work/$base" "$url"
    curl -fsSL -o "$work/CHECKSUM" "$sums"
    want=$(grep -E "^SHA256 \($base\)" "$work/CHECKSUM" | awk '{print $NF}')
    [[ -n "$want" ]] || die "no SHA-256 for $base in $(basename "$sums")"
    echo "$want  $work/$base" | sha256sum -c --quiet - || die "$base does not match its published SHA-256"
    sudo cp "$work/$base" "$cache"; rm -rf "$work"
  fi
  ensure_network
  say "disk for $name (80 GiB)"
  sudo qemu-img convert -O qcow2 "$cache" "$IMAGES/$name.qcow2"
  sudo qemu-img resize -q "$IMAGES/$name.qcow2" 80G
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
  if command -v cloud-localds >/dev/null 2>&1; then cloud-localds "$seed/seed.iso" "$seed/user-data" "$seed/meta-data"
  else xorriso -as mkisofs -quiet -output "$seed/seed.iso" -volid cidata -joliet -rock "$seed/user-data" "$seed/meta-data"; fi
  sudo cp "$seed/seed.iso" "$IMAGES/$name-seed.iso"; rm -rf "$seed"
  say "defining $name: 14 GiB, 4 vCPU, nested"
  sudo virt-install --connect qemu:///system --name "$name" --memory 14336 --vcpus 4 \
    --cpu host-passthrough --osinfo linux2022 --import --noautoconsole \
    --disk "path=$IMAGES/$name.qcow2,bus=virtio" --disk "path=$IMAGES/$name-seed.iso,device=cdrom" \
    --network "network=$NET,model=virtio" --graphics none \
    --serial "pty,log.file=/var/log/libvirt/qemu/$name-serial.log" --console pty,target_type=serial >/dev/null
  local i ip=""
  for i in $(seq 1 60); do ip=$(address); [[ -n "$ip" ]] && break; sleep 5; done
  [[ -n "$ip" ]] || die "$name has no address after 5 minutes (/var/log/libvirt/qemu/$name-serial.log)"
  for i in $(seq 1 60); do
    ssh -i "$KEY" -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 \
      "ptest@$ip" 'test -f /var/lib/cloud/instance/boot-finished' 2>/dev/null && { say "$name ready at $ip"; return 0; }
    sleep 5
  done
  die "$name did not finish cloud-init (/var/log/libvirt/qemu/$name-serial.log)"
}

destroy() {
  "${V[@]}" destroy "$name" >/dev/null 2>&1 || true
  "${V[@]}" undefine "$name" --nvram >/dev/null 2>&1 || "${V[@]}" undefine "$name" >/dev/null 2>&1 || true
  sudo rm -f "$IMAGES/$name.qcow2" "$IMAGES/$name-seed.iso" "/var/log/libvirt/qemu/$name.log" "/var/log/libvirt/qemu/$name-serial.log"
  say "removed $name"
  if ! "${V[@]}" list --all --name | grep -q '^ptest-'; then
    "${V[@]}" net-destroy "$NET" >/dev/null 2>&1 || true
    "${V[@]}" net-undefine "$NET" >/dev/null 2>&1 || true
    sudo rm -f "$IMAGES"/ptest-base-*.qcow2
    say "removed $NET and the cached images"
  fi
}

case $cmd in
  build) build ;;
  destroy) destroy ;;
  address) address ;;
esac
