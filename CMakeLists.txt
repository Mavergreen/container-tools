cmake_minimum_required(VERSION 3.15)

# LANGUAGES NONE: nothing is compiled natively. The real 10.9/x86_64 enforcement is
# the go build flags below + the compat_guard gate, NOT CMake's compiler vars.
project(mavericks_docker LANGUAGES NONE)

# shipyard is needed in BOTH modes: the build-artifact gate scripts (compat_guard, sdk_coverage) for
# the Go builds, AND clone_pinned.sh -- the digest-verified git fetch used for every pinned source,
# including the iso's boot2docker clone. (The 10.9 SDK, target flags, and legacy shim come from the go126
# toolchain's CC wrapper; sdk_coverage fetches its own reference SDK via --fetch-script.)
# Found up here rather than further down because the version resolution below needs it.
find_package(MavericksShipyard REQUIRED)

# The product version (feeds the .pkg name + the release tag). NOT passed to project(VERSION ...): the
# mavericks scheme (20260727-mavericks.15) is not a valid CMake version, and nothing here needs
# PROJECT_VERSION -- MAVERICKS_DOCKER_VERSION carries it.
#
# Derived, never committed: UPSTREAM_VERSION plus the shipped tags decide it, and VERSION is written as
# a build product. The committed VERSION this replaces had drifted to 20260727-mavericks.2 while
# releases were at .14 -- which also made the tag path (it asserted tag == VERSION) unsatisfiable.
mavericks_resolve_version(MAVERICKS_DOCKER_VERSION)

set(CMAKE_OSX_DEPLOYMENT_TARGET 10.9)
set(CMAKE_OSX_ARCHITECTURES x86_64)

# Build-mode detection at configure time. "iso" = Docker-driven boot2docker.iso build
# (its own preset; no Go/SDK, no native/cross). Otherwise: "native" = compiling ON
# Mavericks 10.9 (pkgsrc go126 present), "cross" = a modern host cross-compiling for 10.9.
if(MAVERICKS_DOCKER_EXPECTED_MODE STREQUAL "iso")
  set(MAVERICKS_DOCKER_MODE "iso")
else()
  set(MAVERICKS_DOCKER_MODE "cross")
  # Native 10.9 Go toolchain. Prefer the mavericks-golang native .pkg (/usr/local/go126):
  # its go.env ships the CC wrapper the build relies on (SDK + target flags + legacy shim). pkgsrc go126
  # (/opt/pkg/go126) is a fallback that only works once that wrapper is upstreamed into it.
  set(MAVERICKS_DOCKER_NATIVE_GO "")
  foreach(_cand "/usr/local/go126/bin/go" "/opt/pkg/go126/bin/go")
    if(EXISTS "${_cand}")
      set(MAVERICKS_DOCKER_NATIVE_GO "${_cand}")
      break()
    endif()
  endforeach()
  if(MAVERICKS_DOCKER_NATIVE_GO)
    execute_process(COMMAND sw_vers -productVersion
      OUTPUT_VARIABLE _osv OUTPUT_STRIP_TRAILING_WHITESPACE ERROR_QUIET)
    if(_osv MATCHES "^10\\.9\\.")
      set(MAVERICKS_DOCKER_MODE "native")
    endif()
  endif()
endif()
message(STATUS "container-tools ${MAVERICKS_DOCKER_VERSION} — build: ${MAVERICKS_DOCKER_MODE}")

# Require a per-mode preset: nothing may configure into an unqualified "build/" that
# can't tell native from cross (and would clobber the synced tree). The presets set
# MAVERICKS_DOCKER_EXPECTED_MODE + a distinct binaryDir (build-native / build-cross).
if(NOT DEFINED MAVERICKS_DOCKER_EXPECTED_MODE)
  message(FATAL_ERROR
    "Configure via a preset: 'cmake --preset native' on Mavericks, or "
    "'cmake --preset cross' on a modern host. Direct 'cmake -B <dir>' is disabled.")
