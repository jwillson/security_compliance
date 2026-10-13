#!/usr/bin/env bash
#
# Wazuh standalone on a CUI host (nist_wazuh role, 03.14.02; the Wazuh trial):
# is it running, what it said, what fapolicyd and SELinux refused it, what it
# listens on, what memory it takes, and who signed it. Read-only; run as root
# by tools/probe.sh:
#
#   tools/probe.sh wazuh rl9-cui-01
#
rpm -q wazuh-manager >/dev/null 2>&1 || { echo "wazuh-manager: not installed"; exit 0; }
echo "package:       $(rpm -q wazuh-manager)  signed: $(rpm -q --qf '%{RSAHEADER:pgpsig}' wazuh-manager)"
echo "service:       $(systemctl is-enabled wazuh-manager 2>&1)/$(systemctl is-active wazuh-manager 2>&1)"
echo "--- wazuh-control status"
/var/ossec/bin/wazuh-control status 2>&1 | sed 's/^/  /'
echo "--- listening (wazuh processes)"
ss -tulpnH 2>/dev/null | grep -E 'wazuh|ossec|python' | awk '{print "  " $1, $5, $7}'
echo "--- memory (RSS, MB)"
ps -eo rss=,comm= | awk '$2 ~ /^(wazuh|ossec|python)/ {s += $1; printf "  %-22s %6.1f\n", $2, $1/1024} END {printf "  %-22s %6.1f\n", "total", s/1024}'
echo "--- ossec.log, errors and the last lines"
grep -E 'ERROR|CRITICAL|WARNING' /var/ossec/logs/ossec.log 2>/dev/null | tail -15 | sed 's/^/  /'
tail -8 /var/ossec/logs/ossec.log 2>/dev/null | sed 's/^/  /'
echo "--- the unit's journal"
journalctl -u wazuh-manager --no-pager -n 15 -q 2>/dev/null | sed 's/^/  /'
echo "--- fapolicyd denials since the last hour"
ausearch -m FANOTIFY -ts recent -i 2>/dev/null | grep -oE 'path=[^ ]+|exe=[^ ]+' | sort | uniq -c | sort -rn | head -10 | sed 's/^/  /'
journalctl -u fapolicyd --since -1h --no-pager -q 2>/dev/null | grep -i deny | tail -8 | sed 's/^/  /'
echo "--- SELinux denials since the last hour"
ausearch -m AVC -ts recent -i 2>/dev/null | grep -oE 'comm=[^ ]+ .*name=[^ ]+|scontext=[^ ]+ tcontext=[^ ]+' | sort | uniq -c | sort -rn | head -8 | sed 's/^/  /'
