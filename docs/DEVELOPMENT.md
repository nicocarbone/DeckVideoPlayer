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
| `xprop` (optional) | refresh-rate fallback with non-LuaJIT mpv |

Install the builder with `flatpak install --user flathub org.flatpak.Builder`.
`scripts/build-flatpak.sh` installs the Freedesktop SDK automatically.

## 2. Repository layout

```
app/                    exactly what gets installed under /app in the Flatpak
  bin/deckvideoplayer   launcher
  share/deckvideoplayer/config.ini, mpv/mpv.conf, mpv/scripts/deckplayer/{main.lua,dvp/*.lua}
packaging/              flatpak manifest, desktop/metainfo, icons, Steam artwork
scripts/                build-flatpak, install-steamos, steam_shortcut.py, dev-run
tools/                  test tooling: make-test-media, headless-run, mpv-ipc.py
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
tests/run.sh        # prints "[run] N checks, 0 failures", exit code 0/1
```

`tests/run.lua` runs inside mpv (`--script`), so modules that `require
"mp.utils"` load normally. It covers the pure logic: util (time format,
UTF-8, natural sort, paths), config parsing (lists, enums, invalid values,
warnings), refresh-rate selection (OLED discrete list, LCD range, NTSC
rates), library names and mountinfo parsing, resume thresholds, and media
labels. **Add a test for every pure function you add or change.**

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
`HDR=1`, `DEVICE=deck-oled|deck-lcd|tv`, `MEDIA`, `LOG`, `TIMEOUT`.

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

# Refresh matching (Deck OLED profile): expect "refresh rate -> 48 Hz for 24.000 fps"
DEVICE=deck-oled tools/headless-run.sh -- key:DOWN key:DOWN key:DOWN key:ENTER sleep:2 \
    get:display-fps-override

# Resume: play the 5-minute film, skip 2 min, stop, reopen -> dialog
tools/headless-run.sh -- key:DOWN key:DOWN key:ENTER sleep:1.5 key:PGDWN key:PGDWN \
    sleep:1 key:BS sleep:1 gshot:/tmp/resume-row.png key:ENTER gshot:/tmp/resume-dialog.png

# Same tests against the installed Flatpak (LuaJIT, SDL gamepad, bundled font, sandbox)
MODE=flatpak HDR=1 DEVICE=deck-oled tools/headless-run.sh -- key:DOWN key:DOWN key:DOWN \
    key:ENTER sleep:2.5 get:input-gamepad get:hwdec-current key:i sleep:1 shot:/tmp/fp.png
```

Screenshots of HDR (PQ) frames look oversaturated as PNG. That is normal.

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
`Inter-Regular.ttf: "Inter" "Regular"`.

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
- `release` (tags `v*`): attaches `DeckVideoPlayer.flatpak` and
  `DeckVideoPlayer-<tag>.tar.gz` (bundle + scripts + artwork + README) to a
  GitHub release. Users install from the tarball.

To release: bump `<release>` in the metainfo, commit, `git tag v0.x.y`,
push the tag.

## 8. On-device test checklist (Steam Deck OLED)

Things that can only be confirmed on hardware. Record the results in
DECISIONS.md or the README "Known limitations".

1. Install with `scripts/install-steamos.sh`; the shortcut and artwork
   appear in Gaming Mode (artwork may need a Steam restart).
2. Controller: D-pad, A/B/X/Y, L1/R1, L2/R2, View, Menu all respond (SDL via
   Steam Input's virtual pad).
3. HDR on: play an HDR10 file. Info panel shows `HDR passthrough · pq /
   bt.2020`; the picture is visibly HDR. HDR off: `SDR`, tone-mapped image.
4. Refresh: 23.976 fps → info panel `48 Hz (matched)`; Steam's performance
   overlay (level 1+) shows the panel refresh. Back in the library the
   previous rate is restored.
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

**Add a library source kind (e.g. SMB, Plex)**
1. In `library.sources()` return roots with a new `kind` (e.g.
   `{name="NAS", path="smb://nas/videos", kind="smb"}`).
2. Make `library.list(path, …)` dispatch on the kind or on the path scheme
   and return the same entry shape. `path` must be playable by `loadfile`:
   local path, `smb://` (needs FFmpeg/mpv with libsmbclient; add it to the
   manifest), `http(s)://` (Plex/Jellyfin direct-play URLs; add
   `--share=network` to finish-args).
3. `util.is_dir`/`file_info` don't apply to remote paths: keep remote calls
   out of `render()` and cache listings.
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
