#!/bin/bash
# Install Deck Video Player on SteamOS (run once from Desktop Mode, in Konsole).
#
#   scripts/install-steamos.sh [BUNDLE]   install/upgrade and add to Steam
#   scripts/install-steamos.sh --artwork  (re)install Steam library artwork
#   scripts/install-steamos.sh --uninstall
#
# BUNDLE defaults to dist/DeckVideoPlayer.flatpak next to this script.
# Everything is installed per-user: nothing touches SteamOS's read-only
# system partition, so it survives SteamOS updates.

set -euo pipefail

APP_ID=io.github.nicocarbone.DeckVideoPlayer
RUNTIME_BRANCH=25.08
here=$(cd -- "$(dirname -- "$0")" && pwd)
root=$(cd -- "$here/.." && pwd)
config_dir="$HOME/.config/deckvideoplayer"

say() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*"; }

steam_running() { pgrep -x steam >/dev/null 2>&1; }

# Uninstalls installed branches of the app (keeps settings and data):
# all of them, or all but KEEP (remove_installed_branches [KEEP]).
remove_installed_branches() {
    for ref in $(flatpak list --user --app --columns=ref 2>/dev/null | grep "^$APP_ID/"); do
        [ -n "${1:-}" ] && [ "${ref##*/}" = "$1" ] && continue
        flatpak uninstall --user -y --noninteractive "$ref" >/dev/null 2>&1 || true
    done
}

desktop_file() {
    local f
    for f in "$HOME/.local/share/flatpak/exports/share/applications/$APP_ID.desktop" \
             "/var/lib/flatpak/exports/share/applications/$APP_ID.desktop"; do
        [ -f "$f" ] && { echo "$f"; return 0; }
    done
    return 1
}

install_artwork() {
    # Steam writes shortcuts.vdf shortly after a shortcut is added.
    for _ in $(seq 1 15); do
        if python3 "$here/steam_shortcut.py" artwork >/dev/null 2>&1; then
            say "Steam library artwork installed (visible after restarting Steam)."
            return 0
        fi
        sleep 2
    done
    warn "Could not find the Steam shortcut yet. After restarting Steam run:"
    warn "  $0 --artwork"
}

# Set when the Steam shortcut still names a Flatpak branch that no longer
# exists (Steam was running): the closing message then says what to do.
shortcut_broken=0

add_to_steam() {
    if ! steam_running; then
        # Adds the shortcut to every Steam profile that lacks it, unpins an
        # existing one from a Flatpak branch and installs the artwork.
        say "Adding to Steam (or updating the shortcut)..."
        python3 "$here/steam_shortcut.py" add
        return 0
    fi
    if python3 "$here/steam_shortcut.py" status 2>/dev/null | grep -q 'app id'; then
        say "Already in your Steam library."
        # A shortcut made from the menu entry names a Flatpak branch; it
        # stops working when the app changes branch (v0.3.3), so unpin it.
        python3 "$here/steam_shortcut.py" repair >/dev/null || shortcut_broken=1
        python3 "$here/steam_shortcut.py" artwork >/dev/null 2>&1 || true
        return 0
    fi
    if command -v steamos-add-to-steam >/dev/null 2>&1 && desktop=$(desktop_file); then
        say "Adding to Steam..."
        steamos-add-to-steam "$desktop"
        install_artwork
    else
        warn "Steam is running: close Steam and run this script again,"
        warn "or add it manually: Steam > Add a Game > Add a Non-Steam Game > Deck Video Player."
    fi
}

case "${1:-}" in
    --artwork)
        python3 "$here/steam_shortcut.py" artwork
        exit 0
        ;;
    --uninstall)
        if steam_running; then
            warn "Close Steam first so the shortcut can be removed."
        else
            python3 "$here/steam_shortcut.py" remove || true
        fi
        remove_installed_branches
        say "Uninstalled. Your settings remain in $config_dir"
        exit 0
        ;;
esac

bundle=${1:-"$root/dist/DeckVideoPlayer.flatpak"}
if [ ! -f "$bundle" ]; then
    echo "Flatpak bundle not found: $bundle" >&2
    echo "Download DeckVideoPlayer.flatpak or build it with scripts/build-flatpak.sh" >&2
    exit 1
fi

say "Setting up Flathub (user installation)..."
flatpak remote-add --user --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo

say "Installing Deck Video Player..."
# Bundles built on another Flatpak branch (releases before v0.3.3 used
# "master", test builds "stable") would install next to the current one,
# and `flatpak run` would keep starting the old copy. Settings and data
# are kept.
# The bundle's own branch ("stable") is replaced by --reinstall, so a
# failed install never leaves the app missing.
remove_installed_branches stable
flatpak install --user -y --reinstall "$bundle"

say "Installing the gamescope Vulkan layer (needed for HDR in game mode)..."
flatpak install --user -y --noninteractive flathub "org.freedesktop.Platform.VulkanLayer.gamescope//$RUNTIME_BRANCH" \
    || warn "Could not install the gamescope layer; HDR videos will be tone-mapped to SDR."

if [ ! -f "$config_dir/config.ini" ]; then
    mkdir -p "$config_dir"
    # Owner-only: it may later hold an OpenSubtitles password.
    (umask 077 && flatpak run --command=cat "$APP_ID" /app/share/deckvideoplayer/config.ini > "$config_dir/config.ini")
    say "Created $config_dir/config.ini (set your video folders there)."
fi

add_to_steam

if [ "$shortcut_broken" = 1 ]; then
    cat <<EOF

Installed, but the Steam shortcut needs one more step.

Your "Deck Video Player" shortcut still points to the previous version, which
was just replaced, so launching it would return to Steam immediately.
Fix it in one of two ways:

  * Close Steam completely (in Desktop Mode: Steam menu > Exit), then run
    this script again; it repairs the shortcut by itself.
  * Or in Steam, open the shortcut's Properties and delete the
    "--branch=master" part from Launch options.

Your settings, resume points and Plex sign-in are not affected.
EOF
    exit 0
fi

cat <<EOF

Done! Return to Gaming Mode and launch "Deck Video Player" from your library
(Non-Steam section).

Tips:
  * Edit $config_dir/config.ini to set your video folders.
  * For HDR, enable HDR in Settings > Display (Steam Deck OLED / HDR TVs).
  * On an external 4K screen, set the game's Properties > Game Resolution to
    "Native" so the app renders at full resolution.
EOF
