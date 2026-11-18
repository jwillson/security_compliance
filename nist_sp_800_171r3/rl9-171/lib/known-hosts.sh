# shellcheck shell=bash
# Sourced by lib/ssh-env.sh and the two builders: how a host's key is recorded
# in a known_hosts file, and forgotten.
#
# ssh-keyscan prints a comment line for every key type it asks a host for
# ("# 192.168.171.101:22 SSH-2.0-OpenSSH_9.9"), and ssh-keygen -R removes a
# host's keys and leaves those lines. Appended as they came, they piled up:
# 2 430 of the 2 720 lines of one workstation's ~/.ssh/known_hosts, and after
# a teardown 230 lines in a file with no key left in it (DEFECTS 7.53).

# HOST FILE: append HOST's keys to FILE, hashed, and nothing else.
nist_keyscan() {
  ssh-keyscan -H "$1" 2>/dev/null | grep -v '^#' >> "$2" || true
}

# HOST FILE: forget HOST in FILE - its keys, and the comment lines that scans
# of it left there. No other line is touched.
nist_forget_host() {
  [ -f "$2" ] || return 0
  if ssh-keygen -F "$1" -f "$2" >/dev/null 2>&1; then
    ssh-keygen -R "$1" -f "$2" >/dev/null 2>&1 || true
    rm -f "$2.old"            # ssh-keygen's copy, the forgotten key in it
  fi
  if grep -qF "# $1:" "$2" 2>/dev/null; then
    # Rewritten in place: the file keeps its owner and mode.
    awk -v p="# $1:" 'index($0, p) != 1' "$2" > "$2.nist-tmp" && cat "$2.nist-tmp" > "$2"
    rm -f "$2.nist-tmp"
  fi
  return 0
}
