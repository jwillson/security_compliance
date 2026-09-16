#!/bin/bash
# 03.08.03 Media sanitization helper. Review before use.
set -euo pipefail
if [[ $# -lt 1 ]]; then
  echo "usage: nist-sanitize /dev/sdX" >&2
  exit 2
fi
dev=$1
if [[ ! -b $dev ]]; then
  echo "not a block device: $dev" >&2
  exit 1
fi
echo "This will destroy all data on $dev"
read -r -p "type DESTROY to continue: " ans
[[ $ans == DESTROY ]] || exit 1
if command -v cryptsetup >/dev/null; then
  cryptsetup luksErase "$dev" || true
fi
shred -v -n 2 "$dev"
wipefs -a "$dev"
echo "sanitized $dev"
