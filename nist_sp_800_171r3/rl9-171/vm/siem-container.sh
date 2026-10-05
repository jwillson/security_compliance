#!/usr/bin/env bash
#
# A stand-in SIEM for the lab: syslog-ng - a different implementation from the
# collector role's rsyslog - receiving audit records over TLS with mutual x509,
# in a rootful podman container on the nist-lab bridge (TASKS.md 6.2a).
#
#   vm/siem-container.sh up        mint its certificate, start it at .50:6514
#   vm/siem-container.sh down      stop and remove it (records are kept)
#   vm/siem-container.sh records   what it has received, per sending host
#
# It is not a CUI host and never enters an inventory. It sits at
# 192.168.171.50 (outside the DHCP range) on a macvlan network whose parent
# is virbr17, so the guests reach it as an ordinary peer and no host firewall
# rule is involved. (The laptop itself cannot reach a macvlan child of its
# own bridge; nothing here needs it to.)
#
# Its certificate comes from the BYO lab's CA ($NIST_PKI_DIR, via
# tools/lab-pki.sh) under the name siem.nist-lab - a name no inventory host
# has, which is the point: the forwarder must match the peer name it is told
# to expect. It requires the client's certificate from the same CA.
# State lives in $NIST_BYO_LAB/siem/. Source the lab's env.sh first.
#
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
LAB="${NIST_BYO_LAB:-$HOME/.local/share/nist-byo-lab}"
IMAGE=docker.io/balabit/syslog-ng@sha256:38770d0110134322b863cbaedcd57ef8bb831fe51e0b0bc722fa5c54f8500589  # syslog-ng 4.12.0
NAME=nist-siem NET=nist-lab-siem IP=192.168.171.50 PEER=siem.nist-lab PORT=6514
DIR="$LAB/siem"
say() { echo "==> $*"; }

up() {
  [[ -n "${NIST_PKI_DIR:-}" && -f "$NIST_PKI_DIR/ca.crt" ]] \
    || { echo "error: NIST_PKI_DIR must hold the BYO lab CA (source env.sh)" >&2; exit 2; }
  install -d -m 0700 "$DIR" "$DIR/tls" "$DIR/log"
  "$ROOT/tools/lab-pki.sh" -d "$NIST_PKI_DIR" "$PEER=$IP" >/dev/null
  install -m 0600 "$NIST_PKI_DIR/ca.crt" "$DIR/tls/ca.crt"
  install -m 0600 "$NIST_PKI_DIR/$PEER.crt" "$DIR/tls/siem.crt"
  install -m 0600 "$NIST_PKI_DIR/$PEER.key" "$DIR/tls/siem.key"
  cat > "$DIR/syslog-ng.conf" <<EOF
@version: 4.2
# Written by vm/siem-container.sh. TLS only, and only for a client whose
# certificate the lab CA signed.
options { chain-hostnames(no); keep-hostname(yes); create-dirs(yes);
          dir-perm(0700); perm(0600); };
source s_tls {
  network(ip(0.0.0.0) port($PORT) transport("tls")
          tls(key-file("/etc/syslog-ng/tls/siem.key")
              cert-file("/etc/syslog-ng/tls/siem.crt")
              ca-file("/etc/syslog-ng/tls/ca.crt")
              peer-verify(required-trusted)));
};
destination d_host { file("/var/log/remote/\${HOST}/\${PROGRAM}.log"); };
log { source(s_tls); destination(d_host); };
log { source { internal(); }; destination { file("/dev/stdout"); }; };
EOF
  sudo podman network exists "$NET" || {
    say "creating $NET: macvlan on virbr17"
    sudo podman network create -d macvlan -o parent=virbr17 \
      --subnet 192.168.171.0/24 --gateway 192.168.171.1 "$NET" >/dev/null
  }
  sudo podman rm -f "$NAME" >/dev/null 2>&1 || true
  # :Z relabels the mounts for the container: on an SELinux host (RHEL,
  # Fedora) it could not read files under $HOME otherwise (DEFECTS 7.21).
  sudo podman run -d --name "$NAME" --network "$NET" --ip "$IP" \
    -v "$DIR/syslog-ng.conf:/etc/syslog-ng/syslog-ng.conf:ro,Z" \
    -v "$DIR/tls:/etc/syslog-ng/tls:ro,Z" \
    -v "$DIR/log:/var/log/remote:Z" \
    "$IMAGE" -F >/dev/null
  local i; for i in $(seq 1 30); do
    sudo podman logs "$NAME" 2>&1 | grep -q 'syslog-ng starting up' && { say "$NAME listening at $IP:$PORT as $PEER"; return 0; }
    sleep 1
  done
  sudo podman logs "$NAME" 2>&1 | tail -5
  echo "error: $NAME did not start" >&2; exit 1
}

down() {
  sudo podman rm -f "$NAME" >/dev/null 2>&1 || true
  sudo podman network rm "$NET" >/dev/null 2>&1 || true
  say "$NAME removed (records kept in $DIR/log)"
}

records() {
  sudo bash -c '
    for h in "$1"/*/; do
      [ -d "$h" ] || continue
      all=$(cat "$h"*.log 2>/dev/null | wc -l)
      aud=$(cat "$h"*.log 2>/dev/null | grep -cE "type=[A-Z_]+ msg=audit\(" || true)
      printf "%-14s lines=%s auditd-records=%s\n" "$(basename "$h")" "$all" "$aud"
    done' _ "$DIR/log"
}

case "${1:-}" in
  up) up ;; down) down ;; records) records ;;
  *) sed -n '3,20p' "$0"; exit 2 ;;
esac
