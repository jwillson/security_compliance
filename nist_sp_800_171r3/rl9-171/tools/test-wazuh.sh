#!/usr/bin/env bash
#
# Does Wazuh standalone catch malicious code as it arrives (nist_wazuh role,
# 03.14.02; the Wazuh trial)? On HOST, as root:
#
#   1. the EICAR test file is written to /home/<admin>/: it must be gone from
#      there and in /var/lib/nist-quarantine within 60 s, root-only;
#   2. alerts.json must hold rule 100100 for it;
#   3. the collector must hold the alert, forwarded over 03.03.05c's TLS;
#   4. the longest alert this rule can raise - the test file again, under a
#      path of ~4000 characters, Linux's limit being 4096 - must reach the
#      collector whole. It is about 6 KB, under rsyslog's 8 KB message, so
#      these alerts are not cut (the trial asked whether they would be);
#   and Wazuh's memory is read before and after.
#
#   tools/test-wazuh.sh rl9-cui-01 rl9-log-01
#
# Everything it writes on HOST is quarantined by Wazuh or removed. Runs in the
# control-plane container, with the inventory of the lab that lists HOST.
#
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../lib/container.sh"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
cd "$ROOT" || exit 2
host=${1:?usage: tools/test-wazuh.sh HOST COLLECTOR} collector=${2:?usage: tools/test-wazuh.sh HOST COLLECTOR}
NIST_FOR_HOST=$host . lib/ssh-env.sh || exit 2      # the lab whose inventory lists HOST
OUT="$ROOT/reports/runs/test-wazuh-$host-$(date -u +%Y%m%dT%H%M%SZ)"; mkdir -p "$OUT"
fails=0
ok()  { echo "PASS  $*"; }
bad() { echo "FAIL  $*"; fails=$((fails + 1)); }
on() {   # HOST SCRIPT: run as root, print its output
  ansible "$1" -b -m ansible.builtin.shell -a "$2" -o 2>/dev/null | python3 -c '
import json, re, sys
for line in sys.stdin:
    m = re.match(r"^\S+ \| \w+.*?=> (\{.*\})\s*$", line)
    if m:
        print(json.loads(m.group(1)).get("stdout", ""))
    else:
        m = re.match(r"^\S+ \| \w+ \| rc=\d+ \| \(stdout\) (.*)$", line)
        print(m.group(1).replace("\\n", "\n") if m else line.rstrip())'
}
mem() { on "$host" "ps -eo rss=,comm= | awk '\$2 ~ /^(wazuh|python)/ {s += \$1} END {printf \"%.0f\", s/1024}'"; }

tag=nisttest$(date +%s)
before=$(mem)
echo "==> Wazuh on $host: ${before} MB resident before"

# 1. The test file, written where a download lands.
on "$host" "u=\$(getent passwd 1000 | cut -d: -f6); f=\$u/$tag.com
printf '%s' 'X5O!P%@AP[4\\PZX54(P^)7CC)7}\$EICAR-STANDARD-ANTIVIRUS-TEST-FILE!\$H+H*' > \"\$f\"
for i in \$(seq 1 60); do [ -e \"\$f\" ] || break; sleep 1; done
if [ -e \"\$f\" ]; then echo still-there; rm -f \"\$f\"; else echo gone-after \$i; fi
ls -l /var/lib/nist-quarantine/ | grep $tag" > "$OUT/eicar.txt"
if grep -q gone-after "$OUT/eicar.txt" && grep -qE -- "^-r--------\.? +1 root root .*$tag.com" "$OUT/eicar.txt"; then
  ok "the test file was quarantined, root-only, $(grep -o 'gone-after [0-9]*' "$OUT/eicar.txt" | cut -d' ' -f2) s after it was written"
else
  bad "the test file was not quarantined ($(tr '\n' ' ' < "$OUT/eicar.txt"))"
fi

# 2. The local alert.
on "$host" "grep '$tag' /var/ossec/logs/alerts/alerts.json | grep '\"id\":\"100100\"' | tail -1" > "$OUT/alert.json"
if grep -q '"id":"100100"' "$OUT/alert.json"; then ok "alerts.json holds rule 100100 for it"
else bad "no rule 100100 alert in alerts.json"; fi

# 3. The collector's copy (and the quarantine message from the response).
sleep 10
on "$collector" "grep -rh '$tag' /var/log/nist-remote/$host/ 2>/dev/null | grep -E 'wazuh-alert|nist-quarantine'" > "$OUT/collector.txt"
if grep 'wazuh-alert' "$OUT/collector.txt" | grep -q '"id":"100100"'; then ok "the collector holds the alert"
else bad "the collector has no rule 100100 alert for it (/var/log/nist-remote/$host/)"; fi
grep 'nist-quarantine' "$OUT/collector.txt" | grep -q 'quarantined' && ok "the collector holds the quarantine record" \
  || bad "the collector has no quarantine record"

# 4. An alert past 8 KB: the same file under a ~4000-character path.
long=$tag-long
on "$host" "u=\$(getent passwd 1000 | cut -d: -f6); d=\$u/$long; p=\$d
for i in \$(seq 1 15); do p=\$p/$(printf 'x%.0s' $(seq 1 250)); done
mkdir -p \"\$p\" && printf '%s' 'X5O!P%@AP[4\\PZX54(P^)7CC)7}\$EICAR-STANDARD-ANTIVIRUS-TEST-FILE!\$H+H*' > \"\$p/$long.com\"
sleep 30; rm -rf \"\$d\"
grep '$long' /var/ossec/logs/alerts/alerts.json | grep '\"id\":\"100100\"' | tail -1 | wc -c" > "$OUT/long-local.txt"
sleep 10
# Parsed where it landed: the JSON's own \n escapes would not survive the
# trip back through ansible's one-line output.
on "$collector" "grep -rh '$long' /var/log/nist-remote/$host/ 2>/dev/null | grep wazuh-alert | grep '\"id\":\"100100\"' | tail -1 \
  | python3 -c 'import json, sys; l = sys.stdin.read(); json.loads(l[l.index(\"{\"):]); print(\"whole\", len(l))' 2>&1 | tail -1" > "$OUT/long-collector.txt"
local_len=$(tail -1 "$OUT/long-local.txt" | tr -dc 0-9)
if (( ${local_len:-0} > 4096 )); then
  if grep -q '^whole' "$OUT/long-collector.txt"; then
    ok "the longest alert, ${local_len} bytes, reached the collector whole ($(cut -d' ' -f2 "$OUT/long-collector.txt") with its syslog header)"
  else
    bad "the ${local_len}-byte alert did not reach the collector whole ($(cat "$OUT/long-collector.txt"))"
  fi
else
  bad "the long alert was not raised (${local_len:-0} bytes locally)"
fi

after=$(mem)
echo "==> Wazuh on $host: ${after} MB resident after"
echo "==> $([ $fails -eq 0 ] && echo PASS || echo FAIL): Wazuh standalone ($fails failed) - $OUT"
(( fails == 0 ))
