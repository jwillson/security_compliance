#!/usr/bin/env bash
#
# The control-plane container by behaviour (DEFECTS 7.23).
#
#   tools/test-container.sh            build it, and the checks that need no host
#   tools/test-container.sh HOST       also verify and dry-run apply HOST through it
#
# Without HOST: a fresh build, then inside it make validate, make test, make
# catalog-check (the catalog reproduces with the image's poppler) and both
# playbooks' syntax checks - what a workstation with nothing but podman or
# docker can do. With HOST (a lab host in the inventory NIST_INVENTORY picks;
# source the lab's env.sh first): ./verify.sh and ./apply.sh --check reach it
# from inside the container - SSH, the second factor and sudo all working
# through the mounts - and so does a bare ad-hoc ansible -b, the path
# verify.sh takes. Read-only on the host.
#
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE/.." || exit 2
host=${1:-}
fails=0
ok()  { echo "PASS  $*"; }
bad() { echo "FAIL  $*"; fails=$((fails + 1)); }
run() {   # label command...
  local label=$1; shift
  if out=$("$@" </dev/null 2>&1); then ok "$label"; else bad "$label: $(tail -3 <<<"$out" | tr '\n' ' ')"; fi
}
run "the image builds"                          ./nist --rebuild true
run "ansible-core inside is the pinned one"     ./nist bash -c 'ansible --version | head -1 | grep -q "core 2.21.4"'
run "make validate"                             ./nist make validate
run "make test"                                 ./nist make test
run "make catalog-check"                        ./nist make catalog-check
run "ssh inside finds your known_hosts"        ./nist bash -c '[ "$(getent passwd "$(id -u)" | cut -d: -f6)" = "$HOME" ]'
run "the playbooks parse"                       ./nist bash -c 'cp inventory/hosts.yml.example /tmp/h.yml && ANSIBLE_INVENTORY_UNPARSED_FAILED=true ansible-playbook --syntax-check -i /tmp/h.yml site.yml && ansible-playbook --syntax-check -i /tmp/h.yml rotate-luks-passphrase.yml'
if [[ -n "$host" ]]; then
  # verify.sh drives the host with ad-hoc ansible, apply.sh with a playbook;
  # each is proven. On an ad-hoc failure the -vvvv trace (with ssh -vvv, ansible_ssh_verbosity
  # =3) is kept in reports/runs/, its authentication lines shown, since the
  # one-line message rarely names the cause. A failed attempt can earn a
  # sshd PerSourcePenalties lockout (RUNBOOK, "When you are locked out").
  out=$(./nist ansible "$host" -b -m ansible.builtin.command -a "id -u" </dev/null 2>&1)
  if grep -qE "^$host \| CHANGED.*" <<<"$out" && grep -qx 0 <<<"$out"; then
    ok "ad-hoc ansible -b reaches $host from inside, as root"
  else
    bad "ad-hoc ansible -b: $(grep -m1 -E 'msg|UNREACHABLE|FAILED' <<<"$out")"
    mkdir -p reports/runs; trace=reports/runs/test-container-adhoc-$(date -u +%Y%m%dT%H%M%SZ).log
    ./nist ansible "$host" -b -m ansible.builtin.command -a "id -u" -vvvv -e ansible_ssh_verbosity=3 </dev/null >"$trace" 2>&1
    echo "      trace: $trace"
    grep -E 'debug1: (Authentications|Next auth|Server accepts|Authenticated|Offering|read_passphrase|Entering|Sending command|mux)|ssh_askpass|Permission denied|BECOME|msg' "$trace" | tail -25 | sed 's/^/      /'
  fi
  out=$(./nist ./verify.sh --host "$host" --requirement 03.05.03 </dev/null 2>&1)
  grep -q '1 requirements assessed' <<<"$out" && ok "verify.sh reaches $host from inside (03.05.03)" || bad "verify.sh: $(tail -3 <<<"$out" | tr '\n' ' ')"
  out=$(./nist ./apply.sh --check --limit "$host" --tags 03.01.11 </dev/null 2>&1)
  grep -qE "^$host +:.* unreachable=0 +failed=0" <<<"$out" && ok "apply.sh --check reaches $host from inside, with sudo" || bad "apply.sh --check: $(grep -E "^$host +:|fatal" <<<"$out" | head -2 | tr '\n' ' ')"
fi
echo "==> $([ $fails -eq 0 ] && echo PASS || echo FAIL): the control-plane container ($fails failed)"
exit $(( fails > 0 ))
