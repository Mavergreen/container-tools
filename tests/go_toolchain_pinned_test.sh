#!/bin/sh
# platform: host-agnostic
# Every Go build runs the pinned toolchain (components/golang/version) or fails: GOTOOLCHAIN=local.
# go126's go.env says GOTOOLCHAIN=auto, so a go.mod asking for a newer Go once made it download
# stock Go, which built docker-compose 5.8.0 against the runner's SDK instead of 10.9's.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d "${TMPDIR:-/tmp}/go_toolchain_pinned_test.XXXXXX")
trap 'rm -rf "$T"' EXIT

cat > "$T/go" <<'EOF'
#!/bin/sh
printf '%s %s\n' "$1" "${GOTOOLCHAIN:-unset}" >> "$GO_STUB_LOG"
[ "$1" = version ] && { echo "go version go1.26.10 darwin/amd64"; exit 0; }
while [ $# -gt 0 ]; do [ "$1" = -o ] && { : > "$2"; exit 0; }; shift; done
exit 1
EOF
chmod +x "$T/go"

mkdir -p "$T/src"
printf 'module github.com/docker/compose/v5\n\ngo 1.99.0\n' > "$T/src/go.mod"
: > "$T/src/vendor.mod"; : > "$T/src/vendor.sum"
git -C "$T/src" init -q
git -C "$T/src" -c user.email=t@example.com -c user.name=t add -A
git -C "$T/src" -c user.email=t@example.com -c user.name=t commit -qm src

# The scripts find their patch overlays beside themselves; a copy in a tree with none applies none.
mkdir -p "$T/repo/cmake" "$T/repo/components/docker-cli/patches"
cp "$ROOT"/cmake/build_*.sh "$T/repo/cmake/"

fail=0
for b in docker_cli:v29.9.3 docker_compose:v5.8.0 docker_machine:"$T/gopath" lazydocker:v0.24.1; do
  name=${b%%:*}; arg4=${b#*:}
  log="$T/$name.log"; : > "$log"
  if ! GO_STUB_LOG="$log" GOTOOLCHAIN=auto sh "$T/repo/cmake/build_$name.sh" "$T/src" "$T/out-$name" "$T/go" "$arg4" >/dev/null 2>&1; then
    echo "go_toolchain_pinned_test: build_$name.sh failed against the stub go" >&2; fail=1; continue
  fi
  if grep -v ' local$' "$log" | grep -q .; then
    echo "go_toolchain_pinned_test: build_$name.sh ran go without GOTOOLCHAIN=local, so a go.mod asking for a newer Go downloads stock Go instead of failing on the pin:" >&2
    sed 's/^/  /' "$log" >&2; fail=1
  fi
done
[ "$fail" -eq 0 ] || exit 1
echo "go_toolchain_pinned_test: OK"
