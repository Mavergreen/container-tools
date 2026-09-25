#!/bin/sh
# platform: host-agnostic
# boot2docker pin is well-formed and Renovate-trackable: REPO + REF + a 40-hex commit DIGEST, which
# clone_pinned.sh verifies the checkout against (a moved tag bails). No separate golden.sha256 -- the
# commit digest IS the reproducibility pin (see the shared clone_pinned convention).
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
V="$ROOT/components/boot2docker/version"
[ -f "$V" ] || { echo "missing $V" >&2; exit 1; }
grep -qE '^REPO=https://github\.com/dragonflylee/boot2docker\.git$' "$V" \
  || { echo "version: bad/missing REPO" >&2; exit 1; }
grep -qE '^REF=v[0-9]+\.[0-9]+\.[0-9]+$' "$V" \
  || { echo "version: bad/missing REF" >&2; exit 1; }
grep -qE '^DIGEST=[0-9a-f]{40}$' "$V" \
  || { echo "version: bad/missing DIGEST (40-hex commit sha)" >&2; exit 1; }
# Renovate's git-refs/currentDigest manager matches components/*/version -> confirm the shape it parses:
# REPO=...git, then REF=..., then DIGEST=<40 hex>, in order.
awk '/^REPO=.*\.git$/{r=1;next} r&&/^REF=/{f=1;next} f&&/^DIGEST=[0-9a-f]{40}$/{ok=1} {r=0} END{exit ok?0:1}' "$V" \
  || { echo "version: REPO/REF/DIGEST not in the order Renovate parses" >&2; exit 1; }
# BASE replaces upstream's FROM (a Debian that has aged out of security support fails apt-get update
# outright): a numeric -slim tag, so Renovate can propose the next Debian major, pinned by digest.
grep -qE '^BASE=debian:[0-9]+-slim@sha256:[0-9a-f]{64}$' "$V" \
  || { echo "version: bad/missing BASE (debian:<N>-slim@sha256:<64 hex>)" >&2; exit 1; }
echo "boot2docker_pin_test: OK"
