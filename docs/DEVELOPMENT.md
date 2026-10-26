# Development and testing

## 1. Environment

The app was developed on Ubuntu 26.04 (x86_64, NVIDIA RTX 4090) and targets
SteamOS. You need:

| Tool | Used for |
|---|---|
| `mpv` ≥ 0.38 (0.41 used) | running from source, unit tests |
| `gamescope` | nested/headless testing incl. HDR and refresh property |
| `ffmpeg` with libx264/libx265 | test media, rendering SVG artwork (librsvg decoder) |
| `python3` | IPC driver, Steam shortcut helper |
| `flatpak` + `org.flatpak.Builder` (or `flatpak-builder`) | building the bundle |
| `xprop` (optional) | reads gamescope's refresh feedback with non-LuaJIT mpv |
| `cc`, `wayland-scanner`, `libwayland-dev` | build the refresh-rate helper (`helper/build.sh`, run automatically by the dev scripts) |

Install the builder with `flatpak install --user flathub org.flatpak.Builder`.
`scripts/build-flatpak.sh` installs the Freedesktop SDK automatically.

## 2. Repository layout

```
app/                    exactly what gets installed under /app in the Flatpak
  bin/deckvideoplayer   launcher
  share/deckvideoplayer/config.ini, mpv/mpv.conf, mpv/scripts/deckplayer/{main.lua,dvp/*.lua},
                        hrtf/ (headphone-surround data)
helper/                 dvp-gamescope-refresh.c + gamescope-control.xml + build.sh (D31)
packaging/              flatpak manifest, desktop/metainfo, icons, Steam artwork
scripts/                build-flatpak, install-steamos, steam_shortcut.py, dev-run
tools/                  test tooling: make-test-media, headless-run, mpv-ipc.py, mock-opensubtitles.py;
                        equalize-hrtf.py makes the surround HRTF (D48)
tests/                  unit tests (run inside mpv)
docs/                   this documentation
.dev/                   (git-ignored) dev config, resume data, test media, logs
```

## 3. Running from source

```sh
tools/make-test-media.sh                 # once: synthetic library in .dev/test-media/Videos
scripts/dev-run.sh --window --media .dev/test-media/Videos
scripts/dev-run.sh --gamescope           # nested gamescope 1280x800@90 with HDR
```

`dev-run.sh` points `DVP_CONFIG_DIR`/`DVP_DATA_DIR` at `.dev/config` and
`.dev/data`, so your real `~/.config/deckvideoplayer` is never touched.
Distro mpv builds usually lack SDL2 gamepad support; use the keyboard
(arrows, Enter, Esc/Backspace, `x`, `y`, `m` = Menu, `i` = View, PgUp/PgDn
= L1/R1, Home/End = L2/R2).

Edit Lua files and restart. There is no build step for the UI.

## 4. Unit tests

```sh
tests/run.sh        # "[run] N checks, 0 failures" + "Ran N tests … OK"; exit code 0/1
```

Two suites:
- `tests/test_steam_shortcut.py` (Python `unittest`) covers the Steam helper:
  byte-identical VDF round trip including uint64 values, idempotent
  add/remove, and a failed save leaving `shortcuts.vdf` intact. Runs under a
  temporary fake `HOME`.
- `tests/run.lua` runs inside mpv (`--script`), so modules that `require
"mp.utils"` load normally. It covers the pure logic: util (time format,
UTF-8, natural sort, paths), config parsing (lists, enums, invalid values,
warnings), refresh-rate selection and helper output parsing (OLED discrete list, LCD range, NTSC
rates), library names and mountinfo parsing, resume thresholds, media
labels, the surround filter string and escaping, and the OpenSubtitles
helpers (hash against reference values, release-name parsing, languages,
query strings, result ranking, error texts) plus `menu:update`. **Add a
test for every pure function you add or change.**

The distro mpv usually runs Lua 5.2; the Flatpak runs LuaJIT. Run the
suite on LuaJIT too after touching Lua (needs the Flatpak installed):

```sh
flatpak run --command=mpv --filesystem=$PWD io.github.nicocarbone.DeckVideoPlayer \
    --no-config --idle=once --vo=null --ao=null --really-quiet \
    --msg-level=all=error,run=info --script=$PWD/tests/run.lua
```

## 5. Headless UI testing (no monitor needed)

This is the main automated way to see the UI and verify the HDR and
refresh behaviour. It is how all screenshots during development were made.

