# Architecture

This document explains how Deck Video Player is put together and why. Read
it first; then [CODE_REFERENCE.md](CODE_REFERENCE.md) for per-module detail,
[DECISIONS.md](DECISIONS.md) for the reasoning behind each choice, and
[DEVELOPMENT.md](DEVELOPMENT.md) for how to build and test.

## 1. Goals (from the original brief)

| # | Requirement | Where it is addressed |
|---|---|---|
| i | Play all video formats | FFmpeg (all decoders/demuxers) inside mpv |
| ii | Real HDR | mpv `vo=gpu-next` + `target-colorspace-hint` + gamescope WSI layer → HDR10 swapchain |
| iii | Hardware acceleration / low battery | VA-API decode, dmabuf → Vulkan zero-copy, no idle timers, "balanced" render profile |
| iv | Game-mode UI, controller only | Lua OSD UI, SDL2 gamepad input in mpv, Steam non-Steam shortcut |
| v | Simple file selection, folders in config.ini | `dvp/library.lua` + `~/.config/deckvideoplayer/config.ini` |
| vi | Use the 1280×800 90 Hz HDR panel | 800-unit-tall UI canvas, refresh-rate matching (48/72/50/60/90 Hz), HDR |
| vii | Subtitle and audio track selection | `dvp/player.lua` menus (X / Y buttons) |
| viii | Steam Machines, 4K HDR VRR | `tv` device profile, `high` quality, UI scales by aspect, VRR handled by gamescope |

User-chosen scope for v1: local folders (Plex added in v0.3, network shares later),
resume playback, refresh-rate matching, English UI.

## 2. Big picture

```
┌──────────────────────── SteamOS game mode ───────────────────────────┐
│ Steam client ── launches non-Steam shortcut ──┐                      │
│                                               ▼                      │
│   flatpak run io.github.nicocarbone.DeckVideoPlayer                  │
│   └─ /app/bin/deckvideoplayer  (POSIX sh launcher)                   │
│        · creates ~/.config/deckvideoplayer/config.ini if missing     │
│        · picks --gpu-context=x11vk under gamescope                   │
│        · enables --input-gamepad when mpv supports it                │
│        └─ exec mpv --config-dir=/app/share/deckvideoplayer/mpv …     │
│              │                                                       │
│              ├─ mpv.conf: idle + force-window, gpu-next/Vulkan,      │
│              │            hwdec, HDR hints, profiles                 │
│              ├─ scripts/deckplayer/main.lua  ← the whole UI          │
│              │     dvp/*.lua modules                                 │
│              ▼                                                       │
│   Vulkan swapchain (SDR sRGB or HDR10 PQ)                            │
│        └─ gamescope WSI layer (Flatpak extension)                    │
│              └─ gamescope compositor ── panel / TV (HDR, VRR)        │
└──────────────────────────────────────────────────────────────────────┘
```

There is **one process** (mpv). There is no separate GUI toolkit, web view
or helper daemon.

## 3. Why the UI lives inside mpv

gamescope only shows HDR from clients that present a Vulkan swapchain with
an HDR colorspace (it exposes them through its WSI layer). mpv can do that
when it owns its window (`vo=gpu-next`, `gpu-api=vulkan`). If mpv is
embedded in another toolkit through libmpv's render API, it renders through
OpenGL into the host's surface, and HDR passthrough is lost. A separate
launcher that spawns mpv as a second window works, but adds a process,
dependencies and window-focus handoff under gamescope.

Drawing the UI with mpv's own OSD (ASS overlays rendered by libass) keeps
HDR, zero-copy hardware decoding and the smallest possible footprint. The
trade-off is that the UI is built from vector shapes and text rather than
widgets. `dvp/ui.lua` hides that behind a small drawing toolkit.

## 4. Runtime model

mpv is started with `idle=yes` and `force-window=immediate`, so it keeps a
window open with no file loaded.

