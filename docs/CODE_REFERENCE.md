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
   default `config.ini` on first run. The launcher sets umask 077, so
   everything the app creates (config, `plex.json`, `jellyfin.json`, `resume.json`,
   subtitles) is owner-only from creation (D39, D40).
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
- Reads script-opts `config_file`, `data_dir` and the development-only
  `opensubtitles_url` (mock server, D30); loads config (warnings are logged
  with `msg.warn`).
- `apply_playback_options()` translates `[playback]` into mpv properties
  (`alang`, `slang`, subtitle selection mode (D9), volume, `audio-spdif`,
  `hwdec`; `auto` → `vaapi,vulkan,auto-safe`).
- Creates the services: `display` (D6), `surround` (D27; the HRTF path is
  derived from the script directory: `…/share/deckvideoplayer/hrtf/`),
  `resume`, `menu`, toast layer, `subtitles` (D28), and the two screens
  `browser` and `player` with a shared `ctx`:

  | ctx field | Meaning |
  |---|---|
  | `cfg` | parsed config |
  | `resume`, `menu`, `display` | service instances |
  | `surround` | headphone surround (`dvp/surround.lua`) |
  | `hdr` | HDR choices (`dvp/hdr.lua`, D52) |
  | `subtitles` | online subtitle search/download (`dvp/subdownload.lua`) |
  | `play(list, start)` | load `list[1]` (replace) with start position `start` (nil: the saved position, if any), append the rest |
  | `stop()` | `stop` → idle → browser (progress is saved by on_unload) |
  | `quit()` | restore refresh rate, `quit` (progress is saved by on_unload) |
  | `quit_dialog()` | "Quit?" dialog |
  | `help()` | controls list |
  | `toast(text, seconds)` | notification, 1.8 s unless `seconds` is given |

