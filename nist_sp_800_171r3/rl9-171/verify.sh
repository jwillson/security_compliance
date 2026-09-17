#!/usr/bin/env bash
#
# Assess the inventory against all 97 active requirements of SP 800-171r3.
#
# The assessment runs ON the target using audit/nist-assess, which is written
# independently of the Ansible role: it inspects live system state rather than
# trusting the role's own report. Results come back as JSON and HTML.
#
#   ./verify.sh                         assess every host
#   ./verify.sh --failed-only           show only deviations
#   ./verify.sh --family 03.13          one family
#   ./verify.sh --requirement 03.05.07  one requirement
#   ./verify.sh --host rl9-cui-01       one host
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

HOST_FILTER=""
ASSESS_ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --host) HOST_FILTER="$2"; shift 2 ;;
    *)      ASSESS_ARGS+=("$1"); shift ;;
  esac
done

[[ -f inventory/hosts.yml ]] || {
  echo "error: no inventory/hosts.yml." >&2
  echo "  existing host:  cp inventory/hosts.yml.example inventory/hosts.yml && edit" >&2
  echo "  new lab VM:     make vm" >&2
  exit 1
}

. "$(dirname "${BASH_SOURCE[0]}")/lib/ssh-env.sh"
nist_seed_known_hosts

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p reports
rc=0

# Resolve hosts from the inventory rather than assuming a single target.
mapfile -t HOSTS < <(ansible-inventory --list 2>/dev/null \
  | python3 -c "
import json,sys
d=json.load(sys.stdin)
for h in d.get('cui_hosts',{}).get('hosts',[]):
    print(h)
")

[[ ${#HOSTS[@]} -gt 0 ]] || { echo "error: no hosts in group cui_hosts" >&2; exit 1; }

for host in "${HOSTS[@]}"; do
  [[ -n "$HOST_FILTER" && "$host" != "$HOST_FILTER" ]] && continue

  echo "==> assessing $host"

  # Push the assessor and the policy it reads. Copying every time means the
  # host is always assessed against the current catalog, not a stale copy.
  ansible "$host" -m file -a "path=/opt/nist-assess state=directory mode=0700" -b >/dev/null
  for f in audit/nist-assess audit/checks.yml \
           catalog/overlay-rocky9.yml catalog/requirements.json; do
    ansible "$host" -m copy \
      -a "src=$f dest=/opt/nist-assess/$(basename "$f") mode=0700" -b >/dev/null
  done

  # PyYAML is the assessor's only dependency.
  ansible "$host" -m dnf -a "name=python3-pyyaml state=present" -b >/dev/null 2>&1 || true

  json="reports/${host}-${STAMP}.json"
  html="reports/${host}-${STAMP}.html"

  set +e
  ansible "$host" -m shell -b -a \
    "/opt/nist-assess/nist-assess \
       --checks   /opt/nist-assess/checks.yml \
       --overlay  /opt/nist-assess/overlay-rocky9.yml \
       --catalog  /opt/nist-assess/requirements.json \
       --json     /tmp/nist-assessment.json \
       --html     /tmp/nist-assessment.html \
       ${ASSESS_ARGS[*]:-}" 2>&1 | sed '1d;s/^/    /'
  host_rc=${PIPESTATUS[0]}
  set -e

  ansible "$host" -m fetch -b \
    -a "src=/tmp/nist-assessment.json dest=$json flat=yes" >/dev/null 2>&1 || true
  ansible "$host" -m fetch -b \
    -a "src=/tmp/nist-assessment.html dest=$html flat=yes" >/dev/null 2>&1 || true

  [[ -f "$json" ]] && echo "    results: $json"
  [[ -f "$html" ]] && echo "    report:  $html"
  [[ $host_rc -ne 0 ]] && rc=1
done

echo
if [[ $rc -eq 0 ]]; then
  echo "All host-enforceable requirements satisfied on every host."
else
  echo "Deviations found. See the reports above, or re-run with --failed-only."
fi
exit $rc
