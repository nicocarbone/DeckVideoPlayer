#!/bin/sh
# Run all unit tests:
#   - Lua modules, inside the system mpv (no window, no audio)
#   - the Steam shortcut helper, with Python's unittest
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
status=0
mpv --no-config --idle=once --vo=null --ao=null --really-quiet \
    --msg-level=all=error,run=info --script="$here/run.lua" || status=1
out=$(python3 -m unittest "$here/test_steam_shortcut.py" 2>&1) || status=1
printf '%s\n' "$out" | tail -n 3
# Release bookkeeping: the current version needs a CHANGELOG.md section
# (the GitHub release text) and a <release> in the metainfo.
version=$(sed -n 's/^return "\(.*\)"$/\1/p' \
    "$here/../app/share/deckvideoplayer/mpv/scripts/deckplayer/dvp/version.lua")
"$here/../scripts/release-notes.sh" >/dev/null || status=1
grep -q "<release version=\"$version\"" \
    "$here/../packaging/flatpak/io.github.nicocarbone.DeckVideoPlayer.metainfo.xml" ||
    { echo "metainfo has no <release> for $version" >&2; status=1; }
exit $status
