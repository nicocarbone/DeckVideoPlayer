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
