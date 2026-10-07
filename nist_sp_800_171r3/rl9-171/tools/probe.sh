#!/usr/bin/env bash
#
# Run a read-only evidence probe from tools/probes/ on inventory hosts, as
# root, and print what each host showed. A probe is how a finding is shown
# on a host (AGENTS.md, Doctrine): the command that produced the evidence is
# committed, so the evidence can be produced again, before and after a fix.
#
#   tools/probe.sh PROBE [HOST_PATTERN]      default pattern: cui_hosts
#   tools/probe.sh 6b-evidence
#   tools/probe.sh 6b-evidence byo-rl9-02
#   tools/probe.sh 6b-evidence > before.txt   # ...fix, apply... then diff
#
# Probes must not change the host. Source the lab's env.sh first.
#
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../lib/container.sh"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

probe=${1:-}; pattern=${2:-cui_hosts}
[[ -n "$probe" ]] || { sed -n '3,14p' "$0"; ls "$HERE/probes" | sed 's/\.sh$//;s/^/  /'; exit 2; }
script="$HERE/probes/$probe.sh"
[[ -f "$script" ]] || { echo "error: no probe $script" >&2; exit 2; }

cd "$ROOT"
# ssh-env, not just inventory-env: this script runs ansible itself (probes,
# the reboot), and once 03.05.03 is applied every connection needs the second
# factor - for a lab inventory only ssh-env supplies it - and a host key
# already known (a kickstart host is new until seeded).
. lib/ssh-env.sh || exit 2
nist_seed_known_hosts
# The script module copies the probe to the host and runs it; -b for root.
ansible "$pattern" -b -m ansible.builtin.script -a "$script" -o 2>/dev/null \
  | python3 -c '
import json, re, sys
for line in sys.stdin:
    m = re.match(r"^(\S+) \| (\w+).*?=> (\{.*\})\s*$", line)
    if not m:
        print(line.rstrip()); continue
    host, state, body = m.groups()
    data = json.loads(body)
    print(f"=== {host} ({state})")
    out = data.get("stdout") or data.get("msg") or ""
    for l in out.splitlines():
        print(f"{host:<12} {l}")
'
