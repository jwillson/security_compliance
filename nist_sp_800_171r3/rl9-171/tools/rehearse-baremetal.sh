#!/usr/bin/env bash
#
# Rehearse a bare-metal install in the lab (DEFECTS 7.35): build the install
# ISO with install/iso.sh, exactly as for a real machine, and boot a lab
# guest from it as a plain CD-ROM - what a BMC's virtual media is - with UEFI
# and Secure Boot, no TPM (the owner's spare machine), and its disk known
# only by its by-id name. Nothing is injected: what the ISO carries is all
# the guest gets.
#
#   tools/rehearse-baremetal.sh            fresh: build, install, check; then remove
#   tools/rehearse-baremetal.sh --keep     leave rl9-bm-01 up to inspect
#
# It works as an operator would, with nothing from the kickstart lab's
# .secrets/: a throwaway RSA key and password made for the run (0600 in its
# run directory), the password factor from an askpass that reads it, and the
# host registered as one you brought (--connection byo) in its own
# inventory, inventory/baremetal.yml. Checks:
#   1. the ISO builds and the guest installs itself from it, unattended
#   2. SSH reaches the installed guest with the run's key
#   3. tools/probes/hardware.sh on it: UEFI, no TPM, the disk by its id
#   4. ./apply.sh through ./nist, with the run's become password, askpass,
#      LUKS passphrase and GRUB password
#   5. a reboot that stops for the LUKS passphrase - no TPM, so no key on
#      disk and nothing to unlock alone (ODP-REVIEW I5) - answered at the
#      serial console by tools/console.py (the ISO is built with --console
#      ttyS0 so the prompt is where it can type); a boot that reaches its
#      login prompt unasked fails
#   6. ./verify.sh through ./nist: mp-09-luks-tpm-bound and
#      mp-09-luks-no-key-on-disk pass on a host without a TPM; every other
#      FAIL is listed
# Then the guest, its disk, NVRAM, logs, the staged ISO and its inventory entry
# are removed, and tools/lab-residue.sh must find no orphan. Evidence in
# reports/runs/rehearse-baremetal-UTC/. Exit 0 only if every check passes.
# The guest's address is forgotten from ~/.ssh/known_hosts before and after:
# the host is registered as one you brought, whose key lives there, and lab
# addresses are handed out again. tools/console.py needs pexpect, from the
# lab's tooling (vm/byo-lab-init.sh).
#
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
cd "$ROOT" || exit 2
keep=0; [[ "${1:-}" == --keep ]] && keep=1
NAME=rl9-bm-01 SERIALNO=NISTBM01 URI=qemu:///system
export NIST_INVENTORY=inventory/baremetal.yml
IMAGES=/var/lib/libvirt/images
OUT="$ROOT/reports/runs/rehearse-baremetal-$(date -u +%Y%m%dT%H%M%SZ)"; mkdir -p "$OUT"; chmod 700 "$OUT"
SERIAL=/var/log/libvirt/qemu/$NAME-serial.log
V=(sudo virsh -c "$URI")
fails=0
ok()  { echo "PASS  $*" | tee -a "$OUT/summary.txt"; }
bad() { echo "FAIL  $*" | tee -a "$OUT/summary.txt"; fails=$((fails + 1)); }
say() { echo "==> $(date -u +%H:%M) $*" | tee -a "$OUT/summary.txt"; }

"${V[@]}" dominfo "$NAME" >/dev/null 2>&1 && { echo "error: $NAME exists - a rehearsal left behind; remove it first" >&2; exit 2; }
./vm/lab-network.sh ensure >/dev/null

cleanup() {
  (( keep )) && { say "kept $NAME (--keep): ssh -i $OUT/id_rsa cuiadmin@${ip:-?}; remove with ./vm/build-vm.sh --name $NAME --destroy"; return; }
  say "removing $NAME and what it left"
  "${V[@]}" destroy "$NAME" >/dev/null 2>&1
  "${V[@]}" undefine "$NAME" --nvram --remove-all-storage >/dev/null 2>&1
  sudo rm -f "$IMAGES/$NAME-install.iso" "$SERIAL" "/var/log/libvirt/qemu/$NAME.log"
  rm -f "iso/$NAME-install.iso"
  ./tools/inventory.py remove "$NAME" >/dev/null 2>&1
  [[ -n "${ip:-}" ]] && ssh-keygen -R "$ip" -f "$HOME/.ssh/known_hosts" >/dev/null 2>&1
  if ./tools/lab-residue.sh --orphans > "$OUT/residue.txt" 2>&1; then ok "nothing left behind (tools/lab-residue.sh --orphans)"
  else bad "residue after cleanup: $(grep orphan "$OUT/residue.txt" | head -3 | tr '\n' ' ')"; fi
}
trap 'cleanup; echo "==> $([ $fails -eq 0 ] && echo PASS || echo FAIL): bare-metal rehearsal ($fails failed) - $OUT"; exit $(( fails > 0 ))' EXIT

