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
exit $status
