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
| Choices remembered per movie or season | `…/dvp/memory.lua` (store, keys), `…/dvp/submemory.lua` (subtitles, D72), `…/dvp/videomemory.lua` (Picture, HDR, D73; online Quality per list, D89) |
| Menus/dialogs component | `…/dvp/menu.lua` |
| Drawing primitives, icons, button glyphs, theme | `…/dvp/ui.lua` |
| Button → action mapping | `…/dvp/input.lua` |
| Wiring, lifecycle, resume save/restore | `…/main.lua` |
| Settings schema | `…/dvp/config.lua` + `app/share/deckvideoplayer/config.ini` |
| HDR / refresh rate / device detection | `…/dvp/display.lua`, `helper/dvp-gamescope-refresh.c` (D31), `app/share/deckvideoplayer/mpv/mpv.conf`, `app/bin/deckvideoplayer` |
| Folder listing, sources, sorting | `…/dvp/library.lua` |
| Plex (sign-in, servers, browse, playback, progress) | `…/dvp/plex.lua`, Plex parts of `…/dvp/browser.lua` and `…/main.lua`, `tools/plex-dev-account.py` |
| Jellyfin (discovery, Quick Connect, browse, playback, progress) | `…/dvp/jellyfin.lua`, `helper/dvp-discover.c`, Jellyfin parts of `…/dvp/browser.lua`, `tools/jellyfin-dev-account.py` (D55) |
| DLNA servers (SSDP discovery, ContentDirectory browsing) | `…/dvp/dlna.lua`, `helper/dvp-discover.c` (`--ssdp`), DLNA menus in `…/dvp/browser.lua`, `tools/mock-dlna.py` (D66) |
| Online videos (`.m3u` lists of links, yt-dlp, playlists, cookies) | `…/dvp/online.lua`, yt-dlp transfers in `…/dvp/downloads.lua`, `ytdl` lines in `mpv.conf`, `tools/mock-online.py`, `scripts/update-yt-dlp.py` (D84) |
| Plex / Jellyfin behind one interface | `…/dvp/servers.lua` (router used by browser, main, player, subtitles, video info) |
| HTTP (curl) for all network features | `…/dvp/http.lua` |
| Headphone surround | `…/dvp/surround.lua`, `app/share/deckvideoplayer/hrtf/` (made by `tools/equalize-hrtf.py`, D48) |
| TV speaker mix (5.1/7.1 to stereo, clearer dialogue) | `…/dvp/tvmix.lua` (D75), rows in `player:audio_items()` |
| About panel, version, build info | `…/dvp/about.lua`, `…/dvp/version.lua`, `scripts/build-info.sh` |
| HDR choices (Video menu) | `…/dvp/hdr.lua` (D52), rows in `player:hdr_items()` |
| Video info panel (library) | `…/dvp/videoinfo.lua` (ffprobe / Plex / Jellyfin metadata, D50) |
| Downloads for offline playback, deleting local videos | `…/dvp/downloads.lua` (queue, curl transfers, Downloads menu), `download_info` in `…/dvp/plex.lua` / `…/dvp/jellyfin.lua`, `delete_refusal` / `delete_video` in `…/dvp/library.lua` (D60) |
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

## Current state (2026-11-24, v0.9.5)

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
  commit details of the owner's Plex or Jellyfin servers either
  (addresses, names, library titles, ids, hashes from them): tests and
  docs use made-up data.
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
- v0.5.0 (2026-10-27, D55): Jellyfin as a second media server, with
  Plex moved behind the same interface (`dvp/servers.lua`). Tested against
  the owner's Jellyfin 12.4 test server (browse, play, subtitles,
  Recently played, Video info, Flatpak; progress, watched marks and Next
  up with JELLYFIN_WRITE=1, items restored) and Plex regression-tested.
  Tests against it: `tools/jellyfin-dev-account.py`, read-only unless
  `JELLYFIN_WRITE=1`. Also: source tags in *Recently played* and a
  Source row in Video info (D56), 5.1 headphone surrounds at 120° (D57),
  subtitle brightness (D58). Eighth audit (ISSUES.md Part VIII) fixed in
  D59.
