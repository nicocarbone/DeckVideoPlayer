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
#   KEEP=1             keep resume data (.dev/headless/data) from the previous run
#   SURROUND=1         start with headphone_surround = yes
#   XWAYLAND2=1        two Xwayland servers, app on the second one (like
#                      SteamOS game mode, where Steam has the first)
#   RATES=48,60        force refresh_rates (headless gamescope reports a single
#                      rate, so this is how to exercise the request/verify path)
#   OSMOCK=1           run tools/mock-opensubtitles.py and point the app at it
#                      (port 8765; its request log is appended to LOG)
#   OSMOCK_LOGIN=1     also set a mock account (username/password)
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

# KEEP=1 keeps resume data from the previous run (to test resume behaviour).
if [ "${KEEP:-0}" = 1 ]; then rm -rf "$CFG/config" "$SOCK"; else rm -rf "$CFG" "$SOCK"; fi
mkdir -p "$CFG/config" "$CFG/data" "$(dirname "$LOG")"
# Escape characters special in a sed replacement (\, &, and the | delimiter).
media_esc=$(printf '%s' "$MEDIA" | sed 's/[\\&|]/\\&/g')
sed -e "s|^folder = .*|folder = $media_esc|" \
    -e "s|^device = .*|device = $DEVICE|" \
    -e "s|^removable_media = .*|removable_media = no|" \
    "$root/app/share/deckvideoplayer/config.ini" > "$CFG/config/config.ini"
if [ -n "${RATES:-}" ]; then
    sed -i "s|^refresh_rates = .*|refresh_rates = $RATES|" "$CFG/config/config.ini"
fi
if [ "${SURROUND:-0}" = 1 ]; then
    sed -i "s|^headphone_surround = .*|headphone_surround = yes|" "$CFG/config/config.ini"
fi

gs_args="--backend headless -W $W -H $H"
[ "${XWAYLAND2:-0}" = 1 ] && gs_args="$gs_args --xwayland-count 2"
[ "${HDR:-0}" = 1 ] && gs_args="$gs_args --hdr-enabled --hdr-debug-force-output"

mpv_args="--input-ipc-server=$SOCK --msg-level=all=warn,deckplayer=v"
mock_pid=
if [ "${OSMOCK:-0}" = 1 ]; then
    sed -i "s|^api_key *=.*|api_key = mockkey|" "$CFG/config/config.ini"
    if [ "${OSMOCK_LOGIN:-0}" = 1 ]; then
        sed -i -e "s|^username *=.*|username = mock|" -e "s|^password *=.*|password = secret|" "$CFG/config/config.ini"
    fi
    python3 "$root/tools/mock-opensubtitles.py" 8765 2> "$LOG.mock" &
    mock_pid=$!
    mpv_args="$mpv_args --script-opts-append=deckplayer-opensubtitles_url=http://127.0.0.1:8765/api/v1"
fi
if [ "$MODE" = flatpak ]; then
    # /tmp is private inside Flatpak: share it so the socket and media are reachable.
    cmd="flatpak run --filesystem=/tmp --filesystem=$root/.dev \
        --env=DVP_CONFIG_DIR=$CFG/config --env=DVP_DATA_DIR=$CFG/data \
        io.github.nicocarbone.DeckVideoPlayer $mpv_args"
else
    # The refresh-rate helper (built into the Flatpak) is built into .dev/bin.
    "$root/helper/build.sh" "$root/.dev/bin"
    cmd="env PATH=$root/.dev/bin:$PATH DVP_CONFIG_DIR=$CFG/config DVP_DATA_DIR=$CFG/data $root/app/bin/deckvideoplayer $mpv_args"
fi

# gamescope starts its child on the first server; with XWAYLAND2 the app is
# moved to the next display number, the second server.
second='if [ "$DVP_XWL2" = 1 ]; then export DISPLAY=:$(( ${DISPLAY#:} + 1 )); fi; exec "$@"'
# shellcheck disable=SC2086
DVP_XWL2=${XWAYLAND2:-0} timeout "$TIMEOUT" gamescope $gs_args -- sh -c "$second" sh $cmd > "$LOG" 2>&1 &
gs_pid=$!

python3 "$root/tools/mpv-ipc.py" "$SOCK" sleep:2.5 "$@" 'raw:["quit"]' || true
wait "$gs_pid" || true
if [ -n "$mock_pid" ]; then
    kill "$mock_pid" 2>/dev/null || true
    cat "$LOG.mock" >> "$LOG"
fi

echo "--- app log ($LOG) ---"
grep -E '^\[deckplayer\]|^mock:|Lua error|stack traceback|\[Gamescope WSI\].*colorspace|hdr formats exposed' "$LOG" || true