```
            start                 A on a file                      file ends /
  ┌────────────┐  idle-active=true ┌─────────────┐ loadfile   ┌──────────┐  B pressed
  │ mpv starts │ ────────────────▶ │  BROWSER    │ ─────────▶ │  PLAYER  │ ──────────┐
  └────────────┘                   │ (library)   │ ◀───────── │ (overlay)│           │
                                   └─────────────┘ idle-active└──────────┘           │
                                         ▲                         │ playlist-next   │
                                         └─────────────────────────┴─────────────────┘
```

- `state.screen` in `main.lua` is `"browser"` or `"player"`.
- Files passed on the command line ("Open with") start playback before the
  library is ever used: such an *external* session quits when it ends
  instead of returning to the browser (DECISIONS D21).
- `start-file` event → player screen; `idle-active == true` → browser.
- A **menu stack** (`dvp/menu.lua`) can sit on top of either screen; while a
  menu is open it receives all input.

### Input routing

`dvp/input.lua` binds every gamepad button and keyboard key once, as forced
bindings, to an abstract **action** (`up`, `down`, `left`, `right`,
`confirm`, `back`, `x`, `y`, `menu`, `view`, `lb`, `rb`, `lt`, `rt`,
`playpause`, `stop`, `quit`). `main.lua` dispatches each action:

```
action ─▶ quit?            → quit()
       ─▶ menu open?       → menu:handle(action)
       ─▶ screen=="player" → player:handle(action)
       ─▶ otherwise        → browser:handle(action)
```

mpv's built-in key bindings are disabled (`input-builtin-bindings=no`), so
nothing else reacts to keys. The default OSC is disabled (`osc=no`).

### Drawing model

Each visual element is a **layer**: an mpv `ass-events` OSD overlay with a
z-order.

| z | Layer | Owner |
|---|---|---|
| 0 | Library browser (full screen) | `browser.lua` |
| 10 | Playback overlay (title, progress, hints) | `player.lua` |
| 20 | Playback info panel | `player.lua` |
| 50 | Menus and dialogs | `menu.lua` |
| 60 | Toast notifications | `main.lua` |

Layers redraw **only** when something changes: input, a property observer,
or the 0.5 s timer that runs *only while the overlay or info panel is
visible*. A text too long for its box scrolls with a 24 Hz timer that runs
only while it scrolls and stops by itself after three passes (D32). During
normal playback with the overlay hidden, no Lua code runs except a resume
save every 30 s.

Coordinates are virtual: the canvas is 800 units tall (the Deck's native
height, divided by `ui_scale`) and as wide as the screen aspect requires
(1280 on the Deck, ~1422 on 16:9). libass scales that to the real
resolution, so 1280×800 and 3840×2160 use the same layout code.

## 5. Video pipeline and HDR

```
file ─▶ FFmpeg demux ─▶ VA-API decode (GPU, NV12/P010 surface)
          │                  │ dmabuf export (no copy)
          │                  ▼
          │        libplacebo (Vulkan): scaling, color mapping
          │                  │
          │                  ├─ SDR source  → sRGB swapchain
          │                  └─ HDR source  → HDR10 (PQ/BT.2020) swapchain
          │                         + VkHdrMetadataEXT (mastering / CLL)
          ▼                  ▼
    audio decode ─▶ PipeWire     gamescope ─▶ panel
```

- `target-colorspace-hint=yes` makes mpv choose the swapchain colorspace from
  the source and send HDR metadata. It requires that the swapchain offers
  HDR formats, which happens only when:
  1. gamescope's HDR output is on (Steam: *Settings → Display → HDR*), and
  2. the gamescope WSI Vulkan layer is loaded (env `ENABLE_GAMESCOPE_WSI=1`,
     Flatpak extension `org.freedesktop.Platform.VulkanLayer.gamescope`,
     socket permission `xdg-run/gamescope-0`), and
  3. mpv renders through X11 + Vulkan (`--gpu-context=x11vk`). The layer
     intercepts Xlib/XCB Vulkan surfaces.
- If any of these is missing, mpv tone-maps HDR to SDR itself. The overlay
  badge shows `HDR10 → SDR` and the info panel shows `Output: SDR`.
- Subtitles stay at SDR reference white on HDR output (`sub-hdr-peak=203`).

