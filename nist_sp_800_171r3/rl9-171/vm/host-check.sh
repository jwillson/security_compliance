#!/usr/bin/env bash
#
# Can this host run the labs? Read-only (DEFECTS 7.19).
#
#   vm/host-check.sh [kickstart|byo|all]      default kickstart
#
# Run first by `make vm`, `make vm-log` (and so `make all`) and by
# vm/byo-guest.sh build. Checks, and names the fix for each failure:
#   - hardware virtualisation (/dev/kvm) and memory for the guests the lab
#     runs: kickstart 4 GiB each (the CUI host, then the collector), BYO
#     3 GiB each (two CUI hosts and a collector);
#   - the tools: libvirt and virt-install, qemu-img, swtpm, and for the
#     kickstart lab pdftotext, for BYO a cloud-init seed tool; Python >= 3.12
#     with venv (or uv), which `make tools` builds the pinned Ansible with;
#   - UEFI firmware with Secure Boot and enrolled keys, from the firmware
#     descriptors libvirt reads (the role seals to PCR 7, the Secure Boot
#     state);
#   - libvirt's system instance answering, with QEMU/KVM behind it.
# Prints the package command for this distribution (apt or dnf) when tools
# are missing. Exits 1 if anything required is missing. Installs nothing.
#
set -uo pipefail
lab=${1:-kickstart}
[[ "$lab" =~ ^(kickstart|byo|all)$ ]] || { sed -n '3,22p' "$0"; exit 2; }
fails=0 missing_pkgs=()
ok()   { echo "  ok    $*"; }
bad()  { echo "  FAIL  $*"; fails=$((fails + 1)); }
note() { echo "  note  $*"; }
. /etc/os-release 2>/dev/null || true
family=other
case " ${ID:-} ${ID_LIKE:-} " in
  *" debian "*|*" ubuntu "*) family=apt ;;
  *" rhel "*|*" fedora "*|*" centos "*) family=dnf ;;
  *" arch "*) family=pacman ;;
esac
need() {   # command apt-package dnf-package [why] [pacman-package]
  if command -v "$1" >/dev/null 2>&1; then ok "$1"; return; fi
  bad "$1 not found${4:+ ($4)}"
  case $family in apt) missing_pkgs+=("$2") ;; dnf) missing_pkgs+=("$3") ;; pacman) missing_pkgs+=("${5:-$3}") ;; esac
}

echo "== $(hostname): ${PRETTY_NAME:-unknown OS}, checking for the $lab lab"

# Virtualisation and memory.
[[ -e /dev/kvm ]] && ok "/dev/kvm" || bad "/dev/kvm missing: enable VT-x/AMD-V in the firmware, and load kvm_intel or kvm_amd"
need_mb=0
[[ "$lab" == kickstart || "$lab" == all ]] && need_mb=$((need_mb + 2 * 4096))
[[ "$lab" == byo || "$lab" == all ]] && need_mb=$((need_mb + 3 * 3072))
avail_mb=$(awk '/^MemAvailable:/ {print int($2 / 1024)}' /proc/meminfo)
if (( avail_mb >= need_mb )); then ok "memory: ${avail_mb} MiB available, ${need_mb} MiB for every guest of the $lab lab"
elif (( avail_mb >= 4096 )); then note "memory: ${avail_mb} MiB available, ${need_mb} MiB for every guest at once - build and run fewer at a time"
else bad "memory: ${avail_mb} MiB available; one guest needs 3-4 GiB"; fi

# Tools.
need virsh libvirt-clients libvirt-client "libvirt" libvirt
need virt-install virtinst virt-install "" virt-install
need qemu-img qemu-utils qemu-img "" qemu-img
# libvirt's DHCP and DNS for the lab network; an optional dependency on Arch,
# so a host can have libvirt and not this (DEFECTS 7.22).
need dnsmasq dnsmasq-base dnsmasq "the lab network's DHCP and DNS" dnsmasq
need swtpm swtpm swtpm
need swtpm_setup swtpm-tools swtpm-tools
need make make make
need tar tar tar
need openssl openssl openssl
need curl curl curl
if [[ "$lab" == kickstart || "$lab" == all ]]; then
  # Only make catalog and catalog-check read the PDF; the build uses the
  # committed catalog.
  command -v pdftotext >/dev/null 2>&1 && ok "pdftotext" || note "pdftotext not found: needed only to regenerate the catalog (make catalog, make catalog-check; poppler-utils)"
  command -v podman >/dev/null 2>&1 && ok "podman" || note "podman not found: the kickstart is not syntax-checked before install, and the stand-in SIEM cannot run (optional)"
