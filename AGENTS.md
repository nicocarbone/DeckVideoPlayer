# AGENTS.md: orientation for AI agents and new contributors

Deck Video Player is a controller-driven video player for the Steam Deck
and SteamOS game mode. It is **mpv plus a Lua UI drawn on mpv's OSD**,
shipped as a Flatpak. Read `docs/ARCHITECTURE.md` before changing anything
non-trivial.

## Where things are

| Need to change… | Look at |
|---|---|
| Library screen | `app/share/deckvideoplayer/mpv/scripts/deckplayer/dvp/browser.lua` |
| Playback overlay, track menus, info panel | `…/dvp/player.lua` |
| Menus/dialogs component | `…/dvp/menu.lua` |
| Drawing primitives, icons, button glyphs, theme | `…/dvp/ui.lua` |
| Button → action mapping | `…/dvp/input.lua` |
| Wiring, lifecycle, resume save/restore | `…/main.lua` |
| Settings schema | `…/dvp/config.lua` + `app/share/deckvideoplayer/config.ini` |
| HDR / refresh rate / device detection | `…/dvp/display.lua`, `app/share/deckvideoplayer/mpv/mpv.conf`, `app/bin/deckvideoplayer` |
| Folder listing, sources (future SMB/Plex) | `…/dvp/library.lua` |
| Flatpak build | `packaging/flatpak/io.github.nicocarbone.DeckVideoPlayer.yml`, `scripts/build-flatpak.sh` |
| Steam integration | `scripts/install-steamos.sh`, `scripts/steam_shortcut.py`, `packaging/steam/` |

Full per-module API: `docs/CODE_REFERENCE.md`. Reasons behind each design
choice: `docs/DECISIONS.md` (add an entry when you make a new one).

## Commands

```sh
tests/run.sh                                   # unit tests (must stay green)
tools/make-test-media.sh                       # once: synthetic library in .dev/
tools/headless-run.sh -- gshot:/tmp/lib.png    # run in headless gamescope + screenshot
HDR=1 DEVICE=deck-oled tools/headless-run.sh -- key:DOWN key:DOWN key:DOWN key:ENTER sleep:2 key:i shot:/tmp/i.png
scripts/dev-run.sh --window --media .dev/test-media/Videos   # interactive, system mpv
scripts/build-flatpak.sh [--install]           # Flatpak bundle → dist/
MODE=flatpak tools/headless-run.sh -- …        # test the installed Flatpak
```

Visual changes: take screenshots with `tools/headless-run.sh` at 1280×800
**and** `W=3840 H=2160` and look at them before finishing.

## Rules of the codebase

- Lua must run on Lua 5.1, 5.2 and LuaJIT: no `goto`, `//`, `utf8`, integer
  division assumptions.
- No work while idle: layers redraw on change only; timers run only while
  the overlay/info panel is visible. Keep it that way (battery).
- Never put VO options (`vo`, `gpu-api`, `gpu-context`) in Lua; they must
  be in `mpv.conf` or the launcher.
- Every config key goes through `SCHEMA` in `config.lua`, the documented
  `config.ini` template and `docs/CONFIGURATION.md`.
- New pure logic gets unit tests: Lua in `tests/run.lua`, Python helpers in
  `tests/test_steam_shortcut.py` (both run by `tests/run.sh`).
- Keep the controls consistent: if you change a button, update the hint
  bars, `help()` in `main.lua`, README and `docs/DECISIONS.md` D10.
- Don't touch the user's real `~/.config/deckvideoplayer` or Steam files in
  tests: `dev-run.sh` and `headless-run.sh` use `.dev/`;
  `steam_shortcut.py` should be tested against a fake `HOME`.

## Current state (2026-10-23)

- v0.1.0: local folders + removable media, resume, watched markers,
  refresh-rate matching, HDR passthrough, track menus, Flatpak + SteamOS
  installer + Steam artwork.
- External audit (`ISSUES.md`, by Gemini) reviewed and resolved on
  2026-10-23: fixes and declined items are recorded in DECISIONS D20–D26.
- Verified in headless/nested gamescope on a desktop (HDR10 swapchain
  switch, refresh property, VA-API, SDL gamepad enabled in the Flatpak).
- v0.1.0 released 2026-10-23 (tag `v0.1.0`, GitHub release built by CI)
  after a first test on a real Steam Deck by the owner. The full on-device
  checklist in `docs/DEVELOPMENT.md` §8 has not been formally completed.
- Planned: network shares (SMB/NFS), Plex/Jellyfin, thumbnails, touch input.
