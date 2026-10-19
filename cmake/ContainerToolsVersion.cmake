# Container Tools is its own upstream (see INGREDIENTS.md), versioned YYYYMMDD.N. release.yml's ver
# job decides the version and stamps it into VERSION (a gitignored build product) before anything
# configures. A dev build with no VERSION gets the committed UPSTREAM_VERSION, the bare date.
#
# Not shipyard's mavericks_resolve_version(): that derives <upstream>-mavericks.N, the port scheme.
function(container_tools_version out root)
  if(EXISTS "${root}/VERSION")
    file(STRINGS "${root}/VERSION" _ver LIMIT_COUNT 1)
  elseif(EXISTS "${root}/UPSTREAM_VERSION")
    file(STRINGS "${root}/UPSTREAM_VERSION" _ver LIMIT_COUNT 1)
  endif()
  string(STRIP "${_ver}" _ver)
  # platform: CMake's regex has no {n} repetition, so the eight date digits are spelled out
  if(NOT _ver MATCHES "^[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9](\\.[0-9]+)?$")
    message(FATAL_ERROR "container-tools: version '${_ver}' (from ${root}/VERSION or UPSTREAM_VERSION) is not YYYYMMDD[.N]; a VERSION left by an older build is a gitignored build product, so delete it")
  endif()
  set(${out} "${_ver}" PARENT_SCOPE)
endfunction()
