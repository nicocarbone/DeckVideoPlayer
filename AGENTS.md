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
| HDR / refresh rate / device detection | `…/dvp/display.lua`, `helper/dvp-gamescope-refresh.c` (D31), `app/share/deckvideoplayer/mpv/mpv.conf`, `app/bin/deckvideoplayer` |
| Folder listing, sources, sorting | `…/dvp/library.lua` |
| Plex (sign-in, servers, browse, playback, progress) | `…/dvp/plex.lua`, Plex parts of `…/dvp/browser.lua` and `…/main.lua`, `tools/plex-dev-account.py` |
| HTTP (curl) for all network features | `…/dvp/http.lua` |
| Headphone surround | `…/dvp/surround.lua`, `app/share/deckvideoplayer/hrtf/` (made by `tools/equalize-hrtf.py`, D48) |
| About panel, version, build info | `…/dvp/about.lua`, `…/dvp/version.lua`, `scripts/build-info.sh` |
| HDR choices (Video menu) | `…/dvp/hdr.lua` (D52), rows in `player:hdr_items()` |
| Video info panel (library) | `…/dvp/videoinfo.lua` (ffprobe / Plex metadata, D50) |
| Online subtitles | `…/dvp/opensubtitles.lua` (API), `…/dvp/subdownload.lua` (menu, storage), `tools/mock-opensubtitles.py` |
| Flatpak build | `packaging/flatpak/io.github.nicocarbone.DeckVideoPlayer.yml`, `scripts/build-flatpak.sh` |
| Steam integration | `scripts/install-steamos.sh`, `scripts/steam_shortcut.py`, `packaging/steam/` |

Full per-module API: `docs/CODE_REFERENCE.md`. Reasons behind each design
choice: `docs/DECISIONS.md` (add an entry when you make a new one). What
comes next: `docs/ROADMAP.md`.

## Commands

```sh
tests/run.sh                                   # unit tests (must stay green)
tools/make-test-media.sh                       # once: synthetic library in .dev/
tools/headless-run.sh -- gshot:/tmp/lib.png    # run in headless gamescope + screenshot
HDR=1 DEVICE=deck-oled tools/headless-run.sh -- key:DOWN key:DOWN key:DOWN key:ENTER sleep:2 key:i shot:/tmp/i.png
scripts/dev-run.sh --window --media .dev/test-media/Videos   # interactive, system mpv
scripts/build-flatpak.sh [--install]           # Flatpak bundle → dist/
MODE=flatpak tools/headless-run.sh -- …        # test the installed Flatpak
SURROUND=1 / OSMOCK=1 tools/headless-run.sh -- …   # v0.2 features (mock subtitle API)
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

## Current state (2026-10-26, v0.4.2)

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
- v0.2.0 released 2026-10-23 (tag `v0.2.0`): headphone surround (D27),
  OpenSubtitles downloads (D28–D30), refresh matching via gamescope_control
  (D31, confirmed on a Deck OLED), text scrolling (D32), SD card naming
  (D33), About panel (D34), second audit resolved (D35). Still open on a
  Deck: checklist items 11–12 (surround listening, real download).
- The repo is public: never commit API keys, tokens or passwords.
  OpenSubtitles keys are per user, in their `config.ini` (D29). Never
  commit details of the owner's Plex server either (addresses, names,
  library titles, ids, hashes from it): tests and docs use made-up data.
- v0.3.1 (D42): *Crop black bars* picture mode (`dvp/cropdetect.lua`),
  B dismisses the controls before stopping, *Recently played* on the
  start screen.
- v0.3.2 (D43): keep the screen awake while playing
  (`helper/dvp-keep-awake.c`, `dvp/keepawake.lua`): ScreenSaver inhibition
  verified on a Deck.
- v0.3.3–v0.3.5 (D44): CI builds the Flatpak on branch `stable` like
  `scripts/build-flatpak.sh` (releases up to v0.3.2 were `master`, which
  installed next to test builds); the installer removes other installed
  branches first and unpins the Steam shortcut (`steam_shortcut.py repair`). Keep both on `stable`.
- v0.3.6: fifth audit (Gemini, ISSUES.md Part V) reviewed and fixed in D45.
- Hardware tested informally by the owner (2026-10-24): Steam Deck OLED,
  Steam Deck LCD, DIY Steam Machine with official SteamOS (4K HDR VRR
  120 Hz TV; no refresh switching there, as designed). Docs describe this
  as light testing with no warranty; keep it that way.
- Every release gets a user-facing `CHANGELOG.md` section; CI publishes
  it as the GitHub release text (D41, `docs/DEVELOPMENT.md` §7).
- Adding or upgrading a Flatpak module: update `THIRD_PARTY_NOTICES.md`;
  `scripts/make-source-archive.py` picks the new pins up by itself (D36).
- v0.3.0 released 2026-10-24 (tag `v0.3.0`): Plex source (D37), QR
  sign-in and Plex subtitle downloads (D38), verified against the owner's
  server (local + remote address, 4K HDR10 direct play) and on a Deck. Third audit (ISSUES.md
  Part III) resolved in D39: https-only Plex, hardened curl, narrowed
  sandbox (Videos, Downloads, removable media; no whole home). Fourth
  audit (Gemini, Part IV) reviewed in D40.
  Testing against a real server: `tools/plex-dev-account.py`, read-only by
  default in `headless-run.sh` (never change the owner's watch history
  without `PLEX_WRITE=1`). Never let the account token reach mpv (logs):
  playback uses a transient token.
- v0.4.0 (2026-10-25): night mode (D46, `dvp/nightmode.lua`), skip intro /
  credits from Plex markers (D47, `dvp/markers.lua`, R2; *Next episode*
  verified read-only), headphone surround with a diffuse-field equalized
  HRTF and dialogue-matched level (D48, liked by the owner on a Deck);
  sixth audit (ISSUES.md Part VI) fixed in D49.
- v0.4.1 (2026-10-26, D50): Video info in the library (View),
  Plex videos in *Recently played*, *Remove from Continue watching*,
  Picture-mode fix after "No black bars found". HDR test build (D51)
  judged a matter of taste by the owner, so the choices ship as settings
  (D52, `dvp/hdr.lua`): a Video menu with Picture, refresh matching, HDR
  on/off, HDR mapping and SDR to HDR; defaults as in v0.4.0.
  Seventh audit (ISSUES.md Part VII) fixed in D53.
- v0.4.2 (2026-10-26): *Display, per scene* only for videos with
  per-scene metadata (D54).
- Planned: see `docs/ROADMAP.md`. Next, in order: next episode from
  *Continue watching*, Jellyfin, SMB/NFS;
  Flathub publication floating.
- Network code must stay asynchronous (`dvp/http.lua`) and only run on
  user request; secrets go on curl's stdin, never in argv. The only
  blocking calls are short ones inside mpv hooks, where playback waits
  anyway (Plex metadata/transient token in on_load, final progress report
  in on_unload).
