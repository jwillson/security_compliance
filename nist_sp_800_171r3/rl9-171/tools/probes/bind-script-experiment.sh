#!/usr/bin/env bash
#
# Does the role's bind script work under `set -euo pipefail` on a volume that
# has never been bound, and does each version fail when the bind fails?
# (Review of 2026-09-26, issue #3: main's script lacked set -e, so a failed
# bind printed "bound"; the proposed fix adds it - but its
# first line, slot=$(clevis luks list ... | awk ...), would end the script if
# `clevis luks list` exits non-zero on a volume with no binding.)
# Runs ON the target as root via tools/probe.sh, on a host with a TPM.
# Self-cleaning, away from the real volumes: a 64 MB image on a loop device,
# formatted with the role's luksFormat parameters and a throwaway key.
#
set -uo pipefail
T=$(mktemp -d /root/bindscript.XXXXXX); LOOP=""
cleanup() { [ -n "$LOOP" ] && losetup -d "$LOOP" 2>/dev/null; rm -rf "$T"; }
trap cleanup EXIT
say() { echo "exp  $*"; }

head -c 30 /dev/urandom | base64 | tr -d '\n' > "$T/key"
truncate -s 64M "$T/img"; LOOP=$(losetup -f --show "$T/img")
cryptsetup luksFormat --type luks2 --cipher aes-xts-plain64 --key-size 512 --hash sha512 \
  --pbkdf pbkdf2 --pbkdf-force-iterations 100000 --batch-mode "$LOOP" "$T/key" >/dev/null 2>&1
say "clevis $(rpm -q --qf '%{VERSION}-%{RELEASE}' clevis), tpm $( [ -e /dev/tpmrm0 ] && echo present || echo none)"

clevis luks list -d "$LOOP" > "$T/list.out" 2>&1; rc=$?
say "clevis luks list on an unbound volume: rc=$rc, output: $(head -c 120 "$T/list.out" | tr '\n' ' ')"

# The proposed script, verbatim but for the device and the key path.
cat > "$T/bind.sh" <<EOF
set -euo pipefail
dev=$LOOP
slot=\$(clevis luks list -d "\$dev" 2>/dev/null | awk -F: '/tpm2/ {print \$1; exit}')
if [ -n "\$slot" ] && clevis luks pass -d "\$dev" -s "\$slot" >/dev/null 2>&1; then
  echo "already-bound"
  exit 0
elif [ -n "\$slot" ]; then
  clevis luks regen -q -d "\$dev" -s "\$slot" < $T/key > /dev/null
  result=resealed
else
  clevis luks bind -y -k $T/key \\
    -d "\$dev" tpm2 '{"pcr_bank":"sha256","pcr_ids":"7"}' < /dev/null
  result=bound
fi
slot=\$(clevis luks list -d "\$dev" | awk -F: '/tpm2/ {print \$1; exit}')
[ -n "\$slot" ] || { echo "no tpm2 binding on \$dev after \$result" >&2; exit 1; }
clevis luks pass -d "\$dev" -s "\$slot" > /dev/null \\
  || { echo "the TPM does not release the key for \$dev (slot \$slot) after \$result" >&2; exit 1; }
echo "\$result"
EOF
for run in first second; do
  setsid bash "$T/bind.sh" < /dev/null > "$T/out" 2> "$T/err"; rc=$?
  say "proposed script, $run run: rc=$rc stdout=$(tr '\n' ' ' < "$T/out") stderr=$(head -c 160 "$T/err" | tr '\n' ' ')"
done
say "bindings now: $(clevis luks list -d "$LOOP" 2>&1 | tr '\n' ' ')"

# A bind that fails: a second, never-bound volume and the wrong key. main's
# script (set -o pipefail only) against the proposed one.
truncate -s 64M "$T/img2"; LOOP2=$(losetup -f --show "$T/img2")
cryptsetup luksFormat --type luks2 --pbkdf pbkdf2 --pbkdf-force-iterations 100000 \
  --batch-mode "$LOOP2" "$T/key" >/dev/null 2>&1
echo wrong-key > "$T/wrong"
sed -e "s|dev=$LOOP|dev=$LOOP2|" -e "s|$T/key|$T/wrong|g" "$T/bind.sh" > "$T/bind-proposed-fail.sh"
# main's script at v1.0.0, verbatim but for the device and the key path.
cat > "$T/bind-main-fail.sh" <<EOF
set -o pipefail
dev=$LOOP2
slot=\$(clevis luks list -d "\$dev" 2>/dev/null | awk -F: '/tpm2/ {print \$1; exit}')
if [ -n "\$slot" ] && clevis luks pass -d "\$dev" -s "\$slot" >/dev/null 2>&1; then
  echo "already-bound"
elif [ -n "\$slot" ]; then
  clevis luks regen -q -d "\$dev" -s "\$slot" < $T/wrong > /dev/null
  echo "resealed"
else
  clevis luks bind -y -k $T/wrong \\
    -d "\$dev" tpm2 '{"pcr_bank":"sha256","pcr_ids":"7"}' < /dev/null
  echo "bound"
fi
EOF
for v in main proposed; do
  setsid bash "$T/bind-$v-fail.sh" < /dev/null > "$T/out" 2> "$T/err"; rc=$?
  say "$v script, bind with the wrong key: rc=$rc stdout=$(tr '\n' ' ' < "$T/out") stderr=$(head -c 120 "$T/err" | tr '\n' ' ')"
done
losetup -d "$LOOP2"
