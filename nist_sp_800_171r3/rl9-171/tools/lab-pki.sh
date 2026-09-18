#!/usr/bin/env bash
#
# Mint a lab certificate authority and a certificate per host, for TLS on the
# audit-record forwarding path (03.03.05c over 03.13.08).
#
#   tools/lab-pki.sh [-d DIR] HOST[=IP] ...
#
# DIR defaults to $NIST_PKI_DIR, then .secrets/pki. The CA is created once
# and reused; a host whose certificate already exists is left alone. Each
# certificate carries CN=HOST and SAN DNS:HOST[, IP:IP], which is the name
# rsyslog's x509/name mode checks against the permitted-peer list, so HOST
# must be the inventory hostname.
#
# This is a LAB authority. A real deployment supplies ca.crt and each host's
# HOST.crt/HOST.key from its own PKI in the same directory layout, and never
# needs this script. RSA-3072 and SHA-256 are FIPS-approved (03.13.11).
set -euo pipefail

DIR="${NIST_PKI_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/.secrets/pki}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    -d) DIR="$2"; shift 2 ;;
    -h|--help) sed -n '2,17p' "$0"; exit 0 ;;
    *) break ;;
  esac
done
[[ $# -gt 0 ]] || { echo "usage: $0 [-d DIR] HOST[=IP] ..." >&2; exit 1; }

umask 077
mkdir -p "$DIR"
if [[ ! -f "$DIR/ca.crt" ]]; then
  openssl req -x509 -newkey rsa:3072 -sha256 -nodes -days 3650 \
    -subj "/CN=rl9-171 lab CA" \
    -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign,cRLSign" \
    -keyout "$DIR/ca.key" -out "$DIR/ca.crt" 2>/dev/null
  echo "created CA        $DIR/ca.crt"
fi

for spec in "$@"; do
  host="${spec%%=*}"; ip=""; [[ "$spec" == *=* ]] && ip="${spec#*=}"
  if [[ -f "$DIR/$host.crt" ]]; then echo "exists            $DIR/$host.crt"; continue; fi
  san="DNS:$host"; [[ -n "$ip" ]] && san="$san,IP:$ip"
  openssl req -new -newkey rsa:3072 -sha256 -nodes -subj "/CN=$host" \
    -keyout "$DIR/$host.key" -out "$DIR/$host.csr" 2>/dev/null
  openssl x509 -req -sha256 -days 730 -in "$DIR/$host.csr" \
    -CA "$DIR/ca.crt" -CAkey "$DIR/ca.key" -CAcreateserial \
    -extfile <(printf 'subjectAltName=%s\nextendedKeyUsage=serverAuth,clientAuth\nkeyUsage=critical,digitalSignature,keyEncipherment\nbasicConstraints=CA:FALSE\n' "$san") \
    -out "$DIR/$host.crt" 2>/dev/null
  rm -f "$DIR/$host.csr"
  echo "issued            $DIR/$host.crt  (SAN $san)"
done
chmod 600 "$DIR"/*.key
