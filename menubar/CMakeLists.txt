cmake_minimum_required(VERSION 3.16)
# Menu-bar app for the container-tools product. Standalone project like updater/ (built
# on its own: `shipyard-cmake -S menubar -B build/menubar`). Native ObjC, x86_64 / min-10.9.
set(CMAKE_OSX_DEPLOYMENT_TARGET 10.9 CACHE STRING "runs on the 10.9 box")
set(CMAKE_OSX_ARCHITECTURES x86_64 CACHE STRING "Intel-only (10.9)")
project(DockerMenu LANGUAGES OBJC)
find_package(MavericksShipyard REQUIRED)
set(MAVERICKS_REQUIRE_LANGS OBJC)
include(Mavericks)   # AppleClang gate + build conventions

# Version from the repo root (this project's source dir is menubar/), derived not committed.
mavericks_resolve_version(MAVERICKS_DOCKER_VERSION ROOT "${CMAKE_SOURCE_DIR}/..")

# App icon: the product's shipping-container art (deliberately NOT a whale — see
# updater/ICON-CREDIT.txt), single-sourced from updater/ where the .icns is generated
# from the SVG. Bundled into Resources/ and named by CFBundleIconFile in Info.plist.in.
set(MENUBAR_ICON "${CMAKE_SOURCE_DIR}/../updater/container-tools-updater.icns")
set_source_files_properties("${MENUBAR_ICON}" PROPERTIES MACOSX_PACKAGE_LOCATION Resources)

add_executable(DockerMenu MACOSX_BUNDLE
  main.m AppDelegate.m MDController.m MDWatchers.m MDLoginItem.m
  "${MENUBAR_ICON}")
target_compile_options(DockerMenu PRIVATE -fobjc-arc -Wall)
set_target_properties(DockerMenu PROPERTIES
  MACOSX_BUNDLE_INFO_PLIST "${CMAKE_SOURCE_DIR}/Info.plist.in"
  MACOSX_BUNDLE_BUNDLE_NAME "Mavericks Container Tools"
  MACOSX_BUNDLE_GUI_IDENTIFIER "dev.modernmavericks.DockerMenu"
  MACOSX_BUNDLE_BUNDLE_VERSION "${MAVERICKS_DOCKER_VERSION}"
  MACOSX_BUNDLE_SHORT_VERSION_STRING "1.0"
  MACOSX_BUNDLE_ICON_FILE "container-tools-updater.icns")
target_link_libraries(DockerMenu "-framework Cocoa" "-framework CoreServices")
