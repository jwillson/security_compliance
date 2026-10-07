#!/usr/bin/env bash
#
# Prove the kickstart lab runs on another distribution's host (DEFECTS 7.21):
# on a throwaway control host from vm/portability-host.sh, from its stock
# image, do what a new operator would - and only that:
#
#   tools/portability-run.sh rocky9|fedora [--keep]
#
#   1. copy the repository in, at the committed HEAD (git archive)
#   2. install podman - the tool runs only in its container (TASKS C2) - then
#      vm/host-check.sh, and do what it says: the hypervisor packages it
#      names, libvirt's sockets and group, the default pool; then it must pass
#   3. ./nist make all - catalog, secrets, ISO, the CUI VM (nested), apply,
#      verify - with nothing of the project on the test host but podman
#   4. tools/lab-ssh.sh into the hardened guest
#   5. vm/lab-teardown.sh --yes, which must leave nothing
#   6. the test host is destroyed (--keep leaves it to inspect)
#
# Logs in reports/runs/portability-DISTRO-UTC/. Refuses a worktree with
# changes: the result is for a commit.
#
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../lib/container.sh"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
cd "$ROOT" || exit 2
distro=${1:?usage: tools/portability-run.sh rocky9|fedora [--keep]}; keep=${2:-}
[[ -z "$(git status --porcelain)" ]] || { echo "error: the worktree has changes; the result is for a commit" >&2; exit 2; }
commit=$(git rev-parse --short HEAD)
OUT="$ROOT/reports/runs/portability-$distro-$(date -u +%Y%m%dT%H%M%SZ)"; mkdir -p "$OUT"
KEY="${NIST_BYO_KEY:-$HOME/.ssh/id_rsa}"
fails=0
say()  { echo "==> $(date -u +%H:%M) $*" | tee -a "$OUT/summary.txt"; }
ok()   { echo "PASS  $*" | tee -a "$OUT/summary.txt"; }
bad()  { echo "FAIL  $*" | tee -a "$OUT/summary.txt"; fails=$((fails + 1)); }
finish() {
  [[ "$keep" == --keep ]] || ./vm/portability-host.sh destroy "$distro" >> "$OUT/host.log" 2>&1
  say "$([ $fails -eq 0 ] && echo PASS || echo FAIL): the kickstart lab on $distro at $commit ($fails failed)"
  exit $(( fails > 0 ))
}

say "test host ptest-$distro"
if ! virsh -c "$NIST_LIBVIRT_URI" dominfo "ptest-$distro" >/dev/null 2>&1; then
  ./vm/portability-host.sh build "$distro" > "$OUT/host.log" 2>&1 || { bad "the test host did not build (host.log)"; finish; }
fi
ip=$(./vm/portability-host.sh address "$distro")
[[ -n "$ip" ]] || { bad "no address for ptest-$distro"; finish; }
R() { ssh -i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
        -o ServerAliveInterval=60 "ptest@$ip" "$@" </dev/null; }
release=$(R 'cat /etc/os-release | sed -n "s/^PRETTY_NAME=//p"' | tr -d '"')
say "$release at $ip; copying the repository at $commit"
git -C "$(git rev-parse --show-toplevel)" archive --format=tar HEAD \
  | ssh -i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "ptest@$ip" \
      'rm -rf ~/sc && mkdir ~/sc && tar -x -C ~/sc' || { bad "the copy failed"; finish; }
D='cd ~/sc/nist_sp_800_171r3/rl9-171'

say "podman, then the host check, and what it says to do"
R 'sudo dnf -y -q install podman' > "$OUT/install.log" 2>&1 || { bad "podman did not install (install.log)"; finish; }
R "$D && ./vm/host-check.sh kickstart" > "$OUT/host-check-1.log" 2>&1
install=$(sed -n 's/^== install: //p' "$OUT/host-check-1.log")
[[ -n "$install" ]] && { echo "    $install" | tee -a "$OUT/summary.txt"; R "${install/install /install -y }" >> "$OUT/install.log" 2>&1 || bad "its install command failed (install.log)"; }
# What host-check names for libvirt itself: the per-driver sockets (RHEL and
# Fedora), the libvirt group, the default pool - each an operator's step.
R 'sudo systemctl enable --now virtqemud.socket virtnetworkd.socket virtstoraged.socket virtproxyd.socket
   sudo usermod -aG libvirt ptest
   sudo virsh pool-info default >/dev/null 2>&1 || { sudo virsh pool-define-as default dir --target /var/lib/libvirt/images      && sudo virsh pool-build default && sudo virsh pool-autostart default && sudo virsh pool-start default; }' >> "$OUT/install.log" 2>&1
# A new SSH session, so the libvirt group is in force.
R "$D && ./vm/host-check.sh kickstart" > "$OUT/host-check-2.log" 2>&1 \
  && ok "the host check passes after doing what it said" || { bad "the host check still fails (host-check-2.log)"; finish; }

say "./nist make all (nested: expect an hour or more)"
R "$D && ./nist make all" > "$OUT/make-all.log" 2>&1 && ok "make all" \
  || { bad "make all (make-all.log)"; tail -20 "$OUT/make-all.log" | sed 's/^/    /'; finish; }
grep -E 'requirements assessed|satisfied|not satisfied' "$OUT/make-all.log" | tail -5 | sed 's/^/    /' | tee -a "$OUT/summary.txt"

R "$D && ./tools/lab-ssh.sh rl9-cui-01 'cat /proc/sys/crypto/fips_enabled; hostname'" > "$OUT/lab-ssh.log" 2>&1
tail -2 "$OUT/lab-ssh.log" | grep -q '^rl9-cui-01' && ok "tools/lab-ssh.sh into the hardened guest" || bad "tools/lab-ssh.sh (lab-ssh.log)"

R "$D && ./vm/lab-teardown.sh --yes" > "$OUT/teardown.log" 2>&1 && ok "make teardown leaves nothing" \
  || bad "teardown left something (teardown.log)"
finish
