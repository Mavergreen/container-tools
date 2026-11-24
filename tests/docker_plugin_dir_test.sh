#!/bin/sh
# platform: host-agnostic
# docker finds docker-compose in its own tree's lib/docker/cli-plugins, wherever the tree is: the
# .pkg's install or an unpacked standalone archive. So the family patch adds a directory found from
# the docker executable itself (links resolved), never a fixed /usr/local/mavergreen path.
set -eu
R="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL: $1"; exit 1; }
P="$R/components/docker-cli/patches/0001-cli-plugins-in-the-container-tools-tree.patch"
[ -f "$P" ] || fail "docker needs the family patch that adds its tree's plugin directory to its search list"
grep -q '^+.*os\.Executable()' "$P" && grep -q '^+.*filepath\.EvalSymlinks' "$P" \
  || fail "the patch must locate the tree from the docker executable, through links"
grep -q '^+.*filepath\.Join(filepath\.Dir(exe), "\.\.", "lib", "docker", "cli-plugins")' "$P" \
  || fail "the patch must add <tree>/lib/docker/cli-plugins (../lib/docker/cli-plugins from bin/docker)"
! grep -q '^+.*/usr/local/mavergreen' "$P" || fail "the patch must not name /usr/local/mavergreen (the archive is relocatable)"
grep -q 'install -m 0755 "$DOCKER"  "$T/bin/docker"' "$R/cmake/package_pkg.sh" \
  && grep -q 'install -m 0755 "$COMPOSE" "$T/lib/docker/cli-plugins/docker-compose"' "$R/cmake/package_pkg.sh" \
  || fail "package_pkg.sh must stage docker in bin/ and compose in lib/docker/cli-plugins of the same tree"
grep -q 'components/docker-cli/patches' "$R/cmake/build_docker_cli.sh" || fail "build_docker_cli.sh must apply the docker-cli patches"
echo "PASS: docker_plugin_dir_test"
