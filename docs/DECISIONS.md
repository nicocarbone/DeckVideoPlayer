# Decision log

Each entry records a decision, the alternatives considered, and why. Add new
entries at the end, numbered sequentially, and mark superseded ones instead
of deleting them.

---

## D1. mpv as the playback engine

- **Decision:** use mpv (with libplacebo and FFmpeg).
- **Alternatives:** VLC/libVLC, GStreamer, Kodi, a custom FFmpeg + Vulkan
  player.
- **Why:** mpv's `gpu-next` renderer has the best HDR handling on Linux
  (passthrough via `target-colorspace-hint`, high-quality tone mapping when
  needed), supports VA-API zero-copy into Vulkan, plays every format FFmpeg
  does, and has a mature Lua scripting API for building a UI. Kodi is far
  heavier and isn't tuned for gamescope HDR. VLC's HDR output on Linux lags
  behind.

## D2. The UI is Lua drawn on mpv's OSD, in the same process

- **Decision:** the whole interface (library browser, overlay, menus) is a
  set of mpv Lua scripts drawing ASS vector graphics. The user chose this
  option when asked.
- **Alternatives:** (a) a Qt/QML or Rust launcher embedding libmpv; (b) a
  separate launcher process that spawns mpv for playback.
- **Why:** (a) libmpv's render API is OpenGL only, so HDR passthrough under
  gamescope is lost. (b) works but adds a second process, extra dependencies
  and fragile window-focus handoff in gamescope. In-process Lua is the
  lightest option and keeps HDR. Cost: no widget toolkit, so `dvp/ui.lua`
  implements primitives (rounded rects, icons, button glyphs) and text widths
  are estimated.

## D3. Our own Flatpak instead of Flathub's `io.mpv.Mpv`

- **Decision:** build mpv ourselves in `packaging/flatpak/…yml`.
- **Why:** Flathub's mpv is built without `sdl2-gamepad` (the options are
  commented out in its manifest), and controller input depends on it. Our
  own build also lets us use LuaJIT (FFI for X11), drop unneeded parts
  (encoders, DVD/Blu-ray, JavaScript, VapourSynth) and bundle the app files
  and font. Module versions and commits are copied from Flathub's mpv
  manifest so they stay known-good.
- **Consequence:** the first build takes about 10–20 minutes; CI builds the
  bundle (`.github/workflows/build.yml`).

## D4. Flatpak (per-user) as the SteamOS install format

- **Why:** SteamOS's root filesystem is read-only and gets replaced on
  updates; Flatpak is the supported way to add software and survives
  updates. A per-user install (`--user`) needs no `sudo` (the `deck` user
  has no password by default).
- **Alternatives:** AppImage (no clean runtime/driver story for VA-API and
  Vulkan layers), distrobox (complex for users, HDR layer issues), unlocking
  the rootfs (lost on update).

## D5. HDR through X11 + gamescope WSI layer (`--gpu-context=x11vk`)

- **Decision:** under gamescope (`GAMESCOPE_WAYLAND_DISPLAY` set) the
  launcher forces `--gpu-context=x11vk` and exports `ENABLE_GAMESCOPE_WSI=1`.
- **Why:** games in SteamOS game mode run on gamescope's Xwayland. The
  gamescope WSI Vulkan layer intercepts X11 Vulkan surfaces and offers
  `VK_COLOR_SPACE_HDR10_ST2084_EXT` formats when gamescope outputs HDR. This
  is the same path DXVK/Proton games use, so it's the best-tested one.
  Inside Flatpak the layer comes from the Flathub extension
  `org.freedesktop.Platform.VulkanLayer.gamescope//25.08` (installed by the
  installer) and needs the `xdg-run/gamescope-0` permission.
- **Verified:** headless gamescope with `--hdr-enabled
  --hdr-debug-force-output`, both with the source tree and the installed
  Flatpak: the layer logs `hdr formats exposed to client: true` and the
  swapchain switches to `HDR10_ST2084` for an HDR10 file.
