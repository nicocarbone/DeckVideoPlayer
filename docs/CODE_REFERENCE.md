# Code reference

Every source file, what it does, its public API and the invariants to keep
when changing it. Paths are relative to the repository root; Lua modules
live in `app/share/deckvideoplayer/mpv/scripts/deckplayer/`.

Conventions used across the Lua code:

- Lua 5.1/5.2/LuaJIT compatible: no `goto`, no `//`, no `utf8` library, no
  integer-only `string.format` assumptions. The Flatpak uses LuaJIT and the
  distro mpv used in development often uses Lua 5.2.
- Modules return a table `M`. Stateful ones are classes (`M.new(...)`
  returns an instance with `M` as metatable, methods use `:`).
- Shared services are passed in a `ctx` table (dependency injection), not
  through globals.
- Colors are `"RRGGBB"` strings (converted to ASS `&HBBGGRR&` in `ui.lua`);
  opacity is 0..1.
- Coordinates are in the virtual canvas (`ui.size()`): 800 units tall at
  `ui_scale = 1`.

---

## Launcher: `app/bin/deckvideoplayer` (POSIX sh)

Runs inside the Flatpak (`/app/bin`) and from the source tree.

1. Resolves `APPDIR` (`$DVP_APPDIR` or `<script dir>/../share/deckvideoplayer`)
   and the mpv binary (`$DVP_MPV` or `mpv` on PATH).
2. Config dir `$DVP_CONFIG_DIR` (default `~/.config/deckvideoplayer`) and data
   dir `$DVP_DATA_DIR` (default `$XDG_DATA_HOME/deckvideoplayer`). Copies the
   default `config.ini` on first run.
3. `ini_get section key` is a tiny awk INI reader, used only for
   `[display] gpu_context`.
4. Builds the mpv command line:
   - `--config-dir=$APPDIR/mpv` (mpv ignores `~/.config/mpv`)
   - `--script-opts-append=deckplayer-config_file=…`, `deckplayer-data_dir=…`
     (read by `main.lua` through `mp.options`)
   - `--gpu-context=x11vk` + `ENABLE_GAMESCOPE_WSI=1` under gamescope (D5)
   - `--input-gamepad=yes` inside the Flatpak (`/.flatpak-info`), otherwise
     only if `mpv --list-options` has it (D17, D26)
   - `--include=$CONFIG_DIR/mpv.conf` if the user created one
   - then any arguments passed to the launcher (files, extra mpv options)

Environment variables, for development and tests: `DVP_APPDIR`, `DVP_MPV`,
`DVP_CONFIG_DIR`, `DVP_DATA_DIR`.

## mpv configuration: `app/share/deckvideoplayer/mpv/mpv.conf`

Grouped and commented in the file. Key points:

- App behaviour: `idle=yes`, `force-window=immediate`, `fullscreen`,
  `keep-open=no` (end of file → next or idle → browser),
  `cursor-autohide=always`, `osc=no`, `osd-bar=no`,
  `input-builtin-bindings=no`, unused built-in scripts disabled (console,
  select, context menu, positioning); `stats` stays loaded for "Advanced
  statistics".
- Rendering: `vo=gpu-next`, `gpu-api=vulkan`, `target-colorspace-hint=yes`,
  `video-sync=audio`, `interpolation=no`, `hwdec=auto-safe` (replaced at
  startup from config).
- Subtitles: Inter font, sizes for 800p, `sub-hdr-peak=203`.
- Profiles `dvp-quality-battery|balanced|high`, applied by `display.lua`.

Options that must exist before the window is created (`vo`, `gpu-api`,
`gpu-context`) belong here or in the launcher, **not** in Lua, because
scripts start after the VO is created with `force-window=immediate`.
Per-file options (`hwdec`, `alang`, `slang`, `sid`, …) may be set from Lua
at startup while idle.

## Default settings: `app/share/deckvideoplayer/config.ini`

The documented template copied to the user's config dir. Every key here
must exist in `config.lua`'s `SCHEMA` (unknown keys only produce warnings).
See [CONFIGURATION.md](CONFIGURATION.md).

