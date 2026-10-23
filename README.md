# Deck Video Player

A lightweight, controller-driven video player for the **Steam Deck** and
**SteamOS game mode** (and DIY Steam Machines). It is a thin front end for
[mpv](https://mpv.io): the whole interface (library browser, playback
controls, menus) is drawn by Lua scripts on mpv's own on-screen display, so
there is a single process and nothing between the video and the screen.

- Plays essentially every format (FFmpeg), with **hardware decoding** through
  VA-API on the Deck's AMD APU (H.264, HEVC 8/10-bit, VP9, AV1).
- **Real HDR** in game mode: HDR10/HLG videos go to gamescope as HDR10
  (`VK_COLOR_SPACE_HDR10_ST2084_EXT`) with their metadata; SDR stays SDR.
- **Refresh-rate matching** on the Steam Deck: 24 fps films switch the panel
  to 48 Hz (or 72 Hz), 25 fps to 50 Hz, 30/60 fps to 60/90 Hz, then back.
- Full **controller** control, with a UI designed for 1280×800 that scales
  to 4K TVs.
- Audio / subtitle track selection, subtitle size/position/delay, audio
  delay, zoom modes, playback info panel.
- **Resume playback** per file, watched markers, auto-play next video in the
  folder.

## Documentation

| Document | Contents |
|---|---|
| [docs/INSTALL.md](docs/INSTALL.md) | Installation, Steam settings, usage, troubleshooting |
| [docs/CONFIGURATION.md](docs/CONFIGURATION.md) | Every `config.ini` setting |
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | How it works: process model, UI, HDR, refresh rate, battery |
| [docs/DECISIONS.md](docs/DECISIONS.md) | Decision log with alternatives and reasons |
| [docs/CODE_REFERENCE.md](docs/CODE_REFERENCE.md) | Every source file and module API |
| [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) | Dev setup, unit/headless/Flatpak/on-device testing, building, releasing, recipes |
| [AGENTS.md](AGENTS.md) | Quick orientation for AI agents and new contributors |

## Install on SteamOS

1. Switch to **Desktop Mode**, download the release archive
   (`DeckVideoPlayer-vX.Y.Z.tar.gz`) and extract it.
2. Open Konsole in the extracted folder and run:

   ```sh
   ./scripts/install-steamos.sh
   ```

   This installs everything per-user (nothing on SteamOS's read-only system
   partition, so it survives updates):
   - the app Flatpak (and the Freedesktop runtime from Flathub),
   - the gamescope Vulkan layer extension needed for HDR,
   - `~/.config/deckvideoplayer/config.ini`,
   - a **Non-Steam game** shortcut with library artwork.

3. Edit `~/.config/deckvideoplayer/config.ini` and set your video folders
   (`folder = ...`, one line per folder). The microSD card and USB drives
   are listed automatically.
4. Return to **Gaming Mode** and start *Deck Video Player* from the library.

For HDR enable *Settings → Display → HDR* (Steam Deck OLED or HDR TV). On an
external 4K screen set the shortcut's *Properties → Game Resolution* to
**Native**, otherwise gamescope renders the app at 1280×800 and upscales it.

Uninstall with `./scripts/install-steamos.sh --uninstall`.

## Controls

| Button | Library | Playback |
| --- | --- | --- |
| **A** | Open folder / play | Play / pause |
| **B** | Back (quit at top level) | Stop, back to library |
| **X** | Play from the beginning | Subtitles menu |
| **Y** | Sort by name / date | Audio menu |
| **D-pad ↑ ↓** | Move | Volume |
| **D-pad ← →** | Page | Seek ±10 s |
| **L1 / R1** | Page | Seek ±60 s |
| **L2 / R2** | First / last item | Previous / next chapter |
| **View** | — | Playback info (decoder, HDR, refresh) |
| **Menu** | Library menu | Playback menu (tracks, subtitle size and delay, audio delay, speed, zoom…) |

A keyboard also works (arrows, Enter, Esc/Backspace, `x`, `y`, `m`, `i`,
PgUp/PgDn, Home/End).

## Configuration

`~/.config/deckvideoplayer/config.ini` is commented and covers library
folders, preferred audio/subtitle languages, subtitle behaviour, resume,
seek steps, audio passthrough (for AV receivers), hardware decoding, device
profile, rendering quality, HDR, refresh-rate matching and UI scale.

