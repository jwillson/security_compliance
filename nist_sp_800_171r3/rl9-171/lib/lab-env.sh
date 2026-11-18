# shellcheck shell=bash
# Sourced by the lab's scripts, after lib/container.sh: the names this host's
# lab has in libvirt.
#
# Alone on a hypervisor the lab keeps the names it always had: the network
# nist-lab on virbr17 (vm/nist-lab-network.xml), libvirt's pool `default`,
# guests rl9-* and byo-*. On a hypervisor it shares with other people's guests
# it is given a namespace (owner decision 2026-11-17; DEFECTS 7.45) - one
# line in lab.conf beside ./nist, a file of this host's, untracked:
#
#     namespace = sc
#
# and then everything the lab has in libvirt carries it: guests
# sc-rl9-cui-01, the network sc-lab on bridge sc-br0, and a storage pool of
# its own, sc, in a directory libvirt makes for it (/var/lib/libvirt/images/sc;
# a pool of that name defined beforehand is used where it is). The lab's
# tools then act on nothing else on that host: a guest is the lab's only by
# its prefix or by sitting on the lab's network, and a volume only by being
# in the lab's pool. Without a namespace, teardown and residue look through
# every pool for the lab's names, as they always did - right on a host the
# lab has to itself, and on a shared one how another lab's boot ISO or base
# image of the same name would be deleted (docs/LAB.md, "A shared
# hypervisor").
#
# The operator exports nothing: the file is the host's setting, read by every
# tool. NIST_LAB_NS overrides it and NIST_LAB_CONF names another file, both
# for the tests (tests/test_lab_env.py).
#
#   LAB_NS      the namespace, or empty       LAB_PREFIX  "sc-", or empty
#   LAB_NET     the lab network's name        LAB_BRIDGE  its bridge
#   LAB_POOL    the pool the lab's volumes are in
#   lab_guest_name NAME   is NAME one the lab's scripts give a guest or volume
#   lab_name_ok NAME      in a namespace, NAME must carry it (says so if not)
#   lab_network_xml       the network's definition, as this host names it
#   lab_pools             the pools a volume of the lab can be in
#   lab_pool_ensure       the lab's pool is there and running
#   lab_pool_remove       the namespace's pool, once it is empty

_lab_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
_lab_conf="${NIST_LAB_CONF:-$_lab_root/lab.conf}"
if [[ -z "${NIST_LAB_NS+set}" ]]; then
  NIST_LAB_NS=""
  if [[ -f "$_lab_conf" ]]; then
    while IFS= read -r _lab_line || [[ -n "$_lab_line" ]]; do
      _lab_line="${_lab_line%%#*}"
      [[ "$_lab_line" =~ ^[[:space:]]*$ ]] && continue
      if [[ "$_lab_line" =~ ^[[:space:]]*namespace[[:space:]]*=[[:space:]]*([^[:space:]]*)[[:space:]]*$ ]]; then
        NIST_LAB_NS="${BASH_REMATCH[1]}"
      else
        # A setting misread is a lab built under the wrong names: stop.
        echo "error: $_lab_conf: '$_lab_line' is not understood - the file holds one setting, namespace = NAME" >&2
        exit 2
      fi
    done < "$_lab_conf"
    unset _lab_line
  fi
fi
# One to six characters: with it a guest's name still fits the 20 a disk
# serial takes (vm/build-vm.sh) and the bridge's the 15 an interface name
# does. Not "nist": its network would be nist-lab, the name the lab has
# without a namespace, on another bridge.
if [[ -n "$NIST_LAB_NS" ]] && { [[ ! "$NIST_LAB_NS" =~ ^[a-z][a-z0-9]{0,5}$ ]] || [[ "$NIST_LAB_NS" == nist ]]; }; then
  echo "error: the lab namespace '$NIST_LAB_NS' ($_lab_conf, or NIST_LAB_NS) must be one to six lowercase letters and digits, a letter first, and not 'nist'" >&2
  exit 2
fi
export NIST_LAB_NS
LAB_NS=$NIST_LAB_NS
if [[ -n "$LAB_NS" ]]; then
  LAB_PREFIX="$LAB_NS-" LAB_POOL="$LAB_NS" LAB_POOL_PATH="/var/lib/libvirt/images/$LAB_NS"
else
  LAB_PREFIX="" LAB_POOL=default LAB_POOL_PATH=""
fi

