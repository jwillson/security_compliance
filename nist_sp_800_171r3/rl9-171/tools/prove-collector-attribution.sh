#!/usr/bin/env bash
#
# Prove the collector files a record under the peer it came from, not the
# host the record claims (issue #10): from FORWARDER, with its own TLS
# certificate - what root on any permitted peer holds - send one record whose
# syslog header names VICTIM, then see which directory the collector filed it
# in.
#
#   tools/prove-collector-attribution.sh FORWARDER VICTIM COLLECTOR
#   tools/prove-collector-attribution.sh byo-rl9-02 byo-rl9-01 byo-log-01
#
# PASS when the marker is under COLLECTOR's directory for FORWARDER and not
# under VICTIM's. The marked line stays in the record store; it says what it
# is. Source the lab's env.sh first.
#
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE/.." || exit 2
. lib/ssh-env.sh || exit 2
nist_seed_known_hosts
fwd=${1:?usage: FORWARDER VICTIM COLLECTOR}; victim=${2:?}; col=${3:?}
remote() { ansible "$1" -b -m ansible.builtin.shell -a "$2" </dev/null 2>/dev/null | sed 1d; }
addr=$(ansible-inventory --host "$col" 2>/dev/null | python3 -c "import json,sys; print(json.load(sys.stdin)['ansible_host'])")
marker="nist-attribution-test-$(date +%s)"

echo "==> $fwd sends a record that claims to be from $victim, to $col ($addr:6514)"
remote "$fwd" "printf '<182>%s $victim audispd: node=$victim type=USER_CMD msg=audit(0.0:0): $marker (a forged header, sent by tools/prove-collector-attribution.sh from $fwd)\n' \"\$(date '+%b %e %H:%M:%S')\" \
  | timeout 15 openssl s_client -quiet -connect $addr:6514 -servername $col \
      -cert /etc/pki/rsyslog/host.crt -key /etc/pki/rsyslog/host.key -CAfile /etc/pki/rsyslog/ca.crt >/dev/null 2>&1; echo sent" >/dev/null
sleep 5
where=$(remote "$col" "grep -rl '$marker' /var/log/nist-remote 2>/dev/null")
echo "    filed in: ${where:-nowhere}"
if [[ "$where" == */"$fwd"/* && "$where" != */"$victim"/* ]]; then
  echo "PASS: the record that claimed $victim was filed under $fwd, the peer it came from"
elif [[ -z "$where" ]]; then
  echo "FAIL: the record did not arrive"; exit 1
else
  echo "FAIL: the record was filed as the host it claimed"; exit 1
fi