- **Override:** `[display] gpu_context` in config.ini.

## D6. Refresh-rate matching via `GAMESCOPE_DYNAMIC_REFRESH`

> **Superseded by D31** (2026-10-23): the property has no lasting effect on
> gamescope ≥ 3.13. Kept for the history; the rate selection rules below
> still apply.

- **Decision:** set gamescope's root-window property to an integer multiple
  of the video frame rate, choosing from the panel's valid rates; restore it
  afterwards.
- **Why:** 24 fps on a 90 Hz panel judders (90/24 = 3.75). Steam's per-game
  refresh slider uses this same property, read in gamescope's
  `steamcompmgr.cpp`.
- **Details:** OLED rates come from gamescope's
  `valve.steamdeck.oled.lua` (a discrete list; 75 Hz isn't valid, so 25 fps
  uses 50 Hz). Lowest multiple by default for battery
  (`refresh_prefer = low`). Ignored by gamescope while VRR is active, which
  is fine because VRR already matches frame pacing.
- **Implementation:** LuaJIT FFI → libX11 (no subprocess, works in the
  sandbox). `xprop` fallback for non-LuaJIT mpv.
- **Known caveat:** Steam may write the property itself, for example when
  the user moves the refresh slider in the Quick Access Menu; we re-apply on
  the next file.

## D7. `video-sync=audio` by default, `display-resample` optional

- **Why:** `display-resample` needs an accurate `display-fps`, which under
  Xwayland/gamescope isn't guaranteed. We set `display-fps-override` to the
  matched rate when we switch it, so `display_resample = yes` can be tried,
  but it stays experimental until verified on hardware.

## D8. Resume handled by the app, not mpv's watch-later

- **Decision:** `dvp/resume.lua` stores `{pos, duration, aid, sid, watched,
  t}` per path in `resume.json`. `save-position-on-quit` and
  `resume-playback` are off.
- **Why:** we need to *ask* (Resume / Start over), show progress and watched
  markers in the browser, and survive Steam killing the app. mpv's
  watch-later files are hashed by path, aren't easy to enumerate, and are
  written only on quit.
- **When saved:** `on_unload` hook (stop, end of file, next in playlist,
  quit), on pause, every 30 s during playback, and at shutdown.

## D9. Subtitle default ("auto" = subtitles only when audio is foreign)

- **Decision:** `subtitles = auto` maps to `subs-with-matching-audio=forced`
  plus `subs-fallback=default`.
- **Why:** this is what most people expect: Japanese audio shows English
  subtitles, English audio shows only forced English subtitles. Other modes:
  `always`, `forced`, `off`.

## D10. Controller mapping

| Action | Library | Playback | Reason |
|---|---|---|---|
| A | open/play | pause | universal "confirm" |
| B | back / quit | stop (saves position) | back = leave; resume makes it safe |
| X | play from start | subtitles | X/Y next to A: frequently used playback functions |
| Y | sort | audio | |
| D-pad ←→ | page | seek ±10 s | |
| D-pad ↑↓ | move | volume ±5 | Steam Machine controllers have no volume keys |
| L1/R1 | page | seek ±60 s | |
| L2/R2 | first/last | chapters (±5 min fallback) | |
| View | — | info panel | lets users verify HW decode / HDR / Hz |
| Menu | menu | playback menu | |

The Steam and "…" buttons stay with Steam. Mouse/trackpad clicks are
deliberately not bound: a tap would confirm the *selected* row rather than
the one tapped.

## D11. Virtual 800-unit canvas

- **Why:** the Deck is the main target, so the layout is designed in Deck
  pixels and scales uniformly; 16:9 screens just get a wider canvas.
  `ui_scale` lets TV users enlarge everything.

## D12. Text width estimation

> **Superseded by D32** (2026-10-23): per-character-class widths measured
> from Inter, plus scrolling for text that doesn't fit.

