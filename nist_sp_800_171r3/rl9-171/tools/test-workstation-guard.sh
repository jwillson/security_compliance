#!/usr/bin/env bash
#
# site.yml must refuse the control workstation (DEFECTS 7.13, issue #7): a
# throwaway inventory names this machine in both groups - as localhost over
# a local connection, and as 127.0.0.1 - and a --check run must stop at the
# guard on both plays with no role task reached. Then a real lab host must
# pass the same guard. Read-only here: --check, and the guard fails before
# any role task; fact gathering is the only thing that runs locally.
#
#   tools/test-workstation-guard.sh [LAB_HOST]   default byo-rl9-01; source the BYO env.sh
#
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE/.." || exit 2
lab=${1:-byo-rl9-01}
fails=0
ok()  { echo "PASS  $*"; }
bad() { echo "FAIL  $*"; fails=$((fails + 1)); }
inv=$(mktemp --suffix=.yml); trap 'rm -f "$inv"' EXIT
cat > "$inv" <<YAML
cui_hosts:
  hosts:
    localhost: {ansible_connection: local, ansible_python_interpreter: /usr/bin/python3}
log_hosts:
  hosts:
    loopback-collector: {ansible_host: 127.0.0.1, ansible_connection: local, ansible_python_interpreter: /usr/bin/python3}
YAML
out=$(ANSIBLE_INVENTORY="$inv" ansible-playbook -i "$inv" site.yml --check </dev/null 2>&1)
refused=$(grep -c 'is the control workstation itself' <<<"$out")
reached=$(grep -cE '^TASK \[nist_(800_171|log_collector) :' <<<"$out")
[[ $refused -ge 2 && $reached -eq 0 ]] && ok "both plays refused the workstation; no role task reached" \
  || bad "refused $refused time(s), role tasks reached: $reached"
. lib/ssh-env.sh || exit 2
out=$(./apply.sh --check --limit "$lab" --tags 03.05.07 </dev/null 2>&1)
grep -qE "^$lab +:.*failed=0" <<<"$out" && ! grep -q 'control workstation itself' <<<"$out" \
  && ok "$lab passes the guard" || bad "$lab: $(grep -E "^$lab +:" <<<"$out")"
echo "==> $([ $fails -eq 0 ] && echo PASS || echo FAIL): workstation guard ($fails failed)"
exit $(( fails > 0 ))