endif()
# And fail fast if a preset is used on the wrong machine.
if(NOT MAVERICKS_DOCKER_EXPECTED_MODE STREQUAL MAVERICKS_DOCKER_MODE)
  message(FATAL_ERROR "preset expects a '${MAVERICKS_DOCKER_EXPECTED_MODE}' build but this machine "
    "does a '${MAVERICKS_DOCKER_MODE}' build — wrong preset for this host.")
endif()


if(NOT MAVERICKS_DOCKER_MODE STREQUAL "iso")
  # The Go compiler: go126-cross on PATH (cross) or the mavericks-golang native go126 .pkg (native). Both
  # ship the CC wrapper as the default CC in go.env, so a plain `go build` targets darwin/amd64 10.9
  # correctly and links the legacy shim. (native therefore REQUIRES the .pkg toolchain, not pkgsrc go126.)
  if(MAVERICKS_DOCKER_MODE STREQUAL "native")
    set(MAVERICKS_DOCKER_GO "${MAVERICKS_DOCKER_NATIVE_GO}")
  else()
    set(MAVERICKS_DOCKER_GO "go")
  endif()
endif()

# Read a component's REPO/REF/DIGEST pin from components/<name>/version. DIGEST (the commit sha) is
# what clone_pinned.sh verifies the checkout against; REF is the human/version label. Renovate keeps
# both current via the git-refs/currentDigest customManager.
function(mavericks_docker_read_pin dir out_repo out_ref out_digest)
  file(STRINGS "${dir}/version" _lines)
  foreach(_l IN LISTS _lines)
    if(_l MATCHES "^REPO=(.+)$")
      set(_repo "${CMAKE_MATCH_1}")
    elseif(_l MATCHES "^REF=(.+)$")
      set(_ref "${CMAKE_MATCH_1}")
    elseif(_l MATCHES "^DIGEST=(.+)$")
      set(_digest "${CMAKE_MATCH_1}")
    endif()
  endforeach()
  set(${out_repo}   "${_repo}"   PARENT_SCOPE)
  set(${out_ref}    "${_ref}"    PARENT_SCOPE)
  set(${out_digest} "${_digest}" PARENT_SCOPE)
endfunction()

include(ExternalProject)
enable_testing()

# --- iso mode: Docker-driven boot2docker.iso. No Go/SDK; requires a Docker daemon. ---
set(MAVERICKS_DOCKER_SRC_CACHE "${CMAKE_SOURCE_DIR}/.srccache" CACHE PATH
    "Shared cache dir for pinned dependency source clones")
if(MAVERICKS_DOCKER_MODE STREQUAL "iso")
  execute_process(COMMAND docker version
    RESULT_VARIABLE _dv OUTPUT_QUIET ERROR_QUIET)
  if(NOT _dv EQUAL 0)
    message(FATAL_ERROR "iso mode needs a reachable Docker daemon (`docker version` failed)")
  endif()

  mavericks_docker_read_pin("${CMAKE_SOURCE_DIR}/components/boot2docker" B2D_REPO B2D_REF B2D_DIGEST)
  # The pinned base image that replaces upstream's FROM (see cmake/rebase_dockerfile.sh).
  file(STRINGS "${CMAKE_SOURCE_DIR}/components/boot2docker/version" B2D_BASE REGEX "^BASE=")
  string(REGEX REPLACE "^BASE=" "" B2D_BASE "${B2D_BASE}")
  if(NOT B2D_BASE)
    message(FATAL_ERROR "components/boot2docker/version has no BASE= (the iso's pinned base image)")
  endif()
  set(B2D_SRC "${MAVERICKS_DOCKER_SRC_CACHE}/boot2docker-${B2D_REF}")
  set(B2D_OUT "${CMAKE_BINARY_DIR}/boot2docker")
  set(B2D_ISO "${B2D_OUT}/boot2docker.iso")
  ExternalProject_Add(boot2docker
    SOURCE_DIR       "${B2D_SRC}"
    DOWNLOAD_COMMAND sh "${MavericksShipyard_SCRIPTS}/clone_pinned.sh"
                       "${B2D_REPO}" "${B2D_REF}" "${B2D_DIGEST}" "${B2D_SRC}"
    UPDATE_COMMAND   ""
    CONFIGURE_COMMAND ""
    BUILD_IN_SOURCE  TRUE
    BUILD_COMMAND    sh "${CMAKE_SOURCE_DIR}/cmake/build_boot2docker.sh"
                       <SOURCE_DIR> "${B2D_OUT}" "${B2D_REF}" "${B2D_BASE}"
    INSTALL_COMMAND  ""
    BUILD_BYPRODUCTS "${B2D_ISO}"
  )
  # A REF bump changes SOURCE_DIR (so everything reruns); a BASE bump changes only the build step's
  # argument, which ExternalProject's stamps don't notice -- so rebuild when the pin file changes.
  ExternalProject_Add_StepDependencies(boot2docker build
    "${CMAKE_SOURCE_DIR}/components/boot2docker/version")

  # The iso's supply-chain gate is clone_pinned.sh (in the boot2docker DOWNLOAD_COMMAND above): the
  # source is verified against the pinned commit DIGEST or the build bails. There is deliberately no
  # frozen fingerprint of the *built* iso and no manual on-box boot "bless": those blocked bumps
  # without a shippability signal. We ship the from-source rebuild; runtime issues -> -mavericks.2.

  # Self-contained unit tests for the iso scripts.
  foreach(t boot2docker_pin_test boot2docker_build_script_test boot2docker_rebase_test boot2docker_ci_test)
    add_test(NAME ${t} COMMAND sh "${CMAKE_SOURCE_DIR}/tests/${t}.sh")
  endforeach()

  return()  # iso mode defines nothing from the Mac pipeline below
