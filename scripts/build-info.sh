#!/bin/sh
# Writes the build date and git commit for the About panel (D34):
#
#   scripts/build-info.sh OUTFILE
#
# Run by the Flatpak manifest; OUTFILE is /app/share/deckvideoplayer/build-info.
# Format: key=value lines (date=2026-10-23, commit=1a2b3c4 or
# 1a2b3c4-modified when built with uncommitted changes; empty without git).
set -eu
out=$1
here=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
date=$(date -u +%Y-%m-%d)
commit=
if command -v git >/dev/null 2>&1; then
    g() { git -C "$here" -c safe.directory='*' "$@"; }
    if commit=$(g rev-parse --short HEAD 2>/dev/null); then
        g diff --quiet HEAD 2>/dev/null || commit="$commit-modified"
    else
        commit=
    fi
fi
printf 'date=%s\ncommit=%s\n' "$date" "$commit" > "$out"