Verified in headless gamescope (see DEVELOPMENT.md §5): the SDR swapchain is
`VK_COLOR_SPACE_SRGB_NONLINEAR_KHR`, and when an HDR10 file starts mpv
recreates it as `VK_COLOR_SPACE_HDR10_ST2084_EXT`.

## 6. Refresh-rate matching

Steam's refresh slider and our app both talk to gamescope through its
private Wayland protocol `gamescope_control`
(`set_app_target_refresh_cycle`). gamescope applies the request when the
display has a dynamic refresh table (Steam Deck LCD/OLED) and VRR is not
active; it recomputes the target every frame, so the *latest* request wins
(D31). The older `GAMESCOPE_DYNAMIC_REFRESH` X property no longer has a
lasting effect.

```
dvp/display.lua ──subprocess──► dvp-gamescope-refresh info|set HZ
                                   │  (Wayland: $XDG_RUNTIME_DIR/gamescope-0)
                                   ▼
                               gamescope ──► panel refresh
                                   │
GAMESCOPE_DISPLAY_REFRESH_RATE_FEEDBACK (X root property) ◄── read back by
dvp/display.lua (LuaJIT FFI → libX11, xprop fallback)
```

`dvp/display.lua`, on `file-loaded`:

1. `info` → the active display's valid rates as gamescope reports them
   (or `refresh_rates` from config.ini). Fewer than two rates: nothing to do.