endif()

# --- component builds, gates, and unit tests ---
# The Go components are compiled by the go126 toolchain, whose default CC wrapper (in its $GOROOT/go.env)
# supplies the 10.9 SDK + target flags + the legacy-support shim + -Wl,-U weak-symbol allowances on the
# external link. So there is no legacy-support build here, and each build_*.sh takes only source/out/go/ref.
# compat_guard + sdk_coverage below are the arbiters that the result is actually 10.9-correct.
mavericks_docker_read_pin("${CMAKE_SOURCE_DIR}/components/docker-cli" DC_REPO DC_REF DC_DIGEST)
set(DC_OUT     "${CMAKE_BINARY_DIR}/docker-cli")
set(DOCKER_BIN "${DC_OUT}/docker")
set(DC_SRC     "${MAVERICKS_DOCKER_SRC_CACHE}/docker-cli-${DC_REF}")
ExternalProject_Add(docker_cli
  SOURCE_DIR       "${DC_SRC}"
  DOWNLOAD_COMMAND sh "${MavericksShipyard_SCRIPTS}/clone_pinned.sh"
                     "${DC_REPO}" "${DC_REF}" "${DC_DIGEST}" "${DC_SRC}"
  UPDATE_COMMAND   ""
  BUILD_IN_SOURCE  TRUE
  CONFIGURE_COMMAND ""
  BUILD_COMMAND    sh "${CMAKE_SOURCE_DIR}/cmake/build_docker_cli.sh"
                     <SOURCE_DIR> "${DC_OUT}" "${MAVERICKS_DOCKER_GO}" "${DC_REF}"
  INSTALL_COMMAND  ""
  BUILD_BYPRODUCTS "${DOCKER_BIN}"
)

