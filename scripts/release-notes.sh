#!/bin/sh
# Print the CHANGELOG.md section of a release (default: the version in
# dvp/version.lua), without its heading. CI uses it as the GitHub release
# text; fails if the section is missing or empty, so every release has one.
#   scripts/release-notes.sh [v0.3.0]
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
version=${1:-v$(sed -n 's/^return "\(.*\)"$/\1/p' \
    "$root/app/share/deckvideoplayer/mpv/scripts/deckplayer/dvp/version.lua")}
case $version in v*) ;; *) version=v$version ;; esac
notes=$(awk -v v="$version" '
    /^## / { if (found) exit; found = ($2 == v); next }
    found' "$root/CHANGELOG.md" | sed -e '/./,$!d')
if [ -z "$(printf '%s' "$notes" | tr -d '[:space:]')" ]; then
    echo "CHANGELOG.md has no section for $version" >&2
    exit 1
fi
printf '%s\n' "$notes"
