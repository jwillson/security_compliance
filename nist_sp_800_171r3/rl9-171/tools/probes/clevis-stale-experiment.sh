#!/usr/bin/env bash
#
# What does a stale clevis tpm2 binding look like, and how is it repaired
# without a terminal? (DEFECTS 6b.5: a firmware or Secure Boot update changes
# PCR 7, and the TPM then refuses the binding at the next boot.) Runs ON the
# target as root via tools/probe.sh. Self-cleaning, away from the real
# volumes: a loop image bound to PCR 16 - the debug PCR, which can be
# extended to make the binding stale and reset afterwards - so Secure Boot and
# PCR 7 are never touched.
#
set -uo pipefail
T=$(mktemp -d /root/clevis-stale.XXXXXX); LOOP=""
cleanup() {
  [ -n "$LOOP" ] && losetup -d "$LOOP" 2>/dev/null
  tpm2_pcrreset 16 >/dev/null 2>&1
  rm -rf "$T"
}
trap cleanup EXIT
say() { echo "exp  $*"; }
pass_ok() { clevis luks pass -d "$LOOP" -s "$1" >/dev/null 2>&1; }   # does the TPM release it?

tpm2_pcrreset 16 >/dev/null 2>&1
head -c 30 /dev/urandom | base64 | tr -d '\n' > "$T/key"
truncate -s 64M "$T/img"; LOOP=$(losetup -f --show "$T/img")
cryptsetup luksFormat --type luks2 --cipher aes-xts-plain64 --key-size 512 --hash sha512 \
  --pbkdf pbkdf2 --pbkdf-force-iterations 100000 --batch-mode "$LOOP" "$T/key" >/dev/null 2>&1
CFG='{"pcr_bank":"sha256","pcr_ids":"16"}'
setsid clevis luks bind -y -k "$T/key" -d "$LOOP" tpm2 "$CFG" < /dev/null >/dev/null 2>&1
slot=$(clevis luks list -d "$LOOP" 2>/dev/null | awk -F: '/tpm2/ {print $1; exit}')
say "bound to PCR 16 in slot ${slot:-none}; TPM releases it: $(pass_ok "$slot" && echo yes || echo no)"

tpm2_pcrextend 16:sha256=$(printf '%064d' 1) >/dev/null
say "after extending PCR 16 (as a firmware update changes PCR 7):"
say "  binding still listed: $(clevis luks list -d "$LOOP" 2>/dev/null | grep -q tpm2 && echo yes || echo no)"
say "  TPM releases it:      $(pass_ok "$slot" && echo yes || echo NO - stale)"

# Repair A: clevis luks regen, fed the passphrase, no terminal.
setsid clevis luks regen -q -d "$LOOP" -s "$slot" < "$T/key" > "$T/regen" 2>&1
rc=$?
nslot=$(clevis luks list -d "$LOOP" 2>/dev/null | awk -F: '/tpm2/ {print $1; exit}')
say "repair A: regen -q with the passphrase on stdin: rc=$rc; slot now ${nslot:-none}; releases: $( [ -n "$nslot" ] && pass_ok "$nslot" && echo yes || echo no)  $(tail -1 "$T/regen" | cut -c1-100)"

if ! { [ -n "$nslot" ] && pass_ok "$nslot"; }; then
  # Repair B: drop the stale slot, bind again with the passphrase key file.
  setsid clevis luks unbind -f -d "$LOOP" -s "$slot" < /dev/null > "$T/unbind" 2>&1
  say "repair B: unbind -f rc=$? $(tail -1 "$T/unbind" | cut -c1-100)"
  setsid clevis luks bind -y -k "$T/key" -d "$LOOP" tpm2 "$CFG" < /dev/null > "$T/rebind" 2>&1
  nslot=$(clevis luks list -d "$LOOP" 2>/dev/null | awk -F: '/tpm2/ {print $1; exit}')
  say "          bind -k again rc=$?; slot ${nslot:-none}; releases: $( [ -n "$nslot" ] && pass_ok "$nslot" && echo yes || echo no)"
fi
say "keyslots at the end: $(cryptsetup luksDump "$LOOP" 2>/dev/null | awk '/^Keyslots:/{k=1;next} /^Tokens:/{k=0} k && /^  [0-9]+: luks2/{printf "%s ", $1}')"