# docker-machine (GOPATH/dep era: no go.mod, vendored). Cloned into a GOPATH-shaped path
# so GO111MODULE=off can build it. The toolchain's CC wrapper handles the target + legacy shim.
mavericks_docker_read_pin("${CMAKE_SOURCE_DIR}/components/docker-machine" DM_REPO DM_REF DM_DIGEST)
set(DM_GOPATH   "${MAVERICKS_DOCKER_SRC_CACHE}/docker-machine-${DM_REF}")
set(DM_SRC      "${DM_GOPATH}/src/github.com/docker/machine")
set(DM_OUT      "${CMAKE_BINARY_DIR}/docker-machine")
set(MACHINE_BIN "${DM_OUT}/docker-machine")
ExternalProject_Add(docker_machine
  SOURCE_DIR       "${DM_SRC}"
  DOWNLOAD_COMMAND sh "${MavericksShipyard_SCRIPTS}/clone_pinned.sh"
                     "${DM_REPO}" "${DM_REF}" "${DM_DIGEST}" "${DM_SRC}"
  UPDATE_COMMAND   ""
  BUILD_IN_SOURCE  TRUE
  CONFIGURE_COMMAND ""
  BUILD_COMMAND    sh "${CMAKE_SOURCE_DIR}/cmake/build_docker_machine.sh"
                     <SOURCE_DIR> "${DM_OUT}" "${MAVERICKS_DOCKER_GO}" "${DM_GOPATH}"
  INSTALL_COMMAND  ""
  BUILD_BYPRODUCTS "${MACHINE_BIN}"
)

# docker-compose (Compose v2; a go.mod module, not vendored). Simpler than docker-machine:
# a normal module build (deps from the shared module cache); the toolchain wrapper handles the link.
mavericks_docker_read_pin("${CMAKE_SOURCE_DIR}/components/docker-compose" CO_REPO CO_REF CO_DIGEST)
set(CO_SRC      "${MAVERICKS_DOCKER_SRC_CACHE}/docker-compose-${CO_REF}")
set(CO_OUT      "${CMAKE_BINARY_DIR}/docker-compose")
set(COMPOSE_BIN "${CO_OUT}/docker-compose")
ExternalProject_Add(docker_compose
  SOURCE_DIR       "${CO_SRC}"
  DOWNLOAD_COMMAND sh "${MavericksShipyard_SCRIPTS}/clone_pinned.sh"
                     "${CO_REPO}" "${CO_REF}" "${CO_DIGEST}" "${CO_SRC}"
  UPDATE_COMMAND   ""
  BUILD_IN_SOURCE  TRUE
  CONFIGURE_COMMAND ""
  BUILD_COMMAND    sh "${CMAKE_SOURCE_DIR}/cmake/build_docker_compose.sh"
                     <SOURCE_DIR> "${CO_OUT}" "${MAVERICKS_DOCKER_GO}" "${CO_REF}"
  INSTALL_COMMAND  ""
  BUILD_BYPRODUCTS "${COMPOSE_BIN}"
)

# lazydocker (terminal UI for Docker; a go.mod module, root main package). Same module build as compose.
mavericks_docker_read_pin("${CMAKE_SOURCE_DIR}/components/lazydocker" LD_REPO LD_REF LD_DIGEST)
set(LD_SRC   "${MAVERICKS_DOCKER_SRC_CACHE}/lazydocker-${LD_REF}")
set(LD_OUT   "${CMAKE_BINARY_DIR}/lazydocker")
set(LAZY_BIN "${LD_OUT}/lazydocker")
ExternalProject_Add(lazydocker
  SOURCE_DIR       "${LD_SRC}"
  DOWNLOAD_COMMAND sh "${MavericksShipyard_SCRIPTS}/clone_pinned.sh"
                     "${LD_REPO}" "${LD_REF}" "${LD_DIGEST}" "${LD_SRC}"
  UPDATE_COMMAND   ""
  BUILD_IN_SOURCE  TRUE
  CONFIGURE_COMMAND ""
  BUILD_COMMAND    sh "${CMAKE_SOURCE_DIR}/cmake/build_lazydocker.sh"
                     <SOURCE_DIR> "${LD_OUT}" "${MAVERICKS_DOCKER_GO}" "${LD_REF}"
  INSTALL_COMMAND  ""
  BUILD_BYPRODUCTS "${LAZY_BIN}"
)

# Fail-closed build-artifact gates (run after `shipyard-cmake --build`).
add_test(NAME compat_guard
  COMMAND sh "${MavericksShipyard_SCRIPTS}/assert_binary_compatible.sh" "${DOCKER_BIN}")
add_test(NAME sdk_coverage
  COMMAND sh "${CMAKE_SOURCE_DIR}/cmake/sdk_coverage.sh"
             --fetch-script "${MavericksShipyard_SCRIPTS}/fetch_sdk.sh"
             "${DOCKER_BIN}")
