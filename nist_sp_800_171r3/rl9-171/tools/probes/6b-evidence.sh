#!/usr/bin/env bash
#
# Evidence for TASKS.md 6b.2-6b.6, read from effective state on one host.
# Runs ON the target as root; tools/probe.sh ships it there. Read-only: it
# changes nothing, so it can be run before and after a fix to show both.
# Each line is "6b.N  key  value" so two runs diff cleanly.
#
set -uo pipefail
p() { printf '%-5s %-28s %s\n' "$1" "$2" "$3"; }

# --- 6b.2 03.10.07 GRUB superuser password --------------------------------
f=/etc/grub.d/01_users
p 6b.2 01_users-from-package "$(rpm -V grub2-tools 2>/dev/null | grep -q "$f" && echo modified || echo unmodified)"
p 6b.2 01_users-template-only "$(grep -q 'password_pbkdf2 root \\\${GRUB2_PASSWORD}' "$f" 2>/dev/null && echo yes || echo no)"
for u in /boot/grub2/user.cfg /boot/efi/EFI/rocky/user.cfg; do
  p 6b.2 "user.cfg:${u%/user.cfg}" "$( [ -f "$u" ] && { grep -q 'GRUB2_PASSWORD=grub.pbkdf2.' "$u" && echo real-hash || echo present-no-hash; } || echo absent)"
done
real=$(cat /etc/grub.d/01_users /boot/grub2/user.cfg /boot/efi/EFI/rocky/user.cfg 2>/dev/null | grep -c 'grub.pbkdf2.' || true)
p 6b.2 real-pbkdf2-hashes "$real"
p 6b.2 staged-cleartext "$( [ -e /root/.grub-pw ] && echo "/root/.grub-pw present" || echo none)"
# What GRUB actually reads at boot: the generated grub.cfg (the EFI stub only
# points at it), whether it sources user.cfg, and whether the BLS entries it
# boots are unrestricted (bootable without the password).
p 6b.2 efi-stub-points-to "$(grep -oE 'configfile [^ ]+|set prefix=[^ ]+' /boot/efi/EFI/rocky/grub.cfg 2>/dev/null | paste -sd' ' - || true)"
p 6b.2 grub.cfg-sources-user.cfg "$(grep -c 'source ${prefix}/user.cfg' /boot/grub2/grub.cfg 2>/dev/null || echo 0)"
p 6b.2 bls-entries "$(ls /boot/loader/entries/*.conf 2>/dev/null | wc -l) total, $(grep -l 'grub_arg --unrestricted' /boot/loader/entries/*.conf 2>/dev/null | wc -l) unrestricted"
p 6b.2 10_linux-edited "$(rpm -V grub2-tools 2>/dev/null | grep -q /etc/grub.d/10_linux && echo modified || echo unmodified)"

# --- 6b.3 03.01.11 / 03.13.09 SSH idle termination -------------------------
t=$(sshd -T 2>/dev/null)
for k in clientaliveinterval clientalivecountmax channeltimeout unusedconnectiontimeout; do
  p 6b.3 "$k" "$(awk -v k="$k" '$1==k {$1=""; sub(/^ /,""); print}' <<<"$t")"
done
p 6b.3 openssh "$(rpm -q --qf '%{VERSION}' openssh-server)"
p 6b.3 TMOUT "$(grep -rh '^TMOUT=' /etc/profile.d/ 2>/dev/null | head -1 || true)"

# --- 6b.4 03.01.01 / 03.05.12 account aging on every interactive account --
for u in $(awk -F: '($3>=1000 && $3!=65534 && $7 !~ /(nologin|false)$/){print $1}' /etc/passwd); do
  p 6b.4 "aging:$u" "$(awk -F: -v u="$u" '$1==u {printf "min=%s max=%s warn=%s inactive=%s lastchg=%s", $4,$5,$6,$7,$3}' /etc/shadow)"
done

