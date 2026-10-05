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
#
# Called by vm/build-vm.sh and vm/byo-guest.sh, so a new workstation needs no
# step by hand: before this, the network had been created once by hand on the
# owner's laptop and nothing recreated it, so a build on any other host failed
# or hung (DEFECTS 7.17). Only what is missing is done; an existing network is
# left as it is. It is removed only when no guest is attached - every lab
# guest, BYO and kickstart alike, is on it (make destroy, make teardown).
#
# It does not change the host's libvirt services: if qemu:///system does not
# answer, it says which to start (the single libvirtd, or the per-driver
# daemons that RHEL 9 and Fedora use).
#
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Name, bridge and subnet come from the XML, the one place they are defined.
# NIST_LAB_NETWORK_XML points elsewhere only to test this on a throwaway
# network (tools/test-lab-network.sh).
XML="${NIST_LAB_NETWORK_XML:-$HERE/nist-lab-network.xml}"
NET=$(sed -n 's:.*<name>\(.*\)</name>.*:\1:p' "$XML" | head -1)
BRIDGE=$(sed -n "s:.*<bridge name='\([^']*\)'.*:\1:p" "$XML" | head -1)
SUBNET=$(sed -n "s:.*<ip address='\([0-9]*\.[0-9]*\.[0-9]*\)\.[0-9]*'.*:\1:p" "$XML" | head -1)
[[ -n "$NET" && -n "$BRIDGE" && -n "$SUBNET" ]] || { echo "error: cannot read name, bridge and subnet from $XML" >&2; exit 2; }
V=(sudo virsh -c qemu:///system)
say()  { echo "==> $*"; }
warn() { echo "warning: $*" >&2; }
die()  { echo "error: $*" >&2; exit 1; }

ensure() {
  "${V[@]}" uri >/dev/null 2>&1 || die "qemu:///system does not answer. Start libvirt: \
'sudo systemctl enable --now libvirtd' where libvirt runs as one daemon (Ubuntu, Debian), or \
'sudo systemctl enable --now virtqemud.socket virtnetworkd.socket virtstoraged.socket' on RHEL 9 / Fedora"
  if ! "${V[@]}" net-info "$NET" >/dev/null 2>&1; then
    # The subnet must be free on this host: a LAN or VPN already using it
    # would make the guests' addresses ambiguous.
    if ip -4 route show | grep -v "dev $BRIDGE" | grep -q "^$SUBNET\.0/24"; then
      die "$SUBNET.0/24 is already routed on this host ($(ip -4 route show | grep "^$SUBNET\.0/24" | head -1)); the lab network needs it"
    fi
    say "defining $NET from $(basename "$XML")"
    "${V[@]}" net-define "$XML" >/dev/null
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
  if command -v docker >/dev/null 2>&1 || ip link show docker0 >/dev/null 2>&1; then
    if sudo iptables -S FORWARD 2>/dev/null | grep -q '^-P FORWARD DROP'; then
      warn "Docker is installed and the FORWARD policy is DROP: traffic from $BRIDGE to the internet may be dropped. \
If an install stalls fetching from the mirror, allow it: sudo iptables -I DOCKER-USER -i $BRIDGE -j ACCEPT; \
sudo iptables -I DOCKER-USER -o $BRIDGE -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT"
    fi
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
  *) sed -n '3,25p' "$0"; exit 2 ;;
esac
