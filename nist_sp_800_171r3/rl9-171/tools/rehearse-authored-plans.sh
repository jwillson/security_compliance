#!/usr/bin/env bash
#
# Prove that what the owner writes into the SSP and the POA&M survives every
# regeneration (DEFECTS 6.6: both generators used to destroy it).
#
#   tools/rehearse-authored-plans.sh HOST
#
#   1. apply the planning tasks with authored SSP sections supplied through
#      NIST_SSP_DIR (a temporary directory on this workstation);
#   2. fill an owner column in the POA&M register on the host;
#   3. run the scheduled assessment service, which regenerates both plans;
#   4. apply the planning tasks again;
#   5. after each regeneration: the SSP carries the authored text and lists
#      the sections as authored, and the owner's POA&M entry is still there;
#   6. remove the rehearsal text again - a lab host must not look authored.
#
# PASS/FAIL per step; exit 0 only if all pass. Source the lab's env.sh (or
# the kickstart shell) first.
#
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE/.."
. lib/ssh-env.sh || exit 2
nist_seed_known_hosts
host=${1:?usage: tools/rehearse-authored-plans.sh HOST}
MARK="rehearsal-$(date -u +%Y%m%dT%H%M%SZ)"
fails=0
ok()  { echo "PASS  $*"; }
bad() { echo "FAIL  $*"; fails=$((fails + 1)); }
remote() { ansible "$host" -b -m ansible.builtin.shell -a "$1" </dev/null 2>/dev/null | sed 1d; }
apply_plans() { ./apply.sh --limit "$host" --tags 03.15.02,03.12.01,03.12.02 </dev/null >/dev/null 2>&1; }

# Step 1 overwrites and step 6 deletes the three authored sections, so a host
# that already carries any of them is refused: rehearse on a lab guest, not
# on a host whose owner has written its plan (issue #6). `|| true`, so the
# ad-hoc command succeeds on a clean host - a failed one echoes its own
# command line, which names the files and would read as a match.
authored=$(remote "ls /etc/nist-800-171/ssp.d/0{2,3,7}-*.md 2>/dev/null || true" | tr '\n' ' ')
if [[ -n "${authored// /}" ]]; then
  echo "error: $host already carries authored SSP sections ($authored); this rehearsal would overwrite and delete them" >&2
  exit 2
fi

SSP_SRC=$(mktemp -d); trap 'rm -rf "$SSP_SRC"' EXIT
printf '%s\n' "Information types: $MARK - lab system, no CUI." > "$SSP_SRC/02-information-types.md"
printf '%s\n' "Threats of concern: $MARK." > "$SSP_SRC/03-threats.md"
printf '%s\n' "| System Owner | $MARK | Accepts residual risk |" > "$SSP_SRC/07-roles.md"

check_plans() {   # label
  local out
  out=$(remote "grep -c '$MARK' /etc/nist-800-171/system-security-plan.md; \
                grep -c 'not yet written' /etc/nist-800-171/system-security-plan.md; \
                grep -c ',$MARK,' /etc/nist-800-171/poam.csv")
  local text sections owner
  read -r text sections owner <<<"$(echo $out)"
  [[ "$text" == 3 ]] && ok "$1: the SSP carries all three authored sections" \
                     || bad "$1: the SSP carries $text of 3 authored sections"
  [[ "$sections" == 0 ]] && ok "$1: the SSP lists every section as authored" \
                         || bad "$1: the SSP still lists $sections section(s) as not yet written"
  [[ "$owner" == 1 ]] && ok "$1: the owner's POA&M entry is still there" \
                      || bad "$1: the owner's POA&M entry is gone ($owner)"
}

echo "==> $host: step 1, apply with NIST_SSP_DIR"
NIST_SSP_DIR="$SSP_SRC" NIST_ALLOW_ENV_SECRETS="${NIST_ALLOW_ENV_SECRETS:-}" apply_plans \
  || bad "apply with NIST_SSP_DIR failed"

echo "==> step 2, the owner fills Responsible Party on the first open item"
remote "systemctl start nist-assessment.service" >/dev/null   # a register to edit
remote "python3 - <<'PY'
import csv
p = '/etc/nist-800-171/poam.csv'
rows = list(csv.DictReader(open(p)))
rows[0]['Responsible Party'] = '$MARK'
w = csv.DictWriter(open(p, 'w', newline=''), fieldnames=list(rows[0].keys()))
w.writeheader(); w.writerows(rows)
PY" >/dev/null

echo "==> step 3, the scheduled assessment service (assess, then both generators)"
res=$(remote "systemctl start nist-assessment.service; systemctl show nist-assessment.service -p Result --value")
[[ "$res" == success ]] && ok "the assessment service completed (Result=$res)" \
                        || bad "the assessment service did not complete (Result=$res)"
check_plans "after the assessment service"

echo "==> step 4, apply again"
apply_plans || bad "the second apply failed"
check_plans "after a second apply"

echo "==> step 6, removing the rehearsal text"
remote "rm -f /etc/nist-800-171/ssp.d/0{2,3,7}-*.md; \
        sed -i 's/,$MARK,/,,/' /etc/nist-800-171/poam.csv; \
        /usr/local/sbin/nist-generate-ssp >/dev/null" >/dev/null
left=$(remote "grep -c '$MARK' /etc/nist-800-171/system-security-plan.md /etc/nist-800-171/poam.csv | awk -F: '{s+=\$2} END {print s+0}'")
[[ "$left" == 0 ]] && ok "no rehearsal text left on the host" || bad "$left rehearsal line(s) left"

echo "==> $([ $fails -eq 0 ] && echo PASS || echo FAIL): authored plans on $host ($fails failed)"
exit $(( fails > 0 ))