---

## `main.lua`: entry point and wiring

Responsibilities:

- Sets `package.path` so `require "dvp.x"` works on every mpv version.
- Reads script-opts `config_file`, `data_dir`; loads config (warnings are
  logged with `msg.warn`).
- `apply_playback_options()` translates `[playback]` into mpv properties
  (`alang`, `slang`, subtitle selection mode (D9), volume, `audio-spdif`,
  `hwdec`; `auto` → `vaapi,vulkan,auto-safe`).
- Creates the services: `display` (D6), `resume`, `menu`, toast layer, and
  the two screens `browser` and `player` with a shared `ctx`:

  | ctx field | Meaning |
  |---|---|
  | `cfg` | parsed config |
  | `resume`, `menu`, `display` | service instances |
  | `play(list, start)` | load `list[1]` (replace) with start position `start`, append the rest |
  | `stop()` | save progress, `stop` → idle → browser |
  | `quit()` | save, restore refresh rate, `quit` |
  | `quit_dialog()` | "Quit?" dialog |
  | `help()` | controls list |
  | `toast(text)` | 1.8 s notification |

- Input dispatch (see ARCHITECTURE §4).
- Lifecycle hooks:
  - `on_load` hook: start position from `state.pending_start[path]` (set by
    `play`), else the resume position (auto-advanced playlist entries and
    external launches; remembered in `state.resumed_at` and announced with a
    toast on `file-loaded`); restores `aid`/`sid` from the resume entry (as
    `file-local-options`).
  - `on_unload` hook: `save_progress()` + flush. Properties are still
    readable here, for every end reason.
  - `start-file`: switch to the player screen. If the library never started
    playback (`state.from_ui` false), the session is external
    (`state.external`, D21).
  - `file-loaded`: remember the path, refresh-rate match on `container-fps`,
    `player:on_file_loaded()`, "Resumed at" toast.
  - `end-file` with `reason == "error"`: toast.
  - `idle-active` true: external session → quit; otherwise back to the
    browser, restore the refresh rate, move the cursor to the last played
    file.
  - `pause`: save on pause; tell the player (overlay stays while paused).
  - `osd-dimensions`: re-render everything (resolution changes, e.g. dock
    or undock).
  - `shutdown`: final save and refresh restore (Steam "Exit game" sends
    SIGTERM → mpv quits → this runs).
  - 30 s periodic timer: save progress while playing (crash safety).

## `dvp/util.lua`: pure helpers