Advanced mpv options can be added to `~/.config/deckvideoplayer/mpv.conf`
(loaded after the app's own settings).

## How it works

```
Steam (game mode) ─ launches ─▶ flatpak run … deckvideoplayer (launcher script)
                                    │
                                    ▼
                              mpv --idle --force-window --config-dir=/app/share/deckvideoplayer/mpv
                                 │  vo=gpu-next, Vulkan, hwdec=vaapi
                                 │  target-colorspace-hint=yes
                                 │
                                 ├─ scripts/deckplayer/  (Lua UI: browser, player overlay, menus,
                                 │                        resume, refresh-rate matching)
                                 ▼
                     gamescope WSI layer ─▶ gamescope ─▶ panel / TV (SDR, HDR10, VRR)
```

- **Why mpv draws everything:** gamescope gives HDR only to apps that
  present through Vulkan with an HDR colorspace. Embedding mpv in a toolkit
  (libmpv's render API) is limited to OpenGL, which loses HDR passthrough.
  Letting mpv own the window and drawing the UI as OSD keeps HDR, zero-copy
  hardware decoding and the lowest possible overhead. No timers run while
  the overlay is hidden.
- **HDR:** under gamescope the launcher selects `--gpu-context=x11vk`; the
  gamescope WSI layer (Flatpak extension
  `org.freedesktop.Platform.VulkanLayer.gamescope`) exposes HDR10 swapchain
  formats and mpv switches to them for HDR content.
- **Refresh-rate matching:** sets the `GAMESCOPE_DYNAMIC_REFRESH` root window
  property (what Steam's per-game refresh slider uses), choosing from the
  panel's valid rates (Deck OLED: 45–90 Hz in gamescope's list, LCD:
  40–60 Hz), and restores the previous value afterwards. VRR displays don't
  need it: gamescope follows mpv's frame pacing.
- **Battery:** VA-API decoding with dmabuf import into Vulkan (no copies),
  `video-sync=audio` without interpolation, the "balanced" rendering profile
  on the Deck (cheap downscaling, no HDR peak detection). `quality = battery`
  goes further; Steam Machines default to mpv's `high-quality` profile.
- **Why a custom Flatpak:** Flathub's mpv is built without SDL2 gamepad
  support, which the controller input relies on. The manifest builds mpv
  0.41 (LuaJIT, SDL2 gamepad, Vulkan, VA-API), libplacebo and a decode-only
  FFmpeg on the Freedesktop 25.08 runtime.

## Project layout

```
app/bin/deckvideoplayer                 launcher (Flatpak and source tree)
app/share/deckvideoplayer/config.ini    default user config
app/share/deckvideoplayer/mpv/mpv.conf  mpv settings + quality profiles
app/share/deckvideoplayer/mpv/scripts/deckplayer/
    main.lua        wiring: lifecycle, resume, input routing
    dvp/browser.lua library screen          dvp/player.lua  playback overlay, menus, info
    dvp/menu.lua    modal list menus        dvp/ui.lua      ASS drawing toolkit, button glyphs
    dvp/display.lua device, HDR, refresh    dvp/library.lua sources + directory listing
    dvp/resume.lua  resume/watched store    dvp/media.lua   track/codec/HDR descriptions
    dvp/config.lua  config.ini parser       dvp/input.lua   gamepad/keyboard → actions
packaging/flatpak/    Flatpak manifest, .desktop, metainfo
packaging/steam/      Steam library artwork (SVG sources + PNG)
scripts/              build, SteamOS installer, Steam shortcut helper, dev runner
tools/                test tooling: test media, headless gamescope runner, IPC driver
tests/                Lua unit tests (run inside mpv)
docs/                 full documentation
```

## Development

```sh
tests/run.sh                                  # unit tests (needs mpv)
tools/make-test-media.sh                      # synthetic test library in .dev/
scripts/dev-run.sh --window --media .dev/test-media/Videos   # run with the system mpv
tools/headless-run.sh -- gshot:/tmp/lib.png   # headless gamescope run + screenshot
scripts/build-flatpak.sh --install            # build + install the Flatpak
```

See [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) for the full testing
procedures, including HDR and refresh-rate verification without a Deck.

## Roadmap

- Network shares (SMB/NFS browsing) and Plex/Jellyfin sources: `library.lua`
  is structured around "sources" so these can be added as new kinds.
- Thumbnails / posters in the browser.
- Touchscreen support.

## Known limitations / to verify on hardware

- Developed and tested in nested/headless gamescope on a desktop, including
  the HDR10 swapchain switch and the refresh-rate property; final validation
  on a Steam Deck OLED is still needed.
- Steam may re-apply its own per-game refresh setting when you change it in
  the Quick Access Menu; the app sets its rate again on the next video.
- Whether the Deck dims the screen during long videos in game mode
  (gamescope has no idle-inhibit protocol) still needs checking.

## License

GPL-2.0-or-later (same as mpv). The bundled Inter font is under the SIL Open
Font License.
