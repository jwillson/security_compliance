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
# .secrets/: a throwaway RSA key and secrets made for the run (0600 in its
# run directory), written into the run's own vault, inventory/baremetal.vault.yml
# (tools/vault.sh --from; its password a file in the run directory) - the
# operator's path of TASKS C3 - and the host registered as one you brought
# (--connection byo) in inventory/baremetal.yml. Checks:
#   1. the ISO builds - its admin password from the vault - and the guest
#      installs itself from it, unattended
#   2. SSH reaches the installed guest with the run's key
#   3. tools/probes/hardware.sh on it: UEFI, no TPM, the disk by its id
#   4. ./apply.sh, every secret from the vault - ansible answering the SSH
#      password factor itself
#   5. a reboot that stops for the LUKS passphrase - no TPM, so no key on
#      disk and nothing to unlock alone (ODP-REVIEW I5) - answered at the
#      serial console by tools/console.py (the ISO is built with --console
#      ttyS0 so the prompt is where it can type); a boot that reaches its
#      login prompt unasked fails
#   6. ./verify.sh: mp-09-luks-tpm-bound and mp-09-luks-no-key-on-disk pass
#      on a host without a TPM; every other FAIL is listed
# Then the guest and its volumes, the run's vault and inventory entry are
# removed, and tools/lab-residue.sh must find no orphan. Evidence in
# reports/runs/rehearse-baremetal-UTC/. Exit 0 only if every check passes.
# Runs in the control-plane container, through the libvirt socket.
#
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../lib/container.sh"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
cd "$ROOT" || exit 2
keep=0; [[ "${1:-}" == --keep ]] && keep=1
NAME=rl9-bm-01 SERIALNO=NISTBM01 POOL=default
export NIST_INVENTORY=inventory/baremetal.yml
VAULT=inventory/baremetal.vault.yml
OUT="$ROOT/reports/runs/rehearse-baremetal-$(date -u +%Y%m%dT%H%M%SZ)"; mkdir -p "$OUT"; chmod 700 "$OUT"
V=(virsh -c "$NIST_LIBVIRT_URI")
fails=0
ok()  { echo "PASS  $*" | tee -a "$OUT/summary.txt"; }
bad() { echo "FAIL  $*" | tee -a "$OUT/summary.txt"; fails=$((fails + 1)); }
say() { echo "==> $(date -u +%H:%M) $*" | tee -a "$OUT/summary.txt"; }

"${V[@]}" dominfo "$NAME" >/dev/null 2>&1 && { echo "error: $NAME exists - a rehearsal left behind; remove it first" >&2; exit 2; }
./vm/lab-network.sh ensure >/dev/null

cleanup() {
  [[ -n "${rec:-}" ]] && kill "$rec" 2>/dev/null
  (( keep )) && { say "kept $NAME (--keep): ./tools/lab-ssh.sh $NAME; remove with ./vm/build-vm.sh --name $NAME --destroy"; return; }
  say "removing $NAME and what it left"
  "${V[@]}" destroy "$NAME" >/dev/null 2>&1
  "${V[@]}" undefine "$NAME" --nvram --remove-all-storage >/dev/null 2>&1
  "${V[@]}" vol-delete --pool "$POOL" "$NAME-install.iso" >/dev/null 2>&1
  ./tools/inventory.py remove "$NAME" >/dev/null 2>&1
  rm -f "$VAULT"
  [[ -n "${ip:-}" ]] && ssh-keygen -R "$ip" -f "$HOME/.ssh/known_hosts" >/dev/null 2>&1
  if ./tools/lab-residue.sh --orphans > "$OUT/residue.txt" 2>&1; then ok "nothing left behind (tools/lab-residue.sh --orphans)"
  else bad "residue after cleanup: $(grep orphan "$OUT/residue.txt" | head -3 | tr '\n' ' ')"; fi
}
trap 'cleanup; echo "==> $([ $fails -eq 0 ] && echo PASS || echo FAIL): bare-metal rehearsal ($fails failed) - $OUT"; exit $(( fails > 0 ))' EXIT

# The operator's credentials, made for this run, and its vault.
ssh-keygen -q -t rsa -b 3072 -N '' -C "rehearse-baremetal" -f "$OUT/id_rsa"
for f in admin_password:18 grub_password:18 luks_passphrase:24 vault_password:24; do
  openssl rand -base64 "${f#*:}" | tr -d '\n' > "$OUT/${f%%:*}"
