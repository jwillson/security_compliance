#!/usr/bin/env bash
#
# The lab network, nist-lab (vm/nist-lab-network.xml: bridge virbr17,
# 192.168.171.0/24, NAT), in the system libvirt both labs use.
#
#   vm/lab-network.sh ensure            define, start and autostart it if
#                                       needed; check the host can carry its
#                                       guests' traffic
#   vm/lab-network.sh destroy           remove it; refuses while any guest is
#                                       attached, naming them
#   vm/lab-network.sh destroy-if-unused remove it if no guest is attached,
#                                       otherwise say which guests keep it
#   vm/lab-network.sh upstream          the DNS servers its dnsmasq is given,
#                                       or "resolv.conf"; exit 1 if none works
#
# Called by vm/build-vm.sh and vm/byo-guest.sh, so a new workstation needs no
# step by hand: before this, the network had been created once by hand on the
# owner's laptop and nothing recreated it, so a build on any other host failed
# or hung (DEFECTS 7.17). Only what is missing is done; an existing network is
# left as it is. It is removed only when no guest is attached - every lab
# guest, BYO and kickstart alike, is on it (make destroy, make teardown).
#
# DNS: libvirt's dnsmasq forwards the guests' queries to the nameservers in
# /etc/resolv.conf, and to nothing else. A host can resolve perfectly well
# with none listed there - NetworkManager writing an empty file while
# systemd-resolved or a local resolver serves the host through nsswitch - and
# then dnsmasq refuses every guest query (REFUSED, rcode 5) and the install
# waits for a mirror it cannot name (DEFECTS 7.29). So when resolv.conf lists
# no nameserver, the network is given a forwarder this host does answer from:
# the first of systemd-resolved's stub, a resolver on 127.0.0.1 or ::1, then
# the servers in systemd-resolved's and NetworkManager's files - IPv6 and a
# router's link-local address advertised by RA included - that resolves the
# mirror's name (lib/dnsq.py asks each). It runs in the control-plane
# container (TASKS C5): libvirt through its socket, the host's resolver files
# as ./nist mounts them under /host.
# NIST_LAB_DNS="IP ..." chooses instead (keep it set wherever you run make).
# A changed forwarder is applied at once if no guest is on the network, and
# otherwise when it next starts.
#
# It does not change the host's libvirt services: if qemu:///system does not
# answer, it says which to start (the single libvirtd, or the per-driver
# daemons that RHEL 9 and Fedora use).
#
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../lib/container.sh"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Name, bridge and subnet come from the XML, the one place they are defined.
# NIST_LAB_NETWORK_XML points elsewhere only to test this on a throwaway
# network (tools/test-lab-network.sh).
XML="${NIST_LAB_NETWORK_XML:-$HERE/nist-lab-network.xml}"
NET=$(sed -n 's:.*<name>\(.*\)</name>.*:\1:p' "$XML" | head -1)
BRIDGE=$(sed -n "s:.*<bridge name='\([^']*\)'.*:\1:p" "$XML" | head -1)
SUBNET=$(sed -n "s:.*<ip address='\([0-9]*\.[0-9]*\.[0-9]*\)\.[0-9]*'.*:\1:p" "$XML" | head -1)
[[ -n "$NET" && -n "$BRIDGE" && -n "$SUBNET" ]] || { echo "error: cannot read name, bridge and subnet from $XML" >&2; exit 2; }
# The host's resolv.conf - what libvirt's dnsmasq reads (another file only for
# tools/test-lab-network.sh).
RESOLV="${NIST_RESOLV_CONF:-/host/etc/resolv.conf}"
PROBE_NAME=$(sed -E 's#^[a-z]+://([^/:]+).*#\1#' <<<"${NIST_ROCKY_MIRROR:-https://dl.rockylinux.org/pub/rocky/9}")
V=(virsh -c "$NIST_LIBVIRT_URI")
say()  { echo "==> $*"; }
warn() { echo "warning: $*" >&2; }
die()  { echo "error: $*" >&2; exit 1; }

candidates() {   # resolvers this host might use, best first, one per line
  printf '%s\n' 127.0.0.53 127.0.0.1 ::1
  # The upstream servers the host's resolvers know, from their own files
  # (systemd-resolved's uplink list; NetworkManager's, stub or not).
  cat /host/run/systemd/resolve/resolv.conf /host/run/NetworkManager/no-stub-resolv.conf \
      /host/run/NetworkManager/resolv.conf 2>/dev/null | awk '/^nameserver/ {print $2}'
}

