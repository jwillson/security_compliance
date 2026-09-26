#!/usr/bin/env bash
#
# Prove audit-record forwarding to a receiver that is not this toolkit's own
# rsyslog collector (TASKS.md 6.2a): a different TLS stack, a peer name no
# inventory host has, and records that must be legible on the far side.
#
#   tools/prove-foreign-receiver.sh HOST [--keep]
#
#   1. start the stand-in SIEM (vm/siem-container.sh: syslog-ng, mutual x509)
#   2. point HOST's forwarding at it for this run only - extra vars, the
#      inventory is not touched: nist_log_collector=192.168.171.50:6514,
#      nist_log_collector_name=siem.nist-lab
#   3. generate audit events on HOST
#   4. HOST's checks: au-05-forward-established, au-05-audit-trail-forwarded,
#      sc-08-forward-encrypted must PASS
#      4b. the receiver refuses a client with no certificate
#      4c. HOST refuses the receiver when told to expect another name
#   5. the receiver holds auditd records from HOST, and one is legible
#   6. HOST is pointed back at its own collector and forwards there again
#   7. the container is removed (--keep leaves it up)
#
# PASS/FAIL per step; exit 0 only if all pass. Source the BYO lab's env.sh.
#
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE/.."
. lib/ssh-env.sh || exit 2
nist_seed_known_hosts
host=${1:?usage: tools/prove-foreign-receiver.sh HOST [--keep]}; keep=${2:-}
fails=0
ok()  { echo "PASS  $*"; }
bad() { echo "FAIL  $*"; fails=$((fails + 1)); }
remote() { ansible "$host" -b -m ansible.builtin.shell -a "$1" </dev/null 2>/dev/null | sed 1d; }
check() {   # requirement check-id -> the check's status, read from the report
  # JSON, never inferred from a listing (a check that did not run is not a PASS).
  local json
  json=$(./verify.sh --host "$host" --requirement "$1" </dev/null 2>&1 \
         | grep -oE 'reports/[^ ]+\.json' | tail -1)
  [[ -n "$json" ]] || { echo "NO-REPORT"; return; }
  python3 -c 'import json,sys
d = json.load(open(sys.argv[1]))
s = [c["status"] for r in d["requirements"] for c in r.get("checks", []) if c["id"] == sys.argv[2]]
print(s[0] if s else "NOT-RUN")' "$json" "$2"
}

echo "==> step 1, the stand-in SIEM"
./vm/siem-container.sh up || { echo "FAIL  the receiver did not start"; exit 1; }
before=$(./vm/siem-container.sh records | awk -v h="$host" '$1==h {sub("auditd-records=","",$3); print $3}')

echo "==> step 2, $host forwards to siem.nist-lab (this run only)"
./apply.sh --limit "$host" --tags 03.03.05 \
  -e nist_log_collector=192.168.171.50:6514 -e nist_log_collector_name=siem.nist-lab \
  </dev/null >/dev/null 2>&1 || bad "the apply pointing $host at the receiver failed"
remote "grep -o 'target=\"[^\"]*\" port=\"[^\"]*\"' /etc/rsyslog.d/90-nist-forward.conf; grep -o 'PermittedPeers=\"[^\"]*\"' /etc/rsyslog.d/90-nist-forward.conf" | sed 's/^/    /'

echo "==> step 3, audit events on $host"
remote "for i in \$(seq 20); do cat /etc/shadow >/dev/null; done; sleep 15" >/dev/null

echo "==> step 4, $host's own checks"
for pair in "03.03.05 au-05-forward-established" "03.03.05 au-05-audit-trail-forwarded" \
            "03.13.08 sc-08-forward-encrypted"; do
  set -- $pair; r=$(check "$1" "$2")
  [[ "$r" == PASS ]] && ok "$2" || bad "$2: $r"
done

echo "==> step 4b, the receiver refuses a client with no certificate"
out=$(remote "echo probe | timeout 10 openssl s_client -connect 192.168.171.50:6514 -servername siem.nist-lab -brief 2>&1 | tail -3")
logs=$(sudo podman logs --since 30s nist-siem 2>&1 | grep -iE 'certificate|verify|handshake' | tail -2)
if echo "$out $logs" | grep -qiE 'alert|certificate required|peer did not return|verify|handshake failure'; then
  ok "no client certificate, no session"; echo "    ${logs:0:200}"
else
  bad "a client without a certificate was not refused: ${out:0:200}"
fi

echo "==> step 4c, $host refuses a receiver whose certificate carries another name"
# The baseline is taken only once the apply is done and rsyslog restarted: until
# the handler runs, the old session keeps forwarding the apply's own audit
# records, which once read as thousands of records "sent to the wrong peer".
lines() { ./vm/siem-container.sh records | awk -v h="$host" '$1==h {sub("lines=","",$2); print $2}'; }
./apply.sh --limit "$host" --tags 03.03.05 \
  -e nist_log_collector=192.168.171.50:6514 -e nist_log_collector_name=not-the-siem.nist-lab \
  </dev/null >/dev/null 2>&1 || bad "the apply expecting not-the-siem.nist-lab failed"
peers=$(remote "grep -o 'PermittedPeers=\"[^\"]*\"' /etc/rsyslog.d/90-nist-forward.conf")
remote "sleep 10" >/dev/null
n0=$(lines)
remote "for i in \$(seq 10); do cat /etc/shadow >/dev/null; done; sleep 15" >/dev/null
n1=$(lines)
why=$(remote "journalctl -u rsyslog --since '-40 s' --no-pager -o cat | grep -iE 'not permitted|peer|certificate|x509' | tail -1")
if [[ "$peers" != *not-the-siem.nist-lab* ]]; then
  bad "the forwarding rule does not expect not-the-siem.nist-lab: ${peers:-none}"
elif (( ${n1:-0} - ${n0:-0} == 0 )); then
  ok "nothing reached a peer named siem.nist-lab while $peers was expected"; echo "    ${why:0:200}"
else
  bad "$(( n1 - n0 )) lines still reached the receiver with $peers"
fi

echo "==> step 5, what the receiver holds from $host"
./vm/siem-container.sh records | sed 's/^/    /'
after=$(./vm/siem-container.sh records | awk -v h="$host" '$1==h {sub("auditd-records=","",$3); print $3}')
(( ${after:-0} > ${before:-0} )) && ok "the receiver gained $(( ${after:-0} - ${before:-0} )) auditd records from $host" \
                                 || bad "no new auditd records from $host at the receiver"
sample=$(sudo bash -c "grep -hE 'type=SYSCALL msg=audit\\(' '${NIST_BYO_LAB:-$HOME/.local/share/nist-byo-lab}/siem/log/$host/'*.log 2>/dev/null | tail -1")
[[ -n "$sample" ]] && { ok "a record is legible:"; echo "    ${sample:0:220}"; } || bad "no SYSCALL record to read"

echo "==> step 6, $host back to its own collector"
./apply.sh --limit "$host" --tags 03.03.05 </dev/null >/dev/null 2>&1 || bad "the restoring apply failed"
remote "sleep 5" >/dev/null
r=$(check 03.03.05 au-05-forward-established)
[[ "$r" == PASS ]] && ok "$host forwards to its own collector again" || bad "$host after restore: $r"

if [[ "$keep" != --keep ]]; then echo "==> step 7"; ./vm/siem-container.sh down; fi
echo "==> $([ $fails -eq 0 ] && echo PASS || echo FAIL): forwarding to a foreign receiver from $host ($fails failed)"
exit $(( fails > 0 ))
