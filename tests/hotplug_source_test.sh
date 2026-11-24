#!/bin/sh
# platform: host-agnostic
# container-tools-hotplug asks Fusion to hot-add memory or CPUs to a running VM through libvix's
# undocumented VixVM_HotPlugMemory/VixVM_HotPlugCPU (spike, 2026-11-24). It must find libvix at run
# time (dlopen), never link it: the build runs on Linux with no Fusion, and a Mac without Fusion must
# get a clear error rather than a dyld crash. It ships in the tree's libexec/.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
fail() { echo "hotplug_source_test: FAIL: $*" >&2; exit 1; }
M="$ROOT/hotplug/main.m"; C="$ROOT/hotplug/CMakeLists.txt"
[ -f "$M" ] && [ -f "$C" ] || fail "hotplug/main.m and hotplug/CMakeLists.txt must exist"
grep -q 'dlopen(' "$M" || fail "libvix must be loaded with dlopen"
for f in VixHost_Connect VixVM_Open VixVM_HotPlugMemory VixVM_HotPlugCPU VixJob_Wait Vix_GetErrorText Vix_ReleaseHandle VixHost_Disconnect; do
  grep -q "dlsym([^,]*, *\"$f\")" "$M" || fail "$f must be looked up with dlsym"
done
grep -q 'MAVERICKS_DOCKER_LIBVIX' "$M" || fail "MAVERICKS_DOCKER_LIBVIX must override libvix's path"
grep -q '/Applications/VMware Fusion.app/Contents/Frameworks/libvix.dylib' "$M" || fail "the default libvix path must be Fusion's"
grep -v '^ *#' "$C" | grep -i 'target_link_libraries\|link_libraries\|-lvix' | grep -qi vix && fail "hotplug/CMakeLists.txt must not link libvix"
grep -q 'mavericks_assert_binary_compatible(container-tools-hotplug)' "$C" || fail "the helper must pass the 10.9 compat guard"
grep -q 'for app in updater menubar hotplug' "$ROOT/cmake/build_apps.sh" || fail "build_apps.sh must build hotplug"
grep -q 'libexec/container-tools-hotplug' "$ROOT/cmake/package_pkg.sh" || fail "package_pkg.sh must install libexec/container-tools-hotplug"
grep -q -- '--hotplug ' "$ROOT/.github/workflows/release.yml" || fail "release.yml must pass the helper to package_pkg.sh"
echo "hotplug_source_test: OK"
