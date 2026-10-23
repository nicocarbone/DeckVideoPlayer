#!/bin/sh
# Run Deck Video Player from the source tree with the system mpv.
#
#   scripts/dev-run.sh [--window] [--gamescope] [--media DIR] [mpv args...]
#
#   --window     windowed 1280x800 instead of fullscreen
#   --gamescope  run nested in gamescope at 1280x800 (closest to game mode)
#   --media DIR  library folder to use (default: ~/Videos)
#
# Uses a throw-away config/data dir under .dev/ so your real
# ~/.config/deckvideoplayer is never touched.

set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
export DVP_CONFIG_DIR="$root/.dev/config"
export DVP_DATA_DIR="$root/.dev/data"
mkdir -p "$DVP_CONFIG_DIR" "$DVP_DATA_DIR"
# Refresh-rate helper (part of the Flatpak); harmless if the build fails.
if "$root/helper/build.sh" "$root/.dev/bin" 2>/dev/null; then
    export PATH="$root/.dev/bin:$PATH"
else
    echo "note: helper/build.sh failed (needs cc, wayland-scanner, libwayland-dev); refresh matching off" >&2
fi

window=0
nested=0
media=""
while [ $# -gt 0 ]; do
    case "$1" in
        --window) window=1; shift ;;
        --gamescope) nested=1; shift ;;
        --media) media=$2; shift 2 ;;
        *) break ;;
    esac
done

if [ ! -f "$DVP_CONFIG_DIR/config.ini" ]; then
    cp "$root/app/share/deckvideoplayer/config.ini" "$DVP_CONFIG_DIR/config.ini"
fi
if [ -n "$media" ]; then
    # Point the dev config at the requested folder.
    # Escape characters special in a sed replacement (\, &, and the | delimiter).
    media_esc=$(printf '%s' "$media" | sed 's/[\\&|]/\\&/g')
    sed -i "s|^folder = .*|folder = $media_esc|" "$DVP_CONFIG_DIR/config.ini"
fi

if [ "$window" = 1 ]; then
    set -- --fullscreen=no --geometry=1280x800 "$@"
fi

if [ "$nested" = 1 ]; then
    exec gamescope -W 1280 -H 800 -r 90 --hdr-enabled -- "$root/app/bin/deckvideoplayer" "$@"
fi
exec "$root/app/bin/deckvideoplayer" "$@"