`trim`, `split(s, sep)` (trims, drops empties), `clamp`, `round`,
`expand_path` (`~`, `$VAR`, `${VAR}`, strips trailing `/`), `join`,
`basename`, `dirname`, `extension` (lowercase), `strip_extension`,
`format_time(sec, force_hours)`, `ass_escape` (makes text literal for
libass, same technique as mpv's osc), `utf8_len`, `utf8_truncate(s, n)`
(adds `…`), `natural_key` (zero-pads digit runs to 12 → "Ep 2" < "Ep 10"),
`read_file`, `write_file_atomic` (tmp + rename), `is_dir`, `mkdir_p` (mpv
subprocess), `shallow_copy`.

## `dvp/config.lua`: config.ini parser and schema

- `SCHEMA[section][key] = {default, type, values?}` with types `list`,
  `bool`, `number`, `enum`, `string`. **This is the single source of truth
  for settings.**
- `parse_ini(text)` → `sections[section][key] = {values…}` (repeated keys
  kept; keys lowercased, `-`/space → `_`; full-line `#`/`;` comments only,
  because `;` separates folders; optional quotes stripped).
- `from_text(text)` → `cfg, warnings`. Invalid values fall back to the
  default with a warning; `library.folders` is an alias of `folder`; `list`
  values also split on `;`.
- `load(path)` adds `cfg.path` and `cfg.loaded`.
- `DEFAULT_EXTENSIONS`: video extensions used when the config doesn't set
  `extensions`.

## `dvp/ui.lua`: drawing toolkit

- `configure(cfg)`: `ui_scale` (clamped 0.5–3), accent color.
- `theme`: palette and font name.
- `size()` → virtual `W, H` from `osd-dimensions`.
- `layer(z)` → `{set(ass), clear(), visible}` wrapping an `ass-events`
  overlay. `set` updates `res_x/res_y` each time, so resizes are handled.
- `ass()` builder with methods returning `self`:
  - `raw(s)`, `build()`
  - `path(drawing, o)`: o = `color, opacity, border, border_color,
    border_opacity, blur, clip`
  - `rect(x, y, w, h, o)` (`o.radius` for rounded corners), `circle`,
    `polygon(points, o)`
  - `text(x, y, str, o)`: o = `size, color, opacity, align` (ASS numpad;
    default 4 = left-middle), `bold, italic, outline, clip, font`
  - icons: `icon_folder`, `icon_video`, `icon_drive`, `icon_check`,
    `icon_play`, `icon_pause`, `icon_triangle(dir)`
  - `button(btn, x, cy, s, o)`: controller glyphs `A B X Y`, `L1 R1 L2 R2`,
    `MENU`, `VIEW`, `DPAD`, `DPAD_LR`, `DPAD_UD`. Returns the width.
  - `hints({{btn, label}, …}, x_right, cy, o)`: right-aligned hint bar.
- `text_width(str, size)` and `fit_text(str, size, max_w)`: estimates
  (D12).
- `rrect_path` (exported) builds rounded rectangles with cubic Béziers
  (0.4477·r control offset ≈ circle).

Each drawing is its own ASS event: `{\an7\pos(0,0)\p1}` with absolute
coordinates. libass draws it at those coordinates (verified visually).

## `dvp/input.lua`: buttons → actions

`KEYS[action] = {key names…}`: mpv gamepad names (`GAMEPAD_ACTION_DOWN` =
A, `_RIGHT` = B, `_LEFT` = X, `_UP` = Y, `GAMEPAD_START` = Menu,
`GAMEPAD_BACK` = View, shoulders, triggers, D-pad, left stick) plus keyboard
keys for development. `REPEATABLE` actions auto-repeat while held (mpv's
`input-ar-delay/rate`). `init(dispatch)` registers one forced binding per
key.

## `dvp/library.lua`: sources and listings

- `sources(cfg)` → `{name, path, kind}`: configured folders that exist,
  plus removable media mount points (`kind = "removable"`) when enabled.
- `parse_mountinfo(text)` → mount points under `/run/media/…` or
  `/media/…` (handles `\040` escapes).
- `list(path, cfg, sort_mode)` → entries `{name, label, key, path, is_dir,
  mtime, size}`. Hidden files are skipped unless `show_hidden`; files are
  filtered by extension; folders come first; sorted by `natural_key` or by
  mtime (newest first).
- `display_name(name, is_dir, clean)`: strips the extension; with `clean`,
  `.`/`_` → spaces when the name has no spaces.

## `dvp/resume.lua`: playback state store

`new(data_dir)` (nil dir = in-memory, used by tests), `get(path)`,
`position(path)` (≥ 30 s or nil), `is_watched`, `is_finished(pos, dur)`
(static), `update(path, pos, dur, aid, sid)` (decides pos / watched),
`mark_watched`, `forget`, `flush()` (writes only when dirty, prunes to 1000
entries). Thresholds are `M.MIN_POSITION`, `M.END_MARGIN_MIN` and
`M.END_MARGIN_FRAC`.

## `dvp/display.lua`: device, profile, refresh rate

- `detect_device()` → `deck-oled` (DMI product `Galileo`), `deck-lcd`
  (`Jupiter`) or `tv`.
- `in_gamescope()`: `GAMESCOPE_WAYLAND_DISPLAY` set or
  `XDG_CURRENT_DESKTOP=gamescope`.
- `parse_rates("45-90" | "48,60,72")`, `choose_rate(fps, rates, prefer)`
  (pure, unit-tested).
- `get_root_cardinal(name)` / `set_root_cardinal(name, value|nil)`: X11
  root property access via LuaJIT FFI (`libX11.so.6`), falling back to
  `xprop`. `get` returns a number, `false` (unset) or `nil` (error).
- Instance: `new(cfg)` resolves device, quality and rates; `apply_profile()`
  applies `dvp-quality-*`, HDR off, display-resample; `match(fps)` → Hz or
  nil (stores the original value first; disables itself if X11 can't be
  reached); `restore()`.

## `dvp/media.lua`: descriptions

Language names (ISO 639-1/2), codec display names (DTS profile aware),
`track_label(t)` ("English · Commentary"), `track_detail(t)` ("TrueHD · 7.1 ·
Default"), `tracks(kind)`, `selected_track(kind)`,
`hdr_state(video_track?)` (pass a cached video track to avoid re-reading
`track-list`) → `source, output_hdr, video_params, target_params` (source:
`HDR10`/`HLG`/`Dolby Vision`/`SDR`; output from `video-target-params`), and
`resolution_badge(w, h)`.

## `dvp/menu.lua`: modal menus

Stack-based. A spec looks like:

```lua
menu:open({
  title = "Audio", subtitle = nil, message = nil,
  style = "side" | "center",         -- side panel (over video) or dialog
  items = {
    {label = "English", value = "AAC · Stereo", checked = true, action = fn},
    {label = "Subtitle size", value = fn_returning_text, adjust = function(dir) end},
    {label = "Library", header = true},  -- section title
    {label = "…", disabled = true},       -- skipped by the cursor
    {separator = true, disabled = true},
  },
  selected = 1,
  rebuild = fn,          -- regenerate items after an action/adjust (live values)
  close_action = "y",    -- extra action that closes it (toggle behaviour)
  on_cancel = fn,        -- called on B / close_all, not when an item is chosen
})
```

Handling: up/down move (wraps, skips disabled), L1/R1 jump to first/last,
left/right call `adjust(-1|1)`, A runs `action` (the menu is popped
**before** the action runs, so actions can open other menus or start
playback; `keep_open = true` prevents that) or `adjust(1)`, B pops, Menu
closes all side menus. `render()` draws the top menu only.

## `dvp/browser.lua`: library screen

State: `stack` of locations `{path, label, is_root?}`, `entries`,
`selected`, `scroll`, `cursor[path]` (remembered selection per folder),
`sort`.

- `refresh_sources()`: re-reads `library.sources()`; clears `is_root` on the
  top folder when the setup is no longer single-source (D23). Called by
  `show()`, `reload()` and when listing the root.
- `load()`: root (sources list) or folder listing. With exactly one source
  the root is skipped and that folder becomes the top level (`is_root`).
- `reload()`: refresh sources + listing, keeping the cursor. `at_start()`:
  true at the top level.
- Navigation: `enter`, `go_back` (top level → quit dialog), `select_path`.
- Playback: `open_file(index, from_start)` shows the resume dialog when
  there is a position; `playlist_from(index)` returns the folder's files
  from the chosen one (if `autoplay_next`).
- `open_menu()`: sort, reload, go to library start (whenever not
  `at_start()`), mark (un)watched, controls, quit.
- `render()`: background, header (title, breadcrumb, counts), rows (icon,
  label, status: chevron / ✓ / progress bar + time), scrollbar, empty
  states, footer hints that depend on the selected entry.

Layout constants: `HEADER_H`, `FOOTER_H`, `ROW_H`, `ROW_GAP`, `FS`.

## `dvp/player.lua`: playback screen

- Cached per-file data (D25): `title_text` (set in `start()`),
  `video_track` (set in `on_file_loaded()`), `chapters` (property
  observer).
- Picture mode (D20): `zoom_mode()` derives Fit/Fill/Stretch/Custom from
  `panscan`/`keepaspect`; `set_zoom()` marks `zoom_touched`; `start()`
  restores `zoom_defaults` captured at script start.
- Lifecycle: `start()` (on start-file), `on_file_loaded()`, `stop_screen()`, `show_overlay()`
  (auto-hides after `overlay_timeout`; stays while paused or while a menu is
  open), `hide_overlay()`, `update_timer()` (the 0.5 s timer runs only while
  something is visible).
- `handle(action)`: see the controls table in DECISIONS D10.
  Short seeks are `relative+exact`, long seeks `relative+keyframes`.
  `chapter(dir)`: going back first jumps to the start of the current chapter
  when more than 3 s into it; with no chapters it seeks ±300 s.
- Menus: `open_audio_menu`, `open_subtitle_menu` (with "Off"),
  `open_main_menu` (live values through `rebuild`): tracks, subtitle
  size/position/delay, audio delay, volume, speed, picture (fit / fill =
  `panscan 1` / stretch = `keepaspect no`), next video, info, stats, stop,
  quit.
- `render()`: blurred top/bottom gradients, title, badges (resolution, HDR
  state, HW, matched Hz), pause icon, progress bar with buffered range and
  chapter ticks, elapsed / remaining / "Ends at" / chapter title, hint bar
  (hidden while a menu is open).
- `render_info()` / `info_lines()`: codec, resolution, fps, decoder, HDR
  source and output, mastering peak, display Hz, audio, audio output,
  dropped/late/mistimed frames, cache.
- `refresh_hz` is set by `main.lua` after `display:match()`.

---

## Packaging files

| File | Purpose |
|---|---|
| `packaging/flatpak/io.github.nicocarbone.DeckVideoPlayer.yml` | Flatpak manifest (D3, D18). Pinned tags and commits; `deckvideoplayer` module copies `app/` from the repo (`type: dir`). |
| `…desktop` | Desktop entry (`Exec=deckvideoplayer %F`, `StartupWMClass=deckvideoplayer` = mpv `x11-name`). |
| `…metainfo.xml` | AppStream metadata (gamepad support declared). |
| `packaging/icons/` | App icon SVG + 256 px PNG (rendered with ffmpeg's librsvg decoder). |
| `packaging/steam/*.svg` / `*.png` | Steam artwork: `capsule` 600×900 (portrait grid), `header` 920×430 (wide grid), `hero` 1920×620, `logo` 1440×320, `icon` 256×256. Regenerate PNGs with `ffmpeg -i X.svg -frames:v 1 X.png`. |

## Scripts and tools

| File | Purpose |
|---|---|
| `scripts/build-flatpak.sh [--install]` | Builds with flatpak-builder (or the `org.flatpak.Builder` Flatpak) into `build-dir/` and `repo/`, branch `stable`, then exports `dist/DeckVideoPlayer.flatpak`. Uses `--disable-rofiles-fuse` (needed where FUSE isn't available). |
| `scripts/install-steamos.sh [BUNDLE] \| --artwork \| --uninstall` | End-user installer for SteamOS (see INSTALL.md). |
| `scripts/steam_shortcut.py add\|artwork\|remove\|status` | Binary `shortcuts.vdf` reader/writer and artwork installer (D19). Never writes while Steam runs. `save_shortcuts()` serialises first, then replaces the file atomically with a `.bak` (D22); `UInt64` keeps type-0x07 values lossless. |
| `scripts/dev-run.sh [--window] [--gamescope] [--media DIR]` | Run from source with system mpv; config and data in `.dev/`. |
| `tools/make-test-media.sh [DIR]` | Generates the synthetic test library. |
| `tools/headless-run.sh` | Runs the app in headless gamescope and drives it (see DEVELOPMENT.md). `KEEP=1` keeps resume data between runs. |
| `tools/mpv-ipc.py` | IPC step runner: key presses, screenshots, property reads. |
| `tests/run.sh` | Runs all unit tests: `tests/run.lua` (Lua, inside mpv so `mp.*` exists) and `tests/test_steam_shortcut.py` (Python unittest, fake `HOME`). |
| `.github/workflows/build.yml` | CI: unit tests, Flatpak bundle; on `v*` tags a GitHub release with the bundle and an installer tarball. |
