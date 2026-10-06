#!/usr/bin/env bash
#
# What a machine offers the controls that depend on hardware, before it is
# installed or hardened (DEFECTS 7.35). Read-only, as root.
#
#   tools/probe.sh hardware HOST                 a host in an inventory
#   ssh HOST sudo bash -s < tools/probes/hardware.sh   any Linux, before it is one
#
# Firmware mode, Secure Boot (03.08.09: the LUKS keys seal to it), the TPM
# (whether they can be sealed at all - without one, every boot waits for the
# passphrase, ODP-REVIEW I5), the machine and its disks by stable id (the
# --disk of vm/baremetal-iso.sh). Existing tools where the host has them -
# mokutil, dmidecode, lshw, tpm2_getcap - and /sys where it does not, so it
# also runs on a minimal system.
#
have() { command -v "$1" >/dev/null 2>&1; }
say() { printf '%-14s %s\n' "$1" "$2"; }

if [[ -d /sys/firmware/efi ]]; then say firmware "UEFI"; else say firmware "BIOS (legacy) - the kickstart needs UEFI"; fi

if have mokutil; then sb=$(mokutil --sb-state 2>&1 | head -1)
else
  # The SecureBoot EFI variable: 4 attribute bytes, then 1 = enabled.
  v=$(ls /sys/firmware/efi/efivars/SecureBoot-* 2>/dev/null | head -1)
  sb="unknown (no mokutil, no SecureBoot variable)"
  [[ -n "$v" ]] && case "$(od -An -t u1 -j4 -N1 "$v" | tr -d ' ')" in 1) sb="SecureBoot enabled (efivars)";; 0) sb="SecureBoot disabled (efivars)";; esac
fi
say secure-boot "$sb"

if [[ -e /dev/tpmrm0 || -e /sys/class/tpm/tpm0 ]]; then
  ver=$(cat /sys/class/tpm/tpm0/tpm_version_major 2>/dev/null)
  say tpm "present (/sys/class/tpm/tpm0${ver:+, TPM $ver.x}) - LUKS keys can be sealed to it"
  have tpm2_getcap && say tpm-vendor "$(tpm2_getcap properties-fixed 2>/dev/null | awk '/TPM2_PT_MANUFACTURER/ {getline; print $2; exit}')"
else
  say tpm "none - the CUI volumes will ask for the passphrase at every boot (ODP-REVIEW I5)"
fi
if have lshw; then
  sec=$(lshw -class security -short 2>/dev/null | awk 'NR > 2 {$1 = ""; print}' | xargs)
  [[ -n "$sec" ]] && say lshw-security "$sec"
fi

if have dmidecode; then
  say system "$(dmidecode -s system-manufacturer 2>/dev/null) $(dmidecode -s system-product-name 2>/dev/null)"
  say bios "$(dmidecode -s bios-vendor 2>/dev/null) $(dmidecode -s bios-version 2>/dev/null) ($(dmidecode -s bios-release-date 2>/dev/null))"
else
  say system "$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null) $(cat /sys/class/dmi/id/product_name 2>/dev/null)"
  say bios "$(cat /sys/class/dmi/id/bios_vendor 2>/dev/null) $(cat /sys/class/dmi/id/bios_version 2>/dev/null)"
fi
say memory "$(awk '/MemTotal/ {printf "%.1f GiB", $2 / 1048576}' /proc/meminfo)"

echo "disks (for vm/baremetal-iso.sh --disk):"
for d in /sys/block/*; do
  n=${d##*/}
  [[ "$n" =~ ^(loop|ram|zram|sr|dm-|md) ]] && continue
  size=$(( $(cat "$d/size") * 512 / 1000000000 ))
  ids=$(find /dev/disk/by-id -lname "*/$n" 2>/dev/null | grep -v -- '-part' | sort | tr '\n' ' ')
  printf '  %-10s %5s GB  removable=%s  %s\n' "$n" "$size" "$(cat "$d/removable")" "${ids:-no by-id link}"
done
