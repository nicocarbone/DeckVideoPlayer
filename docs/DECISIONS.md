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
| B | back / quit | hide controls/info; else stop (saves position) | back = dismiss what is on screen, then leave (v0.3.1: B used to stop even with the controls up); resume makes it safe |
| X | play from start | subtitles | X/Y next to A: frequently used playback functions |
| Y | sort | audio | |
| D-pad ←→ | page | seek ±10 s | |
| D-pad ↑↓ | move | volume ±5 | Steam Machine controllers have no volume keys |
| L1/R1 | page | seek ±60 s | |
| L2/R2 | first/last | chapters (±5 min fallback); R2 skips an intro/credits marker (D47) | R2 is already "forward"; the prompt names it |
| View | video info (D50) | info panel | lets users verify HW decode / HDR / Hz; in the library, what a file is before playing it |
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

(HRTF equalization and levels revised in D48, v0.4.)

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
- **Toggle:** "Match refresh rate" in the Video menu (D52) switches matching
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

## D37. Plex Media Server as a library source (v0.3)

- **Sign-in:** plex.tv's PIN flow. The library menu's *Sign in to Plex…*
  shows a 4-character code (big, spaced) to enter at plex.tv/link on a
  phone; the app polls every 2 s only while that dialog is open. Then it
  reads the user name and the server list (`/api/v2/resources`) and saves
  `<data_dir>/plex.json` (client id, account token, servers with their
  addresses and per-server tokens; mode 600). No password ever touches the
  Deck. Chosen over a token/URL in `config.ini`: nothing to type, and the
  server list gives remote addresses for free. *Plex account* in the menu
  refreshes the list or signs out.
- **Sources:** each server is a library source (`library.sources(cfg,
  plex:sources())`), so it appears next to folders and drives with a
  server icon. Server page: *Continue watching* (`/library/onDeck`; the
  `/hubs/continueWatching/items` hub since D50) and
  the movie/show libraries (music/photos skipped). Shows → seasons →
  episodes; a one-season show opens straight into its episodes
  (`/allLeaves`). Listings load asynchronously (`browser:load_plex`,
  "Loading…", late answers for a location the user left are dropped).
  Name/date sort works client-side; the server page and *Continue
  watching* keep the server's order.
- **Connecting:** a server reports many "local" addresses; a server in
  Docker reports bridge addresses (172.17–31.x) nobody can reach.
  Candidates are probed in parallel (`/identity`, 3 s) and ranked: home
  networks (192.168/10) before 172.16/12, local before remote; relays are
  skipped (capped at a few Mbit/s). Only https `*.plex.direct` addresses
  (valid certificate) are used; plain http is an opt-in since D39. The
  best candidate wins as soon as everything ranked above it has failed,
  so the usual case is instant. Verified on a test server running in
  Docker (several unreachable bridge addresses): the LAN address is
  chosen immediately, and forcing the remote address also browses and
  streams.
- **Playback:** direct play only. mpv opens `/library/parts/…` as is, so
  every format, HDR10, VA-API and refresh matching work as for local
  files (4K HDR10 HEVC verified: opens in 0.4 s, seeks across the film in
  0.5 s on the LAN). The on_load hook fetches fresh metadata (resume
  point, external subtitle files, which are `sub-add`ed in on_preloaded),
  sets `http-header-fields` and `force-media-title` file-locally.
- **Token in logs:** mpv logs every property a script sets at `-v`, which
  the troubleshooting guide asks users to share. So mpv never gets the
  account token: it gets a *transient* token from the server
  (`/security/token?type=delegation&scope=all`, cached 12 h). Verified: it
  streams media and subtitles (HTTP 206/200), plex.tv rejects it (401),
  and a 600-line `-v` log of a Plex playback contains the account token 0
  times. Everything else goes through `dvp/http.lua` (secrets on curl's
  stdin).
- **Progress:** Plex is the source of truth for Plex videos (no
  resume.json entries). `/:/timeline` reports playing/paused every 30 s
  and on pause, `stopped` (blocking, 3 s) when the file closes, plus
  `/:/scrobble` when it finished; the library shows Plex's progress bars
  and checkmarks, and *Mark as (un)watched* calls (un)scrobble.
- **Read-only development:** `deckplayer-plex_readonly` makes reports and
  watched changes log-only; `tools/headless-run.sh` sets it unless
  `PLEX_WRITE=1`, so tests against a real server never change its owner's
  watch history. `tools/plex-dev-account.py` writes a signed-in plex.json
  for tests from a token in `.dev/plex/`.
