#!/bin/sh
# platform: macOS-only -- sw_vers -productVersion decides native vs. cross build mode
# Shared helpers for build + gate scripts. POSIX sh; no bashisms.
# mavericks_docker_mode: "native" on the real 10.9 machine (pkgsrc go126 present), else "cross".
mavericks_docker_mode() {
  if [ -x /opt/pkg/go126/bin/go ] && [ "$(uname -s)" = Darwin ] \
     && sw_vers -productVersion 2>/dev/null | grep -q '^10\.9\.'; then
    echo native
  else
    echo cross
  fi
}

# mavericks_docker_die <msg...>: fail-closed helper for gates.
mavericks_docker_die() { echo "CANNOT MEASURE (fail-closed): $*" >&2; exit 4; }
