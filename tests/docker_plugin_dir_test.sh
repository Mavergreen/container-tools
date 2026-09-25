#!/bin/sh
# platform: host-agnostic
set -eu
R="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL: $1"; exit 1; }
P="$R/components/docker-cli/patches/0001-cli-plugins-in-the-container-tools-tree.patch"
dir=/usr/local/mavergreen/container-tools/lib/docker/cli-plugins
[ -f "$P" ] || fail "docker needs the family patch that adds $dir to its plugin search list (D2)"
grep -q "^+[[:space:]]*\"$dir\",\$" "$P" || fail "the patch must add $dir to defaultSystemPluginDirs"
grep -q 'T="$stage/usr/local/mavergreen/container-tools"' "$R/cmake/package_pkg.sh" \
  || fail "package_pkg.sh must stage the tree the patched docker searches"
grep -q 'install -m 0755 "$COMPOSE" "$T/lib/docker/cli-plugins/docker-compose"' "$R/cmake/package_pkg.sh" \
  || fail "the compose plugin must be staged in the tree's lib/docker/cli-plugins, the directory the patch adds"
grep -q 'components/docker-cli/patches' "$R/cmake/build_docker_cli.sh" || fail "build_docker_cli.sh must apply the docker-cli patches"
echo "PASS: docker_plugin_dir_test"
