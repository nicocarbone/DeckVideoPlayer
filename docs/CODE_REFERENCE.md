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
   everything the app creates (config, `plex.json`, `resume.json`,
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
  | `subtitles` | online subtitle search/download (`dvp/subdownload.lua`) |
  | `play(list, start)` | load `list[1]` (replace) with start position `start` (nil: the saved position, if any), append the rest |
  | `stop()` | `stop` → idle → browser (progress is saved by on_unload) |
  | `quit()` | restore refresh rate, `quit` (progress is saved by on_unload) |
  | `quit_dialog()` | "Quit?" dialog |
  | `help()` | controls list |
  | `toast(text)` | 1.8 s notification |

- Input dispatch (see ARCHITECTURE §4).
- Lifecycle hooks:
  - `on_load` hook: sets `aid`, `sid`, `sub-delay`, `audio-delay`
    file-locally to their defaults (D35), then the start position from
    `state.pending_start[path]` (set by
    `play`), else the resume position (auto-advanced playlist entries and
    external launches; remembered in `state.resumed_at` and announced with a
    toast on `file-loaded`); restores `aid`/`sid` from the resume entry (as
    `file-local-options`).
  - Plex videos (D37): on_load fetches the resume point and subtitle
    files (`plex:prepare`), sets the transient-token header and the media
    title file-locally; `save_progress(ending)` reports to the server
    instead of resume.json (blocking `stopped` + scrobble when the file
    closes).
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
`is_dir`, `file_exists`,
`mkdir_p` (mpv subprocess), `shallow_copy`.

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
  - icons: `icon_folder`, `icon_video`, `icon_drive`, `icon_sdcard`, `icon_server`,
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
  (`kind = "sdcard" | "usb" | "removable"`, D33), then `extra` (Plex
  servers, `kind = "plex"`).
- `sort_entries(entries, mode)`: folders first, natural name order or
  newest first (`mode = "date"`); uses `sort_name`, else `name`, else
  `label`, and `mtime`. Shared by folder listings and Plex.
- `parse_mountinfo(text)` → `{path, source}` for mount points under
  `/run/media/…` or `/media/…` (handles `\040` escapes; pseudo
  filesystems such as `tmpfs` are skipped); `source` is the device, e.g.
  `/dev/mmcblk0p1`.
- `removable_info(path, source)` → `kind, name` ("SD Card", "SD Card
  (Label)", "USB drive", a real label, or the folder name).
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
`mark_watched`, `mark_unwatched` (keeps a played file in the recent list), `flush()` (writes only when dirty, prunes to 1000
entries). Thresholds are `M.MIN_POSITION`, `M.END_MARGIN_MIN` and
`M.END_MARGIN_FRAC`.

Recently played (D42): `update()` stamps `played` (time of the last
playback); `mark_watched()` on a never-played file sets `played = false`;
`hide_recent(path)` sets it to `false` too. `recent(n, exists)` returns the
`n` newest played paths, calling `exists(path)` only until `n` are found
(entries from before v0.3.1 have no `played` and use `t`).

## `dvp/cropdetect.lua`: black bars encoded in the video

`bounds(pixel, w, h)` scans lines inward from each edge (`SAMPLES` pixels
per line; dark = brightest channel ≤ `THRESHOLD`) and returns the picture
`{x, y, w, h}` or nil (no bars; bars thinner than `MIN_BAR`; or a side
dark up to `MAX_BAR`, i.e. a dark scene). Bars are rounded down to even
sizes. `from_screenshot(shot)` reads a `screenshot-raw` result (bgr0).

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
  `apply_profile()` applies `dvp-quality-*`, HDR off, display-resample.
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

## `dvp/media.lua`: descriptions

Language names (ISO 639-1/2), codec display names (DTS profile aware),
`track_label(t)` ("English · Commentary"), `track_detail(t)` ("TrueHD · 7.1 ·
Default"; external subtitle files show "External" instead of the codec), `tracks(kind)`, `selected_track(kind)`,
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
closes all side menus. `render()` draws the top menu only. A list with no
selectable item ("Searching…") shows no cursor.

Long text (D32): `Menu.split_row(avail, label_need, value_need, extra,
gap)` shares a row between label and value (pure); the selected row's cut
text scrolls through a `ui.marquee`; title and subtitle are shortened.
`Menu.side_width(W)` is the side panel width (also used by the player to
keep its title clear of the panel).

Center dialogs also take `code` (a big, letter-spaced code to type
elsewhere) and `qr` (a QR matrix from `dvp/qrencode.lua`, drawn left of the
message lines and the code; Plex sign-in, D38).

`menu:update(spec, fields)` changes fields (usually `items`) of a menu that
may still be open, resets the cursor and redraws it if it is on top;
returns false when the menu was closed meanwhile. Used by asynchronous
work (subtitle search) to fill a menu in place.

## `dvp/http.lua`: HTTP through curl

Shared by OpenSubtitles and Plex. `request(req, cb)` (async) and
`request_sync(req)` (blocking; only inside mpv hooks). `req`: `url`,
`method`, `headers` (`{Name = value}`), `body` (table → JSON), `output`
(file), `timeout` (s), `follow` (redirects; off by default because curl
forwards custom headers to the redirect target), `max_size` (bytes), `tag`
(log prefix). Every request is limited to http(s), redirects to https
(D39). `cb(code,
body)`: HTTP status, or nil + error text; body is decoded JSON when
possible. Pure: `curl_config(req)` (the `-K -` text: secrets never in
argv), `curl_quote`, `query_string(params, lower)`, `parse_result(res)`,
`CURL_ERRORS`.

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
movies/episodes with `path` = direct-play URL and `plex = {machine,
rating_key, key, duration, kind, title}`); `external_subtitles(md, base)`.

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
the cached connection and transient token after a failed load), `list(loc, cb)` (loc = `{machine, key,
kind}`; kinds `root`, `ondeck`, `items`, `shows`, `seasons`, `episodes`),
`item_for(path)`, `describe(path)` (info panel), `fetch_range(path, from,
to, file, cb)` (capped at the range size, needs HTTP 206), `prepare(item)` (blocking: resume point +
external subtitles; `ok` false when the server didn't answer),
`media_token(item)` / `header_fields(item)` (transient token for mpv;
never falls back to the account token), `report(item, state, time, duration, sync)`,
`set_watched(item, watched, cb, sync)`. `readonly` (development) turns
reports into log lines.

## `dvp/about.lua`: About panel

D34. `About.open(ctx)` (ctx: `cfg`, `menu`, `display`, `app_dir`,
`data_dir`; `main.lua` exposes it as `ctx.about()`). `About.items(ctx)`
builds the rows. Pure: `parse_build_info(text)` → `{date, commit}`,
`build_text(info)` → "2026-10-23 · 1a2b3c4" / "development build".
Constants: `REPO`, `LICENSE`, `DEVELOPER`, `COPYRIGHT`.

## `dvp/qrencode.lua`: QR encoder (vendored)

[luaqrcode](https://github.com/speedata/luaqrcode), BSD-3-Clause, unchanged
(D38). `qrcode(text)` → `ok, matrix` (`matrix[x][y] > 0` = dark).

## `dvp/surround.lua`: headphone surround

D27. `Surround.new(cfg, sofa_path)`; fields `available` (HRTF file exists,
no passthrough, filter works), `enabled` (user choice), `active` (filter
currently in the chain), `channels` (decoder output channels).

- Observes `audio-params/channel-count`; `update()` adds the filter
  (`af add`, label `@dvp-surround`) when `enabled` and channels > 2, and
  removes it otherwise. A failed `af add` makes the feature unavailable.
- `toggle()` → new `enabled` state.
- Pure: `escape_lavfi(value)` (two-level FFmpeg escaping),
  `filter_string(sofa_path, gain)` (the `af add` argument, `%len%`-quoted),
  `GAIN = 6` (level match with mpv's downmix).

## `dvp/opensubtitles.lua`: OpenSubtitles API client

D28/D29. Pure helpers (all unit-tested):

| Function | Meaning |
|---|---|
| `moviehash_from(size, head, tail)` / `moviehash(path)` | OpenSubtitles hash (64-bit sum done as two 32-bit halves for Lua 5.1). `moviehash` returns `nil, size` for files < 128 KiB. |
| `parse_release(path)` | `{title, year, season, episode}` from a file name (episode markers, years, release junk, show folder for bare `S01E02` names). |
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
- Plex videos (D38): `key` is `plex_key(item)` (no network), search terms
  `plex_info(item)` (both pure), `hash_for(path, cb)` fetches the first
  and last 64 KiB from the server for the exact-match hash.
- Pure: `safe_lang(lang)` (letters and `-`, else `und`), `file_name(release, lang, file_id)`, `parse_file_name(name)` (→
  `{title, lang, file_id}`),
  `video_key(path)` (moviehash, or `small-<size>` for tiny files).

## `dvp/browser.lua`: library screen

State: `stack` of locations `{path, label, is_root?}`, `entries`,
`selected`, `scroll`, `cursor[path]` (remembered selection per folder),
`sort`.

- `refresh_sources()`: re-reads `library.sources()` and the recently
  played files (`resume:recent`, `[interface] recently_played`, D42);
  clears `is_root` on the top folder when the setup is no longer
  single-source (D23). Called by `show()`, `reload()` and when listing the
  root.
- `load()`: root (`root_entries()`: sources, then a "Recently played"
  header entry and the recent files, `recent = true`) or folder listing.
  With exactly one source and nothing recently played (`single_source()`)
  the root is skipped and that folder becomes the top level (`is_root`).
- Header entries (`header = true`) are never selected: up/down skip them,
  `selectable(i, dir)` moves page/first/last jumps off them.
- `reload()`: refresh sources + listing, keeping the cursor. `at_start()`:
  true at the top level.
- Navigation: `enter`, `go_back` (top level → quit dialog), `select_path`.
- Playback: `open_file(index, from_start)` shows the resume dialog when
  there is a position; `playlist_from(index)` returns the folder's files
  from the chosen one (if `autoplay_next`); for a recent file,
  `recent_playlist(path)` lists its own folder.
- `open_menu()`: sort (only where `sortable()`), reload, go to library
  start (whenever not `at_start()`), mark watched / unwatched (both for a
  partly watched video; `mark(entry, watched)` goes to Plex or
  resume.json), remove from recently played, controls, quit.
- Plex (D37): `load_plex(loc)` (async listing, `loading` state, drops late
  answers, `after_load` callback, e.g. to restore the cursor),
  `entry_state(e)` / `resume_position(e)` (Plex state or resume.json),
  `sortable()`, `plex_sign_in()` (code dialog, polls only while open),
  `plex_account_menu()`; `show(select)` puts the cursor on a path once
  the listing is there.
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
  `video-crop` (Fit for the rest); other modes clear it.
- Lifecycle: `start()` (on start-file), `on_file_loaded()`, `stop_screen()`, `show_overlay()`
  (auto-hides after `overlay_timeout`; stays while paused or while a menu is
  open), `hide_overlay()`, `update_timer()` (the 0.5 s timer runs only while
  something is visible).
- `handle(action)`: see the controls table in DECISIONS D10. B (`back`)
  hides the controls, then the info panel, and only stops with nothing on
  screen (D42); the `stop` key always stops.
  Short seeks are `relative+exact`, long seeks `relative+keyframes`.
  `chapter(dir)`: going back first jumps to the start of the current chapter
  when more than 3 s into it; with no chapters it seeks ±300 s.
- Menus: `open_audio_menu` (tracks, then the *Headphone surround* toggle
  when `ctx.surround.available`; `toggle_surround()` toasts the result),
  `open_subtitle_menu` (with "Off", then *Download subtitles…* when
  `ctx.subtitles:available(path)`),
  `open_main_menu` (live values through `rebuild`): tracks, subtitle
  size/position/delay, audio delay, volume, speed, picture (fit / fill =
  `panscan 1` / stretch = `keepaspect no`), match refresh rate
  (`toggle_refresh()`, shown when `display.refresh_possible`), next video,
  info, stats, stop, quit.
- `render()`: blurred top/bottom gradients, title, badges (resolution, HDR
  state, HW, matched Hz), pause icon, progress bar with buffered range and
  chapter ticks, elapsed / remaining / "Ends at" / chapter title, hint bar
  (hidden while a menu is open).
- `render_info()` / `info_lines()`: codec, resolution, fps, decoder, HDR
  source and output, mastering peak, display Hz, audio, audio output
  (plus "· headphone surround" while the filter is active),
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
| `tools/headless-run.sh` | Runs the app in headless gamescope and drives it (see DEVELOPMENT.md). `KEEP=1` keeps resume data between runs; `SURROUND=1`, `OSMOCK=1`, `OSMOCK_LOGIN=1` set up the v0.2 features; `PLEX_WRITE=1` allows progress reports to Plex (read-only by default); `MPV_EXTRA` adds mpv arguments; `RATES=48,60` forces a refresh list (headless gamescope can't switch, so this exercises the request/verify path); `XWAYLAND2=1` runs the app on gamescope's second Xwayland like SteamOS game mode. |
| `tools/mpv-ipc.py` | IPC step runner: key presses, screenshots, property reads. |
| `helper/build.sh [OUTDIR]` | Builds the refresh-rate helper (D31). |
| `scripts/make-source-archive.py OUT [--manifest M]` | GPL corresponding-source archive of a release from the manifest's pinned sources (D36). |
| `scripts/build-info.sh OUTFILE` | Writes `date=` and `commit=` for the About panel; run by the Flatpak manifest (D34). |
| `scripts/release-notes.sh [vX.Y.Z]` | Prints the `CHANGELOG.md` section of a release (default: `dvp/version.lua`) for the GitHub release text; exits 1 if missing (D41). |
| `tools/plex-dev-account.py DATA_DIR` | Writes a signed-in `plex.json` for tests from `.dev/plex/` (D37). |
| `tools/mock-opensubtitles.py [PORT]` | Fake OpenSubtitles API for tests (D30); used by `OSMOCK=1 tools/headless-run.sh`. |
| `tests/run.sh` | Runs all unit tests: `tests/run.lua` (Lua, inside mpv so `mp.*` exists) and `tests/test_steam_shortcut.py` (Python unittest, fake `HOME`). |
| `.github/workflows/build.yml` | CI: unit tests, Flatpak bundle; on `v*` tags a GitHub release with the bundle and an installer tarball. |
