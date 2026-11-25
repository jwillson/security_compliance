#!/usr/bin/env bash
#
# Can libvirt's TPM emulator write its certificate authority on this host?
# If not, no new guest with an emulated TPM starts: swtpm_setup ends with
# "Need read/write rights on statedir /var/lib/swtpm-localca for user tss".
#
#   vm/host-swtpm.sh check         read-only; exit 1 on a mismatch
#   sudo vm/host-swtpm.sh fix      make the directory's owner follow libvirt
#
# libvirt runs swtpm as the user /etc/libvirt/qemu.conf names (swtpm_user),
# and as tss, its built-in default, when that file is absent or silent.
# Ubuntu's swtpm-tools gives /var/lib/swtpm-localca to the user swtpm
# (/usr/lib/tmpfiles.d/swtpm-tmpfiles.conf), which its packaged qemu.conf
# also names - so a stock Ubuntu 26.04 needs nothing (seen on the owner's
# server, 2026-11-17). On a host whose qemu.conf is gone the two disagree
# (the owner's laptop). A chown does not last there: systemd-tmpfiles puts
# the packaged owner back at every boot and package update (it did on
# 2026-10-16, after which no TPM guest could be made).
#
# `fix` writes /etc/tmpfiles.d/swtpm-tmpfiles.conf - the same file name, so
# it replaces the packaged line - naming the user libvirt uses, and applies
# it. When the two agree without it (qemu.conf restored), it removes that
# override instead, which would otherwise break TPM guests the other way
# round. It never restarts libvirtd, edits no libvirt file and touches no
# guest.
#
# libvirt reads qemu.conf when its daemon starts. A file written since is not
# what the running daemon does: it goes on running swtpm as the user it read
# then (the owner's laptop, 2026-11-24: the packaged file put back, a daemon
# that could not be restarted, and no new TPM guest once the directory had
# followed the file). So both commands go by the running daemon - while it
# has not read the file, by the owner of its swtpm log directory, which
# libvirt sets each time it prepares a guest's TPM - and say that `fix` is
# to be run again once the daemon has restarted.
#
# This runs on the host, not in the control-plane container, and
# `fix` as root: with `./nist diagnose` and `./nist vm-logs`, the only places
# the toolkit asks for sudo (owner decision 2026-11-17).
#
set -euo pipefail
DIR=/var/lib/swtpm-localca
LOGDIR=/var/log/swtpm/libvirt/qemu
CONF=/etc/libvirt/qemu.conf
OVERRIDE=/etc/tmpfiles.d/swtpm-tmpfiles.conf
PACKAGED=/usr/lib/tmpfiles.d/swtpm-tmpfiles.conf
cmd=${1:-}
[[ "$cmd" == check || "$cmd" == fix ]] || { sed -n '3,38p' "$0"; exit 2; }

if [[ -e "$CONF" && ! -r "$CONF" ]]; then
  echo "error: $CONF is not readable as $(id -un): sudo vm/host-swtpm.sh $cmd" >&2; exit 2
