#!/bin/sh
# platform: host-agnostic
# Point a Dockerfile's one FROM at a pinned base image. Called by build_boot2docker.sh after the patch
# overlay. Upstream boot2docker hard-codes `FROM debian:bullseye-slim`, inside a pinned third-party
# checkout where Renovate can't see it -- so it rotted until bullseye left security support
# (bullseye-security's Release was last signed 2026-08-31; once that expired, apt-get update failed
# the iso build). The base is pinned in components/boot2docker/version (BASE=, Renovate-tracked) and
# substituted here. Anything but exactly one FROM is refused: which stage of a multi-stage Dockerfile
# to rebase is a decision, not a substitution.
#   usage: rebase_dockerfile.sh DOCKERFILE BASE
set -eu
[ $# -eq 2 ] || { echo "usage: $0 DOCKERFILE BASE" >&2; exit 64; }
F=$1; BASE=$2
n=$(grep -c '^FROM[[:space:]]' "$F" || true)
[ "$n" -eq 1 ] || { echo "$F: expected exactly one FROM, found $n" >&2; exit 1; }
tmp="$F.rebase.$$"
sed "s|^FROM[[:space:]].*|FROM $BASE|" "$F" > "$tmp"
mv "$tmp" "$F"
