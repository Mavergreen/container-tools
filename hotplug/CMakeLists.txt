cmake_minimum_required(VERSION 3.16)
# container-tools-hotplug: asks VMware Fusion to hot-add memory or CPUs to a running VM, through
# Fusion's own libvix, found at run time (dlopen) so nothing here links Fusion. Built by
# cmake/build_apps.sh like updater/ and menubar/ (clang22, x86_64 / min-10.9). Plain C, compiled as
# OBJC only because build_apps.sh drives one compiler for all three projects.
set(CMAKE_OSX_DEPLOYMENT_TARGET 10.9 CACHE STRING "runs on the 10.9 box")
set(CMAKE_OSX_ARCHITECTURES x86_64 CACHE STRING "Intel-only (10.9)")
project(ContainerToolsHotplug LANGUAGES OBJC)
find_package(MavericksShipyard REQUIRED)
set(MAVERICKS_REQUIRE_APPLECLANG OFF)
include(Mavericks)   # build conventions

add_executable(container-tools-hotplug main.m)
target_compile_options(container-tools-hotplug PRIVATE -Wall)
include(MavericksCompatGuard)
mavericks_assert_binary_compatible(container-tools-hotplug)   # pinned minos/SDK, no post-10.9 imports