fi
user=tss why="no $CONF: libvirt's built-in default"
if [[ -r "$CONF" ]]; then
  u=$(sed -n 's/^[[:space:]]*swtpm_user[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$CONF" | tail -1)
  if [[ -n "$u" ]]; then user=$u why="swtpm_user in $CONF"; else why="$CONF names none: libvirt's built-in default"; fi
fi
[[ "$user" =~ ^[a-z_][a-z0-9_-]*$ ]] || { echo "error: '$user' is not a user name ($why)" >&2; exit 2; }
packaged=$(awk '$1 == "d" && $2 == "'"$DIR"'" {print $4}' "$PACKAGED" 2>/dev/null | tail -1)
# Has the running daemon read $CONF as it is? Not if the file is younger than
# the daemon (libvirtd on Ubuntu; virtqemud where libvirt runs modular).
unread=
if [[ -e "$CONF" ]]; then
  for unit in libvirtd.service virtqemud.service; do
    pid=$(systemctl show -P MainPID "$unit" 2>/dev/null) || continue
    [[ "$pid" =~ ^[1-9][0-9]*$ ]] || continue
    up=$(ps -o etimes= -p "$pid" 2>/dev/null | tr -d ' ') || continue
    [[ "$up" =~ ^[0-9]+$ ]] || continue
    (( $(date +%s) - $(stat -c %Y "$CONF") < up )) && unread=${unit%.service}
  done
fi
later=
if [[ -n "$unread" ]]; then
  now=$(stat -c %U "$LOGDIR" 2>/dev/null || true)
  if [[ -z "$now" ]]; then
    echo "error: $CONF was written after $unread started, and with no $LOGDIR nothing says which user $unread runs swtpm as. Restart $unread - or reboot the host, where a restart is not safe (docs/LAB.md)." >&2; exit 2
  fi
  if [[ "$now" != "$user" ]]; then
    later=$user user=$now why="$unread has not read $CONF, written since it started; $LOGDIR is $now's"
  fi
fi
owner=$(stat -c %U "$DIR" 2>/dev/null || echo none)

echo "libvirt runs swtpm as:   $user  ($why)"
echo "$DIR: owner $owner; the package's tmpfiles line gives it to ${packaged:-nobody}"
[[ -e "$OVERRIDE" ]] && echo "override:                $OVERRIDE ($(tr -s ' ' < "$OVERRIDE" | grep '^d ' | head -1))"

if [[ "$cmd" == check ]]; then
  if [[ "$owner" == none ]]; then echo "ok: no $DIR - swtpm-tools is not installed, or nothing has used it"; exit 0; fi
  if [[ "$owner" != "$user" ]]; then
    echo "MISMATCH: new TPM guests cannot start. Fix: sudo vm/host-swtpm.sh fix"; exit 1
  fi
  if [[ "$packaged" != "$user" && ! -e "$OVERRIDE" ]]; then
    echo "MISMATCH soon: the owner is right now, but systemd-tmpfiles will give the directory back to $packaged. Fix: sudo vm/host-swtpm.sh fix"; exit 1
  fi
  if [[ "$packaged" == "$user" && -e "$OVERRIDE" ]]; then
    echo "MISMATCH soon: $OVERRIDE is no longer needed and names another owner than the package. Fix: sudo vm/host-swtpm.sh fix"; exit 1
  fi
  if [[ -n "$later" ]]; then
    echo "ok for now: a new TPM guest can be made. When $unread next starts it reads $CONF and runs swtpm as $later: run sudo vm/host-swtpm.sh fix again then."; exit 0
  fi
  echo "ok: a new TPM guest can be made, and it stays so"; exit 0
fi

(( $(id -u) == 0 )) || { echo "error: fix writes $OVERRIDE: sudo vm/host-swtpm.sh fix" >&2; exit 2; }
id "$user" >/dev/null 2>&1 || { echo "error: there is no user $user on this host" >&2; exit 1; }
if [[ "$packaged" == "$user" ]]; then
  if [[ -e "$OVERRIDE" ]]; then rm -f "$OVERRIDE"; echo "==> removed $OVERRIDE: the package's line is right again"; fi
  systemd-tmpfiles --create "$PACKAGED"
else
  printf '# vm/host-swtpm.sh: libvirt on this host runs swtpm as %s (%s),\n# not as the user the swtpm-tools package gives this directory to. Remove\n# this file if that changes (vm/host-swtpm.sh fix does).\nd %s 0750 %s root\n' \
    "$user" "$why" "$DIR" "$user" > "$OVERRIDE"
  chmod 0644 "$OVERRIDE"
  echo "==> wrote $OVERRIDE"
  systemd-tmpfiles --create "$OVERRIDE"
fi
# What the CA already holds was made by whoever owned the directory then.
chown -R "$user" "$DIR"
echo "==> $DIR: owner $(stat -c %U "$DIR")"
exec "$0" check