- **Decision:** `width ≈ chars × 0.5 × font_size`, plus `\clip` on list rows.
- **Why:** libass has no cheap per-string measuring call from Lua.
  (`compute_bounds` exists on overlays but measures a whole overlay.) The
  estimate is tuned for Inter and DejaVu Sans; ellipsis truncation uses it.

## D13. Bundled Inter font (static TTFs)

- **Why:** a consistent modern UI font. The *variable* Inter TTF registers as
  family "Inter Variable", which `\fnInter` doesn't match, so the static
  Regular and Bold files are installed instead. On development machines
  without Inter, libass falls back to the default sans font.

## D14. Removable media from `/proc/self/mountinfo`

> Extended by D33: the mount's source device names the volume ("SD Card").

- **Why:** listing `/run/media/*` also showed other users' directories. Real
  mount points under `/run/media/` or `/media/` are exactly the SD card and
  USB drives. This works inside the sandbox because Flatpak bind-mounts
  `/run/media` recursively.

## D15. Library sources abstraction

- **Why:** network shares and Plex are planned. `library.sources()` and
  `library.list()` define the shape a new source has to provide; playback
  only needs a path or URL that mpv can `loadfile`.

## D16. Input bindings via forced script bindings, built-ins disabled

- **Why:** one dispatcher decides per screen. `input-builtin-bindings=no`
  removes mpv's defaults (so `q` doesn't quit mid-menu, etc.).
  `CLOSE_WIN` is bound to quit explicitly because disabling built-ins also
  removes that binding.

## D17. `input-gamepad` enabled by the launcher, not mpv.conf

- **Why:** builds without SDL2 (e.g. distro mpv used in development) reject
  the option with an error. The launcher checks `mpv --list-options` first.

## D18. Decode-only FFmpeg

- **Why:** smaller build and bundle. Only the `png` and `mjpeg` encoders are
  kept (screenshots). All decoders, demuxers and parsers are kept.

## D19. Steam shortcut creation

- **Decision:** if Steam is running, use SteamOS's `steamos-add-to-steam`
  with the exported `.desktop` file. Otherwise edit `shortcuts.vdf` directly
  (`scripts/steam_shortcut.py`, a binary VDF reader/writer). Artwork is
  copied to `userdata/<id>/config/grid/<appid>{p,,_hero,_logo,_icon}.png`.
- **Why:** writing `shortcuts.vdf` while Steam runs gets overwritten by
  Steam. The app id of a shortcut we create is
  `crc32(exe + name) | 0x80000000` (the classic non-Steam id scheme). For
  shortcuts Steam creates, we read the id back from `shortcuts.vdf`.
- **Note:** the shortcut's LaunchOptions don't pin a Flatpak branch, so both
  `stable` and `master` installs work.

## D20. Picture mode is per file

- **Decision:** Fit / Fill / Stretch from the playback menu applies to the
  current file only. When the next file starts, `panscan`/`keepaspect` go
  back to the values that were in effect at startup (the app defaults, or
  a user `mpv.conf`). The menu label is derived from mpv's actual
  properties (`Custom` for other `panscan` values), so it can't drift.
- **Why:** a "Fill" chosen for a 2.39:1 film would otherwise crop the next
  16:9 episode. Source: external audit (ISSUES.md 1.3).

## D21. Files opened from outside the library ("Open with", command line)

- **Decision:** if playback starts without the library starting it, the
  session is "external": the saved position is resumed automatically and
  announced with a "Resumed at …" toast, and the app quits when playback
  stops or the playlist ends, instead of showing the library.
- **Why:** this matches what a normal desktop player does, and there is no
  library context to return to. Library playback still asks Resume / Start
  over. Auto-advanced playlist entries also show the toast.
  Source: ISSUES.md 1.4.

## D22. Safe `shortcuts.vdf` writes, lossless 64-bit values