- v0.6.0 (2026-10-28, D60): downloads for offline playback (Plex,
  Jellyfin) to `[library] download_folder`, and *Delete from this
  device…* for local videos (never server or network-share files); the
  library folders in the Flatpak are writable for this. Tested against
  the owner's test servers (reads only) and in headless gamescope;
  on-device checklist item 15 pending. Also *Decoding* (hardware /
  software, per video) in the Video menu, because 4K AV1 stutters with
  the Deck's hardware decoder (D62); bug hunt (D61); B closes toasts and
  the skip prompt first (D63).
- v0.7.0 (2026-10-29): folder listings in a subprocess, network
  folders never stat'ed (D64); `EXTRA_FOLDER` in `tools/headless-run.sh`;
  SMB mount guide (D65); DLNA servers (D66, `tools/mock-dlna.py`);
  pre-release audit fixes recorded in D64. Owner's test NAS: details only
  in git-ignored `.dev/network-test.md`. On a Deck the owner confirmed the
  test build works (SMB share through the guide).
- v0.7.1 (2026-10-29): DLNA downloads (D67); a download's retry status
  names the reason. Open: on the owner's Deck the first attempt of a
  download sometimes retries once (cause not found here; a log of the
  new status would tell).
- v0.7.2 (2026-10-30): ninth audit (ISSUES.md Part IX) fixed in D68.
- v0.8.0 (2026-11-03, D69): old SD video. `deinterlace=auto` in
  `mpv.conf` (refresh matching follows the doubled rate), and
  `dvp/looks.lua`: *Look* (CRT), *Grain*, *Clean-up* (SD only; mpv
  `format` + lavfi `fspp`/`hqdn3d`, libplacebo deband) in the Video menu,
  shaders in `app/share/deckvideoplayer/mpv/shaders/`, remembered in
  `looks.json`. Test builds tried by the owner on a Deck (Clean-up's
  battery cost not measured). Tenth audit (ISSUES.md Part X) fixed in
  D70. Test clips (`.dev/test-media/SD`, interlaced and blocky ones) are
  made with ffmpeg, not by `tools/make-test-media.sh`.
- v0.8.1 (2026-11-03, D71): the Display HDR mapping tone-maps by the
  whole-film metadata (`libplacebo-opts=tone_map_metadata=hdr10`), so
  HDR10+ phone videos with bogus per-frame peaks don't flicker; checked
  on the owner's Deck OLED. *Display, per scene* still drops frames
  there with such files (not changed).
- v0.8.2 (2026-11-05, D72, D73): subtitle settings remembered per movie or
  season (`dvp/submemory.lua`, `subtitle-settings.json`): track matched by
  language and flags, not id; delay per video. Picture and HDR choices
  likewise (`dvp/videomemory.lua`, `video-settings.json`), on a store shared
  with subtitles (`dvp/memory.lua`). `[playback] remember_settings` turns
  all of it off, Looks and Decoding included. Tested in headless gamescope
  with local files and mock DLNA; subtitles also with mock OpenSubtitles
  and the owner's Jellyfin test server (read-only). The same checks passed
  in the Flatpak build for local files, and the owner tried the test build
  before release. Test clips in
  `.dev/test-media/SubMemory` are made with ffmpeg, not by
  `tools/make-test-media.sh`.
- v0.8.3 (2026-11-14, D74): Freedesktop 26.08 runtime, module versions
  unchanged. Regression-tested in headless gamescope on an isolated Flatpak
  install (upgrade from 0.8.2 through the installer included); the owner
  tried the test build before release.
