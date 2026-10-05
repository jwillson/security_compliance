#!/usr/bin/env bash
#
# Why can a lab guest not reach the Rocky mirror? Read-only (DEFECTS 7.22).
#
#   tools/diagnose-lab-net.sh [MIRROR_URL]
#
# What vm/build-vm.sh points at when an install stalls. Each layer a guest's
# install depends on is tested on its own, so the failure names its cause:
#
#   1. the host's own resolver - including systemd-resolved's stub
#      (127.0.0.53), which breaks anything that copies resolv.conf into an
#      isolated network stack (qemu user-mode networking, containers);
#   2. libvirt's dnsmasq for the lab network: installed (Arch packages it as
#      an optional dependency) and running;
#   3. the guests' DNS path: a query sent from this host to the lab
#      network's address, the server the guests use;
#   4. the way out: forwarding, a NAT rule for the lab subnet, and Docker's
#      FORWARD DROP policy;
#   5. the mirror itself, over HTTPS from the host;
#   6. DNS inside a podman container, as the kickstart validator runs.
#
# The lab network must exist (vm/lab-network.sh ensure). Exit 1 if any layer
# fails.
#
# No pipefail: several tests pipe into `grep -q`, whose early exit would
# fail the pipeline with the writer's SIGPIPE and read as a failure.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
XML="$HERE/../vm/nist-lab-network.xml"
NET=$(sed -n 's:.*<name>\(.*\)</name>.*:\1:p' "$XML" | head -1)
GW=$(sed -n "s:.*<ip address='\([0-9.]*\)'.*:\1:p" "$XML" | head -1)
SUBNET=${GW%.*}
MIRROR=${1:-${NIST_ROCKY_MIRROR:-https://dl.rockylinux.org/pub/rocky/9}}
HOST=$(sed -E 's#^[a-z]+://([^/:]+).*#\1#' <<<"$MIRROR")
fails=0
ok()   { echo "  ok    $*"; }
bad()  { echo "  FAIL  $*"; fails=$((fails + 1)); }
info() { echo "  info  $*"; }
dnsq() {   # SERVER NAME -> the first A record, by a plain UDP query (stdlib only)
  python3 - "$1" "$2" <<'PY'
import random, socket, struct, sys
server, name = sys.argv[1], sys.argv[2]
qid = random.randrange(65536)
q = struct.pack(">HHHHHH", qid, 0x0100, 1, 0, 0, 0)
q += b"".join(bytes([len(p)]) + p.encode() for p in name.split(".")) + b"\0" + struct.pack(">HH", 1, 1)
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.settimeout(5)
try:
    s.sendto(q, (server, 53)); data, _ = s.recvfrom(4096)
except OSError as e:
    print("no answer: %s" % e); sys.exit(1)
rcode, an = data[3] & 0x0F, struct.unpack(">H", data[6:8])[0]
if rcode or not an:
    print("rcode %d, %d answers" % (rcode, an)); sys.exit(1)
i = 12
while data[i]: i += data[i] + 1
i += 5
for _ in range(an):
    if data[i] & 0xC0 == 0xC0: i += 2
    else:
        while data[i]: i += data[i] + 1
        i += 1
    rtype, _, _, rdlen = struct.unpack(">HHIH", data[i:i + 10]); i += 10
    if rtype == 1:
        print(".".join(str(b) for b in data[i:i + 4])); sys.exit(0)
    i += rdlen
print("no A record"); sys.exit(1)
PY
}

echo "== the path from a $NET guest to $MIRROR"

echo "1. the host's resolver"
[[ -L /etc/resolv.conf ]] && info "/etc/resolv.conf -> $(readlink -f /etc/resolv.conf)"
ns=$(awk '/^nameserver/ {print $2}' /etc/resolv.conf 2>/dev/null | tr '\n' ' ')
info "nameservers: ${ns:-none}"
[[ "$ns" == "127.0.0.53 " ]] && info "only the systemd-resolved stub: right for this host and for libvirt's dnsmasq (which runs here), wrong for anything that copies resolv.conf into its own network (see 6)"
if addr=$(getent hosts "$HOST" | awk '{print $1; exit}') && [[ -n "$addr" ]]; then ok "this host resolves $HOST ($addr)"
else bad "this host cannot resolve $HOST - fix the host's DNS first; nothing below can work"; fi

echo "2. libvirt's dnsmasq for $NET"
command -v dnsmasq >/dev/null 2>&1 && ok "dnsmasq installed" \
  || bad "dnsmasq not installed: libvirt cannot serve DHCP or DNS to the guests (apt/dnf/pacman install dnsmasq)"
info_out=$(sudo virsh -c qemu:///system net-info "$NET" 2>/dev/null)
if grep -q 'Active: *yes' <<<"$info_out"; then ok "$NET is active"
else bad "$NET is not active (vm/lab-network.sh ensure)"; fi
pgrep -f "dnsmasq.*/$NET.conf" >/dev/null && ok "its dnsmasq is running" || bad "no dnsmasq running for $NET (sudo virsh -c qemu:///system net-destroy $NET; net-start $NET)"

echo "3. the guests' DNS: $GW, as a guest asks it"
if r=$(dnsq "$GW" "$HOST"); then ok "$GW resolves $HOST ($r)"
else bad "$GW does not resolve $HOST ($r): dnsmasq cannot reach the host's upstream resolvers - a VPN's split DNS, a firewall, or resolv.conf it cannot use"; fi

echo "4. the way out"
[[ "$(sysctl -n net.ipv4.ip_forward 2>/dev/null)" == 1 ]] && ok "forwarding on" || bad "net.ipv4.ip_forward is 0"
if sudo nft list ruleset 2>/dev/null | grep -q "$SUBNET\.0/24" || sudo iptables -t nat -S 2>/dev/null | grep -q "$SUBNET\.0/24"; then
  ok "a NAT rule for $SUBNET.0/24"
else bad "no NAT rule for $SUBNET.0/24 (libvirt adds it when $NET starts; a firewall reload can drop it - restart the network)"; fi
if sudo iptables -S FORWARD 2>/dev/null | grep -q '^-P FORWARD DROP' && { command -v docker >/dev/null 2>&1 || ip link show docker0 >/dev/null 2>&1; }; then
  bad "Docker's FORWARD DROP policy is in place: allow virbr17 in DOCKER-USER (vm/lab-network.sh prints the rules)"
fi

echo "5. the mirror"
if curl -fsS -o /dev/null --max-time 20 "$MIRROR/BaseOS/x86_64/os/.treeinfo"; then ok "$MIRROR answers from this host"
else bad "$MIRROR does not answer from this host (a proxy? NIST_ROCKY_MIRROR=URL uses another mirror)"; fi

echo "6. DNS inside a container (the kickstart validator)"
if command -v podman >/dev/null 2>&1; then
  if out=$(sudo podman run --quiet --rm quay.io/rockylinux/rockylinux:9 getent hosts "$HOST" 2>&1) && [[ -n "$out" ]]; then ok "a podman container resolves $HOST"
  else bad "a podman container cannot resolve $HOST: it copied a resolver it cannot reach (the systemd-resolved stub?) - $(tail -1 <<<"$out")"; fi
else info "podman not installed: no kickstart validation, nothing to test"; fi

(( fails )) && { echo "== $fails layer(s) failing - the first is usually the cause"; exit 1; }
echo "== every layer works; if an install still stalls, read its console: /var/log/libvirt/qemu/NAME-serial.log"
