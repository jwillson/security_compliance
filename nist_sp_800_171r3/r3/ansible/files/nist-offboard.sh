#!/bin/bash
# 03.09.02 terminate/transfer: lock, expire, kill sessions.
set -euo pipefail
if [[ $# -lt 1 ]]; then
  echo "usage: nist-offboard USER" >&2
  exit 2
fi
user=$1
if ! getent passwd "$user" >/dev/null; then
  echo "no such user: $user" >&2
  exit 1
fi
usermod -L -s /sbin/nologin "$user"
chage -E 0 "$user"
if command -v loginctl >/dev/null; then
  loginctl terminate-user "$user" || true
fi
pkill -KILL -u "$user" || true
echo "locked $user"
