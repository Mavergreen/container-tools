cmake_minimum_required(VERSION 3.16)
# Cocoa/Sparkle auto-updater .app for the container-tools product. This is a SEPARATE project from
# the docker build (the repo root is project(... LANGUAGES NONE) and guards against non-preset
# configures); build it on its own with `shipyard-cmake -S updater -B build/updater`. Native only: the product
# .pkg installs on the real 10.9 box, so the updater is x86_64 / min-10.9. It links Sparkle + Cocoa and
# NOTHING from docker (a Sparkle host has no product code) -- the release workflow asserts that.
set(CMAKE_OSX_DEPLOYMENT_TARGET 10.9 CACHE STRING "updater runs on the 10.9 box")
set(CMAKE_OSX_ARCHITECTURES x86_64 CACHE STRING "Intel-only (10.9)")

project(ContainerToolsUpdater LANGUAGES OBJC)

find_package(MavericksShipyard REQUIRED)
include(Mavericks)          # universal umbrella: AppleClang gate + build conventions
include(MavericksSparkle)   # the Sparkle updater .app builder

# Single-source the version from the repo root (this project's source dir is updater/). Derived
# from UPSTREAM_VERSION + the shipped tags, not read from a committed file.
mavericks_resolve_version(MAVERICKS_DOCKER_VERSION ROOT "${CMAKE_SOURCE_DIR}/..")

mavericks_add_updater_app(
  NAME ContainerToolsUpdater
  PRODUCT_NAME "Mavericks Container Tools"
  BUNDLE_ID dev.modernmavericks.ContainerToolsUpdater
  FEED_URL "https://github.com/ModernMavericks/container-tools/releases/latest/download/appcast.xml"
  # EdDSA pubkey read by default from this project's updater/ed25519_key.pub (source dir is updater/).
  ICON "${CMAKE_SOURCE_DIR}/container-tools-updater.icns"
  VERSION "${MAVERICKS_DOCKER_VERSION}"
  LOG_PREFIX "MavContainerToolsUpdater"
  CONFIRM_TITLE "Mavericks Container Tools updated"
  CONFIRM_BODY "Docker CLI, Compose, Machine, and the boot2docker image were updated."
  RELAUNCH_MARKER "/tmp/.container-tools-updater-relaunched"
  # After an install, offer to roll existing docker-machine hosts onto the new boot2docker.iso.
  POST_UPDATE_HELPER "/usr/local/bin/container-tools-sync-image"
  # no PANE_HINT_KEY -> background-found updates post an NSUserNotification (CLI product, no pane)
)