# The operator's credentials, made for this run.
ssh-keygen -q -t rsa -b 3072 -N '' -C "rehearse-baremetal" -f "$OUT/id_rsa"
openssl rand -base64 18 > "$OUT/password"
openssl rand -base64 24 > "$OUT/luks_passphrase"
openssl rand -base64 18 > "$OUT/grub_password"
printf '#!/bin/sh\nexec cat "%s"\n' "$OUT/password" > "$OUT/askpass.sh"; chmod 700 "$OUT/askpass.sh"

# --- 1. build and install ----------------------------------------------------
say "1. the install ISO, then an unattended install from it"
if NIST_BECOME_PASSWORD="$(cat "$OUT/password")" ./install/iso.sh "$NAME" \
     --disk "/dev/disk/by-id/virtio-$SERIALNO" --key "$OUT/id_rsa.pub" --console ttyS0 > "$OUT/iso.log" 2>&1; then
  ok "install/iso.sh built iso/$NAME-install.iso"
else bad "ISO build (iso.log): $(tail -3 "$OUT/iso.log" | tr '\n' ' ')"; exit 1; fi
# qemu cannot read under $HOME; the libvirt image directory it can.
sudo install -m 0644 "iso/$NAME-install.iso" "$IMAGES/$NAME-install.iso"

sudo rm -f "$SERIAL"
say "installing $NAME from the CD-ROM alone (expect 15-25 min)"
timeout 7200 sudo virt-install --connect "$URI" --name "$NAME" --memory 4096 --vcpus 2 \
  --cpu host-passthrough --machine q35 \
  --boot "uefi,firmware.feature0.name=secure-boot,firmware.feature0.enabled=yes,firmware.feature1.name=enrolled-keys,firmware.feature1.enabled=yes" \
  --tpm none --disk "size=40,format=qcow2,bus=virtio,serial=$SERIALNO" \
  --cdrom "$IMAGES/$NAME-install.iso" --network network=nist-lab,model=virtio --graphics none \
  --serial "pty,log.file=$SERIAL" --console pty,target_type=serial --os-variant rocky9 \
  --noautoconsole --wait -1 > "$OUT/virt-install.log" 2>&1
vi_rc=$?
if (( vi_rc == 0 )); then ok "$NAME installed itself from the ISO (virt-install rc 0)"
else bad "install: rc=$vi_rc"; ./tools/install-log.sh "$SERIAL" > "$OUT/install-log.txt" 2>&1; sed 's/^/    /' "$OUT/install-log.txt" | tail -15; fi

# --- 2. SSH ------------------------------------------------------------------
say "2. SSH with the run's key"
ip=""
for _ in $(seq 1 60); do
  ip=$("${V[@]}" domifaddr "$NAME" --source lease 2>/dev/null | awk '/ipv4/ {split($4, a, "/"); print a[1]; exit}')
  [[ -n "$ip" ]] && break; sleep 5
done
SSH=(ssh -i "$OUT/id_rsa" -o UserKnownHostsFile="$OUT/known_hosts" -o StrictHostKeyChecking=accept-new
     -o BatchMode=yes -o ConnectTimeout=5 "cuiadmin@$ip")
ssh_ok=0
for _ in $(seq 1 60); do
  [[ -n "$ip" ]] || break
  "${SSH[@]}" true > /dev/null 2>&1 && { ssh_ok=1; break; }
  sleep 5
done
(( ssh_ok )) && ok "SSH to $NAME ($ip) as cuiadmin with the run's key" || bad "no SSH to $NAME (${ip:-no address})"

# --- 3. what the machine offers ----------------------------------------------
say "3. tools/probes/hardware.sh on $NAME"
if (( ssh_ok )); then
  pw=$(cat "$OUT/password")
  # sudo reads the password from stdin (-S), never a command line.
  "${SSH[@]}" "sudo -S -p '' bash -s" < <(printf '%s\n' "$pw"; cat tools/probes/hardware.sh) > "$OUT/hardware.txt" 2>&1
  sed 's/^/    /' "$OUT/hardware.txt"
  if grep -q '^firmware *UEFI' "$OUT/hardware.txt" && grep -q '^tpm *none' "$OUT/hardware.txt" \
     && grep -q "virtio-$SERIALNO" "$OUT/hardware.txt"; then
    ok "the probe sees UEFI, no TPM, and the disk by its id"
  else bad "probe output unexpected (hardware.txt)"; fi
else bad "probe skipped: no SSH"; fi