# The network: name, bridge and subnet are defined in vm/nist-lab-network.xml
# and nowhere else; a namespace renames the network, its bridge and its DNS
# domain and keeps the rest. NIST_LAB_NETWORK_XML is another definition
# altogether, taken as it is (tools/test-lab-network.sh's throwaway copy).
lab_network_xml() {
  if [[ -n "${NIST_LAB_NETWORK_XML:-}" ]]; then
    cat "$NIST_LAB_NETWORK_XML"
  elif [[ -n "$LAB_NS" ]]; then
    sed -e "s:<name>[^<]*</name>:<name>$LAB_NS-lab</name>:" \
        -e "s:<bridge name='[^']*':<bridge name='$LAB_NS-br0':" \
        -e "s:<domain name='[^']*':<domain name='$LAB_NS-lab':" "$_lab_root/vm/nist-lab-network.xml"
  else
    cat "$_lab_root/vm/nist-lab-network.xml"
  fi
}
LAB_NET=$(lab_network_xml | sed -n 's:.*<name>\(.*\)</name>.*:\1:p' | head -1)
LAB_BRIDGE=$(lab_network_xml | sed -n "s:.*<bridge name='\([^']*\)'.*:\1:p" | head -1)
if [[ -z "$LAB_NET" || -z "$LAB_BRIDGE" ]]; then
  echo "error: cannot read the lab network's name and bridge from ${NIST_LAB_NETWORK_XML:-$_lab_root/vm/nist-lab-network.xml}" >&2
  exit 2
fi

# The names the lab's scripts give guests - and so their volumes, which start
# with the guest's name: rl9-* (the kickstart lab and the tests), byo-*,
# ptest-* (the portability hosts), under the namespace's prefix if there is one.
lab_guest_name() { [[ "$1" =~ ^${LAB_PREFIX}(rl9|byo|ptest)- ]]; }

lab_name_ok() {
  [[ -z "$LAB_PREFIX" || "$1" == "$LAB_PREFIX"* ]] && return 0
  echo "error: this host's lab is in the namespace '$LAB_NS' (lab.conf), where every guest's name starts with $LAB_PREFIX: not '$1'" >&2
  return 1
}

lab_pools() {
  if [[ -n "$LAB_NS" ]]; then echo "$LAB_POOL"
  else virsh -c "$NIST_LIBVIRT_URI" pool-list --name 2>/dev/null; fi
}

# libvirt makes the namespace's pool - its directory too (pool-build), so
# nothing on the host is touched by hand and no sudo is needed. The pool
# `default` is the host's: it is used, never made (vm/host-check.sh says how).
lab_pool_ensure() {
  local v=(virsh -c "$NIST_LIBVIRT_URI")
  if ! "${v[@]}" pool-info "$LAB_POOL" >/dev/null 2>&1; then
    if [[ -z "$LAB_NS" ]]; then
      echo "error: no storage pool '$LAB_POOL' in $NIST_LIBVIRT_URI (./nist host-check says how to make it)" >&2
      return 1
    fi
    echo "==> storage pool $LAB_POOL, this lab's own, at $LAB_POOL_PATH"
    "${v[@]}" pool-define-as "$LAB_POOL" dir --target "$LAB_POOL_PATH" >/dev/null \
      && "${v[@]}" pool-build "$LAB_POOL" >/dev/null \
      || { echo "error: could not make the storage pool $LAB_POOL at $LAB_POOL_PATH" >&2; return 1; }
  fi
  [[ -n "$LAB_NS" ]] || return 0
  if [[ "$("${v[@]}" pool-info "$LAB_POOL" | awk '/^State:/ {print $2}')" != running ]]; then
    "${v[@]}" pool-start "$LAB_POOL" >/dev/null || { echo "error: the storage pool $LAB_POOL does not start" >&2; return 1; }
  fi
  [[ "$("${v[@]}" pool-info "$LAB_POOL" | awk '/^Autostart:/ {print $2}')" == yes ]] \
    || "${v[@]}" pool-autostart "$LAB_POOL" >/dev/null
}

# Only an empty pool goes, and only a namespace's: what is still in it is
# either the lab's and not yet removed, or not the lab's at all.
lab_pool_remove() {
  [[ -n "$LAB_NS" ]] || return 0
  local v=(virsh -c "$NIST_LIBVIRT_URI")
  "${v[@]}" pool-info "$LAB_POOL" >/dev/null 2>&1 || return 0
  "${v[@]}" pool-refresh "$LAB_POOL" >/dev/null 2>&1
  [[ -z "$("${v[@]}" vol-list --pool "$LAB_POOL" 2>/dev/null | awk 'NR > 2 && NF')" ]] || return 1
  "${v[@]}" pool-destroy "$LAB_POOL" >/dev/null 2>&1
  "${v[@]}" pool-delete "$LAB_POOL" >/dev/null 2>&1      # its directory, empty
  "${v[@]}" pool-undefine "$LAB_POOL" >/dev/null
}
