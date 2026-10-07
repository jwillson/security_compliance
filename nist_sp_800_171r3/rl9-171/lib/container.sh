# shellcheck shell=bash
# Sourced first by every workstation entry point (TASKS C2): outside the
# control-plane container, run the calling script again inside it, through
# ./nist, with the same arguments. The tool runs only there - the host needs
# podman or docker, and for the lab the hypervisor; nothing else (owner
# decision 2026-10-07). Scripts that run on target hosts (tools/probes/, the
# assessor) do not source this.
#
#   . "$(dirname "${BASH_SOURCE[0]}")/../lib/container.sh"
#
# Sourced with no arguments, "$0" and "$@" are the calling script's own.
if [[ -z "${NIST_IN_CONTAINER:-}" ]]; then
  exec "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/nist" "$0" "$@"
fi
# Inside: libvirt through its socket (./nist mounts /run/libvirt), never sudo.
export NIST_LIBVIRT_URI="${NIST_LIBVIRT_URI:-qemu:///system}"