# --- 4. apply ----------------------------------------------------------------
say "4. ./apply.sh, as an operator would, through ./nist"
PY="${NIST_BYO_LAB:-$HOME/.local/share/nist-byo-lab}/venv/bin/python"
export NIST_BECOME_PASSWORD="$(cat "$OUT/password")" NIST_LUKS_PASSPHRASE="$(cat "$OUT/luks_passphrase")"
export NIST_GRUB_PASSWORD="$(cat "$OUT/grub_password")" SSH_ASKPASS="$OUT/askpass.sh" SSH_ASKPASS_REQUIRE=force
unset NIST_PKI_DIR
applied=0
if (( ssh_ok )); then
  ssh-keygen -R "$ip" -f "$HOME/.ssh/known_hosts" >/dev/null 2>&1
  ./tools/inventory.py add "$NAME" --ip "$ip" --user cuiadmin --connection byo --key "$OUT/id_rsa" > /dev/null
  ./nist ./apply.sh --limit "$NAME" > "$OUT/apply.log" 2>&1
  if grep -qE "^$NAME +:.* unreachable=0 +failed=0" "$OUT/apply.log"; then
    applied=1; ok "apply: $(grep -E "^$NAME +:" "$OUT/apply.log" | tr -s ' ')"
  else bad "apply (apply.log): $(grep -E "^$NAME +:|fatal" "$OUT/apply.log" | head -2 | tr '\n' ' ')"; fi
  grep -q 'every boot waits' "$OUT/apply.log" && echo "    the role said: no TPM, every boot asks for the passphrase (I5)"
else bad "apply skipped: no SSH"; fi

# --- 5. a reboot that asks -----------------------------------------------------
say "5. reboot: it must stop for the LUKS passphrase"
answered=0
if (( applied )); then
  if [[ ! -x "$PY" ]] || ! "$PY" -c 'import pexpect' 2>/dev/null; then bad "no pexpect at $PY (vm/byo-lab-init.sh)"
  else
    answered=$(NIST_CONSOLE_PASSWORD="$NIST_BECOME_PASSWORD" "$PY" - "$NAME" <<'PYCON' 2> "$OUT/console.err"
import os, subprocess, sys
sys.path.insert(0, "tools")
import console
name = sys.argv[1]
con = console.Console(name, user="cuiadmin")
subprocess.run(["sudo", "virsh", "-c", "qemu:///system", "reboot", name], check=True, capture_output=True)
n = con.answer_passphrases(os.environ["NIST_LUKS_PASSPHRASE"],
                           r"[Pp]assphrase for (disk )?[^\r\n]*(cui_data|cui_backup|lv_cui|lv_backup)")
print(n)
con.close()
PYCON
)
    if [[ "$answered" =~ ^[1-9] ]]; then ok "the boot stopped for the passphrase and went on once it was typed ($answered prompt(s))"
    else bad "reboot: ${answered:-no answer} ($(tail -2 "$OUT/console.err" | tr '\n' ' '))"; fi
  fi
else bad "reboot skipped: not applied"; fi

# --- 6. verify -----------------------------------------------------------------
say "6. ./verify.sh through ./nist"
if [[ "$answered" =~ ^[1-9] ]]; then
  for _ in $(seq 1 60); do
    ssh -i "$OUT/id_rsa" -o UserKnownHostsFile="$HOME/.ssh/known_hosts" -o BatchMode=no -o ConnectTimeout=5 \
      -o PreferredAuthentications=publickey,password -o NumberOfPasswordPrompts=1 "cuiadmin@$ip" true </dev/null >/dev/null 2>&1 && break
    sleep 5
  done
  ./nist ./verify.sh --host "$NAME" > "$OUT/verify.log" 2>&1
  json=$(sed -n 's/^ *results: *//p' "$OUT/verify.log" | tail -1)
  if [[ -f "$json" ]]; then
    python3 - "$json" > "$OUT/verify-summary.txt" <<'PYV'
import json, sys
d = json.load(open(sys.argv[1]))
checks = {c["id"]: c for r in d.get("requirements", []) for c in r.get("checks", [])} if "requirements" in d else {}
want = ["mp-09-luks-tpm-bound", "mp-09-luks-no-key-on-disk"]
for w in want:
    c = checks.get(w, {})
    print(f"{w} {c.get('status', 'missing')}")
failed = sorted(i for i, c in checks.items() if c.get("status") == "FAIL")
print("failed " + (" ".join(failed) if failed else "none"))
PYV
    sed 's/^/    /' "$OUT/verify-summary.txt"
    if grep -q '^mp-09-luks-tpm-bound PASS' "$OUT/verify-summary.txt" && grep -q '^mp-09-luks-no-key-on-disk PASS' "$OUT/verify-summary.txt"; then
      ok "no TPM: the volumes open from the console passphrase alone - both mp-09 checks pass"
    else bad "the mp-09 checks did not pass (verify-summary.txt)"; fi
    grep -q '^failed none' "$OUT/verify-summary.txt" && ok "verify: nothing failed" || bad "verify: $(grep '^failed' "$OUT/verify-summary.txt")"
  else bad "verify produced no results (verify.log: $(tail -3 "$OUT/verify.log" | tr '\n' ' '))"; fi
else bad "verify skipped: the reboot did not complete"; fi
