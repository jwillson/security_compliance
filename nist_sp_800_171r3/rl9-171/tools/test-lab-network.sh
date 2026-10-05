#!/usr/bin/env bash
#
# vm/lab-network.sh by behaviour (DEFECTS 7.17): on a throwaway copy of the lab
# network - another name, bridge and subnet, so the real nist-lab and every
# guest on it are untouched - `ensure` must define, start and autostart it, a
# second run must change nothing, and `destroy` must remove it; on the real
# nist-lab, with guests on it, `destroy` must refuse and `destroy-if-unused`
# keep it. The copy is removed at the end whatever happens.
#
#   tools/test-lab-network.sh
#
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE/.." || exit 2
V=(sudo virsh -c qemu:///system)
fails=0
ok()  { echo "PASS  $*"; }
bad() { echo "FAIL  $*"; fails=$((fails + 1)); }
xml=$(mktemp --suffix=.xml)
sed -e 's:<name>nist-lab</name>:<name>nist-lab-nettest</name>:' -e "s:virbr17:virbr179:" \
    -e 's/192\.168\.171\./192.168.179./g' -e "s:<domain name='nist-lab':<domain name='nist-lab-nettest':" \
    vm/nist-lab-network.xml > "$xml"
cleanup() { "${V[@]}" net-destroy nist-lab-nettest >/dev/null 2>&1; "${V[@]}" net-undefine nist-lab-nettest >/dev/null 2>&1; rm -f "$xml"; }
trap cleanup EXIT
"${V[@]}" net-info nist-lab-nettest >/dev/null 2>&1 && { echo "error: nist-lab-nettest already exists" >&2; exit 2; }

out=$(NIST_LAB_NETWORK_XML="$xml" ./vm/lab-network.sh ensure 2>&1); rc=$?
info=$("${V[@]}" net-info nist-lab-nettest 2>/dev/null)
[[ $rc -eq 0 ]] && grep -q 'Active: *yes' <<<"$info" && grep -q 'Autostart: *yes' <<<"$info" \
  && ok "a missing network is defined, started and set to autostart" || bad "rc=$rc: $out"
out=$(NIST_LAB_NETWORK_XML="$xml" ./vm/lab-network.sh ensure 2>&1); rc=$?
[[ $rc -eq 0 && -z "$(grep '^==>' <<<"$out")" ]] && ok "a second run changes nothing" || bad "second run: rc=$rc: $out"
out=$(NIST_LAB_NETWORK_XML="$xml" ./vm/lab-network.sh destroy 2>&1); rc=$?
gone=$("${V[@]}" net-info nist-lab-nettest 2>&1)
[[ $rc -eq 0 && "$gone" == *"not found"* ]] && ok "destroy removes an unused network" || bad "destroy: rc=$rc: $out"
out=$(./vm/lab-network.sh destroy 2>&1); rc=$?
[[ $rc -ne 0 && "$out" == *"still used by"* ]] && ok "destroy refuses the real nist-lab while guests use it, naming them" || bad "destroy of nist-lab: rc=$rc: $out"
out=$(./vm/lab-network.sh destroy-if-unused 2>&1); rc=$?
[[ $rc -eq 0 && "$out" == *"keeping nist-lab"* ]] && ok "destroy-if-unused keeps nist-lab while it is in use" || bad "destroy-if-unused: rc=$rc: $out"
# Captured, not piped to grep -q: its early exit would fail the pipeline with
# virsh's SIGPIPE under pipefail.
real=$("${V[@]}" net-info nist-lab 2>/dev/null)
grep -q 'Active: *yes' <<<"$real" && ok "the real nist-lab is still active" || bad "nist-lab is not active"
echo "==> $([ $fails -eq 0 ] && echo PASS || echo FAIL): lab network ($fails failed)"
exit $(( fails > 0 ))
