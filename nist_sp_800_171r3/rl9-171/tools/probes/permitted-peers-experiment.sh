#!/usr/bin/env bash
#
# Does rsyslog's omfwd refuse a TLS peer whose certificate does not carry the
# name in StreamDriverPermittedPeers? (TASKS.md 6.2a: with PermittedPeers set
# to a name the receiver's certificate does not have, records still arrived.)
# Runs ON the target as root via tools/probe.sh, with the stand-in SIEM up
# (vm/siem-container.sh). Self-cleaning, away from the live forwarding: a
# second rsyslogd with its own config, work directory and pid file, fed by
# logger over a loopback UDP port, one run per case. Each case sends a unique
# marker; which markers reached the receiver is read on the workstation:
#
#   tools/probe.sh permitted-peers-experiment HOST
#   sudo grep -rho 'PEERTEST-[a-z0-9.-]*' $NIST_BYO_LAB/siem/log | sort -u
#
set -uo pipefail
RECEIVER=${RECEIVER:-192.168.171.50}; PORT=${PORT:-6514}
T=$(mktemp -d /var/lib/rsyslog/peertest.XXXXXX); PID=""
cleanup() { [ -n "$PID" ] && kill "$PID" 2>/dev/null; sleep 1; rm -rf "$T"; }
trap cleanup EXIT
say() { echo "exp  $*"; }
nonce=$(head -c4 /dev/urandom | od -An -tx1 | tr -d ' \n')

say "rsyslog $(rpm -q --qf '%{VERSION}-%{RELEASE}' rsyslog), openssl $(rpm -q --qf '%{VERSION}' openssl)"

run_case() {   # label authmode permittedpeers
  local label=$1 mode=$2 peers=$3 port=$((20000 + RANDOM % 10000))
  cat > "$T/$label.conf" <<EOF
global(workDirectory="$T" DefaultNetstreamDriver="ossl"
       DefaultNetstreamDriverCAFile="/etc/pki/rsyslog/ca.crt"
       DefaultNetstreamDriverCertFile="/etc/pki/rsyslog/host.crt"
       DefaultNetstreamDriverKeyFile="/etc/pki/rsyslog/host.key")
module(load="imudp")
input(type="imudp" address="127.0.0.1" port="$port")
if \$msg contains "PEERTEST" then {
  action(type="omfwd" target="$RECEIVER" port="$PORT" protocol="tcp"
         StreamDriver="ossl" StreamDriverMode="1" StreamDriverAuthMode="$mode"
         StreamDriverPermittedPeers="$peers")
  stop
}
EOF
  rsyslogd -N1 -f "$T/$label.conf" >/dev/null 2>&1 || { say "$label: config rejected"; return; }
  rsyslogd -n -f "$T/$label.conf" -i "$T/$label.pid" > "$T/$label.out" 2>&1 &
  PID=$!; sleep 2
  logger -n 127.0.0.1 -P "$port" -d "PEERTEST-$label-$nonce"; sleep 1
  logger -n 127.0.0.1 -P "$port" -d "PEERTEST-$label-$nonce-second"; sleep 4
  kill "$PID" 2>/dev/null; wait "$PID" 2>/dev/null; PID=""
  say "$label (authmode=$mode peers=$peers) sent PEERTEST-$label-$nonce; rsyslog said:"
  grep -iE 'error|not permitted|peer|certificate|x509|name' "$T/$label.out" | head -4 | sed 's/^/exp      /'
}

run_case right   x509/name    siem.nist-lab
run_case wrong   x509/name    not-the-siem.nist-lab
run_case wildcd  x509/name    '*.nist-lab'
say "nonce $nonce: now read which markers the receiver holds"