# NB: there is deliberately NO frozen-gomod "characterize" gate here anymore. The family intent is to
# auto-merge patch/minor/major upstream bumps on a clear SHIPPABILITY signal (compat_guard + sdk_coverage
# below re-check the actual new binary: arch, 10.9 floor, no post-10.9 symbols, every import 10.9-available)
# and to fix any runtime regression in a -mavericks.2 repackage. A frozen reference of the module set
# diverges on *every* dependency bump -- it signals "something changed", not "unshippable" -- so it only
# blocked auto-merge without adding a 10.9-safety signal (identity is now pinned by the commit DIGEST
# the clone verifies). Removed 2026-07-31 -- and for the same reason boot2docker's frozen iso_fingerprint
# and manual iso_boot_proof went too; its supply-chain gate is the digest-verified clone.

# docker-machine through the same 10.9-safety gates.
add_test(NAME compat_guard_machine
  COMMAND sh "${MavericksShipyard_SCRIPTS}/assert_binary_compatible.sh" "${MACHINE_BIN}")
add_test(NAME sdk_coverage_machine
  COMMAND sh "${CMAKE_SOURCE_DIR}/cmake/sdk_coverage.sh"
             --fetch-script "${MavericksShipyard_SCRIPTS}/fetch_sdk.sh"
             "${MACHINE_BIN}")
# docker-compose through the same 10.9-safety gates.
add_test(NAME compat_guard_compose
  COMMAND sh "${MavericksShipyard_SCRIPTS}/assert_binary_compatible.sh" "${COMPOSE_BIN}")
add_test(NAME sdk_coverage_compose
  COMMAND sh "${CMAKE_SOURCE_DIR}/cmake/sdk_coverage.sh"
             --fetch-script "${MavericksShipyard_SCRIPTS}/fetch_sdk.sh"
             "${COMPOSE_BIN}")
# lazydocker through the same 10.9-safety gates.
add_test(NAME compat_guard_lazydocker
  COMMAND sh "${MavericksShipyard_SCRIPTS}/assert_binary_compatible.sh" "${LAZY_BIN}")
add_test(NAME sdk_coverage_lazydocker
  COMMAND sh "${CMAKE_SOURCE_DIR}/cmake/sdk_coverage.sh"
             --fetch-script "${MavericksShipyard_SCRIPTS}/fetch_sdk.sh"
             "${LAZY_BIN}")

# Unit tests (script behavior + output invariants). Output-asserting ones take the
# built artifact path; self-contained ones run from the source tree.
add_test(NAME docker_cli_unit
  COMMAND sh "${CMAKE_SOURCE_DIR}/tests/docker_cli_test.sh" "${DOCKER_BIN}")
# These exercise the gate scripts against the built binary -> pass DOCKER_BIN so they
# work with any build dir (shipyard-cmake -B <dir>), not a hardcoded build/.
add_test(NAME compat_guard_test
  COMMAND sh "${CMAKE_SOURCE_DIR}/tests/compat_guard_test.sh" "${DOCKER_BIN}" "${MavericksShipyard_SCRIPTS}/assert_binary_compatible.sh")
add_test(NAME sdk_coverage_test
  COMMAND sh "${CMAKE_SOURCE_DIR}/tests/sdk_coverage_test.sh" "${DOCKER_BIN}"
             "${MavericksShipyard_SCRIPTS}/fetch_sdk.sh")
# Self-contained (no built binary needed).
foreach(t scaffold_test renovate_test docker_compose_test docker_bootstrap_test docker_common_test docker_ctl_test docker_migrate_test docker_sync_image_test docker_menubar_test)
  add_test(NAME ${t} COMMAND sh "${CMAKE_SOURCE_DIR}/tests/${t}.sh")
endforeach()
add_test(NAME fetch_sdk_test
  COMMAND sh "${CMAKE_SOURCE_DIR}/tests/fetch_sdk_test.sh" "${MavericksShipyard_SCRIPTS}/fetch_sdk.sh")