done
export NIST_VAULT_PASSWORD_FILE="$OUT/vault_password"
./tools/vault.sh "$NIST_INVENTORY" --from "$OUT" > "$OUT/vault.log" 2>&1 \
  || { bad "vault (vault.log): $(tail -2 "$OUT/vault.log" | tr '\n' ' ')"; exit 1; }

# --- 1. build and install ----------------------------------------------------
say "1. the install ISO, then an unattended install from it"
if ./install/iso.sh "$NAME" --inventory "$NIST_INVENTORY" --disk "/dev/disk/by-id/virtio-$SERIALNO" \
     --key "$OUT/id_rsa.pub" --console ttyS0 --out "$OUT/install.iso" > "$OUT/iso.log" 2>&1 \
   && grep -q "admin password from $VAULT" "$OUT/iso.log"; then
  ok "install/iso.sh built the ISO, the admin password from the run's vault"
else bad "ISO build (iso.log): $(tail -3 "$OUT/iso.log" | tr '\n' ' ')"; exit 1; fi
size=$(stat -c %s "$OUT/install.iso")
"${V[@]}" vol-create-as "$POOL" "$NAME-install.iso" "$size" --format raw >/dev/null \
  && "${V[@]}" vol-upload --pool "$POOL" "$NAME-install.iso" "$OUT/install.iso" \
  || { bad "could not upload the ISO into pool $POOL"; exit 1; }
rm -f "$OUT/install.iso"
iso_path=$("${V[@]}" vol-path --pool "$POOL" "$NAME-install.iso")

say "installing $NAME from the CD-ROM alone (expect 15-25 min)"
./tools/console-record.sh "$NAME" "$OUT/console.log" 9000 2> "$OUT/console-record.err" &
rec=$!
timeout 7200 virt-install --connect "$NIST_LIBVIRT_URI" --name "$NAME" --memory 4096 --vcpus 2 \
  --cpu host-passthrough --machine q35 \
  --boot "uefi,firmware.feature0.name=secure-boot,firmware.feature0.enabled=yes,firmware.feature1.name=enrolled-keys,firmware.feature1.enabled=yes" \
  --tpm none --disk "pool=$POOL,size=40,format=qcow2,bus=virtio,serial=$SERIALNO" \
  --cdrom "$iso_path" --network network=nist-lab,model=virtio --graphics none \
  --console pty,target_type=serial --os-variant rocky9 \
  --noautoconsole --wait -1 > "$OUT/virt-install.log" 2>&1
vi_rc=$?
if (( vi_rc == 0 )); then ok "$NAME installed itself from the ISO (virt-install rc 0)"
else bad "install: rc=$vi_rc"; ./tools/install-log.sh "$OUT/console.log" > "$OUT/install-log.txt" 2>&1; sed 's/^/    /' "$OUT/install-log.txt" | tail -15; fi
cd_dev=$("${V[@]}" domblklist "$NAME" --details 2>/dev/null | awk '$2=="cdrom" && !f {print $3; f=1}')
[[ -n "$cd_dev" ]] && "${V[@]}" change-media "$NAME" "$cd_dev" --eject --live --config >/dev/null 2>&1
"${V[@]}" vol-delete --pool "$POOL" "$NAME-install.iso" >/dev/null 2>&1

# --- 2. SSH ------------------------------------------------------------------
say "2. SSH with the run's key"
ip=""
for _ in $(seq 1 60); do
  ip=$("${V[@]}" domifaddr "$NAME" --source lease 2>/dev/null | awk '/ipv4/ && !f {split($4, a, "/"); print a[1]; f=1}')
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
  # sudo reads the password from stdin (-S), never a command line.
  "${SSH[@]}" "sudo -S -p '' bash -s" < <(cat "$OUT/admin_password"; echo; cat tools/probes/hardware.sh) > "$OUT/hardware.txt" 2>&1
  grep -E '^(firmware|secure-boot|tpm|system|bios|memory|disks|  )' "$OUT/hardware.txt" | sed 's/^/    /'
  if grep -q '^firmware *UEFI' "$OUT/hardware.txt" && grep -q '^tpm *none' "$OUT/hardware.txt" \
     && grep -q "virtio-$SERIALNO" "$OUT/hardware.txt"; then
    ok "the probe sees UEFI, no TPM, and the disk by its id"
  else bad "probe output unexpected (hardware.txt)"; fi
else bad "probe skipped: no SSH"; fi

