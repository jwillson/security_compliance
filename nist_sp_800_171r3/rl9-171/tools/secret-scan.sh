#!/usr/bin/env bash
#
# Scan the whole git history - every commit on every branch - for secrets,
# with gitleaks (TASKS.md R8). Run before the repository goes public, and in
# CI on every push so it stays clean.
#
#   tools/secret-scan.sh              scan; exit 1 on any finding
#
# gitleaks is downloaded once into ${XDG_CACHE_HOME:-~/.cache}/nist-gitleaks
# and verified against the SHA-256 pinned below - not against a checksums
# file fetched alongside it, which whoever could swap the binary could swap
# too. To upgrade: change VERSION and SHA256 together, from the release's
# published checksums.
#
# Findings are printed with the secret redacted. A finding is fixed by
# removing the secret from history and rotating it - never by an allowlist
# entry unless it is shown not to be a secret, with the reason in
# .gitleaks.toml.
#
set -euo pipefail
VERSION=8.30.1
SHA256=551f6fc83ea457d62a0d98237cbad105af8d557003051f41f3e7ca7b3f2470eb   # gitleaks_8.30.1_linux_x64.tar.gz

REPO="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"
CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/nist-gitleaks/$VERSION"
BIN="$CACHE/gitleaks"

if [[ ! -x "$BIN" ]]; then
  mkdir -p "$CACHE"
  tgz="$CACHE/gitleaks.tar.gz"
  curl -fsSL --retry 3 -o "$tgz" \
    "https://github.com/gitleaks/gitleaks/releases/download/v$VERSION/gitleaks_${VERSION}_linux_x64.tar.gz"
  echo "$SHA256  $tgz" | sha256sum -c --quiet - \
    || { rm -f "$tgz"; echo "error: gitleaks $VERSION does not match the pinned SHA-256" >&2; exit 2; }
  tar -xzf "$tgz" -C "$CACHE" gitleaks
  rm -f "$tgz"
fi

config=()
[[ -f "$REPO/.gitleaks.toml" ]] && config=(--config "$REPO/.gitleaks.toml")
echo "==> gitleaks $VERSION over $(git -C "$REPO" rev-list --all | wc -l) commits, all branches"
"$BIN" git "$REPO" --log-opts="--all" --redact --no-banner ${config[@]+"${config[@]}"}
