#!/usr/bin/env bash
#
# The lab tools must refuse a libvirt domain that is not a lab guest (issue
# #6): defines a decoy - a domain on no network with a 1 MB disk, never
# started - and runs every destructive entry point against it; each must
# refuse and leave the decoy and its disk in place. Then each guard must
# still let a real BYO and kickstart guest through (asked for a snapshot
# label that does not exist, so nothing is changed). Last, the authored-plans
# rehearsal must refuse BYO_GUEST while it carries an authored SSP section (a
# stand-in, removed after). The decoy is removed at the end whatever happens.
# Source the BYO lab's env.sh first.
#
#   tools/test-lab-guards.sh [BYO_GUEST] [KICKSTART_GUEST]   default byo-rl9-01 rl9-cui-01
#
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE/.." || exit 2
byo=${1:-byo-rl9-01}; ks=${2:-rl9-cui-01}
DECOY=nist-guard-decoy IMG=/var/lib/libvirt/images/nist-guard-decoy.qcow2
V=(sudo virsh -c qemu:///system)
fails=0
ok()  { echo "PASS  $*"; }
bad() { echo "FAIL  $*"; fails=$((fails + 1)); }
cleanup() { "${V[@]}" undefine "$DECOY" >/dev/null 2>&1; sudo rm -f "$IMG"; }
trap cleanup EXIT

sudo qemu-img create -q -f qcow2 "$IMG" 1M
"${V[@]}" define /dev/stdin >/dev/null <<XML || { echo "could not define the decoy"; exit 2; }
<domain type='kvm'><name>$DECOY</name><memory unit='MiB'>64</memory>
  <os><type arch='x86_64'>hvm</type></os>
  <devices><disk type='file' device='disk'><source file='$IMG'/><target dev='vda'/></disk></devices>
</domain>
XML
intact() { "${V[@]}" dominfo "$DECOY" >/dev/null 2>&1 && sudo test -f "$IMG"; }

refuses() {   # label command...
  local label=$1; shift
  out=$("$@" 2>&1 </dev/null); rc=$?
  if [[ $rc -ne 0 ]] && grep -qiE 'not a (lab )?guest|not attached to nist-lab|refusing' <<<"$out" && intact; then
    ok "$label refuses the decoy and leaves it intact"
  else
    bad "$label: rc=$rc, intact=$(intact && echo yes || echo NO): ${out:0:160}"
  fi
}
refuses "byo-guest.sh destroy"       ./vm/byo-guest.sh destroy "$DECOY"
refuses "byo-snapshot.sh save"       ./vm/byo-snapshot.sh save "$DECOY" x
refuses "byo-snapshot.sh revert"     ./vm/byo-snapshot.sh revert "$DECOY" x
refuses "build-vm.sh --destroy"      ./vm/build-vm.sh --name "$DECOY" --destroy

passes() {   # label guest
  out=$(./vm/byo-snapshot.sh revert "$2" no-such-label 2>&1 </dev/null)
  if grep -q 'no snapshot' <<<"$out"; then ok "$1 ($2) passes the guard"
  else bad "$1 ($2): ${out:0:160}"; fi
}
passes "a BYO guest" "$byo"
passes "a kickstart guest" "$ks"

# The authored-plans rehearsal overwrites and deletes ssp.d sections, so it
# must refuse a host that has one. A stand-in section, removed after.
. lib/ssh-env.sh || exit 2
STANDIN=/etc/nist-800-171/ssp.d/02-zz-guard-test.md
ansible "$byo" -b -m ansible.builtin.shell -a "mkdir -p /etc/nist-800-171/ssp.d && echo 'stand-in, tools/test-lab-guards.sh' > $STANDIN" </dev/null >/dev/null 2>&1
out=$(./tools/rehearse-authored-plans.sh "$byo" </dev/null 2>&1); rc=$?
still=$(ansible "$byo" -b -m ansible.builtin.shell -a "cat $STANDIN 2>/dev/null || true" </dev/null 2>/dev/null | sed 1d)
ansible "$byo" -b -m ansible.builtin.shell -a "rm -f $STANDIN" </dev/null >/dev/null 2>&1
if [[ $rc -eq 2 ]] && grep -q 'already carries authored SSP sections' <<<"$out" && [[ "$still" == *stand-in* ]]; then
  ok "rehearse-authored-plans.sh refuses a host with an authored section and leaves it"
else
  bad "rehearse-authored-plans.sh: rc=$rc: ${out:0:160}"
fi

echo "==> $([ $fails -eq 0 ] && echo PASS || echo FAIL): lab-tool guards ($fails failed)"
exit $(( fails > 0 ))