- v0.8.4 (2026-11-14): *TV speakers* in the audio menu
  (`dvp/tvmix.lua`, D75), exclusive with headphone surround; tested in
  headless gamescope (`TVMIX=1`) and the Flatpak, and the owner tried the
  test build before release (TV listening: checklist 17). DLNA videos
  on another LAN address of the server accepted, skipped ones explained (D76;
  tested against a real minidlna 1.3.3 run from the Ubuntu package, not
  committed). Flatpak crash at quit fixed in the launcher (D77: own
  fontconfig setup without the host's mapped font caches). Eleventh audit
  (ISSUES.md Part XI) reviewed in D78.
- v0.8.5 (2026-11-15): CRT look strengths (*CRT, light lines* / *CRT* /
  *CRT, strong lines*, spread apart after the owner's test), beam widths
  and gap depth the same on every screen, mask sized by the screen (2 px
  stripes at 4K), scanlines follow the lines shown in every picture mode
  and aspect ratio (D79, D80). Measured in headless gamescope at several
  sizes and in the Flatpak; the owner tried the test builds before
  release. Twelfth audit (ISSUES.md Part XII) reviewed in D80.
- v0.9.0 (2026-11-19): online videos (D84,
  `dvp/online.lua`): `.m3u` lists of links in library folders, YouTube
  playlists and channels as folders, played through mpv's yt-dlp hook
  confined to the app's `ytdl://` addresses, QuickJS-NG for YouTube,
  downloads (yt-dlp + the bundled `ffmpeg`), an optional cookies file
  (YouTube asks the owner's connection to sign in). Tested in headless
  gamescope and the Flatpak with `tools/mock-online.py` (offline, the
  yt-dlp path through its generic extractor) and real YouTube for titles,
  playlists and channels. Thirteenth audit (ISSUES.md Part XIII) fixed
  in D85, which also fixed maps saved empty in JSON stores losing later
  keys (`util.plain_table`; resume.json since v0.1). The owner tried the
  test builds before release. mpv 0.42 moved out of v0.9.0: it waits
  for 0.42.1, as a release of its own.
- v0.9.1 (2026-11-20, D86): YouTube HDR videos with several audio
  languages lost HDR (streams with sound won the `lang` sort); the format
  choice takes a video-only stream first. The owner tried the test build
  on a Deck.
- v0.9.2 (2026-11-21, D88, D89): quality of online videos:
  `[online] stream_quality`, and *Quality* in the Video menu remembered
  per list (`video-settings.json`), applied by reopening the video where
  it was. Above 1080p on a Deck AV1 is still left out first (a 1440p AV1
  test on a Deck is for later). CI actions on Node.js 24 (D87). The owner
  tried the test build on a Deck.
- v0.9.3 (2026-11-22, D90): one L2 / R2 pull is one press (mpv's analog
  trigger keys have no hysteresis): the trigger keys have complex
  bindings, debounced by `input.trigger_pull`. The owner confirmed the
  test build on a Deck.
- v0.9.4 (2026-11-23): YouTube playlists' listings kept in memory for
  30 minutes (D91, `Online.listings`, wall clock because mpv's stops
  while the Deck sleeps; *Reload library* forgets them). Fourteenth
  audit (ISSUES.md Part XIV) fixed in D92: every format choice ends in
  `/bv` (videos with no audio stream), no *Quality* row while a video
  opens. The owner tried the test builds on a Deck.
- v0.9.5 (2026-11-24): yt-dlp 2026.11.23, the first release through the
  update pull request (`gh workflow run update-yt-dlp.yml` starts it by
  hand; the PR's own `pull_request` build waits for approval, the
  workflow's dispatched build is the one to check). Its CI bundle played
  real YouTube in headless gamescope before merging.
- Planned: see `docs/ROADMAP.md`. Next, in order: rename library sources
  (the UI's first text field), in-app SMB (libsmb2 helper), NFS,
  copies from network shares, next episode from *Continue watching*.
  mpv 0.42 once 0.42.1 exists. v0.10.0: the app's own signed
  Flatpak repository on GitHub Pages, updated by CI on each tag (D81).
  Flathub and FlatPark not planned.
- Network code must stay asynchronous (`dvp/http.lua`) and only run on
  user request; secrets go on curl's stdin, never in argv. The only
  blocking calls are short ones inside mpv hooks, where playback waits
  anyway (Plex metadata/transient token in on_load, final progress report
  in on_unload).
