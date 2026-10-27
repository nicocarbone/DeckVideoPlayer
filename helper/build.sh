#!/bin/sh
# Builds dvp-gamescope-refresh, dvp-keep-awake and dvp-discover into OUTDIR (default:
# .dev/bin). Used by the Flatpak manifest and by the dev/test scripts. Needs
# a C compiler, wayland-scanner, libwayland-client headers (libwayland-dev)
# and libsystemd headers (libsystemd-dev).
set -eu
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
out=${1:-"$here/../.dev/bin"}
mkdir -p "$out"
bin="$out/dvp-gamescope-refresh"
awake="$out/dvp-keep-awake"
discover="$out/dvp-discover"
# Skip when up to date (dev scripts call this on every run).
if [ -x "$bin" ] && [ "$bin" -nt "$here/dvp-gamescope-refresh.c" ] && [ "$bin" -nt "$here/gamescope-control.xml" ] &&
   [ -x "$awake" ] && [ "$awake" -nt "$here/dvp-keep-awake.c" ] &&
   [ -x "$discover" ] && [ "$discover" -nt "$here/dvp-discover.c" ]; then
    exit 0
fi
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
wayland-scanner client-header "$here/gamescope-control.xml" "$tmp/gamescope-control-client-protocol.h"
wayland-scanner private-code "$here/gamescope-control.xml" "$tmp/gamescope-control-protocol.c"
# shellcheck disable=SC2046
${CC:-cc} -O2 -Wall -Wextra -I"$tmp" -o "$bin" \
    "$here/dvp-gamescope-refresh.c" "$tmp/gamescope-control-protocol.c" \
    $(pkg-config --cflags --libs wayland-client)
# shellcheck disable=SC2046
${CC:-cc} -O2 -Wall -Wextra -o "$awake" "$here/dvp-keep-awake.c" $(pkg-config --cflags --libs libsystemd)
${CC:-cc} -O2 -Wall -Wextra -o "$discover" "$here/dvp-discover.c"
