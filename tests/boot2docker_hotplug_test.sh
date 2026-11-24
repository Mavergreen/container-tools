#!/bin/sh
# platform: host-agnostic
# The ISO's kernel accepts memory and CPUs VMware hot-adds to the running VM (docker-machine-ctl
# resize), and a udev rule brings an added CPU online; the kernel onlines added memory by itself
# (MEMORY_HOTPLUG_DEFAULT_ONLINE). The rule's file doubles as ctl's marker that this VM's kernel can
# take a hot-add (spike, 2026-11-24).
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
fail() { echo "boot2docker_hotplug_test: FAIL: $*" >&2; exit 1; }
P=$(grep -l '^+++ b/files/kernel-config.d/mavergreen-hotplug$' "$ROOT"/components/boot2docker/patches/*.patch || true)
[ -n "$P" ] || fail "no patch adds files/kernel-config.d/mavergreen-hotplug"
for c in CONFIG_MEMORY_HOTPLUG=y CONFIG_MEMORY_HOTPLUG_DEFAULT_ONLINE=y CONFIG_ACPI_HOTPLUG_MEMORY=y CONFIG_ACPI_HOTPLUG_CPU=y CONFIG_PSI=y; do
  grep -qx "+$c" $P || fail "the hot-plug fragment must set $c"
done
grep -q '^+++ b/files/udev/99-mavergreen-cpu-online.rules$' $P || fail "the patch must add files/udev/99-mavergreen-cpu-online.rules"
grep -qx '+SUBSYSTEM=="cpu", ACTION=="add", ATTR{online}="1"' $P || fail "the udev rule must online an added CPU"
grep -qx '+COPY files/udev/99-mavergreen-cpu-online.rules ./etc/udev/rules.d/' $P \
  || fail "the Dockerfile must copy the rule into the rootfs's /etc/udev/rules.d/"
echo "boot2docker_hotplug_test: OK"
