#!/usr/bin/env bash
#
# Remove both labs from this host, leaving nothing behind (DEFECTS 7.18).
#
#   vm/lab-teardown.sh          list what goes, ask, remove   (make teardown)
#   vm/lab-teardown.sh --yes    without asking
#
# Every lab guest - BYO (vm/byo-guest.sh destroy), kickstart
# (vm/build-vm.sh --destroy) and portability test host
# (vm/portability-host.sh destroy, with its network and images) - with its disks, snapshots, UEFI variables, TPM
# state, DHCP pin, libvirt logs, host key and inventory entry; the lab network; the staged boot ISO and the
# cached BYO base image in the libvirt image directory; the per-guest
# cloud-init seeds in the BYO lab directory. Then tools/lab-residue.sh must
# find nothing, or this exits 1 saying what is left.
#
# Kept, because they are inputs rather than residue and a rebuild needs them:
# .secrets/ (the kickstart lab's key and passwords), iso/ (the downloaded
# ISO), and the BYO lab directory's secrets and tooling. Remove those by hand
# only if you mean never to rebuild: rm -rf .secrets iso "$NIST_BYO_LAB".
#
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../lib/container.sh"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
cd "$ROOT" || exit 2
V=(virsh -c "$NIST_LIBVIRT_URI")
LAB="${NIST_BYO_LAB:-$HOME/.local/share/nist-byo-lab}"
NET=$(sed -n 's:.*<name>\(.*\)</name>.*:\1:p' vm/nist-lab-network.xml | head -1)
say() { echo "==> $*"; }

guests=$(for d in $("${V[@]}" list --all --name 2>/dev/null); do
  if [[ "$d" =~ ^(rl9|byo|ptest)- ]] || "${V[@]}" domiflist "$d" 2>/dev/null | awk -v n="$NET" '$3==n {f=1} END {exit !f}'; then echo "$d"; fi
done | sort)

echo "This removes both labs from $(hostname):"
echo "  guests:  ${guests:-none}" | tr '\n' ' '; echo
echo "  and the lab network, the BYO base image, and any lab volume left in a pool."
echo "  Kept: .secrets/, iso/, and the secrets in $LAB."
if [[ "${1:-}" != --yes ]]; then
  read -r -p "Type 'teardown' to go on: " answer
  [[ "$answer" == teardown ]] || { echo "nothing removed"; exit 1; }
fi

for g in $guests; do
  if [[ "$g" == ptest-* ]]; then
    say "$g (portability test host)"; ./vm/portability-host.sh destroy "${g#ptest-}" || true
  elif [[ "$g" == byo-* ]]; then
    say "$g (BYO)"; ./vm/byo-guest.sh destroy "$g" || true
    rm -rf "${LAB:?}/$g"                 # its cloud-init seed and passwords
  else
    role=cui; [[ "$g" == *log* ]] && role=log
    # The destroy reads the guest's address from the inventory that holds it
    # (to forget its host key) and then removes its entry there.
    inv=inventory/hosts.yml
    for i in inventory/kickstart.yml inventory/hosts.yml; do
      [[ -f "$i" ]] && NIST_INVENTORY="$i" ./tools/inventory.py show 2>/dev/null | awk -v n="$g" '$1==n {f=1} END {exit !f}' && { inv=$i; break; }
    done
    say "$g (kickstart, $inv)"
    NIST_INVENTORY="$inv" ./vm/build-vm.sh --name "$g" --role "$role" --destroy || true
  fi
done

say "lab network"; ./vm/lab-network.sh destroy || true
say "BYO base image, an older build's staged ISO, any lab volume left in a pool"
# A directory in a pool (the retired snapshot tool saved TPM state as one)
# is a volume vol-delete removes only when empty, and its files are root's.
# libvirt itself empties it: the directory becomes a temporary pool, its
# volumes are deleted - a subdirectory the same way - and then the directory.
purge_dir() {   # PATH
  local tmp="nist-purge-$$-$RANDOM" v t
  "${V[@]}" pool-create-as "$tmp" dir --target "$1" >/dev/null 2>&1 || return 1
  while read -r v t; do
    [[ -n "$v" ]] || continue
    if [[ "$t" == dir ]]; then purge_dir "$1/$v"; fi
    "${V[@]}" vol-delete --pool "$tmp" "$v" >/dev/null 2>&1
  done < <("${V[@]}" vol-list --pool "$tmp" --details 2>/dev/null | awk 'NR > 2 && NF {print $1, $3}')
  "${V[@]}" pool-destroy "$tmp" >/dev/null 2>&1
}
for pool in $("${V[@]}" pool-list --name 2>/dev/null); do
  ppath=$("${V[@]}" pool-dumpxml "$pool" 2>/dev/null | sed -n 's:.*<path>\(.*\)</path>.*:\1:p' | head -1)
  while read -r f t; do
    [[ "$f" =~ ^(rl9|byo|ptest)- || "$f" == Rocky-*-boot.iso || "$f" == rocky9-genericcloud-base.qcow2 ]] || continue
    [[ "$t" == dir && -n "$ppath" ]] && purge_dir "$ppath/$f"
    "${V[@]}" vol-delete --pool "$pool" "$f" >/dev/null 2>&1 && echo "    $pool/$f"
  done < <("${V[@]}" vol-list --pool "$pool" --details 2>/dev/null | awk 'NR > 2 && NF {print $1, $3}')
done

echo
./tools/lab-residue.sh
left=$(./tools/lab-residue.sh | grep -c '^  ')
if (( left > 0 )); then echo "==> FAIL: $left item(s) left behind" >&2; exit 1; fi
echo "==> PASS: nothing of the labs is left on $(hostname)"