- **Not in v0.3:** transcoding (remote play needs upload bandwidth above
  the file's bitrate), relays, Plex Home user switching, GDM discovery of
  servers without an account. (OpenSubtitles search for Plex items was
  added afterwards, D38.) Remote access was tested through the
  router's public address from inside the LAN only.
- **Shared HTTP helper:** `dvp/http.lua` (curl config on stdin, async and
  blocking variants, error texts) now serves OpenSubtitles too.

## D38. Plex sign-in by QR code; subtitle downloads for Plex videos

Both requested after the first Deck test of the Plex build (2026-10-24).

- **QR sign-in:** the sign-in dialog now shows a QR code next to the short
  code. Plex's auth page (`https://app.plex.tv/auth#?clientID=…&code=…&
  context[device][product]=…`) takes the PIN code from the URL, but its
  documented use is with *strong* PINs (25 characters) and it is unclear
  whether 4-character codes work there. So the app creates two PINs: the
  short one to type at plex.tv/link and a strong one inside the QR code,
  and polls both (every 2 s, only while the dialog is open); whichever is
  claimed first signs in. Typing remains the fallback if a phone can't
  scan.
- **QR encoder:** `luaqrcode` (speedata, BSD-3-Clause, upstream commit
  5a9c34bc04d5), vendored unchanged as `dvp/qrencode.lua`: pure Lua that
  runs on Lua 5.1/5.2/LuaJIT, no dependencies. The sign-in URL (~153
  characters) becomes a 45×45 code. `Ass:qr` draws dark modules as
  horizontal runs in one ASS drawing on a white square with the 4-module
  quiet zone. Verified by decoding screenshots (1280×800, 4K, Flatpak)
  with zxing-cpp.
- **Subtitles for Plex videos:** *Download subtitles…* was only offered
  for local files, because the exact-match search hashes the file and
  downloads are stored under that hash. For Plex videos:
  - search terms come from Plex's metadata (show or film title, year,
    season, episode), better than parsing a file name;
  - the OpenSubtitles hash is computed from the first and last 64 KiB,
    fetched with two HTTP range requests and the file size from the
    listing, only when the user searches (verified: same hash as an
    independent Python implementation);
  - downloads are stored under `subtitles/plex-<server>-<item>/`, so they
    reload on later plays (on_preloaded) without any network access.

## D39. Third audit (ISSUES.md Part III, v0.3.0) resolved

An audit of the whole codebase before v0.3.0, focused on the Plex account
and the network code. All findings fixed:

- **Plex connections are https only** (`*.plex.direct`, certificate
  checked). For a server the user owns, the server token *is* the account
  token, and plain http to a LAN address would hand it to whatever answers
  at that address on any network the Deck joins (hotel, café). Plain http
  is available behind `[plex] allow_insecure_lan = yes` (for routers that
  block plex.direct DNS), documented as for trusted home networks only.
- **Probes carry no token:** `/identity` is unauthenticated; the answer
  must have the expected `machineIdentifier`, so a different device at
  the same address is never picked.
- **curl hardening** (`dvp/http.lua`): no redirects by default (curl
  forwards custom headers such as `X-Plex-Token` to the redirect target,
  even on another host); only the subtitle file download (no secrets)
  follows, and only to https. `proto = =http,https` so a server can't make
  curl read `file://` URLs; downloads are capped (`max_size`, 10 MB for
  subtitles).
- **Server-supplied keys validated** (`plex.safe_key`): a single leading
  `/`, URL-path characters only. Rejects `@host` tricks that would send
  the token elsewhere; such entries are skipped.
- **OpenSubtitles responses validated:** login `base_url` must be
  `opensubtitles.com` or a subdomain, the download link must be https,
  the language code is letters/`-` only (else `und`) because it becomes
  part of a file name.
- **Private files:** `plex.json` is made mode 600 *before* the token is
  written (`util.write_private`); `config.ini` (may hold an OpenSubtitles
  password) is created with umask 077 by the launcher and the SteamOS
  installer. `write_file_atomic` now checks write/close errors and keeps
  the old file on failure (full disk no longer truncates `resume.json`).
