#!/usr/bin/env bash
#
# The POA&M register survives a spreadsheet round trip (DEFECTS 7.12, issue
# #5): saving it as "CSV UTF-8" puts a byte-order mark before the first
# column name, and the generator then read every POAM ID as empty and wrote
# them back empty. This re-saves HOST's real register that way, runs the
# generator, and requires every ID kept, a backup written, and a scoped
# assessment refused.
#
#   tools/rehearse-poam-spreadsheet.sh HOST
#
# The register is copied aside first and put back at the end. Source the
# lab's env.sh first.
#
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE/.." || exit 2
. lib/ssh-env.sh || exit 2
host=${1:?usage: tools/rehearse-poam-spreadsheet.sh HOST}
R=/etc/nist-800-171/poam.csv KEEP=/root/.nist-poam-rehearsal.csv
fails=0
ok()  { echo "PASS  $*"; }
bad() { echo "FAIL  $*"; fails=$((fails + 1)); }
remote() { ansible "$host" -b -m ansible.builtin.shell -a "$1" </dev/null 2>/dev/null | sed 1d; }
trap 'remote "[ -f $KEEP ] && mv -f $KEEP $R; true" >/dev/null' EXIT

ids() { remote "python3 -c \"import csv; print(sorted(r['POAM ID'] for r in csv.DictReader(open('$R', encoding='utf-8-sig'))))\""; }
before=$(ids)
n=$(grep -o "'" <<<"$before" | wc -l); n=$((n / 2))
echo "==> $host: $n items in the register; re-saving it with a byte-order mark, as a spreadsheet does"
remote "cp -p $R $KEEP && { printf '\xef\xbb\xbf'; cat $KEEP; } > $R && head -c 3 $R | od -An -tx1" | sed 's/^/    first bytes:/'
out=$(remote "/usr/local/sbin/nist-generate-poam 2>&1; echo rc=\$?")
grep -q 'rc=0' <<<"$out" && ok "the generator merged the re-saved register" || bad "the generator: ${out:0:200}"
after=$(ids)
[[ "$after" == "$before" && $n -gt 0 ]] && ok "every POAM ID kept ($n)" || bad "IDs changed: ${after:0:200}"
remote "test -s $R.bak && echo yes" | grep -q yes && ok "the previous register kept as poam.csv.bak" || bad "no poam.csv.bak"
out=$(remote "/usr/local/sbin/nist-assess --requirement 03.04.06 --json /tmp/nist-scoped.json --quiet >/dev/null 2>&1; /usr/bin/python3 /usr/local/sbin/nist_poam.py --assessment /tmp/nist-scoped.json --register $R 2>&1; echo rc=\$?; rm -f /tmp/nist-scoped.json")
grep -q 'refusing: the assessment covers only' <<<"$out" && grep -q 'rc=2' <<<"$out" \
  && ok "an assessment scoped to one requirement is refused" || bad "scoped assessment: ${out:0:200}"
echo "==> $([ $fails -eq 0 ] && echo PASS || echo FAIL): POA&M spreadsheet round trip on $host ($fails failed)"
exit $(( fails > 0 ))
