#!/usr/bin/env bash
#
# Pin the control-plane image's base to the current Ubuntu 26.04 by digest
# (DEFECTS 7.23). A tag can be moved; a digest cannot, so the Containerfile
# names `ubuntu:26.04@sha256:...` and this is how that digest is chosen and
# renewed - run it, review the diff, rebuild (./nist --rebuild true), commit.
#
#   container/pin-base.sh            print the current digest and pin it
#
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REF=docker.io/library/ubuntu:26.04
if command -v skopeo >/dev/null 2>&1; then
  digest=$(skopeo inspect --format '{{.Digest}}' "docker://$REF")
else
  rt=$(command -v podman || command -v docker) || { echo "error: needs skopeo, podman or docker" >&2; exit 2; }
  "$rt" pull -q "$REF" >/dev/null
  digest=$("$rt" image inspect --format '{{index .RepoDigests 0}}' "$REF" | sed 's/.*@//')
fi
[[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || { echo "error: no digest for $REF ($digest)" >&2; exit 1; }
echo "$REF@$digest"
sed -i -E "s#^FROM docker\.io/library/ubuntu:26\.04(@sha256:[0-9a-f]+)?#FROM $REF@$digest#" "$HERE/Containerfile"
grep -n '^FROM' "$HERE/Containerfile"