- **Plex robustness:** the token is saved as soon as the PIN is claimed
  (a failing server list no longer loses the sign-in); no fallback to the
  account token when the transient token can't be fetched (the file fails
  instead of leaking the token into mpv logs); a failed Plex load forgets
  the cached transient token and connection (server restart); the app
  scrobbles only when it considers a video finished below 90 % (above,
  Plex's own threshold already counted the play).
- **Sandbox narrowed:** `--filesystem=home:ro` replaced by `xdg-videos:ro`
  and `xdg-download:ro` (plus `/run/media`, `/media`, `/mnt`). With
  network access since v0.2, a decoder exploit could otherwise read the
  whole home folder (SSH keys, other apps' tokens) and send it out. Cost:
  folders elsewhere in home need `flatpak override --user
  --filesystem=/path:ro io.github.nicocarbone.DeckVideoPlayer` (INSTALL).
- **CI:** top-level `permissions: contents: read` (write only in the
  release job); third-party actions pinned to commit SHAs.
- **Test data:** the owner's server details (addresses, names, library
  contents) never go into the repository; unit tests use made-up servers.

## D40. Fourth audit (ISSUES.md Part IV, Gemini, v0.3.0) reviewed

Every finding was checked against the code; all but one were valid.

- **Range requests capped:** `fetch_range` (OpenSubtitles hash of a Plex
  video) sets `max_size` to the range and accepts only HTTP 206, so a
  server that ignores `Range` can't stream a whole film into `/tmp` (RAM).
- **umask 077 in the launcher:** `write_private` created the temp file
  with the default mode and only then ran `chmod`; a process that opened
  it in that window kept read access to the token written next. With the
  umask, every file the app creates is owner-only from creation. The
  `chmod` stays as a fallback for runs without the launcher.
- **Server connections validated:** only bare https origins
  (`https://host:port`) are used; plain http (opt-in) only for IPv4
  literals with a numeric port (a non-numeric port used to raise a Lua
  error).
- **Sign-out and sign-in races:** `sign_out` also drops transient tokens
  and pending PINs; `refresh_account` ignores answers that arrive after a
  sign-out (they used to write the servers and their tokens back to
  `plex.json`). Closing the sign-in dialog cancels the PINs, so a late
  answer neither signs in nor closes whatever menu is open by then. A PIN
  claimed while the server list fails now closes the dialog as signed in.
- **One final report:** Stop and Quit no longer save progress themselves:
  mpv runs the on_unload hook for both (verified), and the extra async
  "playing" report could reach Plex after the final "stopped".
- **Plex progress follows resume.json rules** (`item_state`): no position
  under 30 s, near the end counts as watched, so the row, the X hint and
  the resume dialog agree.
- **Seasons and episodes keep the server's order** (listing kinds
  `seasons`/`episodes`, not sortable), whatever the sort chosen elsewhere.
- **Fresh resume point:** the browser passes no start position unless the
  user chose one (resume dialog, X), so a Plex video uses the position the
  server returns at load time, which may be newer than the listing.
- **Hash failures not cached**, so a later search retries.
- **Transient token prefetched** asynchronously once a server is
  connected: the first playback's on_load makes one blocking request
  instead of two.
- **Small items:** no JSON parse of empty bodies; curl exit 63 → "The file
  is too large"; luaqrcode credited in About.
- **Not adopted: asynchronous reports in on_unload when staying in the
  app.** The blocking `stopped` report (3 s timeout, usually milliseconds
  on a LAN) guarantees that the listing reloaded right after Stop, and the
  next playlist entry's metadata, already reflect the new position.
  Making it async would need the browser to wait or patch its state; the
  delay only shows when the server is unreachable.

## D41. Changelog as the GitHub release text

- **What:** `CHANGELOG.md` has one user-facing section per release
  (`## v0.x.y (date)`: new, changed, fixed). The release job publishes the
  tag's section as the GitHub release text (`scripts/release-notes.sh`,
  `body_path`), and fails without one; `tests/run.sh` checks that the
  current version has a section and a metainfo `<release>`.
- **Why:** the owner asked for a changelog on every GitHub release.
  Keeping it in the repository (instead of typing it on GitHub) reviews it
  with the code, ships it in the installer tarball, and makes forgetting it
  a test failure rather than an empty release page.
- **Alternatives:** GitHub's generated notes (a list of commit titles, not
  written for users); the metainfo `<release>` entries alone (kept, but
  short and XML-formatted for software centres).

## D42. v0.3.1: black-bar crop, B dismisses first, recently played

From the owner's tests on a Deck OLED.

- **Crop black bars (Picture mode).** A 4:3 show stored in a 16:9 frame
  (bars encoded into the file) got bars on all sides with Fit and still
  side bars with Fill: mpv only knows the 16:9 frame, so Fit/Fill/Stretch
  were right for the frame but not for the picture. The new mode finds the
  picture in the current frame and sets the file-local `video-crop`, then
  fits it (a 4:3 picture fills the Deck's height, bars only at the sides).
  - Detection uses one `screenshot-raw` frame scanned in Lua
    (`dvp/cropdetect.lua`), not mpv's `cropdetect` filter (its
    `TOOLS/lua/autocrop.lua`): the filter needs software frames, so with
    VA-API it would switch decoding off and on (a hitch, and 4K HEVC in
    software stutters on the Deck). `video-crop` is applied by the VO and
    keeps hardware decoding and HDR.
  - On demand, not automatic: a single frame can be a dark scene (sides
    that stay dark up to 40 % are treated as "can't tell"), and it costs a
    frame copy (33 MB for 4K, collected right away). Per file, like the
    other picture modes.
- **B during playback dismisses first.** B used to stop playback even
  when the user only wanted the controls gone. Now B hides the controls,
  then the info panel, and stops only with nothing on screen. The hint bar
  (visible exactly when B would hide it) says *Hide*; the playback menu
  keeps *Stop and return to library*.
