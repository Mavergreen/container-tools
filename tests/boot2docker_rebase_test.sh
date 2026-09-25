#!/bin/sh
# platform: host-agnostic
# rebase_dockerfile.sh: rewrites the Dockerfile's one FROM to the pinned BASE, leaving every other
# line alone; refuses (non-zero, file untouched) when there isn't exactly one FROM to rewrite.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
S="$ROOT/cmake/rebase_dockerfile.sh"
[ -f "$S" ] || { echo "missing $S" >&2; exit 1; }
sh -n "$S" || { echo "syntax error in $S" >&2; exit 1; }
T=$(mktemp -d "${TMPDIR:-/tmp}/boot2docker-rebase.XXXXXX"); trap 'rm -rf "$T"' EXIT
BASE='debian:12-slim@sha256:0000000000000000000000000000000000000000000000000000000000000000'

printf 'FROM debian:bullseye-slim\n\nRUN echo FROM here stays\n' > "$T/one"
sh "$S" "$T/one" "$BASE" || { echo "single-FROM rewrite failed" >&2; exit 1; }
printf 'FROM %s\n\nRUN echo FROM here stays\n' "$BASE" > "$T/want"
cmp -s "$T/one" "$T/want" || { echo "single-FROM rewrite wrong:" >&2; cat "$T/one" >&2; exit 1; }

printf 'FROM a AS x\nFROM b\n' > "$T/two"; cp "$T/two" "$T/two.orig"
if sh "$S" "$T/two" "$BASE" 2>/dev/null; then echo "expected refusal on two FROMs" >&2; exit 1; fi
cmp -s "$T/two" "$T/two.orig" || { echo "two-FROM Dockerfile was modified" >&2; exit 1; }

printf 'RUN true\n' > "$T/none"; cp "$T/none" "$T/none.orig"
if sh "$S" "$T/none" "$BASE" 2>/dev/null; then echo "expected refusal on no FROM" >&2; exit 1; fi
cmp -s "$T/none" "$T/none.orig" || { echo "no-FROM Dockerfile was modified" >&2; exit 1; }

if sh "$S" "$T/one" 2>/dev/null; then echo "expected refusal on missing BASE" >&2; exit 1; fi
echo "boot2docker_rebase_test: OK"
