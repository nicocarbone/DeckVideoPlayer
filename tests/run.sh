#!/bin/sh
# Run the Lua unit tests with the system mpv (no window, no audio).
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
exec mpv --no-config --idle=once --vo=null --ao=null --really-quiet \
    --msg-level=all=error,run=info --script="$here/run.lua"
