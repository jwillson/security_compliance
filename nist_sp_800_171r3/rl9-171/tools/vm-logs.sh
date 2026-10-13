#!/usr/bin/env bash
#
# What qemu and the TPM emulator said about a lab guest - the evidence for a
# guest the firmware reset before it booted (DEFECTS 7.42). Read-only. The
# logs are root's, so it runs as root, as `sudo ./nist vm-logs NAME`; ./nist
# mounts libvirt's and swtpm's log directories read-only for it, and nothing
# else is privileged.
#
#   sudo ./nist vm-logs rl9-log-01          the last 60 lines of each
#   sudo ./nist vm-logs rl9-log-01 200
#
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../lib/container.sh"
name=${1:?usage: sudo ./nist vm-logs NAME [LINES]}; n=${2:-60}
(( $(id -u) == 0 )) || { echo "error: the logs are root's: sudo ./nist vm-logs $name" >&2; exit 2; }
for f in /host/var/log/libvirt/qemu/"$name".log /host/var/log/swtpm/libvirt/qemu/"$name"-swtpm.log; do
  echo "=== ${f#/host} (last $n lines)"
  if [[ -r "$f" ]]; then tail -n "$n" "$f"; else echo "(none)"; fi
done