fi
if [[ "$lab" == byo || "$lab" == all ]]; then
  # The cloud-init seed: cloud-localds, or xorriso / genisoimage (RHEL 9
  # packages xorriso, not cloud-localds).
  if command -v cloud-localds >/dev/null 2>&1 || command -v xorriso >/dev/null 2>&1 || command -v genisoimage >/dev/null 2>&1; then ok "a cloud-init seed tool"
  else bad "no cloud-init seed tool (cloud-localds, xorriso or genisoimage)"; case $family in apt) missing_pkgs+=(cloud-image-utils) ;; dnf) missing_pkgs+=(xorriso) ;; esac; fi
fi
# make tools builds the pinned Ansible with a Python >= 3.12 that can make a
# venv, or with uv where there is no such Python (uv brings its own). uv is
# no longer required (DEFECTS 7.26).
py12=""
for p in python3 python3.14 python3.13 python3.12; do
  command -v "$p" >/dev/null 2>&1 && "$p" -c 'import sys, venv, ensurepip; sys.exit(sys.version_info < (3, 12))' 2>/dev/null && { py12=$p; break; }
done
if [[ -n "$py12" ]]; then ok "$py12 >= 3.12 with venv (for make tools)"
elif command -v uv >/dev/null 2>&1 || [[ -x "$HOME/.local/bin/uv" || -x "$HOME/.cargo/bin/uv" ]]; then ok "uv (for make tools; no system Python >= 3.12)"
else
  bad "make tools needs Python >= 3.12 with venv, or uv"
  case $family in apt) missing_pkgs+=(python3-venv) ;; dnf) missing_pkgs+=(python3.12 python3.12-pip) ;; pacman) missing_pkgs+=(python) ;; esac
fi
if command -v ansible-playbook >/dev/null 2>&1; then ok "ansible-playbook"
else note "ansible-playbook not on PATH yet: make tools builds the pinned one (make all does it for you)"; fi
python3 -c 'import yaml' 2>/dev/null && ok "python3 yaml" || { bad "python3 yaml module"; case $family in apt) missing_pkgs+=(python3-yaml) ;; dnf) missing_pkgs+=(python3-pyyaml) ;; esac; }

# Firmware with Secure Boot and enrolled keys, as libvirt would choose it.
if python3 - <<'PY' 2>/dev/null
import glob, json, sys
for f in glob.glob("/usr/share/qemu/firmware/*.json"):
    d = json.load(open(f)); feats = set(d.get("features", []))
    if {"secure-boot", "enrolled-keys"} <= feats and d.get("mapping", {}).get("device") == "flash":
        sys.exit(0)
sys.exit(1)
PY
then ok "UEFI firmware with Secure Boot and enrolled keys"
else
  bad "no UEFI firmware with Secure Boot and enrolled keys in /usr/share/qemu/firmware"
  case $family in apt) missing_pkgs+=(ovmf) ;; dnf) missing_pkgs+=(edk2-ovmf) ;; esac
fi

# libvirt's system instance, and QEMU/KVM behind it: libvirt answers without
# a hypervisor installed (RHEL 9's qemu-kvm is a separate package).
if sudo virsh -c qemu:///system uri >/dev/null 2>&1; then
  ok "libvirt qemu:///system answers"
  if sudo virsh -c qemu:///system domcapabilities --virttype kvm >/dev/null 2>&1; then ok "QEMU with KVM"
  else bad "libvirt has no QEMU/KVM hypervisor"; case $family in apt) missing_pkgs+=(qemu-system-x86) ;; dnf) missing_pkgs+=(qemu-kvm) ;; esac; fi
else
  bad "libvirt qemu:///system does not answer"
  case $family in apt) missing_pkgs+=(libvirt-daemon-system) ;; dnf) missing_pkgs+=(libvirt) ;; esac
  case $family in
    dnf) note "then start it: sudo systemctl enable --now virtqemud.socket virtnetworkd.socket virtstoraged.socket virtnodedevd.socket virtsecretd.socket" ;;
    *)   note "then start it: sudo systemctl enable --now libvirtd" ;;
  esac
fi

if (( ${#missing_pkgs[@]} )); then
  pkgs=$(printf '%s\n' "${missing_pkgs[@]}" | sort -u | tr '\n' ' ')
  case $family in
    apt) echo "== install: sudo apt-get install -y $pkgs" ;;
    dnf) echo "== install: sudo dnf install -y $pkgs" ;;
    pacman) echo "== install: sudo pacman -S --needed $pkgs" ;;
    *)   echo "== install the packages providing: $pkgs" ;;
  esac
fi
(( fails )) && { echo "== FAIL: $fails item(s) missing"; exit 1; }
echo "== ready for the $lab lab"