- **Decision:** `steam_shortcut.py` serialises the whole file first, then
  writes a temp file, fsyncs it and `os.replace`s it over the original,
  keeping `shortcuts.vdf.bak`, for both `add` and `remove`. VDF type `0x07`
  (uint64) values are read as `UInt64` and written back as `0x07`.
- **Why:** the previous code opened the file for writing (truncating it)
  before serialising, so any serialisation error erased all of the user's
  non-Steam games. Covered by `tests/test_steam_shortcut.py`
  (byte-identical round trip, failed save leaves the file intact).
  Source: ISSUES.md 1.2, plus the truncation problem found while reviewing
  it.

## D23. Library sources are re-read whenever the library is shown

- **Decision:** `browser:refresh_sources()` runs on `show()` (returning
  from playback), on "Reload library" and at the source list. If a
  single-source setup gains a second source (SD card inserted), the
  top-level folder stops being the top (`is_root` cleared), so B goes back
  to the source list. "Go to library start" is offered whenever the user
  isn't at the top level. Source: ISSUES.md 1.1.

## D24. Audit suggestions deliberately not adopted

Recorded so they are not re-proposed without new evidence:
- **Splitting `readdir` into "dirs"/"files" to save `stat()` calls**
  (ISSUES.md 2.1): mpv's `utils.readdir` with a filter calls `stat()` on
  every entry itself (`player/lua.c`, `script_readdir`), so this would
  double the calls. One `stat` per entry is the minimum needed to tell
  folders from files, and it runs only when a folder is opened.
- **Keeping a persistent X11 connection for the refresh property**
  (ISSUES.md 2.3): it is used about twice per file load; a long-lived
  connection adds failure modes (stale display) for no measurable gain.

## D25. Per-file data cached in the player

- **Decision:** the overlay redraw (every 0.5 s while visible) uses cached
  per-file data: the title (computed on `start-file`), the video track (on
  `file-loaded`) and the chapter list (`observe_property`, so it updates
  only when it changes). `media.hdr_state(video_track)` accepts the cached
  track. Source: ISSUES.md 2.2.

## D26. Gamepad probe skipped inside the Flatpak

- **Decision:** the launcher skips `mpv --list-options` when
  `/.flatpak-info` exists (the bundled mpv always has `sdl2-gamepad`).
- **Why:** saves one extra mpv start (≈25–90 ms) per launch. Source:
  ISSUES.md 2.4.

## D27. Headphone surround with sofalizer and the MIT KEMAR HRTF (v0.2)

