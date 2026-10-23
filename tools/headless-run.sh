#!/bin/sh
# Run the app inside a headless gamescope, drive it with tools/mpv-ipc.py,
# then quit. No window opens and no display is needed.
#
#   tools/headless-run.sh [options] [-- mpv-ipc steps...]
#
# Options (environment variables):
#   MODE=dev|flatpak   dev = source tree + system mpv (default),
#                      flatpak = installed io.github.nicocarbone.DeckVideoPlayer
#   MEDIA=DIR          library folder (default: .dev/test-media/Videos)
#   W=1280 H=800       virtual screen size (try W=3840 H=2160 for a TV)
#   HDR=1              gamescope HDR output (--hdr-enabled --hdr-debug-force-output)
#   DEVICE=deck-oled   device profile written to the test config
#   LOG=FILE           where to write the combined log (default: .dev/headless.log)
#   TIMEOUT=60         hard time limit in seconds
#
# Examples:
#   tools/headless-run.sh -- gshot:/tmp/library.png
#   HDR=1 DEVICE=deck-oled tools/headless-run.sh -- key:DOWN key:ENTER sleep:2 key:i shot:/tmp/info.png
#   MODE=flatpak tools/headless-run.sh -- key:ENTER sleep:2 get:hwdec-current
#
# The IPC socket lives in /tmp/dvp-ipc.sock (Unix socket paths must stay
# under ~108 characters). The test config/data dir is .dev/headless/ and is
# recreated on every run, so runs are reproducible.

set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
MODE=${MODE:-dev}
MEDIA=${MEDIA:-$root/.dev/test-media/Videos}
W=${W:-1280}; H=${H:-800}
DEVICE=${DEVICE:-auto}
LOG=${LOG:-$root/.dev/headless.log}
TIMEOUT=${TIMEOUT:-60}
SOCK=/tmp/dvp-ipc.sock
CFG=$root/.dev/headless

[ "${1:-}" = "--" ] && shift

if [ ! -d "$MEDIA" ]; then
    echo "No media in $MEDIA - run tools/make-test-media.sh first" >&2
    exit 1
fi

rm -rf "$CFG" "$SOCK"
mkdir -p "$CFG/config" "$CFG/data" "$(dirname "$LOG")"
sed -e "s|^folder = .*|folder = $MEDIA|" \
    -e "s|^device = .*|device = $DEVICE|" \
    -e "s|^removable_media = .*|removable_media = no|" \
    "$root/app/share/deckvideoplayer/config.ini" > "$CFG/config/config.ini"

gs_args="--backend headless -W $W -H $H"
[ "${HDR:-0}" = 1 ] && gs_args="$gs_args --hdr-enabled --hdr-debug-force-output"

mpv_args="--input-ipc-server=$SOCK --msg-level=all=warn,deckplayer=v"
if [ "$MODE" = flatpak ]; then
    # /tmp is private inside Flatpak: share it so the socket and media are reachable.
    cmd="flatpak run --filesystem=/tmp --filesystem=$root/.dev \
        --env=DVP_CONFIG_DIR=$CFG/config --env=DVP_DATA_DIR=$CFG/data \
        io.github.nicocarbone.DeckVideoPlayer $mpv_args"
else
    cmd="env DVP_CONFIG_DIR=$CFG/config DVP_DATA_DIR=$CFG/data $root/app/bin/deckvideoplayer $mpv_args"
fi

# shellcheck disable=SC2086
timeout "$TIMEOUT" gamescope $gs_args -- $cmd > "$LOG" 2>&1 &
gs_pid=$!

python3 "$root/tools/mpv-ipc.py" "$SOCK" sleep:2.5 "$@" 'raw:["quit"]' || true
wait "$gs_pid" || true

echo "--- app log ($LOG) ---"
grep -E '^\[deckplayer\]|Lua error|stack traceback|\[Gamescope WSI\].*colorspace|hdr formats exposed' "$LOG" || true