# --- 6b.5 03.08.09 / 03.13.08 where the LUKS key lives ---------------------
p 6b.5 root-on-crypt "$(lsblk -no TYPE "$(findmnt -no SOURCE /)" -s 2>/dev/null | grep -q crypt && echo yes || echo no)"
if [ -s /etc/crypttab ]; then
  while read -r name dev key _; do
    [ -n "$name" ] && [ "${name:0:1}" != "#" ] || continue
    p 6b.5 "crypttab:$name" "key=${key:-none} $( [ -f "${key:-/nonexistent}" ] && echo "(file present, $(stat -c %a "$key"))" )"
  done < /etc/crypttab
else
  p 6b.5 crypttab "empty or absent"
fi
for d in $(lsblk -pnlo NAME,TYPE 2>/dev/null | awk '$2=="lvm"{print $1}'); do
  cryptsetup isLuks "$d" 2>/dev/null || continue
  p 6b.5 "clevis:$(basename "$d")" "$(clevis luks list -d "$d" 2>/dev/null | awk '{print $2}' | paste -sd, - || true)"
done
p 6b.5 tpm "$( [ -e /dev/tpmrm0 ] && echo present || echo none)"
# Why a clevis tpm2 bind would fail: the tooling the role installs with
# failed_when: false, and whether the TPM answers a read of the PCR the
# role seals to (PCR 7). Both read-only.
p 6b.5 clevis-packages "$(rpm -q clevis clevis-luks clevis-systemd clevis-dracut tpm2-tools 2>&1 | sed 's/ is not installed/:MISSING/;s/-[0-9].*//' | paste -sd' ' -)"
if [ -e /dev/tpmrm0 ] && command -v tpm2_pcrread >/dev/null; then
  p 6b.5 tpm-pcr7 "$(tpm2_pcrread sha256:7 2>&1 | awk '/7 *:/ {print "readable"; f=1} END {if (!f) print "UNREADABLE"}')"
  # Seal a throwaway string with the role's exact pin and policy. It writes
  # nothing to disk or to the LUKS headers; only a transient TPM object.
  if command -v clevis >/dev/null; then
    err=$(echo probe | clevis encrypt tpm2 '{"pcr_bank":"sha256","pcr_ids":"7"}' 2>&1 >/dev/null)
    p 6b.5 clevis-tpm2-seal "$([ $? -eq 0 ] && echo works || echo "FAILS: $(echo "$err" | tail -1)")"
  fi
fi

# --- 6b.6 03.03.05c audit records reaching the collector -------------------
p 6b.6 local-audit-records "$(wc -l < /var/log/audit/audit.log 2>/dev/null || echo 0)"
p 6b.6 audisp-syslog-plugin "$(awk -F= '/^[[:space:]]*active/ {gsub(/ /,"",$2); print $2}' /etc/audit/plugins.d/syslog.conf 2>/dev/null || true)"
p 6b.6 rsyslog-imfile-audit "$(grep -rlE 'imfile|audit\.log' /etc/rsyslog.conf /etc/rsyslog.d/ 2>/dev/null | paste -sd, - || true)"
if [ -f /etc/rsyslog.d/10-nist-collector.conf ]; then
  dir=$(sed -n 's/^directory=//p' /etc/nist-800-171/log-collector-status 2>/dev/null)
  for h in "${dir:-/var/log/nist-remote}"/*/; do
    h=${h%/}; [ "$(basename "$h")" = "$(hostname -s)" ] && continue
    all=$(cat "$h"/*.log 2>/dev/null | wc -l)
    # An auditd record reads "type=SYSCALL msg=audit(...)". The kernel prints
    # "audit: type=1131 audit(...)" to kmsg only while auditd is not running
    # (boot, shutdown), and journald passes those on: they are not the trail.
    # A bare "type=" also matches unrelated text (ansible's module arguments).
    aud=$(cat "$h"/*.log 2>/dev/null | grep -cE 'type=[A-Z_]+ msg=audit\(' || true)
    krn=$(cat "$h"/*.log 2>/dev/null | grep -cE 'kernel: audit: type=[0-9]+' || true)
    p 6b.6 "received:$(basename "$h")" "lines=$all auditd-records=$aud kernel-audit-while-auditd-down=$krn"
  done
fi
exit 0
