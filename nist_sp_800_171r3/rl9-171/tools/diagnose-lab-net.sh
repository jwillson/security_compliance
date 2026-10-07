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
#      isolated network stack (qemu user-mode networking, containers), and a
#      resolv.conf with no nameserver at all, which leaves libvirt's dnsmasq
#      nothing to forward to while the host resolves another way;
#   2. libvirt's dnsmasq for the lab network: installed (Arch packages it as
#      an optional dependency) and running;
#   3. the guests' DNS path: a query sent from this host to the lab
#      network's address, the server the guests use;
#   4. the way out: forwarding, a NAT rule for the lab subnet, and Docker's
#      FORWARD DROP policy;
#   5. the mirror itself, over HTTPS from the host;
#   6. the guests' own path, from inside the lab network: a throwaway network
#      namespace on the lab bridge, at an address DHCP never hands out, that
#      resolves the mirror through the guests' DNS server and fetches from it -
#      a small file, then 8 MB, which a path MTU problem (a VPN) lets the
#      first through and stalls the second. If the name does not resolve
#      there, the fetch is tried with the address given, so a DNS fault is
#      not reported as a blocked NAT. Removed afterwards.
#
# The lab network must exist (vm/lab-network.sh ensure). Exit 1 if any layer
# fails.
#
# No pipefail: several tests pipe into `grep -q`, whose early exit would
# fail the pipeline with the writer's SIGPIPE and read as a failure.
set -u
# The one tool that runs privileged (TASKS C5): it puts a network namespace on
# the lab bridge and reads the host's NAT rules, which need root. Run it with
# sudo; it enters the control-plane container as root, privileged, on the
# host's network, with the host's resolver files under /host.
if [[ -z "${NIST_IN_CONTAINER:-}" ]]; then
  [[ $(id -u) -eq 0 ]] || { echo "error: run it with sudo: it needs root for network namespaces and the NAT rules" >&2; exit 2; }
  export NIST_PRIVILEGED=1
fi
. "$(dirname "${BASH_SOURCE[0]}")/../lib/container.sh"
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
dnsq() { python3 "$HERE/../lib/dnsq.py" "$@"; }   # SERVER NAME -> first A record

echo "== the path from a $NET guest to $MIRROR"

echo "1. the host's resolver"
# The host's own resolv.conf - what libvirt's dnsmasq reads - as ./nist mounts it.
ns=$(awk '/^nameserver/ {print $2}' /host/etc/resolv.conf 2>/dev/null | tr '\n' ' ')
info "nameservers: ${ns:-none}"
[[ "$ns" == "127.0.0.53 " ]] && info "only the systemd-resolved stub: right for this host and for libvirt's dnsmasq (which runs here), wrong for anything that copies resolv.conf into its own network (see 6)"
if addr=$(getent hosts "$HOST" | awk '!f {print $1; f=1}') && [[ -n "$addr" ]]; then ok "this host resolves $HOST ($addr)"
else bad "this host cannot resolve $HOST - fix the host's DNS first; nothing below can work"; fi
if [[ -z "$ns" ]]; then
  # libvirt's dnsmasq takes its upstream servers from resolv.conf alone; the
  # host may resolve by another way, which is what this shows (DEFECTS 7.29).
  info "how this host resolves without one - systemd-resolved's servers: $(awk '/^nameserver/ {print $2}' /host/run/systemd/resolve/resolv.conf 2>/dev/null | xargs); NetworkManager's: $(cat /host/run/NetworkManager/no-stub-resolv.conf /host/run/NetworkManager/resolv.conf 2>/dev/null | awk '/^nameserver/ {print $2}' | xargs)"
  info "listening on port 53 here: $(ss -Hlun 'sport = :53' 2>/dev/null | awk '{print $4}' | xargs)"
  live=$(virsh -c "$NIST_LIBVIRT_URI" net-dumpxml "$NET" 2>/dev/null | grep -oE "forwarder addr='[^']*'|server=[^']*" | sed -E "s/.*(addr='|server=)//; s/'$//" | xargs)
  if up=$("$HERE/../vm/lab-network.sh" upstream 2>/dev/null); then
    if [[ -n "$live" ]]; then ok "$NET forwards DNS to $live (this host answers from $up)"
    else bad "resolv.conf lists no nameserver and $NET has no forwarder, so its dnsmasq refuses every guest query (layer 3): vm/lab-network.sh ensure gives it $up - at once if no guest is on it, else when it next starts"; fi
  else bad "resolv.conf lists no nameserver and no resolver this host might use answers for $HOST - fix the host's DNS, or NIST_LAB_DNS=IP for vm/lab-network.sh"; fi