```sh
tools/headless-run.sh -- STEPS...
```

It starts `gamescope --backend headless` with the app inside (with a fresh
test config in `.dev/headless/`, the library pointing at the test media),
waits for the IPC socket, runs the steps with `tools/mpv-ipc.py`, quits,
and prints the relevant log lines (`[deckplayer]`, Lua errors, gamescope
WSI swapchain colorspace). Variables: `MODE=dev|flatpak`, `W`, `H`,
`HDR=1`, `DEVICE=deck-oled|deck-lcd|tv`, `MEDIA`, `LOG`, `TIMEOUT`,
`KEEP=1` (keep resume data from the previous run).

Step syntax (see `tools/mpv-ipc.py`): `key:DOWN`, `key:ENTER`, `key:BS`,
`key:x`, `key:y`, `key:m`, `key:i`, `sleep:2`, `get:hwdec-current`,
`shot:/tmp/a.png` (mpv screenshot with OSD; **only while a video plays**),
`gshot:/tmp/b.png` (gamescope screenshot; use this for the library screen),
`raw:'["seek","30"]'`.

With the test library, folders sort first: Documentaries, Series, then
"A Long Film (2023)", "HDR10 Sample 2160p", "The Test Movie …".

### Recipes

```sh
# Library screen at Deck resolution
tools/headless-run.sh -- gshot:/tmp/lib.png

# Same at 4K (layout scaling)
W=3840 H=2160 tools/headless-run.sh -- gshot:/tmp/lib4k.png

# Track menus and info panel on the multi-track movie
tools/headless-run.sh -- key:DOWN key:DOWN key:DOWN key:DOWN key:ENTER sleep:2 \
    key:y shot:/tmp/audio.png key:BS key:x shot:/tmp/subs.png key:BS \
    key:m shot:/tmp/menu.png key:BS key:i sleep:1 shot:/tmp/info.png

# HDR passthrough: expect "colorspace: VK_COLOR_SPACE_HDR10_ST2084_EXT" in the output
HDR=1 tools/headless-run.sh -- key:DOWN key:DOWN key:DOWN key:ENTER sleep:2.5 \
    key:i sleep:1 shot:/tmp/hdr.png get:video-target-params

# Refresh matching. Headless gamescope reports a single rate, so nothing is
# switched by default. RATES forces a list to exercise request + verify:
# expect "requested 48 Hz for 23.976 fps", then "requested 48 Hz but the
# display is at 60 Hz" (headless can't switch) and "Display: 60 Hz (asked
# for 48 Hz)" in the info panel. Only a real Deck shows "48 Hz (matched)".
RATES=48,60 DEVICE=deck-oled tools/headless-run.sh -- key:DOWN key:DOWN key:DOWN key:DOWN \
    key:ENTER sleep:3.5 key:i sleep:1 shot:/tmp/refresh.png
# Same with the Deck's layout (app on gamescope's second Xwayland, feedback
# not readable): expect "48 Hz (requested)". Toggle: m, 9x DOWN, ENTER.
XWAYLAND2=1 RATES=48,60 DEVICE=deck-oled tools/headless-run.sh -- key:DOWN key:DOWN key:DOWN \
    key:DOWN key:ENTER sleep:3.5 key:i sleep:1 shot:/tmp/refresh2.png
# Talk to gamescope directly (inside any gamescope session):
#   .dev/bin/dvp-gamescope-refresh info

# Resume: play the 5-minute film, skip 2 min, stop, reopen -> dialog
tools/headless-run.sh -- key:DOWN key:DOWN key:ENTER sleep:1.5 key:PGDWN key:PGDWN \
    sleep:1 key:BS sleep:1 gshot:/tmp/resume-row.png key:ENTER gshot:/tmp/resume-dialog.png

# Picture mode is per file: Fill on one movie, next file is back to Fit
tools/headless-run.sh -- key:DOWN key:DOWN key:DOWN key:DOWN key:ENTER sleep:2 key:m \
    key:DOWN key:DOWN key:DOWN key:DOWN key:DOWN key:DOWN key:DOWN key:DOWN key:RIGHT get:panscan \
    key:BS key:BS sleep:1 key:UP key:ENTER sleep:1.5 get:panscan      # 1.0, then 0.0

# External launch ("Open with"): auto-resume + toast, quits on stop.
# Run the resume recipe above first, then (KEEP=1 keeps its resume data):
KEEP=1 tools/headless-run.sh -- "raw:[\"loadfile\",\"$PWD/.dev/test-media/Videos/A Long Film (2023).mkv\"]" \
    sleep:1.2 shot:/tmp/toast.png get:time-pos key:BS    # then "mpv exited"

# Headphone surround: switch the test movie to its 5.1 track; expect the
# dvp-surround lavfi filter in "af" and "· headphone surround" in the info panel
SURROUND=1 tools/headless-run.sh -- key:DOWN key:DOWN key:DOWN key:DOWN key:ENTER sleep:2 \
    'raw:["set_property","aid",2]' sleep:1 get:af key:y shot:/tmp/audio.png key:BS key:i sleep:1 shot:/tmp/info.png

# Online subtitles against the mock API (no key or quota needed): X, UP to
# "Download subtitles…", A, A on the first result. Expect the mock's request
# log ("mock: GET /api/v1/subtitles…") and the new track selected.
OSMOCK=1 tools/headless-run.sh -- key:DOWN key:DOWN key:DOWN key:DOWN key:ENTER sleep:2 \
    key:x key:UP key:ENTER sleep:1.5 shot:/tmp/results.png key:ENTER sleep:1.5 \
    get:current-tracks/sub/title
# OSMOCK_LOGIN=1 adds an account (expect "POST /api/v1/login" and auth=yes on
# the download). Network failure: add the step
#   "sh:pkill -f 'mock-opensubtitles[.]py 8765'"
# before opening the menu (the [.] keeps pkill from matching the IPC
# driver, whose arguments contain this text).

# Same tests against the installed Flatpak (LuaJIT, SDL gamepad, bundled font, sandbox)
MODE=flatpak HDR=1 DEVICE=deck-oled tools/headless-run.sh -- key:DOWN key:DOWN key:DOWN \
    key:ENTER sleep:2.5 get:input-gamepad get:hwdec-current key:i sleep:1 shot:/tmp/fp.png
```