2. Picks a rate that is an integer multiple of `container-fps` within 0.5%
   (`choose_rate`): the lowest by default (`refresh_prefer = low`, saves
   battery) or the highest. Examples on the OLED: 23.976 → 48 (or 72),
   25 → 50 (75 isn't valid), 29.97 → 60 (or 90).
3. Remembers the current rate once, sends `set HZ`.
4. Two seconds later reads the feedback property. Confirmed → sets
   `display-fps-override`, shows the Hz badge; not confirmed → logs it and
   the info panel says "90 Hz (asked for 48 Hz)".
5. On unpause, asks again if the live rate drifted (Steam re-applied its
   own setting).
6. Back in the library, on quit and on shutdown: asks for the previous rate
   (or native).

External displays and Steam Machines don't get dynamic refresh from
gamescope; with VRR enabled, gamescope follows mpv's frame pacing, so a
24 fps film is shown at a VRR multiple without any action from us.

## 7. Battery and efficiency choices

- Hardware decoding first: `hwdec=vaapi,vulkan,auto-safe` (set from
  config). On the Deck's VCN 3 this covers H.264, HEVC Main/Main10, VP9 and
  AV1.
- Zero-copy: VA-API surfaces are imported into Vulkan via dmabuf
  (`video/out/hwdec/dmabuf_interop_pl.c` in mpv). OpenGL is not involved.
- `video-sync=audio`, `interpolation=no`: mpv presents exactly the video
  frames, with no extra frames rendered.
- Quality profiles in `mpv.conf`: `dvp-quality-balanced` (Deck default:
  mpv defaults + hermite downscaling, no HDR peak detection, no debanding),
  `dvp-quality-battery` (bilinear everything, `profile=fast`) and
  `dvp-quality-high` (`profile=high-quality`, the default on TV / Steam
  Machine).
- No Lua timers while the overlay is hidden; layers only re-render on change.
- Refresh matching prefers the lowest valid multiple (48 Hz instead of 72 Hz
  for films).

## 8. Data and files at runtime

| Path | Content | Writer |
|---|---|---|
| `~/.config/deckvideoplayer/config.ini` | User settings (copied from the default on first run) | user / launcher |
| `~/.config/deckvideoplayer/mpv.conf` | Optional raw mpv overrides (`--include`d last) | user |
| `$XDG_DATA_HOME/deckvideoplayer/resume.json` (Flatpak: `~/.var/app/io.github.nicocarbone.DeckVideoPlayer/data/deckvideoplayer/`) | Resume positions, watched flags, chosen audio/sub track per file | `dvp/resume.lua` |
| `$XDG_DATA_HOME/deckvideoplayer/plex.json` | Plex sign-in: client id, account token, servers and their addresses (mode 600) | `dvp/plex.lua` |
| `$XDG_DATA_HOME/deckvideoplayer/subtitles/<moviehash>/<release>.<lang>.srt` | Subtitles downloaded from OpenSubtitles, one folder per video (keyed by the video's hash, so moves/renames keep them) | `dvp/subdownload.lua` |
| `/app/share/deckvideoplayer/` | Default config, `mpv/mpv.conf`, Lua scripts, `hrtf/` (headphone surround HRTF) | Flatpak build |

`resume.json` format:

```json
{"version": 1,
 "entries": {
   "/home/deck/Videos/Film.mkv": {"pos": 1234, "duration": 7200, "aid": "2", "sid": "no",
                                  "watched": true, "t": 1792722130}}}
```

`pos` is present only between 30 s and the "finished" threshold (last 5%,
at least 60 s, at most 25% of the length). `t` is the last update time; the
store keeps the 1000 most recent entries. Writes are atomic (temp file +
rename).

## 9. Packaging

- **Flatpak** `io.github.nicocarbone.DeckVideoPlayer` on runtime
  `org.freedesktop.Platform//25.08`. It builds LuaJIT, libXpresent,
  uchardet, libass, zimg, a decode-only FFmpeg (with libmysofa for the
  headphone-surround filter), libplacebo, mpv 0.41 (with
  `sdl2-gamepad`, `lua=luajit`) and installs the Inter font plus the app
  files. Flathub's `io.mpv.Mpv` can't be used because it is built without
  SDL2 gamepad support.
- Sandbox permissions: X11 + Wayland, PulseAudio + PipeWire, `--device=all`
  (GPU, VA-API, `/dev/input` for SDL), `xdg-run/gamescope-0` (HDR layer),
  read-only `xdg-videos`, `xdg-download`, `/run/media`, `/media`, `/mnt`
  (not the whole home, D39), read-write `xdg-config/deckvideoplayer`,
  network (online subtitles D28, Plex D37), and talking to
  `org.freedesktop.ScreenSaver` (keep the screen awake during playback,
  D43).
- **Steam integration**: `scripts/install-steamos.sh` installs the bundle
  per-user, installs the gamescope layer extension and adds a non-Steam
  shortcut (via `steamos-add-to-steam` while Steam runs, or by editing
  `shortcuts.vdf` directly when it doesn't) with grid/hero/logo/icon
  artwork.

## 10. Optional features (v0.2)

- **Headphone surround** (`dvp/surround.lua`, D27): an mpv audio filter
  (`lavfi` → FFmpeg `sofalizer`) inserted only while the decoded audio has
  more than two channels. Purely event-driven (one property observer), no
  timers.
- **Online subtitles** (`dvp/opensubtitles.lua` + `dvp/subdownload.lua`,
  D28–D30): network work happens only when the user opens
  *Download subtitles…*. HTTP is an asynchronous curl subprocess, so the UI
  keeps responding; results fill the open menu in place. Downloads are
  re-added from the `on_preloaded` hook on later plays.

## 11. Plex (v0.3)

Plex servers are library sources (D37). Network work happens only when
the user opens a Plex location or plays a Plex video: listings are
asynchronous curl requests (`dvp/http.lua`), the first visit to a server
probes its addresses in parallel and keeps the best reachable one for the
session. Playback is direct play of the original file; the on_load hook
fetches the resume point and subtitle files (blocking, 5 s max) and gives
mpv a transient token in an HTTP header. Progress goes back to the server
every 30 s, on pause and when the file closes.

## 12. Extension points

- **New library source kinds** (Jellyfin, SMB, …): Plex shows the shape
  (D37): roots via `library.sources(cfg, extra)`, an asynchronous lister
  dispatched from `browser:load()`, entries with a playable URL `path` and
  a `state` for progress, and an item registry the playback hooks use. See
  DEVELOPMENT.md "Recipes".
- **New actions/buttons**: add keys in `input.lua`, then handle the action in
  `browser:handle` / `player:handle`.
- **New menu entries**: add items to `player:main_menu_items()` or
  `browser:open_menu()`; items support `action`, `adjust` (◀ ▶ values) and
  `checked`.
- **New settings**: add to `SCHEMA` in `config.lua`, document in the default
  `config.ini`, and read via `cfg.<section>.<key>`.
