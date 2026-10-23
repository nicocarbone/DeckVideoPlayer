#!/bin/sh
# Build the Flatpak and export a single-file bundle: dist/DeckVideoPlayer.flatpak
#
#   scripts/build-flatpak.sh [--install]
#
# Needs flatpak-builder (distro package) or the org.flatpak.Builder Flatpak.
# The first build compiles FFmpeg, libplacebo and mpv (~10-20 minutes).

set -eu
APP_ID=io.github.nicocarbone.DeckVideoPlayer
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"

install=0
[ "${1:-}" = --install ] && install=1

if command -v flatpak-builder >/dev/null 2>&1; then
    builder="flatpak-builder"
elif flatpak info org.flatpak.Builder >/dev/null 2>&1; then
    builder="flatpak run org.flatpak.Builder"
else
    echo "flatpak-builder not found. Install it with:" >&2
    echo "  flatpak install --user flathub org.flatpak.Builder" >&2
    exit 1
fi

flatpak remote-add --user --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo

$builder --user --install-deps-from=flathub --force-clean --ccache --disable-rofiles-fuse --default-branch=stable \
    --repo=repo build-dir "packaging/flatpak/$APP_ID.yml"

mkdir -p dist
flatpak build-bundle --runtime-repo=https://dl.flathub.org/repo/flathub.flatpakrepo \
    repo dist/DeckVideoPlayer.flatpak "$APP_ID" stable
echo "Bundle written to dist/DeckVideoPlayer.flatpak"

if [ "$install" = 1 ]; then
    flatpak install --user -y --reinstall dist/DeckVideoPlayer.flatpak
fi