Screenshots of HDR (PQ) frames look oversaturated as PNG. That is normal.

**README screenshots** (`docs/screenshots/`) were made this way: a demo
library in `.dev/screens/Videos` whose files are symlinks to the *Sintel*
trailer (Blender Foundation, CC BY 3.0) remuxed with a stereo and a 5.1
track, three subtitle tracks and chapters; a hand-written `resume.json` in
`.dev/headless/data/` for the watched/progress marks (`KEEP=1` keeps it);
and `KEEP=1 MEDIA=… DEVICE=deck-oled XWAYLAND2=1 RATES=45,48,60,72,90
SURROUND=1 OSMOCK=1 MOCK_TITLE=Sintel.2010 tools/headless-run.sh -- …`
with `gshot:` steps. Seek right before a shot (`raw:["seek",…]`) to get the
same frame each time; seeking with `key:RIGHT` also shows the overlay.
Video shots are saved as JPEG (`ffmpeg -q:v 3`), flat UI shots as PNG.

Notes and pitfalls:
- Unix socket paths must be under ~108 characters; the tool uses
  `/tmp/dvp-ipc.sock`.
- Headless gamescope sometimes prints `Segmentation fault` while tearing
  down *after* mpv exited ("Primary child shut down"). It is a gamescope
  issue, not the app.
- In flatpak mode the tool adds `--filesystem=/tmp` and `.dev` because the
  sandbox `/tmp` is private.
