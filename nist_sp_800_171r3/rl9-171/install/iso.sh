#!/usr/bin/env bash
#
# A bare-metal install ISO: the Rocky 9 boot ISO with this project's kickstart
# inside, for one machine (DEFECTS 7.35). Boot it - BMC virtual media, or a
# USB stick - and the machine installs itself unattended, wiping the one disk
# named, then reboots into a host ready for ./apply.sh.
#
#   install/iso.sh NAME --disk /dev/disk/by-id/ID
#       [--user cuiadmin] [--key ~/.ssh/id_rsa.pub] [--console tty0|ttyS0|ttyS1]
#       [--inventory inventory/hosts.yml | --hash-file FILE] [--out FILE]
#
# --disk is required and should be a /dev/disk/by-id/ path: the install uses
# that disk and no other, and on a machine without it, it stops instead of
# wiping whatever disk it finds. Find it from the running machine
# (`ls -l /dev/disk/by-id/`), or its BMC's storage inventory.
#
# The admin account (--user) gets your public key (--key; RSA, which the FIPS
# policy accepts) and the admin password from the inventory's vault
# (--inventory, default inventory/hosts.yml: its hosts.vault.yml, written by
# tools/vault.sh) - the password ./apply.sh then uses for sudo and SSH. With
# no vault it is asked for, without echo; --hash-file gives a crypt hash
# instead (the kickstart lab's .secrets/admin_password_hash), and
# NIST_BECOME_PASSWORD is read only for automation.
#
# --console is where the installer's screen and, on every later boot, the
# LUKS passphrase prompt appear (a host with no TPM asks at each boot,
# ODP-REVIEW I5): tty0, the default, is the screen a BMC's virtual KVM shows;
# ttyS0 or ttyS1 is serial - a BMC's serial-over-LAN, often ttyS1 - and what
# the lab rehearsal types into. The other one gets the kernel's messages
# too. The installer carries these console= settings into the installed
# system, and the last one is where systemd asks for the passphrase. Only its SHA-512 crypt hash goes into the
# ISO, but that hash is in it: the ISO is written 0600 under iso/ (ignored by
# git); treat it as a credential and delete it after the install.
#
# It runs in the control-plane container, whole: started on the host it
# re-enters itself through ./nist, so the workstation needs only podman or
# docker. Existing tools do the work:
# the kickstart is install/render-kickstart.sh's, as for a lab guest; `openssl
# passwd -6` hashes the password; ksvalidator (pykickstart) checks it; xorriso
# adds it to the ISO and rebuilds the ISO with its BIOS, UEFI and GPT boot
# setup replayed; mtools edits the UEFI boot image (efiboot.img) in place;
# implantisomd5 renews the media checksum. Each boot entry gains
# inst.ks=hd:LABEL=<the ISO's label>:/ks.cfg and inst.text, and the default
# entry becomes "Install" - not "Test this media", which over a BMC's
# virtual media can take long. Lorax's mkksiso does the same, but Rocky 9's
# needs a loop device - root - to rebuild efiboot.img, and Ubuntu does not
# package it. The installer's runtime image comes from the ISO (DEFECTS
# 7.32); packages from the mirror (NIST_ROCKY_MIRROR), over DHCP.
#
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
# The whole of it inside the control-plane image; NIST_* (the password) and
# ~/.ssh (the key) come along.
. "$ROOT/lib/container.sh"
cd "$ROOT"
die() { echo "error: $*" >&2; exit 1; }
log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }

name=${1:-}; [[ -n "$name" && "$name" != -* ]] || { sed -n '3,27p' "$0"; exit 2; }; shift
disk="" user=cuiadmin key="$HOME/.ssh/id_rsa.pub" console=tty0 inv=inventory/hosts.yml hash_file="" out=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --disk) disk=$2; shift 2 ;;
    --user) user=$2; shift 2 ;;
    --key)  key=$2;  shift 2 ;;
    --console) console=$2; shift 2 ;;
    --inventory) inv=$2; shift 2 ;;
    --hash-file) hash_file=$2; shift 2 ;;
    --out) out=$2; shift 2 ;;
    *) die "unknown argument: $1" ;;
  esac