- **Recently played** on the start screen, below the sources: the last
  `recently_played` (default 5) local files, newest first, with their
  progress; A plays and continues with the rest of the file's folder.
  - From `resume.json`, which already has a timestamp per file. A separate
    `played` time keeps *Mark as watched* from listing a file as played;
    *Remove from recently played* sets it to false (position and marks
    stay). Files that are gone or on a removed card are skipped (one stat
    per listed file).
  - Local files only: Plex already has *Continue watching* on its server
    page, and a Plex entry would need the server to be reachable to show.
    (Changed in D50: Plex videos are listed too.)
  - With one source, the start screen used to be skipped; now it is only
    skipped while nothing has been played, so the list is reachable for
    everyone (B from the folder goes back to it).
- **Mark as watched for partly watched videos.** The library menu offered a
  single toggle, and anything with a position counted as "watched", so an
  in-progress video (all of Plex's *Continue watching*) could only be
  marked unwatched. A partly watched video now gets both entries; watched
  clears the position (Plex's scrobble does the same on the server).
  *Mark as unwatched* keeps a played local file in *Recently played*.

## D43. Keep the screen awake during playback (screensaver inhibition)

- **Problem:** in game mode the screen dims and the Deck sleeps on Steam's
  own idle timer during long videos. mpv's `stop-screensaver` doesn't
  reach it (SteamOS#2619 for other players).
- **Experiment:** a test bundle had four modes in the playback menu so a
  test on a Deck could show what Steam honours: an idle-inhibit request
  (the `org.freedesktop.portal.Inhibit` portal and the
  `org.freedesktop.ScreenSaver` service), an F24 press every 20 s on a
  virtual keyboard (`/dev/uinput`), or both. Result on a Steam Deck
  (2026-10-24, dimming at its shortest, 1 minute): the portal is not
  available in game mode, **the ScreenSaver inhibition is accepted and
  prevents both dimming and sleep**; the key press worked too.
- **Decision:** keep only the request. It is the standard mechanism, needs
  no fake input and no device access (just
  `--talk-name=org.freedesktop.ScreenSaver`), and goes away cleanly. The
  virtual keyboard was removed; the portal call stays because it is what
  desktop sessions offer. On by default (`[display] keep_awake = yes`):
  a player should not dim mid-film, and only while playing.
- **How:** a small C helper, `dvp-keep-awake` (sd-bus), because an
  inhibition lasts only as long as the D-Bus connection that asked for it.
  It runs only while a video plays and is killed on pause or stop, so
  Steam's timers apply again when paused or in the library (battery). It
  writes the outcome to a status file shown in the info panel (*Keep
  awake*), which makes a failure visible.

## D44. One Flatpak branch, and shortcuts that don't name it

- **Problem:** releases up to v0.3.2 were built on branch `master` (the
  flatpak-builder action's default), test builds on `stable`; installed
  side by side, `flatpak run` kept starting the older one. v0.3.3 moved CI
  to `stable` and made the installer remove other installed branches.
  That broke shortcuts created from the app's menu entry (*Add a Non-Steam
  Game*, or `steamos-add-to-steam`, which the installer uses while Steam is
  running): Flatpak writes `--branch=master` into the entry's command, and
  that branch was now gone, so the app returned to Steam immediately.
- **Fix:** `steam_shortcut.py repair` removes `--branch=…` from the app's
  own shortcut (no other shortcut is touched); `add` does the same for an
  existing shortcut, and the installer runs `repair` when the app is
  already in the library. While Steam runs nothing is written (Steam would
  overwrite it); if the named branch no longer exists the installer asks
  to close Steam and run it again. A shortcut pinned to `stable` still
  works, so it is repaired quietly the next time Steam is closed.
- **Rule:** keep CI and `scripts/build-flatpak.sh` on `stable`.

## D45. Fifth audit (ISSUES.md Part V, Gemini, v0.3.5) reviewed

Each finding was checked against the code; fixed unless noted.

- **Plex playlist after an error:** a failed file used to drop the server
  connection, so every following episode played without its token and
  failed too. Now a file that fails although the server answered only
  drops the streaming token (`forget_token`); when the server is
  unreachable (`prepare` → `unreachable`), the rest of the playlist is
  cleared and the file fails at once (`stream-open-filename` set to an
  unknown protocol: 0.03 s instead of a network timeout per episode), with
  "Can't reach the Plex server".
- **Keep-awake helper:** breaks out when the bus goes away (was a 100 % CPU
  loop), waits at most 1 s at a time with a SIGTERM handler that
  interrupts the wait (a signal just before the wait could hang it while
  holding the inhibition), checks its parent each second (subreapers),
  guards the unique-name parsing and the status path length. The Lua side
  reports a helper that exits by itself, falls back to the private data
  dir instead of `/tmp`, and removes the status file on stop.
  *Not adopted:* the claim that `PR_SET_PDEATHSIG` would fire when an mpv
  worker thread ends mid-film: the thread that spawned the helper stays
  blocked on it until it exits.
- **Crop black bars:** opposite sides are paired (bars are symmetric), so
  a dark sky or a shadow on one side is no longer cropped; a failed
  detection leaves the mode at Fit so the next press retries (changed in
  D50: that kept right presses from ever leaving the mode). *Not
  applicable:* the still-cropped screenshot after clearing `video-crop`;
  detection never runs while a crop is active.
- **Smaller fixes:** recently played episodes continue in name order; pre-
  v0.3.1 resume entries keep their place when marked; the Plex PIN expiry
  is noticed whichever answer arrives last; the Subtitles menu rebuilds
  after a download; stale `after_load` callbacks are cleared; B closes
  Advanced statistics; NUL bytes are dropped from curl config values; the
  launcher reads `config.ini` keys and values like the app (`-`, quotes).
- **Installer:** keeps the `stable` copy while installing (a failed install
  no longer leaves nothing), runs `steam_shortcut.py add` whenever Steam is
  closed (adds the shortcut to every Steam profile, unpins, artwork), and
  `BRANCH_RE` no longer swallows quotes.
- **Battery / speed:** paused playback does no periodic work (no overlay
  re-render every 4 s, no 0.5 s tick); Y re-sorts the loaded entries in
  place (no new Plex request); `video-params` is read once per render; the
  subtitle store skips its folder check for Plex items and known keys.
- **Polish:** the metainfo feature list mentions Plex, recently played,
  black-bar cropping and keeping the screen awake.

## D46. Night mode: compressor + limiter, before everything else

- **What:** *Night mode* in the audio menu (Y), `[playback] night_mode`
  (off by default): `acompressor` (threshold −30 dBFS, ratio 4:1, attack
  10 ms, release 300 ms, soft knee, +5 dB make-up, `link=maximum` since
  D49) then `alimiter`
  (−1 dBFS, auto-level off), as one labelled `lavfi` graph added with
  `af pre`.
- **Why these numbers:** measured with pink noise rendered through mpv:
  a passage at −43 dBFS RMS comes out 5 dB louder, one at −18 dBFS 8 dB
  quieter (the 25 dB gap becomes 12 dB); at dialogue-like levels (−32 /
  −22 dBFS, 5.1) +5 / −1 dB. Loud passages never come out louder than
  without it, so turning it on doesn't jump the volume. A first try with
  +10 dB make-up raised everything 10 dB: rejected for that reason.
- **Any output:** it works per channel, so 5.1 to a TV or receiver (LPCM)
  keeps its layout; with headphones it runs before headphone surround
  (`af pre`). Not offered with `audio_passthrough` (compressed audio can't
  be filtered). Session toggle, like surround.
- **Alternatives:** `dynaudnorm` (smoother, but seconds of look-ahead and
  more CPU), `loudnorm` (two-pass/real-time EBU R128, much heavier), a
  centre-channel boost for 5.1 (only helps 5.1 sources, and only when
  downmixing).

## D47. Skip intro / credits from Plex markers

- **Data:** Plex detects intros (Plex Pass) and credits on the server and
  returns them as `Marker` entries when the item is fetched with
  `includeMarkers=1`; the app already fetches the item in `on_load`
  (`plex:prepare`), so no extra request. `final` marks the closing
  credits. Verified on the owner's server: most episodes carry an intro
  and a credits marker, films a credits marker.
- **UI:** while a marker plays, a pill at the bottom right says *R2 Skip
  intro*, *R2 Next episode* (closing credits with a next playlist entry;
  *Next video* for films) or *R2 Skip credits*; it sits above the
  controls when they show. R2 was "next chapter", the same direction; A
  stays pause. Only the closing credits go to the next entry: credits in
  the middle of a film may be followed by more of it.
- **Options:** `[playback] skip_intro = ask | auto | off`, `skip_credits =
  ask | off`. `auto` skips an intro once per file (seeking back into it
  shows the prompt instead). Credits are never skipped automatically:
  post-credits scenes exist.
- **Cost:** a 1 s timer, only while a file with markers plays (not when
  paused), plus a check after each seek (`playback-restart`).
- **Local files:** not yet. Chapter names ("Opening", "Ending") could feed
  the same `dvp/markers.lua`, but they are too inconsistent to act on
  without the user asking.


## D48. Headphone surround: diffuse-field equalized HRTF, dialogue-matched level

Supersedes the HRTF file and gain of D27, after the owner found surround
quieter and thinner than plain playback on a Deck.

- **Cause (measured):** the MIT KEMAR responses are recorded at the dummy
  head's eardrum with a small loudspeaker. Averaged over all directions
  they have the ear canal resonance (+20 dB around 2.5 kHz, relative to
  200–500 Hz) and the speaker's bass roll-off (−23 dB below 40 Hz).
  Headphones already produce the ear canal response, so it was applied
  twice. With pink noise on one channel against mpv's stereo downmix: 5.1
  dialogue (centre) −6 dB, the same on 7.1 −12 dB, main-channel bass below
  120 Hz −32 dB.
- **HRTF:** `hrtf/mit_kemar_normal_pinna_dfeq.sofa`, made by
  `tools/equalize-hrtf.py` from the original file: every response is
  filtered with a fit of the inverse diffuse-field average (a low shelf
  capped at +18 dB and five peaking filters), then rounded to 24-bit steps
  so it compresses like the 16-bit original (1.8 MB). Only `Data.IR`
  changes (edited in place with h5py), so libmysofa reads the file as
  before; a copy with longer responses (1024 taps) was rejected by
  libmysofa. Result: the average is flat within ±1.5 dB from 80 Hz to
  12.5 kHz; the differences between directions (the 3D cues) are kept.
  The 512-tap responses can't hold more bass: −3 dB at 63 Hz, −8 dB at
  40 Hz (was −12.5 and −21). The LFE channel doesn't go through the HRTF,
  so the deepest effects aren't affected.
- **Level:** gain 12.5 dB for 5.1, 3 dB more per extra channel
  (sofalizer subtracts 3 dB per input channel, so 7.1 is 18.5 dB):
  centre-channel dialogue measures the same loudness as the downmix
  (−34.6 LUFS both), so toggling surround doesn't change the volume; with
  all channels playing it's 1.7 dB louder (surround channels to the side
  are louder at the near ear, as with real speakers). The filter is
  replaced when the next file has another channel count. Since D49 the
  gain is a `volume` filter after sofalizer, followed by a limiter.
- **LFE:** mpv's stereo downmix drops the LFE channel; sofalizer adds it to
  both ears. `lfegain = 3` puts it level with the main channels' bass,
  like FFmpeg's downmix with the LFE included. The cinema calibration
  (+10 dB) was rejected: that much bass on top of a downmix-level
  soundtrack would clip loud scenes.
- **Rejected:** an EQ after sofalizer (simpler, but it boosts the LFE
  along with the main channels' bass, and sofalizer's `lfegain` can't go
  low enough to compensate); an extra bass shelf after it (+2 dB on the
  main channels' bass, +5 dB on the LFE); another HRTF set (SADIE II
  needs the same equalization and is 36 MB).

## D49. Sixth audit (ISSUES.md Part VI, Gemini, v0.4.0 work) reviewed

All findings checked against the code, FFmpeg 8 and measurements; fixed
unless noted.

- **1.1 Night mode on 5.1/7.1:** `acompressor` defaults to `link=average`,
  so dialogue alone in the centre of 5.1 was measured 15 dB too low.
  Measured: loud centre-only 5.1 came out 4 dB *louder* with night mode;
  with `link=maximum` it is reduced like stereo (−6.4 dB on the same
  test). One gain for all channels keeps the balance.
- **1.2 Surround clipping:** confirmed but smaller than reported: with all
  six channels near full scale, the old filter peaked at +2.7 dBFS (the
  plain downmix at +2.2) and sofalizer logged 135 "samples clipped"
  warnings in 10 s. Now `sofalizer` runs at gain 0, then `volume` and an
  `alimiter` at −1 dBFS: peaks −1.0 dBFS, no warnings, dialogue loudness
  unchanged (−34.6 LUFS).
- **1.3 Night mode at start:** `af pre` while idle only stores the option,
  so missing filters would have muted the first file. The filter is now
  added once audio is open, where a failure is reported and rolled back.
- **2.1 Next episode left the episode unfinished:** R2 on the closing
  credits now counts the episode as ended (`ctx.finished()`; the final
  report uses the duration as position), so Plex and `resume.json` mark
  it watched.
- **2.2 R2:** the triggers no longer auto-repeat (holding R2 on *Skip
  intro* went on to the next chapter); R2 checks the marker at the
  current position instead of the last 1 s check; the marker timer stops
  during a skip and restarts on `playback-restart`. The reported prompt
  flashing during an exact seek doesn't happen (mpv reports the seek
  target as `time-pos` while seeking), but stopping the timer is cheap.
- **2.3:** markers are cleared at the start of `on_load` (the previous
  file's prompt could stay up while a Plex item is prepared); the marker
  prompt is redrawn on resize; "Resumed at …" is shown before the
  automatic intro skip, so "Skipped intro" replaces it. Declined: moving
  the start position past an intro at 0:00 in `on_load`; the extra seek
  happens before the first frame and costs one range request.
- **3.1 Keep-awake helper:** after SIGTERM it no longer writes the status
  file (which the app had removed and a new helper may be using) or makes
  the second D-Bus call.

## D50. v0.4.1: video info, Plex in Recently played, Remove from Continue watching

Requests from the owner after v0.4.0.

- **Video info** in the library (View, or *Menu → Video info*;
  `dvp/videoinfo.lua`): file, size, duration, container, bitrate; video
  codec/profile, resolution, frame rate, bit depth, HDR type, colour
  primaries, mastering peak, MaxCLL/MaxFALL, video bitrate; one row per
  audio and subtitle track. A wide side panel (`wide = true`) so paths
  fit; the selected row scrolls what still doesn't.
  - **Local files: ffprobe**, now built from the FFmpeg already in the
    bundle (`--enable-ffprobe`, the only program). mpv can't describe a
    file without loading it as playback (resume, keep-awake, refresh
    matching would all react), and its `track-list` lacks the Dolby Vision
    configuration and HDR10+. Run in the background, only when asked: one
    run for container and streams, a second one that decodes the first
    video frame (`-read_intervals %+#1 -show_frames`), where HDR10+ and
    the brightness metadata are. The frame is needed for the colours too:
    FFmpeg 9's ffprobe left the HDR10 test file's transfer and primaries
    "unknown" at stream level (FFmpeg 8 filled them). Measured: 40 ms for
    the 1080p HDR10 test file.
  - **Plex: the item's metadata** (`/library/metadata/<id>`: Media, Part,
    Stream), not ffprobe over the network, which would need the token in
    the URL (argv). Plex gives `colorTrc`/`colorPrimaries` and the
    `DOVIPresent`/`DOVIProfile` fields, but no brightness metadata;
    HDR10+ only when its display title says so. The folder is the file's
    path on the server.
  - A video that signals no transfer function is shown as SDR (what
    players assume); Dolby Vision profile 5 has no HDR10 base layer, so
    it isn't labelled HDR10.
- **Plex videos in *Recently played*** (reverses D42's local-only rule).
  `save_progress()` also writes the item to `resume.json` under
  `plex://<machine>/library/metadata/<id>` (stable, unlike the stream URL
  that holds the server's address) with its label. The entry is drawn
  from that local copy, without contacting the server (no network work
  until the user acts), and listed while the account still has that
  server. A opens it through `plex:resolve()`: fresh metadata (the server
  stays the source of truth for the position) and, for an episode with
  `autoplay_next`, the rest of its season. Mark watched/unwatched there
  goes to the server and updates the local copy.
- **Remove from Continue watching** (Plex, library menu inside *Continue
  watching*): most entries there are "next up" episodes not yet started,
  which only offered *Mark as watched*; *Mark as unwatched* would change
  nothing for them. Plex's own action is
  `PUT /actions/removeFromContinueWatching?ratingKey=` (Plex Web,
  python-plexapi), which keeps progress and applies to every Plex app.
  *Continue watching* is now read from the `/hubs/continueWatching/items`
  hub, the list Plex apps show (same items as `/library/onDeck` on the
  owner's server), with `/library/onDeck` as a fallback when a server
  answers 400/404. Checked read-only: the server answers 400 for the
  action without an item and 404 for unknown actions; the removal itself
  is still to be confirmed on a real account. Partly watched items keep
  both *Mark as watched* and *Mark as unwatched* (D42).
- **Picture mode after "No black bars found"** (bug): D45 left the mode at
  Fit so the next press would retry, but the next mode to the right of
  Fit is *Crop black bars* again, so pressing right never left it.
  `crop_bars = "none"` now keeps the row on that mode (shown as "No black
  bars found", picture at Fit): right goes on to Fill, left back to Fit,
  and coming back to the mode retries.

## D51. HDR experiment: who tone-maps, and SDR to HDR (test build)

Status: **done, outcome in D52**: the owner found the difference a
matter of taste, so all choices ship as settings, defaulting to the
shipped behaviour.

- **Question 1: who fits HDR to the display.** Shipped behaviour: mpv
  sends HDR10 with the source's static metadata (`target-colorspace-hint`,
  hint mode `target` with `target-peak=auto` = the source's values);
  gamescope or the TV does the rest. libplacebo can do better with
  information the display never gets: Dolby Vision and HDR10+ per-scene
  metadata, or measured peaks. Three choices in the playback menu
  (`dvp/hdrtest.lua`, *HDR mapping (test)*), session only:
  - *Display*: shipped behaviour.
  - *Per scene*: `target-colorspace-hint-mode=source-dynamic`, which sends
    the per-scene metadata to the display as it changes (measured on a
    Dolby Vision 8.1 film: 112 nits signalled in a dark scene instead of
    the 1000-nit master).
  - *App*: `target-peak=<App peak>` (300–2000 nits, default 1000, the
    Deck OLED's HDR peak) and `hdr-compute-peak=yes`: mpv tone-maps and
    tells the display the content peaks there, so gamescope or the TV
    should have nothing left to compress. Risk to check by eye: a second
    mapping by gamescope.
- **Question 2: SDR to HDR.** mpv's `inverse-tone-mapping` with PQ /
  BT.2020 output and highlights up to 300–1000 nits (*SDR to HDR (test)*,
  off by default). Measured: gamescope's swapchain switches to
  `HDR10_ST2084` and back when turned off. Expected trade-offs:
  invented highlights, banding in 8-bit sources, extra GPU
  work and brighter OLED pixels (battery); TVs switch picture mode for
  every SDR file.
- Not offered on the Deck LCD (SDR panel) or with `hdr = off`. Options are
  set only when a file's transfer function becomes known or a choice
  changes; the values at start (from mpv.conf and the quality profile)
  are restored when a choice goes back to the shipped one.
- The info panel shows *HDR test* (what is applied) and *Signalled peak*
  (what the display is told), and says "HDR" instead of "HDR passthrough"
  while a test choice is active.
- Verified in headless gamescope (HDR on, Deck OLED profile, installed
  Flatpak): all three mappings and SDR to HDR change
  `video-target-params` as expected, hardware decoding and 0 dropped
  frames throughout.

## D52. HDR choices ship as settings, in a Video menu

The D51 test build showed that which HDR mapping looks best is
subjective (owner, Deck OLED and TV). So every choice ships, with the
v0.4.0 behaviour as the default:

- **Video menu** (*Menu → Video*, `player:open_video_menu()`), shaped like
  the audio and subtitle menus: video tracks (only when there is a choice;
  cover art doesn't count), *Picture* and *Match refresh rate* (moved from
  the playback menu, which now has a *Video* row showing e.g.
  "Fit · HDR"), then the HDR rows. No button of its own: the face buttons
  are taken, and it is used less often than audio or subtitles.
- **HDR rows** (`dvp/hdr.lua`, which replaces `dvp/hdrtest.lua`): *HDR*
  on/off; for HDR sources *HDR mapping* (Display / Display, per scene /
  App) and, for App, *Peak brightness*; for SDR sources *SDR to HDR*.
  Contextual, so a file only shows what applies to it. Not on a Deck LCD.
- **HDR off at runtime:** `target-colorspace-hint=no` mid-file makes
  gamescope's swapchain go back to sRGB and mpv tone-map to SDR; on again
  returns to HDR10 (measured in headless gamescope). Before, `hdr = off`
  was applied once at startup by `display.lua`; now `dvp/hdr.lua` owns it.
- **Persistence:** like night mode, the menu changes the session and
  `config.ini` holds the defaults (`hdr`, `hdr_mapping`, `hdr_peak`,
  `sdr_to_hdr`). The app never writes config.ini.
- **Screens not in HDR mode** (SteamOS HDR off, an SDR TV): *SDR to HDR*
  and *App* would make the picture dim and washed out (measured: mpv falls
  back to an SDR target but keeps the 600-nit inverse mapping). mpv's
  output tells whether the screen is in HDR mode, so after a change that
  should give HDR output, a one-shot check (1.5 s) reads
  `video-target-params/gamma`: PQ/HLG means an HDR screen; anything else
  turns those two choices off for the session with a toast, and the menu
  then shows "Screen not in HDR mode". At most one short glitch per
  session, and no work while idle. All choices are dropped there (D53).
  A known HDR screen is checked again with each file (docked to an SDR
  TV); a known SDR screen becomes HDR again as soon as mpv outputs HDR
  (`video-target-params/gamma` observed), not by retrying every file,
  which would flash every SDR file on an SDR TV with SDR to HDR set.
- **Info panel:** an *HDR* row says what is applied ("App maps to 1000
  nits", "Off (tone-mapped to SDR)"…); the badge shows "SDR → HDR" while
  SDR to HDR is active.

## D53. Seventh audit (ISSUES.md Part VII, Gemini, v0.4.1 work) reviewed

All findings checked against the code and in headless gamescope; all
fixed.

- **1.1 Badges and info panel after an HDR choice while paused:** the
  output changes a frame later, and no timer runs while paused. The
  player now observes `video-target-params/gamma` (fires on change only)
  and redraws the overlay / info panel if shown. Verified: HDR off while
  paused shows "HDR10 → SDR" at once.
- **1.2 Screen not in HDR mode:** `effective()` now drops every choice
  there (*Display, per scene* was still described in the info panel
  although the output was SDR), and `check()` always rebuilds an open
  Video menu when it learns the screen is SDR, not only when it turned
  something off. Verified with the menu opened before the check.
- **1.3 Screen state cached for the session:** a known HDR screen is
  checked again with each file; a known SDR one is promoted as soon as
  mpv outputs HDR (see D52 for why not every file). Changing the dock or
  SteamOS's HDR setting in the middle of a file still takes the next file.
- **2.1 Section headers took the cursor** (Video info, Controls, About):
  `selectable()` skips them; scrolling up onto a section's first row
  shows its header; the Video info workaround (`selected = 2`) is gone.
  The highlight did not disappear on headers as reported; the cursor
  just stopped on rows that do nothing.
- **2.2 Plex colour names** are lowercased before lookup (servers report
  lowercase today; cheap hardening).
- **2.3 Plex item from *Recently played*:** a toast ("Opening from
  Plex…") while the server is asked; the answer only opens the video if
  the cursor is still on that row with nothing else opened (a dialog
  opened and cancelled meanwhile no longer leads to a surprise start);
  the server's progress is copied into the row (`resume:sync`, play time
  kept).
