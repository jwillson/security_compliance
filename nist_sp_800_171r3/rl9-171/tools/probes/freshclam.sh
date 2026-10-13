#!/usr/bin/env bash
#
# Why ClamAV has no signatures on a host (03.14.02; DEFECTS 7.43): the
# installed version, FIPS mode, the cool-down freshclam records after the CDN
# refuses it, what the CDN answers freshclam's user agent, and one verbose
# freshclam run into a scratch directory - so the cause is printed, not
# guessed. Run as root by tools/probe.sh:
#
#   tools/probe.sh freshclam rl9-cui-01
#
# The host's own state is left alone: the run downloads into a directory of
# its own (--datadir), whose cool-down file is not the host's, and removes
# it. It does fetch the databases once (about 300 MB), so run it on one host
# at a time - several hosts behind one address are what the CDN rate-limits.
#
ver=$(rpm -q --qf '%{VERSION}' clamav 2>/dev/null) || { echo "clamav: not installed"; exit 0; }
echo "clamav:        $ver ($(rpm -q --qf '%{VERSION}-%{RELEASE}' clamav-freshclam 2>/dev/null))"
echo "fips:          $(fips-mode-setup --check 2>&1 | tail -1)"
echo "unit:          clamav-freshclam $(systemctl is-enabled clamav-freshclam 2>&1)/$(systemctl is-active clamav-freshclam 2>&1)"
cool=$(journalctl -u clamav-freshclam --no-pager -q -n 200 2>/dev/null | grep -o 'cool-down until after: .*' | tail -1)
echo "cool-down:     ${cool:-none recorded}"
echo "databases:     $(ls /var/lib/clamav 2>/dev/null | grep -E '\.c[vl]d$' | xargs echo)"
ua="ClamAV/$ver (OS: linux-gnu, ARCH: $(uname -m), CPU: $(uname -m))"
echo "cdn:           $(curl -s -o /dev/null -w '%{http_code}' -r 0-511 -A "$ua" https://database.clamav.net/daily.cvd) for daily.cvd as $ua"
echo "dns current:   $(dig +short TXT current.cvd.clamav.net 2>/dev/null || echo 'no dig')"

d=$(mktemp -d /var/tmp/nist-freshclam-probe.XXXXXX)
chown clamupdate: "$d" 2>/dev/null
echo "--- freshclam --datadir $d --verbose"
timeout 900 freshclam --datadir="$d" --verbose --stdout --foreground 2>&1 \
  | grep -v -E '^\s*$|Downloading .*\[.*%\]' | tail -40
echo "--- exit ${PIPESTATUS[0]}; downloaded: $(ls "$d" 2>/dev/null | grep -E '\.c[vl]d$' | xargs echo)"
rm -rf "$d"