done
# The primary console last: the installer, and systemd's passphrase prompt, use it.
case "$console" in
  tty0)      consoles="console=ttyS0,115200n8 console=tty0 inst.text" ;;
  ttyS[0-9]) consoles="console=tty0 console=$console,115200n8 inst.text" ;;
  *) die "--console takes tty0, ttyS0 .. ttyS9" ;;
esac
[[ -n "$disk" ]] || die "--disk is required: the one disk the install wipes, as /dev/disk/by-id/..."
[[ "$disk" == /dev/disk/by-id/* ]] || echo "warning: --disk $disk is not a /dev/disk/by-id/ path; names like sda can change between boots and machines" >&2
# The admin's key: a public key file, or `agent` - the first key the host's
# SSH agent holds (./nist forwards it) that the FIPS policy accepts. After
# 03.13.11 the host takes RSA >= 3072 and ECDSA P-256/384 only; anything
# else would lock the admin out at the first apply.
fips_key() {   # one public key line on stdin -> 0 if the hardened host accepts it
  local l t bits; IFS= read -r l; t=${l%% *}
  case "$t" in
    ecdsa-sha2-nistp256|ecdsa-sha2-nistp384) return 0 ;;
    ssh-rsa) bits=$(ssh-keygen -lf - <<<"$l" | awk '{print $1}'); (( bits >= 3072 )) ;;
    *) return 1 ;;
  esac
}
pubkey=$(mktemp)
if [[ "$key" == agent ]]; then
  [[ -n "${SSH_AUTH_SOCK:-}" ]] || die "--key agent, but no SSH agent reached the container: run ssh-agent on the host, ssh-add the key, and run ./nist from that shell"
  while IFS= read -r l; do fips_key <<<"$l" && { printf '%s\n' "$l" > "$pubkey"; break; }; done < <(ssh-add -L 2>/dev/null)
  [[ -s "$pubkey" ]] || die "the SSH agent holds no RSA >= 3072 or ECDSA P-256/384 key: ./nist ssh-keygen -t rsa -b 3072, then ssh-add it"
else
  [[ -f "$key" ]] || die "no public key at $key (--key; it must be under ~/.ssh, or use --key agent)"
  fips_key < "$key" || die "$key: the FIPS policy accepts RSA >= 3072 and ECDSA P-256/384 only - another key would lock the admin out after the first apply (./nist ssh-keygen -t rsa -b 3072)"
  cp "$key" "$pubkey"
fi
key_given=$key; key=$pubkey
iso=iso/Rocky-9.8-x86_64-boot.iso
[[ -f "$iso" ]] || die "$iso missing (make iso)"
[[ -n "$out" ]] || out="iso/${name}-install.iso"

work=$(mktemp -d "$ROOT/iso/.baremetal-XXXXXX")
trap 'rm -rf "$work"' EXIT
umask 077
# The admin password's crypt hash: given, from the vault, from automation's
# environment, or asked - never on a command line.
if [[ -n "$hash_file" ]]; then cp "$hash_file" "$work/hash"
else
  vault="${inv%.yml}.vault.yml"
  if [[ -f "$vault" ]]; then
    NIST_INVENTORY=$inv . "$ROOT/lib/inventory-env.sh"      # the vault password, once
    ansible-vault view "$vault" | python3 -c 'import sys,yaml; print(yaml.safe_load(sys.stdin)["all"]["vars"]["ansible_become_password"], end="")' \
      | openssl passwd -6 -stdin > "$work/hash"
    log "admin password from $vault"
  elif [[ -n "${NIST_BECOME_PASSWORD:-}" ]]; then
    openssl passwd -6 -stdin <<<"$NIST_BECOME_PASSWORD" > "$work/hash"
  else
    [[ -t 0 ]] || die "no vault ($vault), no terminal to ask for the admin password: tools/vault.sh $inv first"
    IFS= read -rsp "admin password for $name: " pw </dev/tty; echo >&2
    IFS= read -rsp "again: " pw2 </dev/tty; echo >&2
    [[ -n "$pw" && "$pw" == "$pw2" ]] || die "empty, or they differ"
    printf '%s' "$pw" | openssl passwd -6 -stdin > "$work/hash"; unset pw pw2
  fi
fi
"$HERE/render-kickstart.sh" --out "$work/ks.cfg" --name "$name" --disk "$disk" --user "$user" \
  --hash-file "$work/hash" --pubkey-file "$key"
rm -f "$work/hash"
log "kickstart rendered for $name: disk ${disk#/dev/}, user $user, console $console"

log "validating it and writing it into the ISO (ksvalidator, xorriso, mtools, implantisomd5)"
bash -c '
  set -euo pipefail
  in=$1 w=$2 add=$3
  ksvalidator -v RHEL9 "$w/ks.cfg"
  xorriso -osirrox on -indev "$in" -extract /EFI/BOOT/grub.cfg "$w/grub.cfg" \
    -extract /isolinux/isolinux.cfg "$w/isolinux.cfg" -extract /images/efiboot.img "$w/efiboot.img" 2>/dev/null
  chmod u+w "$w"/grub.cfg "$w"/isolinux.cfg "$w"/efiboot.img
  # Every entry that boots the installer: add the kickstart, from this ISO by
  # its own label, and text mode (the BMC console shows it as well as graphics).
  ks() { sed -i -E "s|(inst\.stage2=hd:LABEL=([^ ]+))|\1 inst.ks=hd:LABEL=\2:/ks.cfg $add|" "$1"; }
  ks "$w/grub.cfg"; ks "$w/isolinux.cfg"
  sed -i "s/^set default=.*/set default=\"0\"/" "$w/grub.cfg"
  grep -q "inst.ks=hd:LABEL=" "$w/grub.cfg" || { echo "no installer entry found in grub.cfg"; exit 1; }
  # The UEFI boot image carries its own grub.cfg: the same edit, in place.
  if mtype -i "$w/efiboot.img" ::/EFI/BOOT/grub.cfg > "$w/efi-grub.cfg" 2>/dev/null; then
    ks "$w/efi-grub.cfg"; sed -i "s/^set default=.*/set default=\"0\"/" "$w/efi-grub.cfg"
    mcopy -o -i "$w/efiboot.img" "$w/efi-grub.cfg" ::/EFI/BOOT/grub.cfg
  fi
  xorriso -indev "$in" -outdev "$w/out.iso" -boot_image any replay \
    -map "$w/ks.cfg" /ks.cfg -map "$w/grub.cfg" /EFI/BOOT/grub.cfg \
    -map "$w/isolinux.cfg" /isolinux/isolinux.cfg -map "$w/efiboot.img" /images/efiboot.img
  implantisomd5 --force "$w/out.iso" >/dev/null' _ "$ROOT/$iso" "$work" "$consoles" > "$work/build.log" 2>&1 \
  || { cat "$work/build.log" >&2; die "the ISO was not written (above)"; }

mv "$work/out.iso" "$out"; chmod 600 "$out"
log "wrote $out ($(du -h "$out" | cut -f1)), mode 0600 - it holds the admin password's hash"
# An operator's next steps; a tool that names --out (vm/build-vm.sh, the
# rehearsal) takes the ISO on itself.
[[ "$out" == "iso/${name}-install.iso" ]] || exit 0
cat <<DONE

  1. Attach $out to $name as virtual media (or write it to a USB stick).
  2. Boot it in UEFI mode. It installs unattended - wiping ${disk} - and
     reboots into Rocky 9; detach the media then.
  3. From this workstation:
       ./nist inventory add $name --ip ADDRESS --user $user --connection byo --key $([[ "$key_given" == agent ]] && echo agent || echo "${key_given%.pub}")
       ./nist apply --limit $name --reboot && ./nist verify --host $name
  Then delete $out.
DONE
