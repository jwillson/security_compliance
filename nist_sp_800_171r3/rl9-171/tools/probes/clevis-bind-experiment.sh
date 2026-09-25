#!/usr/bin/env bash
#
# Why does the role's `clevis luks bind ... tpm2` exit 1 with no output
# (DEFECTS 6b.5)? Runs ON the target as root via tools/probe.sh.
# Self-cleaning and away from the real volumes: a 64 MB image on a loop
# device, formatted with the role's exact luksFormat parameters and a
# throwaway key, bound with the role's exact clevis command under `bash -x`,
# then detached and deleted. The TPM gets a transient object only.
#
set -uo pipefail
T=$(mktemp -d /root/clevis-exp.XXXXXX); LOOP=""
cleanup() { [ -n "$LOOP" ] && losetup -d "$LOOP" 2>/dev/null; rm -rf "$T"; }
trap cleanup EXIT
say() { echo "exp  $*"; }

head -c 30 /dev/urandom | base64 | tr -d '\n' > "$T/key"   # no trailing newline, like the role's key file
truncate -s 64M "$T/img"
LOOP=$(losetup -f --show "$T/img") || { say "losetup failed"; exit 0; }
say "fips_enabled=$(cat /proc/sys/crypto/fips_enabled)  clevis=$(rpm -q --qf '%{VERSION}' clevis)  cryptsetup=$(rpm -q --qf '%{VERSION}' cryptsetup)"

cryptsetup luksFormat --type luks2 --cipher aes-xts-plain64 --key-size 512 \
  --hash sha512 --pbkdf pbkdf2 --pbkdf-force-iterations 100000 --batch-mode \
  "$LOOP" "$T/key" > "$T/fmt" 2>&1
say "luksFormat (role's parameters) rc=$? $(tail -1 "$T/fmt")"

# Detached from any terminal (setsid, stdin /dev/null), as the role's task
# is: a prompt then fails at once instead of waiting for an answer.
bind() {  # label args...
  local label=$1; shift
  setsid clevis luks bind "$@" < /dev/null > "$T/out" 2> "$T/err"
  local rc=$?
  say "$label rc=$rc $(grep -v '^$' "$T/err" | tail -1 | cut -c1-150)"
  say "  bindings now: $(clevis luks list -d "$LOOP" 2>&1 | tr '\n' ' ')"
}
CFG='{"pcr_bank":"sha256","pcr_ids":"7"}'
# 1. The role's order: getopts stops at the first positional (the pin), so
#    -k and -y after it are never parsed and clevis prompts for the password.
bind "role's order   (-d DEV tpm2 CFG -k KEY -y)" -d "$LOOP" tpm2 "$CFG" -k "$T/key" -y
# 2. The documented order: options first, then -d DEV PIN CFG.
bind "options first  (-y -k KEY -d DEV tpm2 CFG)" -y -k "$T/key" -d "$LOOP" tpm2 "$CFG"
# 3. Does the binding unlock with nothing but the TPM? (bind adds a new
#    random key in its own slot, sealed to the TPM; it does not wrap the
#    passphrase, so the test is an actual unlock, not a key comparison.)
name="clevisexp$$"
if setsid clevis luks unlock -d "$LOOP" -n "$name" < /dev/null > /dev/null 2> "$T/unlock" \
   && [ -e "/dev/mapper/$name" ]; then
  say "clevis luks unlock with the TPM alone: opened /dev/mapper/$name"
  cryptsetup close "$name"
else
  say "clevis luks unlock FAILED: $(tail -1 "$T/unlock")"
fi
say "keyslots: $(cryptsetup luksDump "$LOOP" 2>/dev/null | awk '/^Keyslots:/{k=1;next} /^Tokens:/{k=0} k && /^  [0-9]+: luks2/{printf "%s ", $1} k && /PBKDF:/{printf "(%s) ", $2}')"