- Input dispatch (see ARCHITECTURE §4).
- Lifecycle hooks:
  - `on_load` hook: sets `aid`, `sid`, `sub-delay`, `audio-delay`
    file-locally to their defaults (D35), then the start position from
    `state.pending_start[path]` (set by
    `play`), else the resume position (auto-advanced playlist entries and
    external launches; remembered in `state.resumed_at` and announced with a
    toast on `file-loaded`); restores `aid`/`sid` from the resume entry (as
    `file-local-options`).
  - Server videos (Plex D37, Jellyfin D55; `servers:item_for(path)`):
    on_load fetches the resume point and subtitle files
    (`backend:prepare`), sets the header (Plex: transient token;
    Jellyfin: usually none) and the media title file-locally;
    `save_progress(ending)` reports to the server instead of resume.json
    (blocking `stopped` + watched mark when the file closes below the
    server's own 90 % threshold), and keeps a local copy under
    `backend.recent_key(item)` with the label for *Recently played* (D50).
  - `on_preloaded` hook: `subtitles:load_stored(path)` adds subtitles
    downloaded earlier for this video before track selection (D28).
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
`read_file`, `write_file_atomic(path, data, private)` (tmp + rename;
returns `false, err` and keeps the old file if the write fails; `private`
makes the tmp file mode 600 before writing), `write_private(path, data)`,
`is_dir`, `file_exists`, `readdir(path, filter)` (mpv's, without `.` and
`..`, D61), `mkdir_p` (mpv subprocess), `shallow_copy`.

## `dvp/version.lua`

Returns the app version string (`"0.2.0"`), used in the OpenSubtitles
User-Agent. Bump it with the metainfo `<release>` when releasing.

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
  - `text` never wraps (`\q2`).
  - `qr(x, y, size, matrix)`: QR code on a white square with quiet zone.
  - icons: `icon_folder`, `icon_video`, `icon_drive`, `icon_sdcard`, `icon_network` (D64), `icon_server`,
    `icon_check`, `icon_play`, `icon_pause`, `icon_triangle(dir)`
  - `button(btn, x, cy, s, o)`: controller glyphs `A B X Y`, `L1 R1 L2 R2`,
    `MENU`, `VIEW`, `DPAD`, `DPAD_LR`, `DPAD_UD`. Returns the width.
  - `hints({{btn, label}, …}, x_right, cy, o)`: right-aligned hint bar.
- `text_width(str, size, bold)` and `fit_text(str, size, max_w, bold)`:
  per-character-class estimates calibrated on Inter (D32).
- `marquee(redraw)` → scroller for one long text per screen:
  `m:begin()` at the start of a render, `m:draw(ass, key, x, y, text,
  max_w, opts)` for the text that may scroll (plain text when it fits),
  `m:finish()` at the end (starts/stops its 24 Hz timer), `m:reset()` when
  the screen hides. `marquee_offset(t, overflow)` is the pure timing
  function (rest, scroll, rest, three passes, then nil).
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

- `sources(cfg, extra)` → `{name, path, kind}`: configured folders that exist
  (`kind = "folder"`), plus removable media mount points when enabled
  (`kind = "sdcard" | "usb" | "removable"`, D33), then `extra` (media
  servers, `kind = "plex"` / `"jellyfin"`). Folders and mount points on a
  network filesystem or an automount point are `kind = "network"` and are
  never stat'ed (D64).
- `is_slow_path(mounts, path)`: on a network filesystem or an `autofs`
  automount point (pure); `read_mounts()` parses this process's
  `/proc/self/mountinfo`.
- `sort_entries(entries, mode)`: folders first, natural name order or
  newest first (`mode = "date"`); uses `sort_name`, else `name`, else
  `label`, and `mtime`. Shared by folder listings and Plex.
- `parse_mountinfo(text)` → `{path, source}` for mount points under
  `/run/media/…` or `/media/…` (handles `\040` escapes; pseudo
  filesystems such as `tmpfs` are skipped); `source` is the device, e.g.
  `/dev/mmcblk0p1`.
- `removable_info(path, source)` → `kind, name` ("SD Card", "SD Card
  (Label)", "USB drive", a real label, or the folder name).
- `source_for(sources, path)` → the local source holding a file (longest
  path prefix) or nil; `source_tag(source)` → "Local" / "SD Card" /
  "USB" / "Drive" / "Network" (*Recently played* tags), `source_label(source)` →
  "Local · Videos", "USB drive · Label"… (Video info Source row, D56).
- `list(path, cfg, sort_mode)` → entries `{name, label, key, path, is_dir,
  mtime, size}`. Hidden files are skipped unless `show_hidden`; files are
  filtered by extension; folders come first; sorted by `natural_key` or by
  mtime (newest first). Synchronous: only for folders known to be local
  (delete); the browser uses `list_async`.
- `list_async(path, cfg, sort_mode, cb)` (D64): the same entries from a
  `find -L … -printf` subprocess (`list_args(path)`), so a share that
  doesn't answer can't block mpv; `cb(entries)` or `cb(nil, err)`;
  returns the handle for `mp.abort_async_command`. Pure helpers:
  `parse_listing(out, path, cfg, sort_mode)` (NUL-separated records,
  names may hold tabs and newlines) and `listing_error(res)` (find's
  reason, e.g. "Permission denied"; partial output counts as success).
- `display_name(name, is_dir, clean)`: strips the extension; with `clean`,
  `.`/`_` → spaces when the name has no spaces.
- `download_folder(cfg)` → the expanded `[library] download_folder` or
  nil (empty or not absolute); `sources()` adds it as a `folder` source
  while it holds something (D60).
- Deleting (D60): `parse_mounts(text)` → `{path, fstype}` for every mount,
  `mount_for(mounts, path)` (longest mount point), `is_network_fs(fstype)`,
  `is_video(name, cfg)`, `delete_refusal(path, sources, mounts, cfg)` →
  nil or why not (absolute plain path inside a local source, not the source
  itself, a video extension, not on a network filesystem or automount point),
  `sidecar_subtitles(video, names)` (its subtitle files; ones matching a
  longer video name belong to that one), `delete_video(path, sources,
  cfg)` → true or false, message (checks again, removes the file, its
  subtitles and folders left empty inside the download folder),
  `prune_folders(dir, downloads)` (removes `dir` and the folders above it
  while empty, inside the download folder; also used by a cancelled download).

## `dvp/resume.lua`: playback state store

`new(data_dir)` (nil dir = in-memory, used by tests), `get(path)`,
`position(path)` (≥ 30 s or nil), `is_watched`, `is_finished(pos, dur)`
(static), `update(path, pos, dur, aid, sid, title?)` (decides pos /
watched; `title` names Plex entries, whose key is no file name, D50),
`mark_watched`, `mark_unwatched` (keeps a played file in the recent list), `forget(path)`
(a deleted file, D60), `flush()` (writes only when dirty, prunes to 1000
entries). Thresholds are `M.MIN_POSITION`, `M.END_MARGIN_MIN` and
`M.END_MARGIN_FRAC`.

Recently played (D42): `update()` stamps `played` (time of the last
playback); `mark_watched()` on a never-played file sets `played = false`;
`hide_recent(path)` sets it to `false` too. `recent(n, exists)` returns the
`n` newest played paths, calling `exists(path)` only until `n` are found
(entries from before v0.3.1 have no `played` and use `t`; marking one
migrates `t` to `played` first, so it keeps its place, D45).
`mark_unwatched(path)` keeps a played entry (timestamps) and drops others.
`sync(path, state)` copies a Plex server's progress into an existing entry,
keeping its timestamps (D53).
`set_decoder(path, decoder)` stores the Video menu's *Decoding* choice
(`"software"` / `"hardware"`, nil = `config.ini`'s) in an existing entry;
`main.lua` saves it with the progress (`Player.remembered_decoder()`) and
sets `file-local-options/hwdec` from it in `on_load` (D62).

## `dvp/cropdetect.lua`: black bars encoded in the video

`bounds(pixel, w, h)` scans lines inward from each edge (`SAMPLES` pixels
per line; dark = brightest channel ≤ `THRESHOLD`) and returns the picture
`{x, y, w, h}` or nil (no bars; bars thinner than `MIN_BAR`; or a pair
dark up to `MAX_BAR`, i.e. a dark scene). Opposite sides are paired and
cropped by the thinner one (bars are symmetric; a dark sky at the top is
picture, D45), rounded down to even sizes. `from_screenshot(shot)` reads a `screenshot-raw` result (bgr0).

## `dvp/display.lua`: device, profile, refresh rate

- `detect_device()` → `deck-oled` (DMI product `Galileo`), `deck-lcd`
  (`Jupiter`) or `tv`.
- `in_gamescope()`: `GAMESCOPE_WAYLAND_DISPLAY` set or
  `XDG_CURRENT_DESKTOP=gamescope`.
- `parse_rates("45-90" | "48,60,72")`, `choose_rate(fps, rates, prefer)`,
  `parse_helper_info(text)` (pure, unit-tested).
- `get_root_cardinal(name)`: X11 root property read via LuaJIT FFI
  (`libX11.so.6`), falling back to `xprop`; returns a number, `false`
  (unset) or `nil` (error).
- Instance (D31): `new(cfg)` resolves device and quality; fields
  `requested_hz`, `actual_hz` (confirmed by gamescope), `original_hz`.
  `apply_profile()` applies `dvp-quality-*` and display-resample (HDR off: `dvp/hdr.lua`).
  `match(fps, on_result)` runs `dvp-gamescope-refresh info`, chooses a rate,
  sends `set HZ` and schedules `verify()` (2 s) which reads
  `GAMESCOPE_DISPLAY_REFRESH_RATE_FEEDBACK` and calls `on_result`.
  `current_hz()` reads the live rate. `reassert(on_result)` re-sends when the
  live rate drifted. `restore()` asks for the previous rate or native.
  `refresh_possible` (gamescope + helper work) vs `refresh_on` (user
  choice); `set_matching(on, fps, on_result)` is the menu toggle.
  `verified`: true / false / nil (nil = feedback unreadable, the Deck case).

## `helper/dvp-gamescope-refresh.c`

C client of gamescope's private `gamescope_control` Wayland protocol
(vendored XML: `helper/gamescope-control.xml`, MIT). `info` prints
`connector=… internal=0|1 only_refresh=0|1 rates=45,47,…`; `set HZ` sends
`set_app_target_refresh_cycle(HZ, flags)` then prints the same line. Exit 2
when not under gamescope. Built by `helper/build.sh OUTDIR` (wayland-scanner
+ cc), used by the Flatpak manifest (→ `/app/bin`) and by the dev scripts
(→ `.dev/bin`, put on `PATH`).

## `helper/dvp-keep-awake.c` (D43)

`dvp-keep-awake [--status FILE]` calls `org.freedesktop.ScreenSaver.Inhibit`
(what SteamOS game mode honours) and `org.freedesktop.portal.Inhibit.Inhibit`
(flags idle + suspend; `handle_token` so the `Response` signal can be
watched) over sd-bus, then waits: both inhibitions last while the process
stays connected. Writes `request: screensaver …, portal …` to FILE after each call (5 s call timeout; screensaver first, it is what SteamOS honours)
(`accepted` / `requested` / `refused (n)` / `not running` / `not
supported`). Exits on SIGTERM (handler without `SA_RESTART`; closing the
bus drops the inhibitions), when its parent dies (`PR_SET_PDEATHSIG`, plus a
`getppid()` check each second for subreapers) and when the bus goes away;
the wait is bounded to 1 s so a signal just before it can't hang it (D45). Built by `helper/build.sh` with
libsystemd.

## `dvp/keepawake.lua` (D43)

`new(cfg, data_dir)` (`[display] keep_awake`; status file in
`XDG_RUNTIME_DIR`, else the private data dir; removed by `stop()`),
`set_playing(on)` (main.lua: true after file-loaded or on unpause, false
on pause, idle and shutdown) starts/kills the helper with
`mp.command_native_async` / `mp.abort_async_command`; a helper that exits
by itself sets `error` (exit 1: the status file says why), `info_lines()`
(a *Keep awake* info panel row from the status file, while playing). Pure:
`args(file)`, `parse_status(text)`.

## `dvp/media.lua`: descriptions

Language names (ISO 639-1/2), codec display names (DTS profile aware),
`track_label(t)` ("English · Commentary"), `track_detail(t)` ("TrueHD · 7.1 ·
Default"; external subtitle files show "External" instead of the codec), `tracks(kind)`, `selected_track(kind)`,
`hdr_state(video_track?)` (pass a cached video track to avoid re-reading
`track-list`) → `source, output_hdr, video_params, target_params` (source:
`HDR10`/`HLG`/`Dolby Vision`/`SDR`; output from `video-target-params`),
`resolution_badge(w, h)`, and `sub_brightness(level, peak)` → `sub-color`
grey and `image-subs-hdr-peak` nits (D58).

## `dvp/menu.lua`: modal menus

Stack-based. A spec looks like:

```lua
menu:open({
  title = "Audio", subtitle = nil, message = nil,
  style = "side" | "center",         -- side panel (over video) or dialog
  items = {
    {label = "English", value = "AAC · Stereo", checked = true, action = fn},
    {label = "Subtitle size", value = fn_returning_text, adjust = function(dir) end},
    {label = "Library", header = true},  -- section title, skipped by the cursor (D53)
    {label = "…", disabled = true},       -- skipped by the cursor
    {separator = true, disabled = true},
  },
  selected = 1,
  rebuild = fn,          -- regenerate items after an action/adjust (live values)
  close_action = "y",    -- extra action that closes it (toggle behaviour)
  wide = true,           -- side style: wider panel (Video info, D50)
  on_cancel = fn,        -- called on B / close_all, not when an item is chosen
})
```

Handling: up/down move (wraps, skips disabled), L1/R1 jump to first/last,
left/right call `adjust(-1|1)`, A runs `action` (the menu is popped
**before** the action runs, so actions can open other menus or start
playback; `keep_open = true` prevents that) or `adjust(1)`, B pops, Menu
closes all side menus. `render()` draws the top menu only. A list with no
selectable item ("Searching…") shows no cursor.

Long text (D32): `Menu.split_row(avail, label_need, value_need, extra,
gap)` shares a row between label and value (pure); the selected row's cut
text scrolls through a `ui.marquee`; title and subtitle are shortened.
`Menu.side_width(W, wide)` is the side panel width (also used by the player to
keep its title clear of the panel).

Center dialogs also take `code` (a big, letter-spaced code to type
elsewhere) and `qr` (a QR matrix from `dvp/qrencode.lua`, drawn left of the
message lines and the code; Plex sign-in, D38).

`menu:shows(spec)`: whether a menu is still open (on top or under
another). `menu:update(spec, fields)` changes fields (usually `items`) of a menu that
may still be open, resets the cursor and redraws it if it is on top;
returns false when the menu was closed meanwhile. Used by asynchronous
work (subtitle search) to fill a menu in place.

## `dvp/http.lua`: HTTP through curl

Shared by OpenSubtitles and Plex. `request(req, cb)` (async) and
`request_sync(req)` (blocking; only inside mpv hooks). `req`: `url`,
`method`, `headers` (`{Name = value}`), `body` (table → JSON), `output`
(file), `timeout` (s), `follow` (redirects; off by default because curl
forwards custom headers to the redirect target), `max_size` (bytes), `tag`
(log prefix), `raw_body` + `content_type` (a text body as is: DLNA's SOAP,
D66). Every request is limited to http(s), redirects to https
(D39). `cb(code,
body)`: HTTP status, or nil + error text; body is decoded JSON when
possible. Pure: `curl_config(req)` (the `-K -` text: secrets never in
argv), `curl_quote`, `query_string(params, lower)`, `parse_result(res)`,
`CURL_ERRORS`.

Media server backends' `download_info(item, cb)` call `cb(info, err,
fatal)`: `fatal` when trying again can't help (refused, gone, D61).

Long downloads (D60): `download(req, cb)` → a handle for `abort(handle)`;
`cb(code, status, killed)` (HTTP status, curl exit status, stopped by
`abort`). Extra `req` fields: `timeout = 0` (no time limit; aborts below
1 KB/s for 60 s), `resume` (`continue-at -`), `fail` (an HTTP error writes
nothing to `output`).

## `dvp/plex.lua`: Plex Media Server

D37. Pure (unit-tested): `parse_resources(list, account_token)` → servers
`{name, machine, token, owned, connections}`; `local_rank(address)`;
`server_candidates(server, allow_insecure)` (ordered base URLs: https
`*.plex.direct` only, plain http on local addresses only with
`allow_insecure`; no relays); `safe_key(key)` (server-supplied paths: one
leading `/`, URL-path characters only; entries failing it are dropped);
`pick_candidate(results, n)`; `auth_url(client_id, code)` (QR sign-in, D38);
`item_label(md, kind)`; `item_state(md)` →
`{pos, duration, watched}` (same rules as resume.json: no position under
30 s, near the end = watched); `entries_from(container, base, machine, kind)`
→ browser entries (sections, shows → `/allLeaves` for one season, kind
`seasons`/`episodes` for their listings, which keep the server's order;
movies/episodes with `path` = direct-play URL and `server = {backend =
"plex", machine, rating_key, key, duration, kind, title}`);
`external_subtitles(md, base)`. Backend of `dvp/servers.lua` (D55):
`ID = "plex"`, `NAME = "Plex"`, `video_info(ref, cb)`, `recent_ref(machine,
key)`. Downloads (D60): `download_info(item, cb)`, pure
`download_allowed(container, owned)` (own server, or `allowSync`) and
`download_parts(md, base)` (part URL with `download=1`, size, file name,
text subtitles).

Instance `Plex.new(data_dir, {allow_insecure})` (account in `plex.json`,
written with `util.write_private`):
`signed_in()`, `username()`, `sources()`, `start_pin(cb)` (short + strong
PIN, `cb(code, auth_url)`) / `poll_pin(cb)` (both PINs; `cb(true, err)`
once claimed, even if the server list then failed) / `cancel_pin()`
(dialog closed: answers in flight are ignored) / `refresh_account(cb)`
(answers after a sign-out are dropped) / `sign_out()`, `connect(machine, cb)` (parallel
`/identity` probes without token, answer must carry the server's
`machineIdentifier`; cached per session; then `prefetch_token(machine)`
fetches the transient token in the background), `forget_session(machine)` (drops
the cached connection and transient token when the server was unreachable),
`forget_token(machine)` (only the transient token: a file failed although
the server answered, D45), `list(loc, cb)` (loc = `{machine, key,
kind}`; kinds `root`, `ondeck`, `items`, `shows`, `seasons`, `episodes`),
`item_for(path)`, `describe(path)` (info panel), `fetch_range(path, from,
to, file, cb)` (capped at the range size, needs HTTP 206), `prepare(item)` (blocking: resume point +
external subtitles + `markers` (requested with `includeMarkers=1`, D47);
`ok` false without metadata, `unreachable` when there
is no connection or no answer: main.lua then clears the playlist and makes
the file fail at once via `stream-open-filename`, D45),
`media_token(item)` / `header_fields(item)` (transient token for mpv;
never falls back to the account token), `report(item, state, time, duration, sync)`,
`set_watched(item, watched, cb, sync)`, `metadata(machine, key, cb)` (full
metadata for Video info: `cb(md, err, server_name)`),
`remove_from_continue(item, cb)` (`PUT /actions/removeFromContinueWatching`,
D50), `resolve(machine, key, siblings, cb)` (a *Recently played* entry →
fresh browser entry and, with `siblings`, the paths of the rest of its
season). Pure: `recent_key(item)` / `parse_recent_key(path)`
(`plex://<machine>/library/metadata/<id>`). `CONTINUE_KEY` is the
*Continue watching* hub; `list()` falls back to `/library/onDeck` on
400/404. `readonly` (development) turns reports, marks and removals into
log lines.

## `dvp/downloads.lua`: downloads for offline playback (D60)

Pure: `clean_name(s)` (one FAT/exFAT-safe name, ≤ 120 bytes, nil if
empty), `safe_ext(file)`, `relative_path(item, ext)` (`Title (Year).ext`,
`Show/Season NN/Show - SNNEMM - Title.ext`), `subtitle_paths(video,
subs)` → `{url, path}` (`<name>.<lang>.<ext>`, numbered per language),
`job_id(item)`, `format_size`, `enough_space(avail, size, have)`,
`outcome(code, status)` → "done" / "restart" / "retry" / "fail", why,
`status_text(job, have, speed)`.

`new(ctx, data_dir)` loads `downloads.json` (finished ones whose file is
gone are dropped; unfinished ones become "paused": nothing starts by
itself). Jobs: `id`, the item fields (backend, machine, key, kind, title,
name, year, show, season, episode), `status` (queued / downloading /
paused / failed / done), `error`, `size`, `path`. `add(items)` → how many
were new; `pump()` starts the next queued one; `start(job)` asks the
backend's `download_info`, picks the path (`free_path`), checks space,
runs `http.download` into `<path>.part`; `transferred()` decides by
`outcome()` and the size, `retry()` (3 times, 15 s), `fetch_subtitles()`,
`finish(job, "done" | "pause" | "fail", why)`. `pause`, `resume`,
`pause_all`, `resume_all`, `cancel` (deletes the partial file),
`forget_path(path)` (file deleted), `shutdown()`, `counts()` → active,
stopped/failed, done; `find(item)`, `can_download(item)`, `tag(item)`
(the label on server rows). Menu: `open_menu()` (progress once a second
while open: `sample()` measures speed), `job_menu(job)`, `done_menu(job)`.
`ctx.changed(job)`, `ctx.play_path`, `ctx.browse`, `ctx.delete` are set by
`main.lua`.

## `dvp/servers.lua`: media servers behind one interface (D55)

`Servers.new({plex, jellyfin})`: `get(id)`, `for_ref(ref)` (the backend of
an entry's `server` / `server_recent` table, by its `backend` field),
`sources()` (every backend's), `item_for(path)` → item, backend (nil for
local files), `parse_recent_key(path)` → backend, server id, key,
`recent_key(item)`, `recent_available(path)` (nil for local paths). The
backends share the method set listed at the top of the file.

## `dvp/jellyfin.lua`: Jellyfin (D55)

Pure (unit-tested): `safe_id(id)`, `private_host(host)`,
`normalize_url(url)` (http only for home network addresses; optional path
prefix), `auth_header(device, device_id, token)`, `parse_discovery(text)`
(dvp-discover output → `{id, name, url}`, checked, one per id and address,
at most `MAX_ANSWERS` = 16),
`item_state(it)` (ticks → `{pos, duration, watched}`, rules as Plex),
`date_key(iso)`, `item_label(it, kind)`, `stream_url(base, id)`,
`entries_from(items, base, server_id, kind)` (libraries, folders, series →
`seasons` or `series_episodes` for one season, seasons → `episodes`;
videos with `server = {backend = "jellyfin", machine, key, rating_key,
duration (ms), kind, title, …}`), `listing_path(loc, user)` (kinds `root`,
`ondeck`, `nextup`, `items`, `seasons`, `episodes`, `series_episodes`),
`external_subtitles(it, base)` (text formats only),
`recent_key(item)` / `parse_recent_key(path)`
(`jellyfin://<server>/<item>`), `recent_ref(id, key)`.

Instance `Jellyfin.new(data_dir, {urls})` (servers in `jellyfin.json`,
owner-only; `urls` from `[jellyfin] server`): `signed_in()`, `servers()`,
`server(id)`, `sources()`, `probe(url, cb)`, `discover(cb)` (dvp-discover
+ config URLs, each probed; a broadcast answer counts only if its address
answers with the same id; config URLs win, D59), `start_quick_connect(server, cb(code))` /
`poll_quick_connect(cb(done, err))` / `cancel_quick_connect()`,
`sign_out(id)` (revokes the token, best effort) / `forget_server(id)`,
`connect(id, cb)` (the saved address must answer with the server's id,
else the LAN is searched), `list(loc, cb)`, `metadata(id, item, cb)`,
`video_info(ref, cb)`, `resolve(id, item, siblings, cb)`, `item_for(path)`,
`prepare(item)` (blocking: resume point, size, external subtitles, media
segments → markers; checks once per connection whether streams need a
token, `streams_anonymously`, with a 1-byte range request to `/dev/null`;
resets the item's "playing" report state), `header_fields(item)` (empty unless the
server needs the token), `report(item, state, time, duration, sync)`
(`/Sessions/Playing`, `…/Progress`, `…/Stopped`), `set_watched(item,
watched, cb, sync)` (`/UserPlayedItems`), `describe(path)`,
`fetch_range(…)`, `forget_session(id)`, `forget_token(id)`,
`download_info(item, cb)` / pure `download_parts(it, base)`
(`/Items/<id>/Download`, honours `CanDownload`, D60). `readonly`
(development) turns reports and marks into log lines.

## `helper/dvp-discover.c` (D55, D66)

`dvp-discover [TIMEOUT_MS]`: sends Jellyfin's discovery broadcast (UDP
7359) on every IPv4 interface and to 255.255.255.255, prints each answer
on its own line (control characters replaced) until the time is up, at
most 64 answers. `dvp-discover --ssdp [TIMEOUT_MS]` (default 2500): an
SSDP `M-SEARCH` for `MediaServer:1` to 239.255.255.250:1900, twice, on
the default route and every multicast interface; prints `sender address
<TAB> LOCATION <TAB> USN <TAB> SERVER` per answer.

## `dvp/dlna.lua`: DLNA / UPnP media servers (D66)

Same interface as the other backends (`ID = "dlna"`, `NAME = "DLNA"`),
without sign-in; `LOCAL_STATE = true` (marks without reaching the
server); `download_info(item, cb)` (v0.7.1, D67: BrowseMetadata for the
current URL and size; `fatal` when the server answered that the object is
gone) with the pure `download_file(url, protocolInfo)` (the URL's file
name, else `video.<ext>` from the MIME type). Pure (unit-tested): `xml_unescape`
(predefined entities and numeric references, one pass), `xml_escape`,
`element_text(xml, name)` (with or without a namespace prefix, CDATA),
`attr(attrs, name)`, `safe_id` (UUID of a UDN/USN), `split_url`,
`parse_ssdp(text)` (answers whose LOCATION host is the sender, a private
IPv4, one per location, at most 16), `resolve_url(base, ref)` (same host
only), `parse_description(xml, location)` → `{id, name, control}` (the
ContentDirectory control URL on the description's host),
`browse_body(id, flag, start, count)`, `parse_browse(xml)` → `{didl,
returned, total}` or nil + the SOAP fault, `parse_didl(didl)` →
containers and video items (by class or video MIME type) with `pos`
(document order), `pick_res(res, host)` (http(s) on the server's host, a
video type, the original before a converted copy, then the largest),
`parse_duration`, `recent_key` / `parse_recent_key` / `recent_ref`
(`dlna://<id>/<percent-encoded object id>`).
Instance (`new(data_dir, {resume, clean_names})`, `dlna.json`):
`servers()`, `server(id)`, `signed_in()` (any added), `sources()`,
`discover(cb)` (dvp-discover, then each description), `add(info)`,
`remove(id)`, `connect(id, cb)` (control URL from the saved description;
if that address is gone, a search finds the server by id),
`browse(...)` (20 s, 8 MB per answer), `list(loc, cb)` (pages of 200, at
most 5000 entries, in the server's order; titles cleaned like file names),
`metadata`, `resolve(id, key, siblings, cb)` (BrowseMetadata, then the
parent container for auto-play), `prepare(item)` (the local position),
`header_fields()` = "", `report()` (nothing: main.lua saves progress in
resume.json under `recent_key`), `set_watched` (local), `describe`,
`fetch_range`, `video_info` (`VideoInfo.probe_url`).

## `dvp/hdr.lua`: HDR choices (D52)

`Hdr.new(cfg, device, notify)`: state `enabled` (`hdr`), `mapping`
(`hdr_mapping`: static / dynamic / app), `peak` (`hdr_peak`), `itm`
(`sdr_to_hdr`, 0 = off), `screen` (nil until mpv's output shows whether
the screen is in HDR mode; a known HDR screen is reset with each file);
`menu` is false on a Deck LCD. Captures the start values of `PROPS`,
observes `video-params/gamma` and `video-target-params/gamma` (HDR output
proves an HDR screen). `notify(text)` (text may be nil) when `screen`
changes. `toggle()`,
`set_mapping(dir)`, `set_peak(dir)`, `set_itm(dir)`, `apply()` (sets only
changed options; schedules `check()` while `screen` is unknown and HDR
output is expected), `check()` (reads `video-target-params/gamma`; on an
SDR output drops every choice and calls `notify`),
`show_menu()`, `describe()` (info panel line). Pure (unit-tested):
`options(state, defaults)`, `effective(state)`, `expects_hdr(state)`,
`step`, `clamp_peak`, `parse_itm`, `is_hdr`, `has_scene_metadata(vp,
track)`, `mapping_choices(dynamic)`, `shown_mapping(state)` (D54: "dynamic"
works as "static" without per-scene metadata; `dynamic` is read once per
file). The rows are built in
`player:hdr_items()`.

## `dvp/videoinfo.lua`: Video info panel (D50)

Pure (unit-tested): `format_fps`, `format_bitrate` (bits/s), `format_size`,
`hdr_label{dv_profile, transfer, hdr10plus}` ("Dolby Vision 8 · HDR10+";
profile 5 without HDR10), `from_ffprobe(probe, frame, path)` and
`from_plex(md, source)`, `from_jellyfin(it, source)` → a normalized description `{file, video,
audio, subs}`, `server_source(service, server_name, connection)` →
"Plex · Home · local network" (the Source row, D56),
`sections(d)` → `{title, rows = {label, value}}` (File starts with Source),
`items(sections)` → menu items (headers + rows).
`probe_local(path, cb)` runs ffprobe asynchronously (streams and format,
then the first video frame: colours when the stream says "unknown",
HDR10+, brightness); `probe_url(url, cb)` the same for an http(s) URL
(DLNA), with `-protocol_whitelist http,https,tcp,tls`.
`open(ctx, entry, source)` opens the wide side panel ("Reading…") and fills it
from ffprobe or the server's `video_info(ref, cb)` (entries with `server` or `server_recent`, D55).

## `dvp/about.lua`: About panel

D34. `About.open(ctx)` (ctx: `cfg`, `menu`, `display`, `app_dir`,
`data_dir`; `main.lua` exposes it as `ctx.about()`). `About.items(ctx)`
builds the rows. Pure: `parse_build_info(text)` → `{date, commit}`,
`build_text(info)` → "2026-10-23 · 1a2b3c4" / "development build".
Constants: `REPO`, `LICENSE`, `DEVELOPER`, `COPYRIGHT`.

## `dvp/qrencode.lua`: QR encoder (vendored)

[luaqrcode](https://github.com/speedata/luaqrcode), BSD-3-Clause, unchanged
(D38). `qrcode(text)` → `ok, matrix` (`matrix[x][y] > 0` = dark).

## `dvp/nightmode.lua`: night mode (D46)

`GRAPH` (acompressor −30 dBFS, 4:1, +5 dB make-up, detector on the loudest
channel; alimiter −1 dBFS), `filter_string(graph)`
(`@dvp-night:lavfi=graph=%n%…`), `new(cfg)` (`available` unless
`audio_passthrough`; `enabled` at start with `night_mode`), `set(on)`,
`toggle()`. The filter is added with `af pre` (before surround and the
downmix) once audio is open (`audio-params/channel-count` observer), so a
missing filter turns the feature unavailable instead of muting the file.
`enabled` / `active` for the menu and the info panel.

## `dvp/markers.lua`: intro / credits markers (D47)

Pure. `from_plex(md)` (Plex `Marker` list, ms → `{kind, start, stop,
final}`, intros and credits ≥ 2 s, sorted), `at(list, pos)` (marker
playing at `pos`, not in its last second), `action(mk, has_next, episode)`
(`{label, target | next, done}`: intro → seek to its end; final credits
with a next playlist entry → next episode/video; other credits → seek to
their end).

## `dvp/surround.lua`: headphone surround

D27. `Surround.new(cfg, sofa_path)`; fields `available` (HRTF file exists,
no passthrough, filter works), `enabled` (user choice), `active` (filter
currently in the chain: "<channels> <layout>" it was added for, or false),
`channels`, `layout` (decoder output channel count and layout name).

- Observes `audio-params` (one observer for count and layout); `update()` adds the filter
  (`af add`, label `@dvp-surround`) when `enabled` and channels > 2,
  replaces it when the count or layout changes, and removes it otherwise. A failed `af add` makes the feature unavailable.
- `toggle()` → new `enabled` state.
- Pure: `escape_lavfi(value)` (two-level FFmpeg escaping),
  `filter_string(sofa_path, channels, layout)` (the `af add` argument,
  `%len%`-quoted: `sofalizer` at gain 0 with `SPEAKERS[layout]`, then `volume` and `LIMITER`),
  `SPEAKERS` (5.1 / 5.1(side): surrounds at 120° / 240°, by layout index, D57),
  `gain(channels)` (`GAIN_51 = 12.5` dB plus 3 dB per channel above six:
  dialogue level matches mpv's downmix, D48), `LFE_GAIN = 3`, `LIMITER`
  (alimiter −1 dBFS, D49).
- HRTF: `hrtf/mit_kemar_normal_pinna_dfeq.sofa`, made from the MIT file by
  `tools/equalize-hrtf.py` (D48).

## `dvp/opensubtitles.lua`: OpenSubtitles API client

D28/D29. Pure helpers (all unit-tested):

| Function | Meaning |
|---|---|
| `moviehash_from(size, head, tail)` / `moviehash(path)` | OpenSubtitles hash (64-bit sum done as two 32-bit halves for Lua 5.1). `moviehash` returns `nil, size` for files < 128 KiB. |
| `parse_name(name)` | `{title, year, season, episode}` from a name without extension (episode markers, years, release junk); title `""` when nothing is left. Also used for DLNA titles. |
| `parse_release(path)` | The same from a file path, with the show folder for bare `S01E02` names. |
| `languages(slang)` | ISO 639-2 list → OpenSubtitles codes (`pob` → `pt-br`), English if empty. |
| `query_string(params)` | sorted, lowercase, URL-encoded. |
| `curl_quote(s)` | quoted string for a curl config file. |
| `parse_results(json)` / `rank(lists, languages)` | flatten `/subtitles` responses; merge, de-duplicate and order them. |
| `result_value(r)` | right-hand text: `Exact`, `SDH`, `Auto` (machine translated) or the download count. |
| `error_message(code, body, during)` | user-facing error text. |

Client: `OpenSubtitles.new{api_key, username, password, api_url}`,
`:enabled()`, `:http(req, cb)` (async curl, config on stdin), `:search(params,
cb)`, `:ensure_login(cb)` (once per session, follows `base_url` only if
`valid_base_url(host)`: `opensubtitles.com` or a subdomain),
`:download(file_id, dest, cb)` (download request, then fetch the link,
which must pass `valid_link(link, api_url)`: https, or the mock's origin, to `dest.part` with redirects and a 10 MB cap, rename). Constants: `API_URL`, `USER_AGENT`. There is no built-in key (D29):
`SubDownload` passes `cfg.opensubtitles.api_key`.

## `dvp/subdownload.lua`: online subtitles UI and storage

D28. `SubDownload.new(ctx, data_dir, api_url)`.

- `available(path)`: an API key exists and `path` is a local file.
- `open(path)`: results menu ("Searching…" → results via `menu:update`).
  `search(path, info, cb)` runs the hash and name searches in parallel.
- `download(path, result)`: stores the file as
  `<data_dir>/subtitles/<key>/<release> #<file_id>.<lang>.srt` and selects
  it (or selects the stored file if that upload was downloaded before).
- `stored(path)` / `load_stored(path)`: downloaded files of a video, added
  with `sub-add … auto <title> <lang>` from the `on_preloaded` hook.
- Server videos (Plex D38, Jellyfin D55): `key` is `server_key(item)`
  (`plex-…` / `jellyfin-…`, no network), search terms `server_info(item)`
  (both pure), `hash_for(path, cb)` fetches the first and last 64 KiB from
  the server (`fetch_range`) for the exact-match hash. `server_files(item)`
  lists a server video's stored files, which a download copies next to
  the video (D61).
- Pure: `safe_lang(lang)` (letters and `-`, else `und`), `file_name(release, lang, file_id)`, `parse_file_name(name)` (→
  `{title, lang, file_id}`),
  `video_key(path)` (moviehash, or `small-<size>` for tiny files).

## `dvp/browser.lua`: library screen

Downloads and deleting (D60): `download(entries)`, `download_season(entry)`,
`deletable(entry)`, `delete_dialog(path, label)` (defaults to *Cancel*),
`delete(path)`, `open_folder(path, select)` (stack built from the folder's
source down), `play_path(path)`, `downloads_changed()` (deferred while a
menu is open: `menu_closed()` catches up); server rows show `downloads:tag()` as a pill.

State: `stack` of locations `{path, label, is_root?}`, `entries`,
`selected`, `scroll`, `cursor[path]` (remembered selection per folder),
`sort`.

- `refresh_sources()`: re-reads `library.sources()` and the recently
  played videos (`resume:recent`, `[interface] recently_played`, D42;
  Plex keys count while the account has their server, D50);
  clears `is_root` on the top folder when the setup is no longer
  single-source (D23). Called by `show()`, `reload()` and when listing the
  root.
- `load()`: root (`root_entries()`: sources, then a "Recently played"
  header entry and the recent videos, `recent = true`; server ones carry
  `server_recent = backend.recent_ref(id, key)`; every recent has a `tag`
  from `recent_tag(path, backend, id)`, drawn as a pill on the right,
  D56) or folder listing.
  With exactly one source and nothing recently played (`single_source()`)
  the root is skipped and that folder becomes the top level (`is_root`).
- Header entries (`header = true`) are never selected: up/down skip them,
  `selectable(i, dir)` moves page/first/last jumps off them.
- `reload()`: refresh sources + listing, keeping the cursor. `at_start()`:
  true at the top level.
- `reload_to_start()`: after a server sign-in, leaves the only folder
  (start screen skipped) for the start screen, then reloads (D59).
- Navigation: `enter`, `go_back` (top level → quit dialog), `select_path`
  (a server stream URL also matches its *Recently played* key).
- Playback: `open_file(index, from_start)` → `start(entry, list,
  from_start)`, which shows the resume dialog when there is a position;
  `playlist_from(index)` returns the folder's files from the chosen one
  (if `autoplay_next`); for a recent file, `recent_playlist(path, cb)`
  lists its own folder asynchronously (plays alone after `PLAYLIST_WAIT`
  = 5 s, D64); a server recent goes through `open_server_recent()`
  (`backend:resolve`, D50, D55).
- `open_menu()`: sort (only where `sortable()`), reload, go to library
  start (whenever not `at_start()`), mark watched / unwatched (both for a
  partly watched video; `mark(entry, watched)` goes to the server, updating a
  *Recently played* copy, or resume.json), remove from Continue watching
  (`remove_from_continue(entry)`, Plex *Continue watching* only), remove
  from recently played, video info (`video_info(entry)`, also on View),
  controls, quit.
- Folders (D64): `load_folder(loc)` lists through `library.list_async`;
  `render()` keeps the previous screen for `LISTING_QUIET` (0.15 s) so a
  local folder doesn't flash "Loading…", says the folder is slow after
  `LISTING_SLOW` (4 s) and gives up after `LISTING_GIVE_UP` (60 s);
  `listing_done()` restores the cursor, runs `after_load` and re-sorts in
  the current order; `cancel_listing()` (every `load()`, `hide()`) kills
  the subprocess and its timers. *Recently played* files on a network
  share are listed without a stat (`refresh_sources`).
- Media servers (D37, D55): `load_server(loc)` (async listing through the
  backend, `loading` state, drops late answers, `after_load` callback,
  e.g. to restore the cursor), `entry_state(e)` / `resume_position(e)`
  (server state or resume.json), `sortable()` (not the server page, its
  two lists, seasons or episodes), `plex_sign_in()` (code dialog, polls
  only while open), `plex_account_menu()`, `jellyfin_add()` (servers found
  on the LAN and in config.ini), `jellyfin_sign_in(server)` (Quick Connect
  code + QR, polls every 3 s only while open), `jellyfin_menu()` /
  `jellyfin_server_menu(s)` (sign out); `show(select)` puts the cursor on
  a path once the listing is there. Server sources show "Plex" /
  "Jellyfin" before the chevron.
- `render()`: background, header (title, breadcrumb, counts), rows
  (`draw_row()`; header entries as a small caption with a rule) (icon:
  folder / server / SD card / drive / video, label, status: chevron / ✓ / progress
  bar + time), scrollbar, empty states, footer hints that depend on the
  selected entry. The selected label scrolls when cut (`self.marquee`,
  D32; not while a menu is open over the library).

Layout constants: `HEADER_H`, `FOOTER_H`, `ROW_H`, `ROW_GAP`, `FS`.

## `dvp/player.lua`: playback screen

- Cached per-file data (D25): `title_text` (set in `start()`),
  `video_track` (set in `on_file_loaded()`), `chapters` (property
  observer).
- Picture mode (D20): `zoom_mode()` derives Fit/Fill/Stretch/Custom from
  `panscan`/`keepaspect`; `set_zoom()` marks `zoom_touched`; `start()`
  restores `zoom_defaults` captured at script start. *Crop black bars*
  (`crop_bars`, D42): `crop_black_bars()` takes one `screenshot-raw`
  frame, runs `cropdetect.from_screenshot` and sets the file-local
  `video-crop` (Fit for the rest); other modes clear it. `crop_bars` is
  true, `"none"` (nothing found: the row stays on this mode, shown as "No
  black bars found", so left/right move on, D50) or false.
- Lifecycle: `start()` (on start-file), `on_file_loaded()`, `stop_screen()`, `show_overlay()`
  (auto-hides after `overlay_timeout`; stays while paused or while a menu is
  open; while paused the hide timeout isn't re-armed, unpausing does it),
  `hide_overlay()`, `update_timer()` (the 0.5 s timer runs only while
  something is visible and the video plays, D45). `toggle_stats()` tracks
  mpv's *Advanced statistics* so B closes it and `stop_screen()` turns it
  off.
- `handle(action)`: see the controls table in DECISIONS D10. B (`back`)
  hides the controls, then the info panel, then Advanced statistics, and
  only stops with nothing on screen (D42, D45); the `stop` key always stops.
  Short seeks are `relative+exact`, long seeks `relative+keyframes`.
  `chapter(dir)`: going back first jumps to the start of the current chapter
  when more than 3 s into it; with no chapters it seeks ±300 s.
- Menus: `open_audio_menu` (tracks, then the *Headphone surround* toggle
  when `ctx.surround.available`; `toggle_surround()` toasts the result),
  `open_subtitle_menu` (with "Off", then *Download subtitles…* when
  `ctx.subtitles:available(path)`),
  `open_video_menu` (D52: video tracks when there is more than one,
  picture (fit / fill = `panscan 1` / stretch = `keepaspect no`), match
  refresh rate (`toggle_refresh()`, shown when `display.refresh_possible`),
  decoding (`toggle_decoding()`: `file-local-options/hwdec` from the pure
  `hwdec_choice(software, configured)`, D62), then `hdr_items()` from
  `ctx.hdr`),
- Drop hint (D62): `on_frame_drops(count)` (observer of
  `frame-drop-count`, hardware decoding and speed ≤ 1× only) suggests
  *Decoding: Software* once per file when the pure
  `sustained_drops(samples, now, window, min)` sees 15 drops in 10 s;
  `watch_drops()` restarts counting (start, seek, speed above 1×) after a
  5 s grace.
  `open_main_menu` (live values through `rebuild`): tracks, *Video*
  (`video_summary()`), subtitle size/brightness/position/delay
  (`set_sub_brightness(level)`, 30–100 %, D58), audio delay, volume,
  speed, next video, info, stats, stop, quit.
- `render()`: blurred top/bottom gradients, title, badges (resolution, HDR
  state, HW, matched Hz), pause icon, progress bar with buffered range and
  chapter ticks, elapsed / remaining / "Ends at" / chapter title, hint bar
  (hidden while a menu is open).
- `render_info()` / `info_lines()`: codec, resolution, fps, decoder, HDR
  source and output, mastering peak, display Hz, audio, audio output
  (plus "· headphone surround" while the filter is active),
  dropped frames (video output; decoder drops when any; late/mistimed
  only in display-resample mode), cache.
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
| `scripts/steam_shortcut.py add\|artwork\|remove\|repair\|status` | Binary `shortcuts.vdf` reader/writer and artwork installer (D19). `repair` (also done by `add`) removes a `--branch=…` from the app's own shortcut (D44); `status` reports a pinned branch. Never writes while Steam runs. `save_shortcuts()` serialises first, then replaces the file atomically with a `.bak` (D22); `UInt64` keeps type-0x07 values lossless. |
| `scripts/dev-run.sh [--window] [--gamescope] [--media DIR]` | Run from source with system mpv; config and data in `.dev/`. |
| `tools/make-test-media.sh [DIR]` | Generates the synthetic test library. |
| `tools/headless-run.sh` | Runs the app in headless gamescope and drives it (see DEVELOPMENT.md). `KEEP=1` keeps resume data between runs; `SURROUND=1`, `OSMOCK=1`, `OSMOCK_LOGIN=1` set up the v0.2 features; `PLEX_WRITE=1` / `JELLYFIN_WRITE=1` allow progress reports to Plex / Jellyfin (read-only by default); `MPV_EXTRA` adds mpv arguments; `RATES=48,60` forces a refresh list (headless gamescope can't switch, so this exercises the request/verify path); `XWAYLAND2=1` runs the app on gamescope's second Xwayland like SteamOS game mode. |
| `tools/mpv-ipc.py` | IPC step runner: key presses, screenshots, property reads. |
| `helper/build.sh [OUTDIR]` | Builds the native helpers: refresh rate (D31), keep awake (D43), Jellyfin discovery (D55). |
| `scripts/make-source-archive.py OUT [--manifest M]` | GPL corresponding-source archive of a release from the manifest's pinned sources (D36). |
| `scripts/build-info.sh OUTFILE` | Writes `date=` and `commit=` for the About panel; run by the Flatpak manifest (D34). |
| `scripts/release-notes.sh [vX.Y.Z]` | Prints the `CHANGELOG.md` section of a release (default: `dvp/version.lua`) for the GitHub release text; exits 1 if missing (D41). |
| `tools/plex-dev-account.py DATA_DIR` | Writes a signed-in `plex.json` for tests from `.dev/plex/` (D37). |
| `tools/jellyfin-dev-account.py login [URL]` / `DATA_DIR` | Quick Connect sign-in for tests (token in `.dev/jellyfin/`), then writes a signed-in `jellyfin.json` (D55). |
| `tools/mock-opensubtitles.py [PORT]` | Fake OpenSubtitles API for tests (D30); used by `OSMOCK=1 tools/headless-run.sh`. |
| `tests/run.sh` | Runs all unit tests: `tests/run.lua` (Lua, inside mpv so `mp.*` exists) and `tests/test_steam_shortcut.py` (Python unittest, fake `HOME`). |
| `.github/workflows/build.yml` | CI: unit tests, Flatpak bundle; on `v*` tags a GitHub release with the bundle and an installer tarball. |