fi

echo "2. libvirt's dnsmasq for $NET"
info_out=$(virsh -c "$NIST_LIBVIRT_URI" net-info "$NET" 2>/dev/null)
# An active network means libvirt started its dnsmasq (a missing dnsmasq
# fails the start, which vm/lab-network.sh reports).
if grep -q 'Active: *yes' <<<"$info_out"; then ok "$NET is active, its dnsmasq with it"
else bad "$NET is not active (vm/lab-network.sh ensure; without dnsmasq installed on the host it cannot start)"; fi

echo "3. the guests' DNS: $GW, as a guest asks it"
if r=$(dnsq "$GW" "$HOST"); then ok "$GW resolves $HOST ($r)"
else bad "$GW does not resolve $HOST ($r): dnsmasq cannot reach the host's upstream resolvers - a VPN's split DNS, a firewall, or resolv.conf it cannot use"; fi

echo "4. the way out"
[[ "$(sysctl -n net.ipv4.ip_forward 2>/dev/null)" == 1 ]] && ok "forwarding on" || bad "net.ipv4.ip_forward is 0"
if nft list ruleset 2>/dev/null | grep -q "$SUBNET\.0/24" || iptables -t nat -S 2>/dev/null | grep -q "$SUBNET\.0/24"; then
  ok "a NAT rule for $SUBNET.0/24"
else bad "no NAT rule for $SUBNET.0/24 (libvirt adds it when $NET starts; a firewall reload can drop it - restart the network)"; fi
if iptables -S FORWARD 2>/dev/null | grep -q '^-P FORWARD DROP' && { command -v docker >/dev/null 2>&1 || ip link show docker0 >/dev/null 2>&1; }; then
  bad "Docker's FORWARD DROP policy is in place: allow virbr17 in DOCKER-USER (vm/lab-network.sh prints the rules)"
fi

echo "5. the mirror, over IPv4 and IPv6 separately"
# Separately, because a host with an IPv6 route that carries nothing makes
# curl try IPv6 first and time out, while IPv4 would have worked (DEFECTS
# 7.27). The lab network is IPv4 only, so the guests are not affected; the
# host's own downloads (make iso, the BYO base image) are.
for v in ${https_proxy:+https_proxy} ${HTTPS_PROXY:+HTTPS_PROXY} ${http_proxy:+http_proxy}; do info "$v is set: curl goes through ${!v}"; done
url="$MIRROR/BaseOS/x86_64/os/.treeinfo"
v4=0 v6=0
curl -4 -fsS -o /dev/null --connect-timeout 10 --max-time 30 "$url" 2>/dev/null && v4=1
curl -6 -fsS -o /dev/null --connect-timeout 10 --max-time 30 "$url" 2>/dev/null && v6=1
if (( v4 && v6 )); then ok "$MIRROR answers over IPv4 and IPv6"
elif (( v4 )); then
  info "$MIRROR answers over IPv4 but not IPv6"
  if getent ahostsv6 "$HOST" >/dev/null 2>&1 && ip -6 route show default 2>/dev/null | grep -q .; then
    bad "this host has an IPv6 default route that does not reach the mirror, so curl tries IPv6 first and times out: fix IPv6, or NIST_CURL_OPTS=-4 for make iso"
  else ok "IPv4 is what this host uses"; fi
elif (( v6 )); then ok "$MIRROR answers over IPv6 only"
else bad "$MIRROR does not answer over IPv4 or IPv6: a proxy (https_proxy), a firewall, or the mirror - NIST_ROCKY_MIRROR=URL uses another (https://mirrors.rockylinux.org/mirrormanager/mirrors lists them)"; fi

