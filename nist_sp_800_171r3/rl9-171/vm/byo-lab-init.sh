#!/usr/bin/env bash
#
# Create the BYO lab's operator directory, $NIST_BYO_LAB (default
# ~/.local/share/nist-byo-lab): the Ansible tooling and the files env.sh
# reads, which docs/LAB.md described but no script created (DEFECTS 7.16,
# issue #15). Run once on a new workstation, before vm/byo-guest.sh build.
#
#   vm/byo-lab-init.sh               everything below
#   vm/byo-lab-init.sh --tools-only  the Ansible venv, collections and
#                                    tools.sh only - what `make tools` runs for
#                                    the kickstart lab, which needs no BYO
#                                    secrets
#
# Creates only what is missing and never overwrites a file, so it is safe on
# a lab already in use. Secrets are random, written 0600, and never printed:
#   byoadmin_password   sudo on every BYO guest, and the SSH second factor
#   grub_password       given to the role for 03.10.07
#   luks_passphrase     given to the role for 03.08.09 (harden-cycle reads it)
# Tooling, with no secrets: venv/ (ansible-core at the version CI pins, via
# uv), collections/ (requirements.yml), tools.sh. Then env.sh (reads the
# secrets from the files above, never holds them), askpass.sh (answers the
# second factor from byoadmin_password) and wrongpass.sh (a deliberately
# wrong one, for the lockout rehearsals). Guests get the operator's own
# RSA key, $NIST_BYO_KEY (default ~/.ssh/id_rsa) - RSA, since the FIPS policy
# refuses ed25519 (README).
#
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
LAB="${NIST_BYO_LAB:-$HOME/.local/share/nist-byo-lab}"
ANSIBLE_CORE=2.21.4      # the version .github/workflows/ci.yml pins
say() { echo "==> $*"; }
made() { echo "    created $1"; }

tools_only=0; [[ "${1:-}" == --tools-only ]] && tools_only=1
install -d -m 0700 "$LAB"
umask 077

secret() {   # name length
  [[ -s "$LAB/$1" ]] && return 0
  head -c 64 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c "$2" > "$LAB/$1"
  made "$1 (random, 0600)"
}
if (( ! tools_only )); then
  say "secrets in $LAB"
  secret byoadmin_password 24
  secret grub_password 24
  secret luks_passphrase 32
fi

say "tooling"
if [[ ! -x "$LAB/venv/bin/ansible-playbook" ]]; then
  # ansible-core 2.21 needs Python >= 3.12 on the control side. A system
  # Python that new builds the venv with its own venv and pip; uv only when
  # there is none - it brings its own Python, which is how RHEL 9 (python3 is
  # 3.9) gets one without a package. uv used to be required (DEFECTS 7.26).
  PY=""
  for p in python3 python3.14 python3.13 python3.12; do
    command -v "$p" >/dev/null 2>&1 || continue
    "$p" -c 'import sys, venv, ensurepip; sys.exit(sys.version_info < (3, 12))' 2>/dev/null && { PY=$(command -v "$p"); break; }
  done
  UV=$(command -v uv || ls "$HOME/.local/bin/uv" "$HOME/.cargo/bin/uv" 2>/dev/null | head -1 || true)
  if [[ -n "$PY" ]]; then
    "$PY" -m venv "$LAB/venv"
    "$LAB/venv/bin/pip" install -q "ansible-core==$ANSIBLE_CORE" pyyaml
  elif [[ -n "$UV" ]]; then
    "$UV" venv -q --python 3.12 "$LAB/venv"
    "$UV" pip install -q --python "$LAB/venv/bin/python" "ansible-core==$ANSIBLE_CORE" pyyaml
  else
    echo "error: needs Python >= 3.12 with venv (Ubuntu: python3-venv; RHEL 9: dnf install python3.12) or uv" >&2; exit 2
  fi
  made "venv/ (ansible-core $ANSIBLE_CORE, $("$LAB/venv/bin/python" --version))"
fi
if [[ ! -d "$LAB/collections/ansible_collections" ]]; then
  ANSIBLE_COLLECTIONS_PATH="$LAB/collections" \
    "$LAB/venv/bin/ansible-galaxy" collection install -p "$LAB/collections" -r "$ROOT/requirements.yml" >/dev/null
  made "collections/"
fi

write() {   # name mode - content on stdin
  if [[ -e "$LAB/$1" ]]; then cat >/dev/null; return 0; fi
  cat > "$LAB/$1"; chmod "$2" "$LAB/$1"; made "$1"
}
say "scripts"
write tools.sh 0600 <<EOF
# The Ansible tooling for either lab, and nothing else: no secrets.
# Source this alone for the kickstart lab (with NIST_INVENTORY set);
# env.sh sources it and adds the BYO lab's secrets. Written by vm/byo-lab-init.sh.
export PATH=$LAB/venv/bin:\$PATH
export ANSIBLE_COLLECTIONS_PATH=$LAB/collections
EOF
if (( tools_only )); then say "done: source $LAB/tools.sh, or run make, which puts it on PATH"; exit 0; fi
write env.sh 0600 <<EOF
# Source from nist_sp_800_171r3/rl9-171 before ./apply.sh or ./verify.sh
# against the BYO lab. Reads its secrets from this directory; holds none.
# Written by vm/byo-lab-init.sh.
. $LAB/tools.sh
export NIST_BECOME_PASSWORD="\$(cat $LAB/byoadmin_password)"
# 03.10.07: the BYO hosts' GRUB superuser password.
export NIST_GRUB_PASSWORD="\$(cat $LAB/grub_password)"
# 03.05.03: the knowledge factor once sshd enforces publickey,password.
export SSH_ASKPASS=$LAB/askpass.sh
export SSH_ASKPASS_REQUIRE=force
# 03.03.05c over TLS: the CA and per-host certificates (tools/lab-pki.sh).
export NIST_PKI_DIR=$LAB/pki
EOF
write askpass.sh 0700 <<'EOF'
#!/usr/bin/env bash
# The SSH askpass for the BYO lab: the knowledge factor once 03.05.03 applies.
exec cat "$(dirname "$(readlink -f "$0")")/byoadmin_password"
EOF
write wrongpass.sh 0700 <<'EOF'
#!/bin/sh
# A deliberately wrong askpass, for the lockout rehearsals (03.01.08).
echo not-the-password
EOF
install -d -m 0700 "$LAB/pki"

key="${NIST_BYO_KEY:-$HOME/.ssh/id_rsa}"
[[ -f "$key.pub" ]] || echo "note: no $key.pub - create an RSA key (ssh-keygen -t rsa -b 3072) or set NIST_BYO_KEY before vm/byo-guest.sh build"
say "done: source $LAB/env.sh, then vm/byo-guest.sh build NAME --ip 192.168.171.N"
