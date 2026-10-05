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
#     kickstart lab pdftotext, for BYO cloud-localds; uv, which `make tools`
#     builds the pinned Ansible with;
#   - UEFI firmware with Secure Boot and enrolled keys, from the firmware
#     descriptors libvirt reads (the role seals to PCR 7, the Secure Boot
#     state);
#   - libvirt's system instance answering.
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
esac
need() {   # command apt-package dnf-package [why]
  if command -v "$1" >/dev/null 2>&1; then ok "$1"; return; fi
  bad "$1 not found${4:+ ($4)}"
  case $family in apt) missing_pkgs+=("$2") ;; dnf) missing_pkgs+=("$3") ;; esac
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
need virsh libvirt-clients libvirt-client "libvirt"
need virt-install virtinst virt-install
need qemu-img qemu-utils qemu-img
need swtpm swtpm swtpm
need swtpm_setup swtpm-tools swtpm-tools
need openssl openssl openssl
need curl curl curl
if [[ "$lab" == kickstart || "$lab" == all ]]; then
  need pdftotext poppler-utils poppler-utils "make catalog"
  command -v podman >/dev/null 2>&1 && ok "podman" || note "podman not found: the kickstart is not syntax-checked before install, and the stand-in SIEM cannot run (optional)"
fi
if [[ "$lab" == byo || "$lab" == all ]]; then
  need cloud-localds cloud-image-utils cloud-utils "BYO cloud-init seed"
fi
# uv's own installer puts it in ~/.local/bin, which a plain shell's PATH may
# lack (the from-scratch run of 2026-10-05 stopped here); look there too.
if command -v uv >/dev/null 2>&1 || [[ -x "$HOME/.local/bin/uv" || -x "$HOME/.cargo/bin/uv" ]]; then ok "uv"
else bad "uv not found (make tools builds the pinned Ansible with it): curl -LsSf https://astral.sh/uv/install.sh | sh, or pip install --user uv"; fi
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

# libvirt's system instance.
if sudo virsh -c qemu:///system uri >/dev/null 2>&1; then ok "libvirt qemu:///system answers"
else
  bad "libvirt qemu:///system does not answer"
  case $family in apt) missing_pkgs+=(libvirt-daemon-system) ;; dnf) missing_pkgs+=(libvirt) ;; esac
  note "then start it: sudo systemctl enable --now libvirtd (Ubuntu, Debian) or virtqemud.socket virtnetworkd.socket virtstoraged.socket (RHEL 9, Fedora)"
fi

if (( ${#missing_pkgs[@]} )); then
  pkgs=$(printf '%s\n' "${missing_pkgs[@]}" | sort -u | tr '\n' ' ')
  case $family in
    apt) echo "== install: sudo apt-get install -y $pkgs" ;;
    dnf) echo "== install: sudo dnf install -y $pkgs" ;;
    *)   echo "== install the packages providing: $pkgs" ;;
  esac
fi
(( fails )) && { echo "== FAIL: $fails item(s) missing"; exit 1; }
echo "== ready for the $lab lab"
