#!/usr/bin/env bash
#
# Render install/kickstart/rl9-cui.ks.j2 for one host. The one renderer for every
# install: a lab guest (vm/build-vm.sh) and a bare-metal host
# (install/iso.sh) get the same kickstart, differing only in what is
# substituted (DEFECTS 7.35).
#
#   install/render-kickstart.sh --out FILE --name HOST --disk DISK \
#       --user NAME --hash-file FILE --pubkey-file FILE [--mirror URL]
#
# DISK is the one disk the install may use and wipes: `vda` in the lab; on
# bare metal a /dev/disk/by-id/... path, so the kickstart refuses to touch
# any other disk - and, booted on another machine, finds none and stops.
# The password hash and the public key are read from files: nothing secret
# is passed on a command line. Fails on any placeholder left unsubstituted.
#
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
out="" name="" disk="" user="" hash_file="" key_file=""
mirror="${NIST_ROCKY_MIRROR:-https://dl.rockylinux.org/pub/rocky/9}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --out) out=$2 ;; --name) name=$2 ;; --disk) disk=$2 ;; --user) user=$2 ;;
    --hash-file) hash_file=$2 ;; --pubkey-file) key_file=$2 ;; --mirror) mirror=$2 ;;
    *) sed -n '3,15p' "$0" >&2; exit 2 ;;
  esac
  shift 2
done
for v in out name disk user hash_file key_file; do
  [[ -n "${!v}" ]] || { echo "error: --${v//_/-} is required" >&2; exit 2; }
done
[[ "$name" =~ ^[a-z0-9][a-z0-9-]*$ ]] || { echo "error: '$name' is not a host name" >&2; exit 2; }
# anaconda names disks without /dev/ (vda, disk/by-id/...).
disk=${disk#/dev/}
version="$(awk '/^  version:/ {gsub(/"/,"",$2); print $2; exit}' "$ROOT/catalog/overlay-rocky9.yml")"

python3 - "$HERE/kickstart/rl9-cui.ks.j2" "$out" "$mirror" "$name" "$user" "$hash_file" "$key_file" "$disk" "$version" <<'PY'
import re, sys
src, dst, mirror, name, user, hash_file, key_file, disk, version = sys.argv[1:]
subs = {
    "@@MIRROR@@": mirror, "@@HOSTNAME@@": name, "@@ADMIN_USER@@": user,
    "@@ADMIN_HASH@@": open(hash_file).read().strip(),
    "@@SSH_PUBKEY@@": open(key_file).read().strip(),
    "@@DISK@@": disk, "@@OVERLAY_VERSION@@": version,
}
text = open(src).read()
for k, v in subs.items():
    text = text.replace(k, v)
# Comment lines aside, nothing may be left unsubstituted.
left = [l for l in text.splitlines() if re.search(r"@@[A-Z_]+@@", l) and not l.lstrip().startswith("#")]
if left:
    sys.exit("unsubstituted placeholders:\n" + "\n".join(left))
open(dst, "w").write(text)
PY
chmod 600 "$out"