echo "6. the guests' own path: from inside $NET"
# What the host can reach, a guest may not: the guests go out through the
# lab bridge and NAT, where firewalld, Docker or a VPN's MTU can stop them
# while the host's own curl works (DEFECTS 7.28). A namespace on the bridge
# is a guest without a VM.
# Interface names are at most 15 characters.
NS=nistdiag$$ VETH=nd$$ PROBE=$SUBNET.250
BRIDGE=$(sed -n "s:.*<bridge name='\([^']*\)'.*:\1:p" "$XML" | head -1)
if ip link show "$BRIDGE" >/dev/null 2>&1; then
  cleanup_ns() { ip netns del "$NS" 2>/dev/null; ip link del "$VETH" 2>/dev/null; rm -rf "/etc/netns/$NS"; }
  trap cleanup_ns EXIT
  if ! { ip netns add "$NS" && ip link add "$VETH" type veth peer name eth0 netns "$NS" \
         && ip link set "$VETH" master "$BRIDGE" up \
         && ip -n "$NS" addr add "$PROBE/24" dev eth0 && ip -n "$NS" link set eth0 up \
         && ip -n "$NS" link set lo up && ip -n "$NS" route add default via "$GW"; }; then
    bad "could not set up the test namespace on $BRIDGE - this says nothing about the network itself"
  else
  mkdir -p "/etc/netns/$NS"; echo "nameserver $GW" | tee "/etc/netns/$NS/resolv.conf" >/dev/null
  inside() { ip netns exec "$NS" "$@"; }
  sleep 2
  resolved=0 pin=()
  if inside getent hosts "$HOST" >/dev/null 2>&1; then ok "from $PROBE, $HOST resolves through $GW"; resolved=1
  else bad "from $PROBE, $HOST does not resolve through $GW (layer 3 again, from the guests' side)"; fi
  # Without a name the fetch tells nothing about the NAT, so it is tried
  # with the address this host resolved: DNS and the way out judged apart.
  if (( ! resolved )); then
    v4=$(getent ahostsv4 "$HOST" 2>/dev/null | awk 'NR == 1 {print $1}')
    if [[ -n "$v4" ]]; then pin=(--resolve "$HOST:443:$v4"); info "fetching with $HOST given as $v4, to test the way out apart from DNS"
    else info "this host has no IPv4 address for $HOST either: the way out cannot be tested by name"; fi
  fi
  if (( ! resolved )) && (( ${#pin[@]} == 0 )); then :
  elif inside curl -4 -fsS -o /dev/null --connect-timeout 10 --max-time 30 ${pin[@]+"${pin[@]}"} "$MIRROR/BaseOS/x86_64/os/.treeinfo" 2>/dev/null; then
    ok "from $PROBE, a small file from $MIRROR${pin:+ (address given)}"
    (( resolved )) || info "so the way out works: the guests' fault is DNS alone (layers 1 and 3)"
    if inside curl -4 -fsS -o /dev/null --connect-timeout 10 --max-time 60 -r 0-8388607 ${pin[@]+"${pin[@]}"} "$MIRROR/isos/x86_64/Rocky-9.8-x86_64-boot.iso" 2>/dev/null; then
      ok "from $PROBE, 8 MB from $MIRROR"
    else bad "from $PROBE the small file came but 8 MB did not: a path MTU problem (a VPN or tunnel on this host) - lower the lab network's MTU, or NIST_ROCKY_MIRROR=URL to a nearer mirror"; fi
  else bad "from $PROBE nothing comes from $MIRROR${pin:+ even with its address given}, though this host reaches it: the lab's NAT out is blocked (firewalld, Docker, a VPN's policy) - layer 4"; fi
  fi
  cleanup_ns; trap - EXIT
else bad "$BRIDGE does not exist (vm/lab-network.sh ensure)"; fi

(( fails )) && { echo "== $fails layer(s) failing - the first is usually the cause"; exit 1; }
echo "== every layer works; if an install still stalls, read its console: /var/log/libvirt/qemu/NAME-serial.log"