# --- 4. apply ----------------------------------------------------------------
say "4. ./apply.sh, every secret from the run's vault"
applied=0
if (( ssh_ok )); then
  ssh-keygen -R "$ip" -f "$HOME/.ssh/known_hosts" >/dev/null 2>&1
  ./tools/inventory.py add "$NAME" --ip "$ip" --user cuiadmin --connection byo --key "$OUT/id_rsa" > /dev/null
  ./apply.sh --limit "$NAME" > "$OUT/apply.log" 2>&1
  if grep -qE "^$NAME +:.* unreachable=0 +failed=0" "$OUT/apply.log"; then
    applied=1; ok "apply: $(grep -E "^$NAME +:" "$OUT/apply.log" | tr -s ' ')"
  else bad "apply (apply.log): $(grep -E "^$NAME +:|fatal" "$OUT/apply.log" | head -2 | tr '\n' ' ')"; fi
  grep -q 'every boot waits' "$OUT/apply.log" && echo "    the role said: no TPM, every boot asks for the passphrase (I5)"
else bad "apply skipped: no SSH"; fi

# --- 5. a reboot that asks -----------------------------------------------------
say "5. reboot: it must stop for the LUKS passphrase"
answered=0
if (( applied )); then
  kill "$rec" 2>/dev/null; rec=""       # the console is tools/console.py's now
  # The rehearsal's own throwaway secrets, to the console driver alone.
  answered=$(NIST_CONSOLE_PASSWORD="$(cat "$OUT/admin_password")" LUKS="$(cat "$OUT/luks_passphrase")" \
    python3 - "$NAME" <<'PYCON' 2> "$OUT/console.err"
import os, subprocess, sys
sys.path.insert(0, "tools")
import console
name = sys.argv[1]
con = console.Console(name, user="cuiadmin")
subprocess.run(["virsh", "-c", os.environ["NIST_LIBVIRT_URI"], "reboot", name], check=True, capture_output=True)
n = con.answer_passphrases(os.environ["LUKS"],
                           r"[Pp]assphrase for (disk )?[^\r\n]*(cui_data|cui_backup|lv_cui|lv_backup)")
print(n)
con.close()
PYCON
)
  if [[ "$answered" =~ ^[1-9] ]]; then ok "the boot stopped for the passphrase and went on once it was typed ($answered prompt(s))"
  else bad "reboot: ${answered:-no answer} ($(tail -2 "$OUT/console.err" | tr '\n' ' '))"; fi
else bad "reboot skipped: not applied"; fi

# --- 6. verify -----------------------------------------------------------------
say "6. ./verify.sh"
if [[ "$answered" =~ ^[1-9] ]]; then
  # Both factors from the vault, as every later connection: ansible answers.
  for _ in $(seq 1 60); do ansible "$NAME" -m ansible.builtin.ping >/dev/null 2>&1 && break; sleep 5; done
  ./verify.sh --host "$NAME" > "$OUT/verify.log" 2>&1
  json=$(sed -n 's/^ *results: *//p' "$OUT/verify.log" | tail -1)
  if [[ -f "$json" ]]; then
    python3 - "$json" > "$OUT/verify-summary.txt" <<'PYV'
import json, sys
d = json.load(open(sys.argv[1]))
checks = {c["id"]: c for r in d.get("requirements", []) for c in r.get("checks", [])}
for w in ("mp-09-luks-tpm-bound", "mp-09-luks-no-key-on-disk"):
    print(f"{w} {checks.get(w, {}).get('status', 'missing')}")
failed = sorted(i for i, c in checks.items() if c.get("status") == "FAIL")
print("failed " + (" ".join(failed) if failed else "none"))
s = d.get("summary", {})
print(f"summary {s.get('pass')}/{s.get('manual')}/{s.get('fail')}/{s.get('not_applicable')}, {s.get('checks_run')} checks, {s.get('checks_failed')} failed")
PYV
    sed 's/^/    /' "$OUT/verify-summary.txt"
    if grep -q '^mp-09-luks-tpm-bound PASS' "$OUT/verify-summary.txt" && grep -q '^mp-09-luks-no-key-on-disk PASS' "$OUT/verify-summary.txt"; then
      ok "no TPM: the volumes open from the console passphrase alone - both mp-09 checks pass"
    else bad "the mp-09 checks did not pass (verify-summary.txt)"; fi
    grep -q '^failed none' "$OUT/verify-summary.txt" && ok "verify: nothing failed" || bad "verify: $(grep '^failed' "$OUT/verify-summary.txt")"
  else bad "verify produced no results (verify.log: $(tail -3 "$OUT/verify.log" | tr '\n' ' '))"; fi
else bad "verify skipped: the reboot did not complete"; fi