upstreams() {   # the forwarders dnsmasq needs - none while resolv.conf names a server
  if [[ -n "${NIST_LAB_DNS:-}" ]]; then echo "$NIST_LAB_DNS"; return 0; fi
  grep -q '^nameserver' "$RESOLV" 2>/dev/null && return 0
  local c n
  while read -r c; do
    [[ -n "$c" ]] || continue
    # resolvectl names a link-local server's interface by number; dnsmasq
    # wants its name.
    if [[ "$c" =~ %([0-9]+)$ ]]; then
      n=$(grep -lx "${BASH_REMATCH[1]}" /sys/class/net/*/ifindex 2>/dev/null | head -1 | cut -d/ -f5)
      [[ -n "$n" ]] && c="${c%\%*}%$n"
    fi
    python3 "$HERE/../lib/dnsq.py" "$c" "$PROBE_NAME" >/dev/null 2>&1 && { echo "$c"; return 0; }
  done < <(candidates | awk 'NF && !seen[$0]++')
  return 1
}

forwarders_of() {   # the forwarders the network's persistent definition has
  "${V[@]}" net-dumpxml --inactive "$NET" 2>/dev/null \
    | grep -oE "forwarder addr='[^']*'|option value='server=[^']*'" | sed -E "s/.*(addr='|server=)//; s/'\$//" | xargs
}

definition() {   # FORWARDERS [UUID] -> a temporary XML: the committed one, plus
  # the forwarders, plus the existing network's UUID (libvirt redefines a
  # network only under the UUID it has). A plain address is a libvirt
  # <forwarder>; a scoped link-local one (fe80::1%eth0) is not accepted
  # there, so it goes to dnsmasq directly.
  local out; out=$(mktemp --suffix=.xml)
  awk -v f="$1" -v uuid="${2:-}" '
    /^<network>/ && f ~ /%/ { print "<network xmlns:dnsmasq='"'"'http://libvirt.org/schemas/network/dnsmasq/1.0'"'"'>"; next }
    /<name>/ && uuid != "" { print; print "  <uuid>" uuid "</uuid>"; next }
    /<ip address=/ && !dns { n = split(f, a, " "); plain = ""
      for (i = 1; i <= n; i++) if (a[i] !~ /%/) plain = plain "    <forwarder addr='"'"'" a[i] "'"'"'/>\n"
      if (plain != "") printf "  <dns>\n%s  </dns>\n", plain
      dns = 1 }
    /^<\/network>/ && f ~ /%/ { print "  <dnsmasq:options>"; n = split(f, a, " ")
      for (i = 1; i <= n; i++) if (a[i] ~ /%/) print "    <dnsmasq:option value='"'"'server=" a[i] "'"'"'/>"
      print "  </dnsmasq:options>" }
    { print }' "$XML" > "$out"
  echo "$out"
}

ensure() {
  "${V[@]}" uri >/dev/null 2>&1 || die "qemu:///system does not answer. Start libvirt: \
'sudo systemctl enable --now libvirtd' where libvirt runs as one daemon (Ubuntu, Debian), or \
'sudo systemctl enable --now virtqemud.socket virtnetworkd.socket virtstoraged.socket' on RHEL 9 / Fedora"
  local fwd
  if ! fwd=$(upstreams); then
    # Nothing found that answers - but a network that already forwards
    # somewhere keeps that: its forwarder was found before, perhaps by a
    # tool the container has not got (nmcli, on the owner's Rocky 9 host).
    fwd=$(forwarders_of)
    [[ -n "$fwd" ]] || die "$RESOLV lists no nameserver, so libvirt's dnsmasq could not answer the guests, \
and no resolver this host might use answers for $PROBE_NAME (tried systemd-resolved, 127.0.0.1, ::1, \
and the servers in systemd-resolved's and NetworkManager's files). Fix the host's DNS, or name a server: NIST_LAB_DNS=IP"
    warn "no resolver found that answers for $PROBE_NAME; keeping $NET's DNS forwarder ($fwd)"
  fi
  # EXIT, not RETURN: a RETURN trap fires as any function returns
  # (forwarders_of, attached) and would remove the file before net-define;
  # and global, since the trap runs after ensure's locals are gone.
  trap 'rm -f "${DEF:-}"' EXIT
  if ! "${V[@]}" net-info "$NET" >/dev/null 2>&1; then
    # The subnet must be free on this host: a LAN or VPN already using it
    # would make the guests' addresses ambiguous.
    if ip -4 route show | grep -v "dev $BRIDGE" | grep -q "^$SUBNET\.0/24"; then
      die "$SUBNET.0/24 is already routed on this host ($(ip -4 route show | grep "^$SUBNET\.0/24" | head -1)); the lab network needs it"
    fi
    say "defining $NET from $(basename "$XML")${fwd:+, DNS forwarded to $fwd}"
    DEF=$(definition "$fwd"); "${V[@]}" net-define "$DEF" >/dev/null
  elif [[ "$(forwarders_of | tr ' ' '\n' | sort | xargs)" != "$(tr ' ' '\n' <<<"$fwd" | sort | xargs)" ]]; then
    DEF=$(definition "$fwd" "$("${V[@]}" net-uuid "$NET")"); "${V[@]}" net-define "$DEF" >/dev/null
    if [[ -n "$(attached)" ]]; then
      warn "$NET's DNS forwarders are now '${fwd:-from resolv.conf}' but apply only when it next starts: guests are on it"
    else
      say "DNS for $NET: ${fwd:-from resolv.conf}"
      "${V[@]}" net-destroy "$NET" >/dev/null 2>&1 || true
    fi
  fi
  if [[ "$("${V[@]}" net-info "$NET" | awk '/^Active:/ {print $2}')" != yes ]]; then
    say "starting $NET"
    "${V[@]}" net-start "$NET" >/dev/null
  fi
  [[ "$("${V[@]}" net-info "$NET" | awk '/^Autostart:/ {print $2}')" == yes ]] \
    || { "${V[@]}" net-autostart "$NET" >/dev/null; say "$NET set to start with libvirt"; }

  # What lets a guest reach the internet - the Rocky mirror the kickstart
  # installs from, and dnf afterwards. None of these breaks the network
  # itself; each silently strands the guests, which is how an install waits
  # forever at a console prompt nobody sees.
  [[ "$(sysctl -n net.ipv4.ip_forward 2>/dev/null)" == 1 ]] \
    || warn "net.ipv4.ip_forward is 0: the guests cannot reach the internet (libvirt normally sets it; something reset it)"
  # Docker sets the FORWARD policy to DROP. Reading the rules needs root, so
  # its bridge is what is looked for (sudo tools/diagnose-lab-net.sh reads them).
  if ip link show docker0 >/dev/null 2>&1; then
    warn "Docker runs on this host, and it usually sets the FORWARD policy to DROP: traffic from $BRIDGE to the internet may be dropped. \
If an install stalls fetching from the mirror, allow it on the host: sudo iptables -I DOCKER-USER -i $BRIDGE -j ACCEPT; \
sudo iptables -I DOCKER-USER -o $BRIDGE -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT"
  fi
}

attached() {   # the domains with an interface on the network
  local d
  for d in $("${V[@]}" list --all --name 2>/dev/null); do
    if "${V[@]}" domiflist "$d" 2>/dev/null | awk -v n="$NET" '$3==n {f=1} END {exit !f}'; then echo "$d"; fi
  done
}

destroy() {   # quiet: 1 to keep it silently when in use
  "${V[@]}" net-info "$NET" >/dev/null 2>&1 || { say "$NET does not exist"; return 0; }
  local users; users=$(attached | tr '\n' ' ')
  if [[ -n "${users// /}" ]]; then
    [[ "${1:-0}" == 1 ]] && { say "keeping $NET: still used by $users"; return 0; }
    die "$NET is still used by $users- destroy those guests first (make teardown removes everything)"
  fi
  "${V[@]}" net-destroy "$NET" >/dev/null 2>&1 || true
  "${V[@]}" net-undefine "$NET" >/dev/null
  say "removed $NET"
}

case "${1:-}" in
  ensure) ensure ;;
  destroy) destroy 0 ;;
  destroy-if-unused) destroy 1 ;;
  upstream) fwd=$(upstreams) || exit 1; echo "${fwd:-resolv.conf}" ;;
  *) sed -n '3,25p' "$0"; exit 2 ;;
esac