- Don't run `xprop` against every X display in `/tmp/.X11-unix`: some
  servers (another session's) block waiting for authorization.

## 6. Building the Flatpak

```sh
scripts/build-flatpak.sh            # → dist/DeckVideoPlayer.flatpak (branch "stable")
scripts/build-flatpak.sh --install  # also install it for the current user
```

The first build compiles FFmpeg, libplacebo and mpv (~10 min on 32 cores;
much longer on a Deck). Rebuilds reuse `.flatpak-builder/` caches, so a
change only in `app/` takes under a minute. Inspect the build without
installing:

```sh
flatpak build build-dir sh -c 'mpv -v --no-config --vo=null --ao=null /dev/null 2>&1 | grep "enabled features"; fc-match Inter'
```

Expect `luajit sdl2-gamepad vaapi vulkan x11 wayland` among the features and
`Inter-Regular.ttf: "Inter" "Regular"`. The headphone-surround filter needs
FFmpeg's `--enable-libmysofa` (libmysofa comes from the runtime); check
with the `SURROUND=1` recipe in §5 in flatpak mode.

Manifest maintenance:
- Versions/commits are copied from Flathub's `io.mpv.Mpv` manifest
  (https://github.com/flathub/io.mpv.Mpv). Update them together.
- mpv option names are in mpv's `meson.options`. `vaapi-drm` was dropped:
  it needs mpv's DRM feature, which requires libdisplay-info, and the player
  never uses DRM output.
- Keep the runtime branch (25.08) in sync with the gamescope layer branch
  in `scripts/install-steamos.sh` (`RUNTIME_BRANCH`).

## 7. CI and releases

`.github/workflows/build.yml`:
- `tests`: installs mpv on Ubuntu and runs `tests/run.sh`.
- `flatpak`: builds the bundle in `ghcr.io/flathub-infra/flatpak-github-actions:freedesktop-25.08`.
- `release` (tags `v*`): attaches `DeckVideoPlayer.flatpak`,
  `DeckVideoPlayer-<tag>.tar.gz` (bundle + scripts + artwork + README) and
  `DeckVideoPlayer-<tag>-sources.tar.gz` (complete corresponding source,
  required by the GPL; `scripts/make-source-archive.py`, D36) to a GitHub
  release. Users install from the installer tarball. The release text is
  the tag's section of `CHANGELOG.md` (`scripts/release-notes.sh`, D41);
  the job fails if there is none.

The About panel shows the build date and commit automatically
(`scripts/build-info.sh`, D34); a bundle built with uncommitted changes
shows `<commit>-modified`.

To release: bump `dvp/version.lua` (and the year in `About.COPYRIGHT` if
needed), add a `## v0.x.y (date)` section to `CHANGELOG.md` (user-facing:
new, changed, fixed; it becomes the GitHub release text) and a `<release>`
to the metainfo, update `docs/ROADMAP.md` and the "Current state" of
`AGENTS.md`, commit, `git tag -a v0.x.y`, push the tag. `tests/run.sh`
fails while the changelog section or the metainfo entry is missing;
`scripts/release-notes.sh` prints the text CI will publish.

### Plex (against a real server)

Sign in once with a link code (creates `.dev/plex/client-id` and
`.dev/plex/token`, git-ignored; see D37), then give the headless test
data a signed-in account:

```sh
rm -rf .dev/headless && tools/plex-dev-account.py .dev/headless/data
# Sources → server → Movies → 2nd movie; info panel shows "Stream: Plex · … · local"
KEEP=1 HDR=1 DEVICE=deck-oled tools/headless-run.sh -- key:PGDWN key:ENTER sleep:2 \
    key:DOWN key:ENTER sleep:2 key:DOWN key:ENTER sleep:5 key:i sleep:1 shot:/tmp/plex.png
```

Runs are **read-only** by default (progress and watched changes are only
logged: `plex (read-only): would report …`). `PLEX_WRITE=1` sends them;
restore any item you changed afterwards (unscrobble + scrobble resets a
watched movie). To test the remote path, drop the local connections from
`.dev/headless/data/plex.json`. To check that no account token reaches the
logs: `MPV_EXTRA=--msg-level=all=v LOG=/tmp/v.log …`, then
`grep -c -F "$(cat .dev/plex/token)" /tmp/v.log` must print 0.

## 8. On-device test checklist (Steam Deck OLED)

Things that can only be confirmed on hardware. Record the results in
DECISIONS.md or the README "Known limitations".

1. Install with `scripts/install-steamos.sh`; the shortcut and artwork
   appear in Gaming Mode (artwork may need a Steam restart).
2. Controller: D-pad, A/B/X/Y, L1/R1, L2/R2, View, Menu all respond (SDL via
   Steam Input's virtual pad).
3. HDR on: play an HDR10 file. Info panel shows `HDR passthrough · pq /
   bt.2020`; the picture is visibly HDR. HDR off: `SDR`, tone-mapped image.
4. Refresh (D31): 23.976 fps → Steam's performance overlay shows 48 Hz
   (the Quick Access Menu slider keeps showing Steam's own value), the Hz
   badge appears and the info panel says `48 Hz (requested)`. Verified
   2026-10-23 on an OLED. The menu toggle *Match refresh rate* switches
   back to 90 Hz and again to 48 Hz. Then open the
   Quick Access Menu, close it, pause/unpause: the rate should come back to
   48 Hz. Back in the library the previous rate is restored. Try with
   Steam's "Use per-game profile" both off and on.
5. Hardware decoding for H.264, HEVC 10-bit, AV1: `Decoder: Hardware (vaapi)`.
6. Battery: note the battery draw (W) in the performance overlay for a
   1080p HEVC and a 4K HDR file at fixed brightness, with `quality =
   balanced` and `battery`, and record the numbers here for comparison.
7. Screen dimming: does the Deck dim or sleep during a 30-minute video?
   (gamescope has no idle inhibit; see Known limitations.)
8. Steam "Exit game" while playing, then relaunch: resume offered at the
   right position.
9. SD card: shows up as a source; files play.
10. Docked to a 4K HDR TV with Game Resolution = Native: UI sharp, HDR
    works, `tv`/`deck` profile as expected.
11. Headphone surround (v0.2): with headphones, a film with a 5.1 track.
    Toggle in the audio menu: dialogue stays centred, effects move around
    and behind, loudness and tone (bass, voices) don't change; the info panel says
    `· headphone surround`. A stereo video sounds the same either way.
12. Online subtitles (v0.2): over Wi-Fi in game mode, X → *Download
    subtitles…* on a real film. Results in your language, "Exact" on
    matching releases, download selects it, the toast shows downloads
    left, and the subtitle is back after replaying the film.
13. Plex (v0.3): sign in from the library menu in game mode (code shown
    big; enter it on a phone); the server appears as a source; play a
    movie and an episode; stop halfway and check another Plex app resumes
    at the same point; from outside the home network (phone hotspot), the
    info panel says `remote` and playback holds up for a 1080p file.

## 9. Recipes for common changes

**Add a controller action**
1. `dvp/input.lua`: add `myaction = {"GAMEPAD_…", "key"}` (and to
   `REPEATABLE` if it should auto-repeat).
2. Handle it in `browser:handle` and/or `player:handle`.
3. Update the hint bars (`browser:render` footer, `player:render` hints),
   `help()` in `main.lua`, the README controls table and DECISIONS D10.

**Add a playback-menu entry**: append to `player:main_menu_items()`. Use
`value = function() … end` for live values and `adjust = function(dir)` for
◀ ▶ settings. The menu uses `rebuild`, so values refresh after each change.

**Add a library source kind (e.g. Jellyfin, SMB)** — Plex is the model (D37)
1. Return roots from the new module and pass them to
   `library.sources(cfg, extra)` (see `plex:sources()`); give them a
   `kind` and a table describing the location (Plex uses `entry.plex`).
2. In `browser:load()`, dispatch such locations to an asynchronous lister
   (like `load_plex`): entries with `label`, `name`/`sort_name`, `mtime`,
   `is_dir`, a playable `path` (URL), and `state = {pos, duration,
   watched}` for progress. Use `dvp/http.lua` for requests.
3. Register playable paths so main.lua's hooks can find the item (headers,
   resume point, progress reports): see `plex:item_for(path)`.
4. Add an icon in `ui.lua` and use it in `browser:render` for the new kind.

**Change the look**: colors in `ui.theme` (accent is configurable),
layout constants at the top of `browser.lua` / `menu.lua` and in
`player:render()`. Verify at 1280×800 and 3840×2160 with the headless tool.

**Add a setting**: see CONFIGURATION.md "Adding a new setting".

## 10. Gotchas (learned the hard way)

- `screenshot-to-file … window` fails while mpv is idle (no video). Use
  gamescope screenshots for the library.
- `force-window=immediate` creates the VO before scripts run. VO options
  (`vo`, `gpu-api`, `gpu-context`) must come from mpv.conf or the launcher.
- `input-builtin-bindings=no` also removes `CLOSE_WIN → quit`; it is bound
  explicitly in `input.lua`.
- The variable Inter font is family "Inter Variable"; the Flatpak installs
  the static TTFs so `\fnInter` matches.
- LuaJIT `ffi.cdef` fails if the same types are declared twice in one Lua
  state; `display.lua` guards with `pcall` and does it once.
- Format-32 X11 properties are arrays of C `long` (64-bit on x86_64), not
  `int32`.
- `flatpak build-bundle` exports branch `master` unless told otherwise; the
  build script passes `stable` explicitly.
- `flatpak-builder` needs `--disable-rofiles-fuse` where FUSE isn't usable
  (containers, some sandboxes).