- **Decision:** 5.1/7.1 audio can be rendered binaurally for headphones
  with FFmpeg's `sofalizer` filter (`dvp/surround.lua`). The filter is in
  the chain only while the decoder outputs more than two channels
  (`audio-params/channel-count`, which is measured before filters, so
  inserting it doesn't retrigger the observer). Stereo is never touched.
  Off by default; toggled in the audio menu or with
  `[playback] headphone_surround`.
- **HRTF file:** `mit_kemar_normal_pinna.sofa` (1.2 MB, "without any
  usage restrictions", citation requested) is committed in
  `app/share/deckvideoplayer/hrtf/` so dev runs and the Flatpak use the
  same file. SADIE II (Apache-2.0) was the alternative but is 36 MB per
  head. Provenance and checksum: `hrtf/README.md`.
- **Gain +6 dB:** measured with uncorrelated pink noise on 5.1, sofalizer
  at 0 dB is about 6 dB quieter than mpv's own stereo downmix; +6 dB makes
  toggling level-neutral (−29.7 vs −29.5 dB mean).
- **Cost:** well under 1 % of one core (frequency-domain convolution).
  Note that sofalizer resamples to the HRTF's 44.1 kHz; PipeWire takes
  that rate as is.
- **Build:** FFmpeg gets `--enable-libmysofa` (library and headers are in
  the Freedesktop 25.08 runtime/SDK, no new module).
- **Why not automatic:** mpv can't tell headphones from speakers (the
  PipeWire sink is the same for the Deck's speakers and its jack).
  Unavailable with `audio_passthrough` (compressed audio can't be
  filtered, and a receiver means speakers).
- **Filter string:** the graph is passed to `af add` with mpv's
  `%length%` quoting, and the path is escaped for both FFmpeg levels
  (`Surround.escape_lavfi`), so any install path works (tested with
  `: , [ ] '` in the path). If the filter fails (an mpv/FFmpeg without
  libmysofa), the toggle disappears instead of retrying.

## D28. Online subtitles: OpenSubtitles, stored per video hash (v0.2)

- **Provider:** OpenSubtitles.com REST API, the only large provider with a
  documented API. Others (Addic7ed, Subscene successors) mean scraping.
- **Search:** two requests in parallel: by the OpenSubtitles file hash
  (exact release match) and by a title parsed from the file name
  (`parse_release`: "Show.S01E02" → title + season/episode, "Film (2019)"
  → title + year, release junk cut, show folder used for bare "S01E02"
  names). Results are merged and ranked: preferred language, exact match,
  human translation, downloads. Languages come from
  `[playback] subtitle_languages` (ISO 639-2 mapped to OpenSubtitles
  codes), English if empty.
- **Storage:** video folders are read-only in the Flatpak, so downloads go
  to `<data dir>/subtitles/<moviehash>/<release>.<lang>.srt`. Keying by
  the hash means renaming or moving the video keeps its subtitles.
- **Reloading:** an `on_preloaded` hook `sub-add`s stored files with the
  `auto` flag before track selection, so the usual language rules and a
  resumed subtitle choice include them. With no downloads at all, nothing
  is hashed (one `readdir`).
- **Re-download protection:** picking a release that is already stored
  selects the existing file; no quota is spent.
- **HTTP:** curl subprocess, asynchronous (`command_native_async`), with
  its configuration (API key, password, JSON body) on stdin via `-K -`, so
  secrets never appear in a process list. Parameters are sent sorted and
  lowercase, as the API asks (it redirects otherwise).
- **UI:** the results menu opens immediately with "Searching…" and is
  filled in place (`menu:update`) when both requests finish; failures show
  "Search failed" plus a toast with the reason.

## D29. OpenSubtitles API key and account

- **Facts:** every request needs a consumer API key and a User-Agent
  naming the app. Downloads without an account are limited per IP (a few
  per day); a free account raises the limit. Searching doesn't count.
- **Decision:** no API key is built in. Each user creates a personal key
  (free, at opensubtitles.com/consumers) and sets `[opensubtitles]
  api_key`; without it the feature shows no UI. The step-by-step is in
  INSTALL.md, the config template and CONFIGURATION.md.
- **Why:** the source code is meant to be public. A key in the code (what
  Kodi's add-on does) would be in the git history for anyone to reuse, and
  abuse would get it blocked for every user. A personal key also keeps
  each user's usage on their own quota.
- **Rejected alternative:** a built-in key, written into the code during
  development and removed before committing; never commit a real key.
- Username and password are optional, stored in `config.ini` (a
  user-owned file), and only used to log in once per session before the
  first download.
- **User-Agent:** `DeckVideoPlayer v<dvp/version.lua>`.

## D30. Mock server for network features

- **Decision:** `tools/mock-opensubtitles.py` implements the four
  endpoints the app uses; `OSMOCK=1 tools/headless-run.sh` starts it and
  points the app at it with the development-only script option
  `deckplayer-opensubtitles_url`. It logs each request with its Api-Key,
  Authorization and User-Agent headers.
- **Why:** the download flow (search, login, download, quota and network
  errors, reload on replay) can be tested headlessly and repeatably,
  without a key, without spending quota and without depending on the
  service being up. Future Plex work should follow the same pattern.

## D31. Refresh-rate requests through the gamescope_control protocol

- **Bug (found on a Deck, 2026-10-23):** the app said "48 Hz" for a 24 fps
  film while Steam's performance overlay showed 90 Hz. Since gamescope 3.13
  (late 2023), `steamcompmgr.cpp` recomputes the dynamic refresh target on
  every painted frame (`_update_app_target_refresh_cycle` resets it, then
  derives it from the *app refresh-cycle override*), so a
  `GAMESCOPE_DYNAMIC_REFRESH` written by a client is overwritten at the next
  frame. The override is set by Steam through the private
  `gamescope_control.set_app_target_refresh_cycle` Wayland request. Our
  headless test only checked that the property was written, never that the
  display changed (headless/nested gamescope can't switch rates).
- **Decision:** send the same request Steam sends, from a tiny C helper
  (`helper/dvp-gamescope-refresh.c`, built into `/app/bin`):
  `set HZ` with flags `internal_display` (when the active display is
  internal), `allow_refresh_switching` and `only_change_refresh_rate` (no
  frame limiter: mpv paces video itself). gamescope picks the highest valid
  rate divisible by HZ, so we pass the exact rate we chose (48, not 24, which
  would give 72). `set 0` gives the display back.
- **Rates from gamescope:** `info` returns the `active_display_info` event's
  valid refresh rates, which replace our hard-coded Deck tables. A display
  reporting fewer than two rates (TVs, nested/headless gamescope) is not
  switched. `refresh_rates` in config.ini still overrides the list.
- **Trust but verify, where possible:** gamescope publishes the rate in
  effect in the `GAMESCOPE_DISPLAY_REFRESH_RATE_FEEDBACK` root property,
  but only on its *first* Xwayland server. SteamOS game mode runs Steam
  there and games on the second one, and the Flatpak can only reach its own
  X server, so on a Deck the property is not readable. Two seconds after a
  request the app tries: confirmed → "48 Hz (matched)"; contradicted →
  "90 Hz (asked for 48 Hz)" and no badge; unreadable (the Deck case) →
  "48 Hz (requested)", badge shown, `display-fps-override` set to the
  request. mpv's own `display-fps` is no help: gamescope gives Xwayland a
  fixed output mode, so it keeps saying ~90 Hz (89.89 on the OLED).
  `XWAYLAND2=1 tools/headless-run.sh` reproduces the two-server layout.
- **Competing with Steam:** the override is global and last-writer-wins;
  Steam re-sends its own (e.g. from the Quick Access Menu). The app asks
  again on every file and when playback resumes from pause, if the live
  rate drifted. On restore it asks for the rate the display had before
  (or native when that was the maximum).
- **Why a helper and not Lua:** mpv's Lua can't speak Wayland; LuaJIT FFI
  to libwayland-client would need the protocol's interface tables by hand.
  The helper is ~150 lines, uses the vendored protocol XML (MIT, from
  gamescope) and needs no new sandbox permission (`xdg-run/gamescope-0` was
  already granted for the HDR layer). A one-shot process per request is
  fine: requests happen about twice per file.
- **Verified on a Deck OLED (2026-10-23):** a 24 fps film switches the panel
  to 48 Hz (Steam's performance overlay shows 48 Hz). The Quick Access
  Menu's refresh slider keeps showing Steam's own value (90 Hz); that is
  expected, Steam doesn't know about our request. Moving the slider makes
  Steam's value win until the next file or unpause.
- **Toggle:** "Match refresh rate" in the playback menu switches matching
  on/off for the session (`set_matching`); `refresh_match` in config.ini is
  the default. Off restores the previous rate immediately.

## D32. Text measuring per character class, and scrolling long text

- **Bug (found on a Deck, 2026-10-23):** in the playback menu, a long
  subtitle name (downloaded subtitles are named after the release) ran out
  of the side panel to the left and covered the "Subtitles" label. Menu
  values were never shortened, only labels; and the flat estimate
  `0.5 × size` per character under-measured capitals and wide letters.
- **Measuring:** `ui.text_width` sums per-character widths by class
  (narrow `iIl.,:;·` 0.28 em, semi-narrow `ftr()-/` 0.39, wide `mwMW@%`
  0.92, capitals 0.68, digits 0.6, other lowercase and punctuation 0.58,
  accented/Cyrillic 0.6, CJK 1.0, emoji 1.2), averaged per disjoint class
  from Inter's real advance widths (fontTools on the bundled TTFs; a first
  version averaged lowercase *including* the narrow letters, 0.53, and
  under-measured URLs). libass sizes
  text by ascender+descender (1.21 em for Inter), so 1 em = 0.826 `\fs`;
  calibrated against a real render (a 96-character release name at size 23
  measures ~955 units, the estimate gives 900–1010). Bold is +4 %.
  `fit_text` cuts by that measure and appends "…". Exact measuring with
  `compute_bounds` would need an overlay render per string; not worth it.
- **Menu rows** (`Menu.split_row`): label and value get their full width
  when both fit; otherwise the label keeps up to 45 % and the value the
  rest, both shortened.
- **Scrolling (marquee):** the selected menu row (its value if cut, else
  its label) and the selected library entry scroll inside their box when
  cut: 1.2 s rest showing the "…" version, scroll at 45 units/s, 1.2 s
  rest at the end, three passes, then stop on the "…" version. Pixel-smooth
  via `\clip` + moving `\pos`, redrawn at 24 Hz *only while scrolling*;
  the timer stops by itself (battery rule). Not used for the playback
  title (fits left of an open side panel instead) or the info panel.
- **No wrapping:** every text event has `\q2`; libass would otherwise wrap a
  long line (seen while the library entry scrolled).
- `tools/make-test-media.sh` adds a long-named symlink to the test library
  so this stays covered.

## D33. Removable volumes named by device: "SD Card", "USB drive"

- **Request (2026-10-23):** the microSD card appeared as its UUID.
- **Decision:** `parse_mountinfo` also returns the mount's source device
  (the field after ` - fstype`), which stays the real device inside the
  Flatpak because it describes the filesystem, not the bind mount.
  `removable_info(path, source)`: `/dev/mmcblk*` → kind `sdcard`, "SD Card"
  (or "SD Card (Label)" when the volume has a real label), SD-card icon;
  `/dev/sd*` / `/dev/nvme*` → kind `usb`, its label or "USB drive",
  drive icon; anything else keeps the folder name. Folder names that are
  IDs (UUIDs, FAT/exFAT serials like `1A2B-3C4D`, kernel names like
  `mmcblk0p1`) count as "no label". Duplicate names get " 2", " 3".

## D34. About panel

- **Decision:** "About" at the end of the library menu and the playback
  menu opens a side panel (`dvp/about.lua`): version (`dvp/version.lua`),
  build date and git commit, developer, repository, licence, copyright,
  no-warranty note; mpv / FFmpeg / Lua versions, detected device, settings
  and data paths (what a bug report needs); credits (mpv, FFmpeg,
  libplacebo, libass, LuaJIT, Inter, MIT KEMAR HRTF, OpenSubtitles) and the
  trademark notice (not affiliated with Valve).
- **Build info:** `scripts/build-info.sh` writes
  `/app/share/deckvideoplayer/build-info` (`date=`, `commit=`) during the
  Flatpak build; the commit gets `-modified` when built with uncommitted
  changes, so test builds are recognisable. The manifest no longer skips
  `.git` (1.5 MB) so the commit is available, also in CI. Running from
  source shows "development build".
- **Developer name:** the GitHub handle (`About.DEVELOPER`,
  `About.COPYRIGHT`), already public in the repository URL and the
  metainfo. A copyright line also names the holder of the GPL'd code.
- Rows are plain menu items (selectable, no action), so long values scroll
  when selected (D32).

## D35. Second audit (ISSUES.md Part II, v0.2.0) resolved

Reviewed on 2026-10-23; each item verified against the code (and, for 1.3,
reproduced) before fixing:
- **Per-file track choices and delays (1.3):** reproduced: after choosing
  audio track 2, "Subtitles off" or an audio/subtitle delay, the *next*
  file inherited them (mpv keeps runtime changes of `aid`, `sid`,
  `sub-delay`, `audio-delay`). `on_load` now sets them file-locally
  (`aid=auto`, `sid=auto`/`no` per `[playback] subtitles`, delays 0) before
  the saved choice from resume.json, so changes are undone when a file
  ends. Volume, subtitle size/position and speed stay session-wide on
  purpose.
- **Downloaded subtitle names (1.2):** stored as
  `<release> #<file_id>.<lang>.srt`, so different uploads with the same
  release name no longer collide; re-picking the same upload still reuses
  the file. Track titles strip the id.
- **API key not sent with the file download (2.1);** language codes from
  the API lowercased before ranking (1.4); error toast only while the
  results menu is still open, `menu:refresh()` after a download (1.6).
- **Text:** half-unit slack in the menu's scroll decision so long labels
  with short values scroll (1.1); the marquee restarts when the text
  under the same key changes, and the library re-renders when a menu over
  it closes (1.5).
- **Mounts (1.7):** pseudo filesystems (`tmpfs`, `autofs`, …) under
  `/run/media` are ignored. Not adopted: "only `/dev/…` sources", which
  would hide network mounts under `/media`.
- **Small resets (1.8):** `display-fps-override` cleared while a new
  refresh request is pending; `state.resumed_at` cleared at each `on_load`.
- **Helper (2.2):** `set` rejects non-numeric rates instead of treating
  them as 0 (= native).
- **Release metadata (3.1):** 0.2.0 `<release>` and features added to the
  metainfo (plus homepage/bugtracker URLs). 3.2 (ROADMAP/AGENTS status)
  is done in the release commit.

## D36. Going public: GPL source, notices, beta disclaimer, funding

- **Corresponding source:** the release Flatpak contains GPL binaries
  (mpv; FFmpeg built `--enable-gpl --enable-version3`, i.e.
  GPL-3.0-or-later, which makes the bundle as a whole GPL-3.0-or-later).
  Pointing at upstream repositories is not enough for GPLv2 §3 / GPLv3 §6,
  so every release carries `DeckVideoPlayer-<tag>-sources.tar.gz`, made by
  `scripts/make-source-archive.py` from the manifest: each git source at
  its pinned commit with submodules, each archive checksum-verified, the
  app's own `git archive`, the manifest and a `SOURCES.md` index (~70 MB).
  CI builds it in the release job. The runtime and the gamescope layer come
  from Flathub and are not ours to provide.
- **Notices:** `THIRD_PARTY_NOTICES.md` lists every bundled component and
  its licence, the files vendored in the repo (HRTF data, gamescope
  protocol XML) and the trademark statement. flatpak-builder already
  installs each module's licence files in
  `/app/share/licenses/<app-id>/<module>/`.
- **Disclaimer:** beta, tested only on a Steam Deck OLED, no warranty: at
  the top of the README and INSTALL, in the About panel ("Status") and in
  the metainfo description.
- **Funding:** Ko-fi only for now (one-off tips by card/PayPal):
  `.github/FUNDING.yml`, a "Support the project" README section, an About
  row and the metainfo donation URL. GitHub Sponsors was considered and
  postponed by the owner; adding it later is one `github:` line in
  FUNDING.yml plus a README/About line.
- **Checked and fine:** no secrets anywhere in the git history; Steam
  artwork is original (app name and generic shapes, no Valve marks); the
  only third-party files in the repo are the HRTF data (no restrictions)
  and gamescope's MIT protocol XML (notice kept). Commit metadata carries
  the owner's name and e-mail; left as is (rewriting published history
  would be destructive).
