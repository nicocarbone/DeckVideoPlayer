# Code Audit: Findings & Optimization Opportunities

---

# Part VII — v0.4.1 Audit: HDR Overhaul, Video Info Panel & Plex Recently Played / Continue Watching (2026-10-26)

All 325 Lua checks and 10 Python unit tests in `tests/run.sh` pass, and the v0.4.1 HDR option mappings (`dvp/hdr.lua`, `mpv/mpv.conf`, `dvp/player.lua`) were verified in headless gamescope (`HDR=1` and `HDR=0`) against `mpv 0.41.0` (`vo=gpu-next`, `libplacebo v7.360.0`):
* **`hdr_mapping = static | dynamic | app`:** The mpv/libplacebo options in `Hdr.options` are correct. `static` passes PQ frames untouched with whole-film `VkHdrMetadataEXT` (`target-colorspace-hint=yes`, `target-colorspace-hint-mode=target`); `dynamic` sets `target-colorspace-hint-mode=source-dynamic` to forward per-frame Dolby Vision RPU / HDR10+ dynamic metadata into `VkHdrMetadataEXT`; `app` sets `target-peak=<peak>` and `hdr-compute-peak=yes` so libplacebo tone-maps peaks above `<peak>` nits and signals `max-luma = <peak>` / `max-cll = <peak>` on the swapchain.
* **`sdr_to_hdr = 300 | 400 | 600 | 1000`:** Setting `inverse-tone-mapping=yes`, `target-trc=pq`, `target-prim=bt.2020`, and `target-peak=<itm>` correctly switches the Gamescope WSI swapchain to `VK_COLOR_SPACE_HDR10_ST2084_EXT` on HDR displays and expands SDR diffuse white (`203 nits`) up to `<itm>` nits PQ, while `--target-colorspace-hint-strict=yes` prevents `pq` on an SDR swapchain so `Hdr:check()` can detect non-HDR displays.
* **`hdr = off`:** Setting `target-colorspace-hint=no` keeps the swapchain in `VK_COLOR_SPACE_SRGB_NONLINEAR_KHR` and tone-maps HDR sources to SDR.

Below are the bugs and edge cases found in the HDR state machine/UI synchronization and the other v0.4.1 additions (`dvp/hdr.lua`, `dvp/player.lua`, `dvp/menu.lua`, `dvp/videoinfo.lua`, `dvp/browser.lua`, and `main.lua`).

---

## 1. HDR Overhaul Bugs & Edge Cases (v0.4.1)

### 1.1. `dvp/player.lua` & `main.lua`: Overlay HDR badge (`[HDR10]`, `[HDR10 → SDR]`, `[SDR → HDR]`) and Info panel do not update when toggling HDR options while paused (and lag behind when playing)
* **Location:** `app/share/deckvideoplayer/mpv/scripts/deckplayer/main.lua` (`Hdr.new` callback lines 134–137, `dispatch` lines 290–295) and `app/share/deckvideoplayer/mpv/scripts/deckplayer/dvp/player.lua` (`render` lines 622–627, `render_info` lines 770–790)
* **Problem (*verified in headless gamescope*):**
  1. When the user changes `HDR` (`On`/`Off`), `HDR mapping`, `Peak brightness`, or `SDR to HDR` in the Video menu, `dispatch()` calls `player:render()` synchronously in the same Lua tick right after `mp.set_property(...)`.
  2. However, `video-target-params` (`gamma`, `primaries`, `max-luma`) only updates **asynchronously** after mpv's VO thread renders a frame with the new swapchain/shader state.
  3. When the video is **paused** (where `player.timer` and `player.info_timer` are stopped to save battery, D45), nothing triggers `player:render()` or `player:render_info()` once `video-target-params` updates. For example, enabling `SDR to HDR = 300 nits` while paused switches the swapchain to `VK_COLOR_SPACE_HDR10_ST2084_EXT` (`video-target-params/gamma = "pq"`), but the top-left overlay badge stays `[360p] [HW]` without `[SDR → HDR]`; conversely, turning `HDR` to `Off` while paused leaves the `[HDR10]` badge instead of `[HDR10 → SDR]`.
  4. In `main.lua` (lines 134–137), the `Hdr.new` `notify` callback only calls `toast(text)` and `if menu:is_open() then menu:refresh() end`, omitting `player:render()` and `player:render_info()`.
* **Suggested Fix:**
  * Observe `video-target-params/gamma` and `video-target-params/max-luma` in `dvp/player.lua` (or in `main.lua`) to call `player:render()` and `player:render_info()` when the overlay or info panel is visible.
  * In `main.lua`'s `Hdr.new` callback, also update `player:render()` and `player:render_info()` when `state.screen == "player"`.

---

### 1.2. `dvp/hdr.lua`: Non-HDR display detection (`Hdr:check` / `Hdr.effective`) leaves `mapping == "dynamic"` active and fails to refresh an open Video menu when `mapping` is `"static"` or `"dynamic"`
* **Location:** `app/share/deckvideoplayer/mpv/scripts/deckplayer/dvp/hdr.lua` (`Hdr.effective` lines 57–66, `Hdr:check` lines 147–169)
* **Problems:**
  ```lua
  function M.effective(s)
      if not s.enabled or not s.gamma then return nil end
      if is_hdr(s.gamma) then
          if s.mapping == "app" and s.screen == false then return nil end
          if s.mapping == "static" then return nil end
          return {mapping = s.mapping}
      end
      if s.itm > 0 and s.screen ~= false then return {itm = s.itm} end
      return nil
  end
  ```
  1. **`mapping == "dynamic"` is not guarded by `s.screen ~= false` in `Hdr.effective(s)`:**
     When `s.screen == false` (an SDR display or SteamOS with HDR disabled), mpv tone-maps HDR videos to SDR (`HDR10 → SDR (tone-mapped)`), and `hdr:show_menu()` hides the HDR settings behind `HDR: Screen not in HDR mode`. However, if `s.mapping == "dynamic"` (via `config.ini` or selected before `check()` ran), `Hdr.effective(s)` still returns `{mapping = "dynamic"}`. In `player:render_info()` (`dvp/player.lua` line 778), this appends `DESCRIPTIONS.dynamic` to the SDR tone-mapped line, displaying the contradictory string:
     **`HDR: HDR10 → SDR (tone-mapped) · Display maps, per-scene metadata`**.
  2. **Open Video menu is not refreshed when `self.screen` becomes `false` under `mapping == "static"` or `"dynamic"`:**
     In `Hdr:check()` (lines 161–168), `self.notify(...)` (which triggers `menu:refresh()`) is only called when `before and (before.itm or before.mapping == "app")`. If the user starts an HDR video on an SDR screen (with default `mapping == "static"`) and opens the **Video** menu within the first 1.5 s, `self.screen` transitions from `nil` to `false` without refreshing the open Video menu—leaving interactive `HDR` and `HDR mapping` rows on screen that only disappear (jumping the cursor) if the user tries to adjust one.
* **Suggested Fix:**
  * In `Hdr.effective(s)`, return `nil` whenever `s.screen == false` (`if not s.enabled or not s.gamma or s.screen == false then return nil end`).
  * In `Hdr:check()`, refresh the open Video menu whenever `self.screen` transitions to `false` (even if no toast is needed because `before` was `nil`).

---

### 1.3. `dvp/hdr.lua`: `self.screen` (`true` / `false`) is cached for the entire process lifetime and never re-evaluated on dock/undock or SteamOS HDR toggle
* **Location:** `app/share/deckvideoplayer/mpv/scripts/deckplayer/dvp/hdr.lua` (`Hdr.new` line 117, `Hdr:apply` line 140, `Hdr:check` lines 157–162)
* **Problem:**
  Once `Hdr:check()` sets `self.screen = true` or `self.screen = false`, `if self.screen == nil and M.expects_hdr(self)` never runs again for the rest of the app session:
  1. If a user starts a video while HDR is turned off in Steam's Quick Access Menu (`•••`) or while docked to an SDR display (`self.screen = false`), and then turns HDR on in `•••` or undocks the Steam Deck OLED, the Video menu remains stuck at `HDR: Screen not in HDR mode` and refuses to enable `SDR to HDR` or `App` tone mapping until the app is restarted.
  2. Conversely, if a user starts a video on the Steam Deck OLED (`self.screen = true`) with `SDR to HDR` or `App` mapping enabled and then docks to an SDR display (or turns HDR off in `•••`), `Hdr:check()` never runs again, leaving `inverse-tone-mapping=yes, target-trc=pq` or `target-peak=1000` active on the SDR display (dimming and washing out the picture).
* **Suggested Fix:**
  Reset `self.screen = nil` when `video-params/gamma` changes for a new file (and/or when `osd-dimensions` changes on dock/undock) so `Hdr:check()` re-verifies the output once per file/display change without adding any idle timers.

---

## 2. Video Info Panel, Menu & Plex Recently Played Bugs (v0.4.1)

### 2.1. `dvp/menu.lua` & `dvp/videoinfo.lua`: Section headers (`header = true`) are treated as selectable rows in `Menu`
* **Location:** `app/share/deckvideoplayer/mpv/scripts/deckplayer/dvp/menu.lua` (`selectable` lines 48–50, `render` lines 244–247) and `app/share/deckvideoplayer/mpv/scripts/deckplayer/dvp/videoinfo.lua` (`VideoInfo.open` lines 345–348)
* **Problems:**
  1. In `dvp/menu.lua`, `local function selectable(item) return item and not item.disabled and not item.separator end` does not exclude `item.header`.
  2. However, `Menu:render()` (line 244) renders `item.header` rows without a selection highlight box. When navigating through **Video info** (or **Controls**) with `Up`/`Down` or `L1`/`R1` to scroll or marquee-scroll long values, the cursor lands on the uppercase section header rows (`FILE`, `VIDEO`, `AUDIO`, `SUBTITLES`), causing the blue selection highlight to disappear for one press at every section boundary.
  3. In `VideoInfo.open` (lines 345–348), because `items[1]` (`{label = "File", header = true}`) is treated as selectable, `ctx.menu:update(spec, {items = items})` selects row 1 and renders the menu once, and then lines 346–347 manually set `spec.selected = 2` and call `ctx.menu:render()` a second time.
* **Suggested Fix:**
  Change `selectable(item)` in `dvp/menu.lua` to:
  ```lua
  local function selectable(item)
      return item and not item.disabled and not item.separator and not item.header
  end
  ```
  and remove the manual `spec.selected = 2; ctx.menu:render()` workaround in `VideoInfo.open`.

---

### 2.2. `dvp/videoinfo.lua`: `VideoInfo.from_plex` does not normalize `colorPrimaries` / `colorTrc` case
* **Location:** `app/share/deckvideoplayer/mpv/scripts/deckplayer/dvp/videoinfo.lua` (`hdr_label` lines 53–64, `PRIMARIES` lines 66–67, `from_plex` lines 273–281)
* **Problem:**
  `from_plex` passes `primaries = s.colorPrimaries` and `transfer = s.colorTrc` verbatim into `PRIMARIES[v.primaries or ""]` and `M.hdr_label(v)`. If a Plex server reports uppercase/mixed-case strings (e.g. `"BT709"` or `"SMPTE2084"`), `PRIMARIES` returns `nil` and `hdr_label` falls back to `"SDR"`. Normalizing `s.colorPrimaries` and `s.colorTrc` with `:lower()` makes Plex metadata handling resilient.

---

### 2.3. `dvp/browser.lua`: Opening a Plex item from *Recently played* (`open_plex_recent`) has no loading feedback, does not guard `open_file` on local entries while in flight, and leaves stale `resume.json` progress if the Resume prompt is canceled
* **Location:** `app/share/deckvideoplayer/mpv/scripts/deckplayer/dvp/browser.lua` (`open_file` lines 316–321, `open_plex_recent` lines 325–339, `start` lines 341–363)
* **Problems:**
  1. **No visual feedback during `plex:resolve` (up to 4–10 s on first connect):** When pressing **A** or **X** on a Plex item in *Recently played* right after launching the app, `plex:resolve` has to probe/connect to the Plex server, fetch `/library/metadata/<id>`, and (for TV episodes) fetch `/library/metadata/<parent>/children` before anything happens on screen. During those seconds, no toast or loading indicator is shown.
  2. **`self.opening` only guards `open_plex_recent`, not `open_file`:** If the user presses **A** on a Plex recent entry, sees nothing happen while `resolve` is connecting, moves the cursor to a local file with a resume position, opens `"Resume playback?"`, and presses **B** to cancel just before `resolve` finishes, `resolve`'s callback sees `self.active and not self:location() and not self.ctx.menu:is_open()` and unexpectedly opens the Plex video's resume prompt or starts playback.
  3. **Stale progress bar on the Start screen if the video was watched/updated on another device:** `open_plex_recent` fetches `fresh` (`fresh.state`) from the Plex server, but does not sync `fresh.state` back into `self.ctx.resume` (`resume.json`). If the user watched the video further (or finished it) on another device and cancels the `"Resume playback?"` prompt with **B**, the Start screen row continues showing the old progress bar from `resume.json`.
* **Suggested Fix:**
  * Check `if self.opening then return end` at the top of `Browser:open_file`, and cancel/ignore the in-flight `open_plex_recent` if the user moves or interacts with another entry (or show a `"Loading…"` toast/state while `self.opening` is true).
  * When `fresh` arrives in `open_plex_recent`, update the local `resume.json` entry (`plex://<machine>/library/metadata/<id>`) with `fresh.state` (`pos` / `watched` / `duration`) while preserving its `played` timestamp, and call `self:render()`.

---

## 3. v0.4.1 (Part VII) Summary Checklist

Reviewed and fixed on 2026-10-26 (DECISIONS D53).

- [x] **HDR (`dvp/player.lua`):** Redraw badges / info panel when `video-target-params/gamma` changes (also while paused).
- [x] **HDR (`dvp/hdr.lua`, `main.lua`):** No choice is effective on a screen not in HDR mode; an open Video menu is rebuilt whenever the screen is found to be SDR.
- [x] **HDR (`dvp/hdr.lua`):** A known HDR screen is checked again with each file; a known SDR screen is promoted when mpv outputs HDR. *(Not re-checked every file: that would flash every SDR file on an SDR TV with SDR to HDR set. A change in the middle of a file takes the next file.)*
- [x] **Menu (`dvp/menu.lua`, `dvp/videoinfo.lua`):** Section headers are not selectable; scrolling up shows a section's header; Video info workaround removed. *(The highlight didn't disappear on headers; the cursor stopped on them.)*
- [x] **Plex (`dvp/videoinfo.lua`):** Lowercase `colorPrimaries` / `colorTrc`.
- [x] **Plex (`dvp/browser.lua`, `dvp/resume.lua`):** "Opening from Plex…" toast; open only if the cursor is still on that row and nothing else opened; server progress synced into `resume.json` (`resume:sync`).

---

# Part VI — v0.4.0 Audit: Night Mode, Plex Intro/Credits Markers & HRTF Surround (2026-10-25)

All 252 Lua checks and 10 Python unit tests in `tests/run.sh` pass, and the diffuse-field equalized SOFA file matches the documented SHA-256 in `hrtf/README.md`. Below are the DSP/audio bugs, playback state bugs, race conditions, and edge cases identified in the v0.4.0 changes (`dvp/nightmode.lua`, `dvp/markers.lua`, `dvp/surround.lua`, `dvp/player.lua`, `dvp/plex.lua`, `main.lua`, `tools/equalize-hrtf.py`, and `helper/dvp-keep-awake.c`).

---

## 1. Audio DSP & Filter Chain Bugs (v0.4.0)

### 1.1. `dvp/nightmode.lua`: `acompressor` uses default `link=average` instead of `link=maximum`, breaking compression on 5.1 and 7.1 tracks
* **Location:** `app/share/deckvideoplayer/mpv/scripts/deckplayer/dvp/nightmode.lua` (`M.GRAPH`, lines 14–17)
* **Problem:**
  ```lua
  M.GRAPH = table.concat({
      "acompressor=threshold=0.0316:ratio=4:attack=10:release=300:knee=4:makeup=1.78",
      "alimiter=limit=0.891:attack=5:release=100:level=0",
  }, ",")
  ```
  `@dvp-night` is inserted with `af pre`, so it runs on the multi-channel stream (e.g. 6 channels for 5.1, 8 channels for 7.1) before `@dvp-surround` and before mpv's stereo downmix.
  FFmpeg's `acompressor` defaults to `link=average`, which computes the sidechain detector level as the **average across all channels** (`sum / nb_channels`) rather than the loudest channel (`link=maximum`).
  * In 5.1 (`6` channels) and 7.1 (`8` channels) soundtracks, sounds concentrated in 1 or 2 channels—such as centre-channel dialogue/shouts, stereo music inside a 5.1 container, or single-channel gunshots while surround/LFE channels are silent—have their detected level divided by `6` (`-15.6 dB`) or `8` (`-18.1 dB`).
  * This shifts the effective `-30 dBFS` compression threshold for a single-channel signal up to **`-14.4 dBFS` on 5.1** and **`-11.9 dBFS` on 7.1**.
  * **Measured with FFmpeg:** A loud `-6 dBFS` (`0.5`, `-9.03 dBFS` RMS) signal in the centre channel is compressed to **`-21.62 dBFS` RMS** (`-12.6 dB` reduction) on stereo, but on 5.1 its RMS remains **`-9.98 dBFS`** (with a `+4.3 dB` attack peak jump to `-1.71 dBFS`), and on 7.1 `makeup=1.78` makes it **louder than without Night Mode** (**`-8.12 dBFS` RMS**, `-1.21 dBFS` peak).
* **Suggested Fix:**
  Add `:link=maximum` to `acompressor`:
  ```lua
  M.GRAPH = table.concat({
      "acompressor=threshold=0.0316:ratio=4:attack=10:release=300:knee=4:makeup=1.78:link=maximum",
      "alimiter=limit=0.891:attack=5:release=100:level=0",
  }, ",")
  ```
  `link=maximum` still applies one shared gain reduction across all channels (preserving 5.1/7.1 spatial balance), while keying off the loudest channel so 5.1 and 7.1 compress identically to stereo (`-21.62 dBFS` RMS).

---

### 1.2. `dvp/surround.lua`: Boosting `sofalizer` `gain` to `12.5` / `18.5` dB without a limiter causes `+8..+10 dBFS` clipping and FFmpeg log spam on loud multi-channel scenes
* **Location:** `app/share/deckvideoplayer/mpv/scripts/deckplayer/dvp/surround.lua` (`GAIN_51`, `LFE_GAIN`, `gain`, `filter_string`, lines 16–43)
* **Problem:**
  ```lua
  function M.filter_string(sofa_path, channels)
      local g = string.format("sofalizer=sofa=%s:gain=%s:lfegain=%s:type=freq",
          M.escape_lavfi(sofa_path), tostring(M.gain(channels)), tostring(M.LFE_GAIN))
      return string.format("@dvp-surround:lavfi=graph=%%%d%%%s", #g, g)
  end
  ```
  Setting `gain=12.5` (5.1) / `gain=18.5` (7.1) and `lfegain=3` inside `sofalizer` matches single-channel (centre dialogue) loudness to mpv's stereo downmix by undoing `sofalizer`'s internal `-3 * N` dB headroom.
  However, when a 5.1 or 7.1 soundtrack has a loud multi-channel scene (an explosion or orchestral crescendo with `-6` to `-2 dBFS` across multiple channels simultaneously), the convolved stereo sum reaches **`+8` to `+10 dBFS` (`2.5x–3.1x` full scale)**:
  1. When Night Mode is off, samples above `0 dBFS` are sent un-limited to the audio output and hard-clip at `0 dBFS` when volume is near 100%.
  2. Inside `sofalizer`, FFmpeg checks `fabs(out[i]) > 1.0` after applying `gain` and logs an `AV_LOG_WARNING` (`[ffmpeg/audio] sofalizer: N of 2048 samples clipped. Please reduce gain.`) on **every 2048-sample FFT block (~21 times per second)** during loud scenes.
* **Suggested Fix:**
  Keep `sofalizer`'s internal `gain=0` (so convolution inside `sofalizer` stays below `1.0` and never triggers its per-frame clip warning), and apply the dialogue-matching gain + a protective limiter immediately after `sofalizer` in the same `@dvp-surround` lavfi graph:
  ```lua
  local g = string.format(
      "sofalizer=sofa=%s:gain=0:lfegain=%s:type=freq,volume=%sdB,alimiter=limit=0.95:attack=5:release=50:level=0",
      M.escape_lavfi(sofa_path), tostring(M.LFE_GAIN), tostring(M.gain(channels)))
  ```
  Dialogue level at `-20 dBFS` is identical to `0.001 dB`, multi-channel explosions are cleanly soft-limited below `0 dBFS`, and `sofalizer` emits zero clip warnings.

---

### 1.3. `dvp/nightmode.lua`: Enabling `night_mode = yes` in `config.ini` calls `af pre` while mpv is idle, bypassing filter validation and muting audio if unavailable
* **Location:** `app/share/deckvideoplayer/mpv/scripts/deckplayer/dvp/nightmode.lua` (`M.new`, `M:set`, lines 25–56)
* **Problem:**
  ```lua
  function M.new(cfg)
      ...
      if pb.night_mode and self.available then self:set(true) end
      return self
  end
  ```
  `NightMode.new(cfg)` runs at script startup while mpv is **idle** (no audio stream open). While mpv is idle, `mp.commandv("af", "pre", ...)` only appends the filter string to mpv's `af` option list without instantiating `lavfi`, so `ok` is **always `true`** even if `acompressor` or `alimiter` is missing from FFmpeg.
  Later, when a file is opened, mpv attempts to build the initial audio filter chain, fails (`[user_filter_wrapper] Creating filter 'lavfi' failed. Audio filter initialized failed! Audio: no audio`), and **disables audio completely** for the file while `NightMode` still thinks `self.available == true` and `self.active == true`.
  (By contrast, when `mp.commandv("af", "pre", ...)` is called while an audio track is already active—as `Surround:update()` does from its `audio-params/channel-count` observer—mpv validates the filter immediately, rolls back the failed `af pre` without dropping audio playback, and returns `nil, "error running command"`.)
* **Suggested Fix:**
  Follow the same pattern as `dvp/surround.lua`: set `self.enabled = pb.night_mode and self.available` in `M.new(cfg)`, and observe `audio-params/channel-count` (or `current-ao`) to insert `@dvp-night` once an audio stream is active.

---

## 2. Plex Intro / Credits Markers & Playback Lifecycle Bugs (v0.4.0)

### 2.1. `dvp/player.lua` & `main.lua`: Pressing `R2` on `"Next episode"` / `"Next video"` during final credits leaves the episode unwatched / in-progress when credits are longer than `END_MARGIN`
* **Location:** `app/share/deckvideoplayer/mpv/scripts/deckplayer/dvp/player.lua` (`skip_marker`, lines 194–205) and `app/share/deckvideoplayer/mpv/scripts/deckplayer/main.lua` (`save_progress`, lines 142–164)
* **Problem:**
  When `self.marker` is a final credits marker (`mk.kind == "credits" and mk.final`) and `has_next` is true, the prompt offers **`R2 Next episode`** (or **`R2 Next video`**). Pressing `R2` runs:
  ```lua
  if a.next then
      mp.commandv("playlist-next")
  ```
  `mp.commandv("playlist-next")` immediately unloads the current episode while `time-pos` is still at the start of the credits (`mk.start`).
  In `main.lua`, `on_unload` calls `save_progress(true)`:
  ```lua
  plex:report(item, "stopped", pos, duration, true)
  if duration and duration > 0 and Resume.is_finished(pos, duration) and pos / duration < 0.9 then
      plex:set_watched(item, true, nil, true)
  end
  ```
  `Resume.is_finished(pos, duration)` only returns `true` within `max(60s, 5% of duration)` of the end (`72 s` on a 24-minute anime/sitcom episode; `135 s` on a 45-minute drama episode).
  * Whenever end credits + post-credits/next-episode preview begin earlier than that margin (e.g. a standard 90 s anime ending + 30 s preview = `120 s` before EOF, or 3–5 minute drama credits = `180–300 s` before EOF where `pos / duration < 0.90`), `Resume.is_finished(pos, duration)` is **`false`**!
  * `save_progress(true)` reports `stopped` at `mk.start` and **does not scrobble the episode**, so the episode the user just finished via `R2 Next episode` stays in Plex's *Continue watching* as partially watched at the start of the credits.
* **Suggested Fix:**
  When the user skips final credits (`mk.kind == "credits" and mk.final`), record in `state` (or pass via a callback/flag before `playlist-next`) that the current file was completed via final-credits skip so `save_progress(true)` treats it as finished and marks/scrobbles it as watched on Plex (and in `resume.json`).

---

### 2.2. `dvp/input.lua` & `dvp/player.lua`: `R2` (`rt`) key-repeat and 1-second marker polling race with `skip_marker()`
* **Location:** `app/share/deckvideoplayer/mpv/scripts/deckplayer/dvp/input.lua` (`REPEATABLE`, lines 30–33) and `app/share/deckvideoplayer/mpv/scripts/deckplayer/dvp/player.lua` (`check_marker`, `skip_marker`, `handle`, lines 174–205, 307–309)
* **Problems:**
  1. **`R2` (`rt`) is marked `REPEATABLE = true`, causing a chapter jump (+5 min) if the trigger is held >200 ms:**
     In `dvp/input.lua`, `rt` is in `REPEATABLE`. On the Steam Deck, `R2` is a long-travel analog trigger. If the user holds `R2` for 200 ms (`input-ar-delay`) when pressing `R2 Skip intro`, the initial press calls `self:skip_marker()` and sets `self.marker = nil`; the first auto-repeat event 200 ms later enters `player:handle("rt")`, sees `self.marker == nil`, and runs `else self:chapter(1)`—jumping to the next chapter (or seeking **+5 minutes forward** if the file has no chapters) and replacing `"Skipped intro"` with `"Next chapter"`.
     (In `browser.lua`, `lt` and `rt` only jump to the first and last item in the list, which is idempotent and does not need `repeatable = true`.)
  2. **`marker_timer` flashes the `"R2 Skip intro"` / `"R2 Next episode"` badge back on screen while an HTTP seek or `playlist-next` is in flight:**
     `skip_marker()` sets `self.marker = nil` and clears `self.marker_layer`, then issues `mp.commandv("seek", tostring(a.target), "absolute+exact")` (or `mp.commandv("playlist-next")`), but leaves the 1-second `self.marker_timer` running.
     When streaming over HTTP/HTTPS from Plex, an exact seek or playlist transition takes >100 ms before `time-pos` updates and `playback-restart` fires. If `self.marker_timer` ticks during that window, `check_marker()` reads the pre-seek `time-pos` (still inside `[mk.start, mk.stop - 1)`), sees `mk ~= self.marker` (`nil`), and **re-renders the marker prompt on screen** (even after `skip_intro = "auto"` auto-skipped it, because `self.auto_skipped[mk]` is now `true`).
  3. **`self.marker` can be up to 1 second stale when `R2` is pressed:**
     Because `self.marker` is only polled every 1.0 s, pressing `R2` during the first second of a marker (before `marker_timer` ticks) sees `self.marker == nil` and jumps to the next chapter (+5 min) instead of skipping the marker; conversely, pressing `R2` up to 1 s after leaving a marker still triggers `skip_marker()`.
* **Suggested Fix:**
  1. Remove `lt` and `rt` from `REPEATABLE` in `dvp/input.lua`.
  2. In `player:skip_marker()`, call `self.marker_timer:kill()`, and in the `playback-restart` handler (`player.lua` line 50), call `self:update_marker_timer(); self:check_marker()`.
  3. In `player:handle("rt")`, refresh `self.marker` against the live `time-pos` before branching (`self:check_marker(); if self.marker then ...`).

---

### 2.3. `main.lua` & `dvp/player.lua`: Previous file's markers are not cleared at the start of `on_load`, `skip_intro = "auto"` conflicts with `resumed_at` / `0:00` load, and `osd-dimensions` omits `render_marker()`
* **Location:** `app/share/deckvideoplayer/mpv/scripts/deckplayer/main.lua` (lines 286–315, 358–369, 423–427) and `app/share/deckvideoplayer/mpv/scripts/deckplayer/dvp/player.lua` (lines 73–79, 208–225)
* **Problems:**
  1. **Markers not cleared at the top of `on_load`:**
     In `main.lua`, `player:set_markers(prep.markers)` is only called inside `if item then` *after* the blocking `plex:prepare(item)` call returns (and in `player:stop_screen()` when entering `idle-active`).
     * During a playlist transition between two Plex episodes, `plex:prepare(item)` blocks for up to 5 s while the previous episode's `self.markers` and `marker_layer` stay on screen.
     * If a non-Plex file is loaded without passing through `idle-active` (e.g. external/IPC `loadfile`), `player:set_markers({})` is never called, leaving the previous Plex item's markers active on the local file.
  2. **`skip_intro = "auto"` toast is immediately overwritten by `"Resumed at …"`, and intros at `0:00` cause a double HTTP seek:**
     * In `main.lua` (`file-loaded`, lines 363–368), `player:on_file_loaded()` runs *before* `if state.resumed_at then toast("Resumed at ...") end`. If a file resumes at a position inside an intro with `skip_intro == "auto"`, `on_file_loaded()` -> `check_marker()` auto-skips to `mk.stop` and shows `"Skipped intro"`, which is immediately overwritten on the next line by `"Resumed at <old_pos>"`.
     * When `skip_intro == "auto"` and an episode's intro starts at `0:00` (`mk.start == 0`), `on_load` already has `prep.markers` and `start`, yet lets mpv open and buffer the HTTP stream at `0:00` only for `file-loaded` to immediately issue a second HTTP range seek to `mk.stop`.
  3. **`osd-dimensions` observer does not re-render `marker_layer`:**
     In `main.lua` (lines 423–427), the `osd-dimensions` observer calls `player:render()`, `player:render_info()`, and `menu:render()`, but neither it nor `player:render()` calls `player:render_marker()`. If the canvas size changes while a marker pill is visible (especially when `overlay_visible` is `false`, where `player:render()` returns on line 594), `marker_layer` remains at the old coordinates/resolution.
* **Suggested Fix:**
  * Call `player:set_markers({})` near the top of `on_load` (alongside `state.plex_subs = nil`).
  * In `main.lua`'s `osd-dimensions` observer, also call `player:render_marker()`.
  * In `file-loaded`, either check `state.resumed_at` before `player:on_file_loaded()` or clear `state.resumed_at` when `check_marker()` auto-skips (or apply `skip_intro == "auto"` directly to `start` in `on_load` when `start` falls inside an intro marker).

---

## 3. Native Helper Robustness (v0.4.0)

### 3.1. `helper/dvp-keep-awake.c`: `request_inhibit` ignores `stop` (`SIGTERM`) between blocking D-Bus calls and recreates `status_file` after `keepawake:stop()` deletes it
* **Location:** `helper/dvp-keep-awake.c` (`write_status`, `request_inhibit`, lines 31–41, 77–127) and `app/share/deckvideoplayer/mpv/scripts/deckplayer/dvp/keepawake.lua` (`stop`, lines 65–72)
* **Problem:**
  In `helper/dvp-keep-awake.c`, `request_inhibit(bus)` runs two sequential synchronous D-Bus calls (`org.freedesktop.ScreenSaver.Inhibit` and `org.freedesktop.portal.Inhibit.Inhibit`, each with a 5 s timeout) and calls `write_status()` after each one, before `main()` enters `while (!stop && getppid() == parent)`.
  If playback is paused or stopped while `request_inhibit(bus)` is in progress:
  1. `keepawake:stop()` sends `SIGTERM` to the helper (`stop = 1`) and immediately calls `os.remove(self.status_file)`.
  2. Because `write_status()` and `request_inhibit()` do not check `stop`, as soon as the in-flight `sd_bus_call_method` returns, the dying helper calls `write_status()`—recreating `self.status_file` on disk after `keepawake:stop()` deleted it—and even starts the second 5-second `sd_bus_call_method` before reaching the main loop and exiting.
  3. If the user pauses and quickly unpauses within that window, the new `dvp-keep-awake` instance and the dying instance share the same `status_file` / `status_file.tmp` path and race on `write_status()`.
* **Suggested Fix:**
  Guard `write_status()` and the second D-Bus call in `request_inhibit()` with `if (stop || getppid() != parent) return;`.

---

## 4. v0.4.0 (Part VI) Summary Checklist

Reviewed and fixed on 2026-10-25 (DECISIONS D49).

- [x] **DSP (`dvp/nightmode.lua`):** `link=maximum` on `acompressor`. *(Measured: loud centre-only 5.1 was 4 dB louder with night mode; now −6.4 dB like stereo.)*
- [x] **DSP (`dvp/surround.lua`):** `sofalizer` at gain 0, then `volume` and `alimiter` at −1 dBFS. *(Confirmed with a smaller margin than reported: +2.7 dBFS peaks and 135 warnings in 10 s with all channels near full scale; now −1.0 dBFS, no warnings, same dialogue loudness.)*
- [x] **DSP (`dvp/nightmode.lua`):** Add the filter once audio is open, not while idle.
- [x] **Bug (`dvp/player.lua`, `main.lua`):** *R2 Next episode* counts the episode as finished (`ctx.finished()`).
- [x] **Bug (`dvp/input.lua`, `dvp/player.lua`):** No auto-repeat on the triggers; R2 checks the marker at the current position; marker timer stopped during a skip, restarted on `playback-restart`. *(The prompt flashing during an exact seek doesn't happen: mpv reports the seek target as `time-pos` while seeking.)*
- [x] **Bug (`main.lua`):** Clear markers at the start of `on_load`, redraw the marker prompt on resize, show "Resumed at" before the automatic intro skip. *(Declined: skipping an intro at 0:00 in `on_load`; the extra seek happens before the first frame.)*
- [x] **Helper (`helper/dvp-keep-awake.c`):** No status write and no portal call after SIGTERM or when orphaned.

---

# Part V — v0.3.5 Full Audit: Security, Bugs & Optimizations (2026-10-25)

All 229 Lua checks and 9 Python tests in `tests/run.sh` pass. Below are the security/robustness issues, functional bugs, optimization opportunities, and polish items identified across the v0.3.1–v0.3.5 additions (`helper/dvp-keep-awake.c`, `dvp/keepawake.lua`, `dvp/cropdetect.lua`, `dvp/browser.lua`, `dvp/player.lua`, `dvp/resume.lua`, `scripts/steam_shortcut.py`, `scripts/install-steamos.sh`) as well as the existing Plex and core modules.

---

## 1. Security, Privacy & Native Helper Vulnerabilities (v0.3.5)

### 1.1. `helper/dvp-keep-awake.c`: 100% CPU busy-loop on D-Bus disconnect, `SIGTERM` race, and `PR_SET_PDEATHSIG` thread semantics
* **Location:** `helper/dvp-keep-awake.c` (`request_inhibit` lines 81–86, `main` lines 124–144)
* **Problems:**
  ```c
  prctl(PR_SET_PDEATHSIG, SIGTERM);
  if (getppid() == 1) return 0;
  signal(SIGTERM, on_signal);
  signal(SIGINT, on_signal);
  ...
  while (!stop) {
      while (sd_bus_process(bus, NULL) > 0) {}
      sd_bus_wait(bus, UINT64_MAX);   /* a signal interrupts it */
  }
  ```
  1. **100% CPU infinite loop if the D-Bus connection drops or errors:**
     `sd_bus_process(bus, NULL)` returns `< 0` on error or bus disconnect (e.g. `-ENOTCONN` / `-ECONNRESET` during session shutdown). Because the inner loop only checks `> 0` and ignores `< 0`, it immediately falls through to `sd_bus_wait(bus, UINT64_MAX)`, which also immediately returns `-ENOTCONN` without sleeping—spinning in `while (!stop)` at **100% CPU forever**.
  2. **`SIGTERM` race before `sd_bus_wait(bus, UINT64_MAX)`:**
     With `#define _GNU_SOURCE`, `signal(SIGTERM, on_signal)` sets `SA_RESTART`. If `SIGTERM` arrives while `request_inhibit(bus)` is running (two synchronous D-Bus calls) and finishes, or arrives during `sd_bus_process(bus, NULL)` right before `sd_bus_wait(bus, UINT64_MAX)`, `stop` is set to `1` *before* entering `sd_bus_wait(bus, UINT64_MAX)`. Because no further D-Bus messages arrive on this connection after `Inhibit` replies, `sd_bus_wait(bus, UINT64_MAX)` blocks forever—keeping the helper process and its `org.freedesktop.ScreenSaver` inhibition alive after playback was paused or stopped.
  3. **`PR_SET_PDEATHSIG` triggers on thread exit, not process exit (`man 2 prctl`):**
     On Linux, `PR_SET_PDEATHSIG` sends `SIGTERM` when the **thread** that called `fork()` terminates, not when the `mpv` process terminates. Because `mpv` executes `subprocess` commands from worker threads in its `mp_thread_pool`, if that worker thread exits after its idle timeout while the video is still playing, the kernel sends `SIGTERM` to `dvp-keep-awake`, silently dropping the screensaver inhibition mid-film. Also, `if (getppid() == 1)` does not detect orphanhood under Flatpak (`bwrap`) or `systemd --user` (`PR_SET_CHILD_SUBREAPER`), where the subreaper PID is not `1`.
  4. **Unchecked `unique + 1` pointer arithmetic:**
     In `request_inhibit` (line 84), `for (const char *p = unique + 1; *p ...` reads 1 byte past the NUL terminator if `unique` is ever `""`.
* **Suggested Fix:**
  * Check `unique && unique[0] == ':'` before `unique + 1`.
  * In the event loop, break if `sd_bus_process` returns `< 0`, check `if (stop) break;` immediately before `sd_bus_wait`, and use a bounded wait (e.g. `1000000` µs = 1 s, or `sigaction` without `SA_RESTART`) so a signal arriving just before `sd_bus_wait` can never hang the helper.

### 1.2. Predictable `/tmp` fallback filename and leftover status files in `dvp/keepawake.lua` & `helper/dvp-keep-awake.c`
* **Location:** `app/share/deckvideoplayer/mpv/scripts/deckplayer/dvp/keepawake.lua` (`KeepAwake.new` lines 34–36, `KeepAwake:stop` lines 58–64) and `helper/dvp-keep-awake.c` (`write_status` lines 30–39)
* **Problems:**
  1. When `XDG_RUNTIME_DIR` is unset, `KeepAwake.new` falls back to `/tmp/dvp-keep-awake-<pid>.status`, and `write_status()` opens `/tmp/dvp-keep-awake-<pid>.status.tmp` with `fopen(tmp, "w")` (without `O_EXCL` or `O_NOFOLLOW`) in world-writable `/tmp`. Falling back to `data_dir` (which is already private under `umask 077`) avoids `/tmp`.
  2. `KeepAwake:stop()` does not remove `self.status_file`, leaving `/run/user/1000/dvp-keep-awake-<pid>.status` behind in `XDG_RUNTIME_DIR` (RAM `tmpfs`) after the app exits.
  3. `write_status()` in `dvp-keep-awake.c` does not check `snprintf(tmp, sizeof tmp, "%s.tmp", status_file)` for truncation before `fopen`.
* **Suggested Fix:** Pass `opts.data_dir` to `KeepAwake.new(cfg, opts.data_dir)` as the fallback before `/tmp`, call `os.remove(self.status_file)` in `KeepAwake:stop()`, and check the `snprintf` return value in `write_status()`.

### 1.3. `http.curl_quote`: NUL byte (`\0`) not stripped
* **Location:** `app/share/deckvideoplayer/mpv/scripts/deckplayer/dvp/http.lua` (`http.curl_quote` lines 16–19)
* **Problem:** `curl_quote` escapes `\`, `"`, `\n`, `\r`, `\t`, but does not strip NUL bytes (`%z`). Because curl reads `-K -` lines as C strings, a NUL byte in any string would truncate the line in curl's config parser.
* **Suggested Fix:** Strip `%z` (`:gsub("%z", "")`) in `http.curl_quote`.

---

## 2. Bugs & Functional Edge Cases (v0.3.5)

### 2.1. Three bugs in *Crop black bars* (`dvp/cropdetect.lua` & `dvp/player.lua`)
* **Location:** `app/share/deckvideoplayer/mpv/scripts/deckplayer/dvp/cropdetect.lua` (`cropdetect.bounds` lines 19–49) and `dvp/player.lua` (`Player:set_zoom` lines 316–327, `Player:crop_black_bars` lines 332–344)
* **Problems:**
  1. **Asymmetric dark edges in normal scenes are misdetected as single-sided black bars (`dvp/cropdetect.lua`):**
     `cropdetect.bounds` measures `top`, `bottom`, `left`, and `right` independently and crops each side on its own:
     * On a standard 16:9 video during a night scene with a dark sky at the top (`top = 260, bottom = 0`), `cropdetect.bounds` crops 260 px off the top of the image.
     * On a 2.39:1 letterboxed film (`top = 140, bottom = 140`) when one side of the scene is in dark shadow (`left = 360, right = 0`), it crops both the 140 px letterbox bars **and** 360 px off the left side (`1560x800+360+140`), cutting off the left side of the film and shifting it off-center.
     * Conversely, if one side of a letterboxed film is completely dark (`left >= max_x, right = 0, top = 140, bottom = 140`), line 40 (`if top >= max_y or bottom >= max_y or left >= max_x or right >= max_x then return nil end`) rejects the entire frame even though `right == 0` proves there are no pillarbox bars and `top = 140, bottom = 140` are valid letterbox bars.
     * Real encoded letterbox and pillarbox bars are symmetric on opposite sides (`math.min(top, bottom)` and `math.min(left, right)`).
  2. **Failed detection (`"No black bars found"`) still sets `self.crop_bars = true` (`dvp/player.lua`):**
     In `Player:set_zoom("bars")`:
     ```lua
     if mode == "bars" then
         self.crop_bars = true
         self:crop_black_bars()
     ```
     When `crop_black_bars()` finds no bars and toasts `"No black bars found (try again in a brighter scene)"`, `self.crop_bars` stays `true`:
     * The *Picture* menu row falsely shows **`Crop black bars`** even though no crop is active.
     * When the user waits for a brighter scene and presses **A** or **▶** on *Picture* to try again, it cycles away to `Fill (crop)` instead of retrying `Crop black bars`.
  3. **Synchronous `screenshot-raw` right after clearing `video-crop` returns the still-cropped frame (*verified*):**
     In `Player:crop_black_bars()`, calling `mp.set_property("file-local-options/video-crop", "")` and `mp.command_native({"screenshot-raw", "video", "bgr0"})` on the very next line returns the **already-cropped** dimensions until the VO renders a new frame.
* **Suggested Fix:**
  * In `cropdetect.bounds`: pair opposite edges symmetrically (`local v = bar(math.min(top, bottom), h)` and `local s = bar(math.min(left, right), w)`), and only reject as a dark frame when `math.min(top, bottom) >= max_y or math.min(left, right) >= max_x`.
  * In `Player:set_zoom("bars")`: set `self.crop_bars = self:crop_black_bars()` (returning `true` only when a crop was applied).

### 2.2. `Browser:recent_playlist` uses `self.sort`, playing TV episodes backwards when `self.sort == "date"`
* **Location:** `app/share/deckvideoplayer/mpv/scripts/deckplayer/dvp/browser.lua` (`Browser:recent_playlist` lines 281–290)
* **Problem:**
  ```lua
  function M:recent_playlist(path)
      if not self.cfg.playback.autoplay_next then return {path} end
      local out
      for _, e in ipairs(library.list(util.dirname(path), self.cfg, self.sort) or {}) do
  ```
  On the Start screen (`loc == nil`), sorting is disabled (`self:sortable()` is `false` and the `"Sorted by …"` indicator is hidden). However, if `self.sort` is `"date"` (from `config.ini` or from pressing **Y** in a Movies folder earlier), playing `Show S01E01.mp4` from **Recently played** on the Start screen lists its folder in reverse chronological order (`E10, E09, …, E01`), so auto-play either stops after `E01` or plays the season backwards.
* **Suggested Fix:** Always sort by `"name"` in `Browser:recent_playlist`: `library.list(util.dirname(path), self.cfg, "name")`.

### 2.3. `Resume:mark_watched` and `Resume:mark_unwatched` mishandle pre-v0.3.1 entries (`e.played == nil`)
* **Location:** `app/share/deckvideoplayer/mpv/scripts/deckplayer/dvp/resume.lua` (`Resume:mark_watched` lines 74–80, `Resume:mark_unwatched` lines 84–93, `Resume:recent` lines 110–113)
* **Problems:**
  Entries saved before v0.3.1 have `e.played == nil` and use `e.t` as their played timestamp in `Resume:recent()` (`local t = e.played; if t == nil then t = e.t end`).
  1. In `Resume:mark_watched(path)`:
     ```lua
     function M:mark_watched(path)
         local e = self.entries[path] or {}
         e.pos, e.watched, e.t = nil, true, os.time()
         if e.played == nil and not e.duration then e.played = false end
     ```
     If `e` is a pre-v0.3.1 entry with `e.duration` set (`e.played == nil, e.duration = 3600, e.t = 100`), `mark_watched` overwrites `e.t = os.time()` while leaving `e.played = nil`, which bumps the entry to **#1 in *Recently played*** with the current timestamp (contradicting D42: *"Marking doesn't count as playing"*).
  2. In `Resume:mark_unwatched(path)`:
     ```lua
     if e.played then
         e.pos, e.watched = nil, nil
     else
         self.entries[path] = nil
     end
     ```
     For a pre-v0.3.1 entry (`e.played == nil, e.t = 100`), `if e.played then` evaluates to `false`, deleting the entry from `resume.json` and dropping it from *Recently played* (and if triggered from the Start screen, `Browser:mark` only calls `self:render()`, leaving a stale row on screen).
* **Suggested Fix:**
  * In `mark_watched`: set `if e.played == nil then e.played = e.duration and e.t or false end` *before* setting `e.t = os.time()`.
  * In `mark_unwatched`: migrate `if e.played == nil and e.t then e.played = e.t end` before checking `if e.played then`.

### 2.4. `Plex:poll_pin` misses PIN expiry (`404`) whenever `pins.short` responds before `pins.strong`
* **Location:** `app/share/deckvideoplayer/mpv/scripts/deckplayer/dvp/plex.lua` (`Plex:poll_pin` lines 371–394)
* **Problem:**
  ```lua
  elseif pending == 0 then
      -- The short code is what the user types: its expiry ends the dialog.
      cb(false, (code == 404 and pin == pins.short) and "The code expired" or nil)
  end
  ```
  `poll_pin` fires two parallel HTTP requests (`pins.short` and `pins.strong`). `pending == 0` is only reached in the callback of whichever request finishes **second**. Whenever `pins.short` returns `404` first (`pending == 1`) and `pins.strong` finishes second (`pending == 0`), `pin == pins.short` is `false` in the second callback—so `"The code expired"` is never reported and the dialog keeps polling expired PINs every 2 seconds.
* **Suggested Fix:** Record `if code == 404 and pin == pins.short then expired = true end` before checking `pending == 0`, and pass `expired and "The code expired" or nil` to `cb`.

### 2.5. Plex playlist failure cascade in `main.lua` (`on_load` / `end-file`)
* **Location:** `app/share/deckvideoplayer/mpv/scripts/deckplayer/main.lua` (`on_load` lines 286–303, `end-file` lines 361–371) and `dvp/plex.lua` (`forget_session` lines 483–486)
* **Problems:**
  When starting a video in a Plex folder/season with `autoplay_next = true`, `play()` appends all remaining videos in the folder (`list[2..N]`) to mpv's playlist:
  1. **Unreachable server blocks `on_load` across the entire playlist:** If the server is unreachable (`not prep.ok` in `on_load`), `list[1]` fails, `end-file` calls `plex:forget_session(item.machine)` (setting `self.bases[machine] = nil`), and mpv immediately advances through `list[2..N]`, attempting to open every remaining item in the playlist without a token header and failing each one in a loop.
  2. **Single-file stream failure wipes `self.bases[machine]` for the rest of the playlist:** If `plex:prepare(item)` succeeded (`prep.ok == true`, proving `self.bases[machine]` is reachable) and mpv then fails to open that file (`ev.reason == "error"` in `end-file`, e.g. stale transient token or one missing file), `plex:forget_session` clears `self.bases[machine] = nil`, breaking `plex:prepare` for all subsequent playlist entries.
* **Suggested Fix:**
  * In `on_load`: when `not prep.ok`, call `plex:forget_session(item.machine)` and `mp.commandv("playlist-clear")` so mpv stops immediately instead of stepping through `list[2..N]`.
  * When `prep.ok` was `true` and `end-file` fails with `ev.reason == "error"`, only clear `self.transient[item.machine] = nil` (keeping `self.bases[item.machine]`).

### 2.6. `KeepAwake:start()` ignores positive exit codes and unexpected helper termination
* **Location:** `app/share/deckvideoplayer/mpv/scripts/deckplayer/dvp/keepawake.lua` (`KeepAwake:start` lines 40–56, `KeepAwake:info_lines` lines 74–79)
* **Problem:**
  ```lua
  local status = result and result.status
  if err or (status and status < 0) then
      self.error = (result and result.error_string ~= "" and result.error_string) or err or "failed"
  ```
  In mpv's `subprocess`, `result.status` is `< 0` only when spawning fails, and is the process exit code (`>= 0`) when the process exits. Because `dvp-keep-awake` is a long-running helper that stays alive until killed by `KeepAwake:stop()`, *any* exit where `self.job == job` (not killed by `stop()`) means the helper died while `self.playing` is still `true` and the D-Bus inhibition is gone. Currently, if the helper exits with code `0`, `1` (after writing `.status`), or `2`, or is killed externally, `status < 0` is `false` and `info_lines()` continues reading the stale `.status` file as `"accepted"`.
* **Suggested Fix:** If the callback runs with `self.job == job`, the helper exited unexpectedly while playing: if `status ~= 1` (or if `.status` has no `request`), set `self.error` so `info_lines()` reports that the helper exited instead of showing a stale `"accepted"` status.

### 2.7. `Player:open_subtitle_menu()` omits `rebuild`, so completed downloads don't refresh the open Subtitles menu
* **Location:** `app/share/deckvideoplayer/mpv/scripts/deckplayer/dvp/player.lua` (`Player:open_subtitle_menu` lines 294–299) and `dvp/menu.lua` (`Menu:refresh` lines 83–90)
* **Problem:** `open_audio_menu()` and `open_main_menu()` pass `rebuild = function() ... end`, but `open_subtitle_menu()` omits `rebuild = function() return self:subtitle_items() end`. If a subtitle download finishes while the user has the **Subtitles** menu open, `self.ctx.menu:refresh()` (`dvp/subdownload.lua` line 297) does not rebuild the track list. Also, in `Menu:refresh()`, `spec.selected = math.min(spec.selected, #spec.items)` does not call `first_selectable`, which can leave the cursor on a separator if the rebuilt item count changes.
* **Suggested Fix:** Add `rebuild = function() return self:subtitle_items() end` in `Player:open_subtitle_menu()`, and use `spec.selected = first_selectable(spec.items, math.min(spec.selected, #spec.items), -1)` in `Menu:refresh()`.

### 2.8. Stale `self.after_load` callback in `Browser` when navigating away from a loading Plex folder
* **Location:** `app/share/deckvideoplayer/mpv/scripts/deckplayer/dvp/browser.lua` (`Browser:enter` lines 230–235, `"Go to library start"` lines 361–366)
* **Problem:** If `self.after_load` is set while a Plex folder is loading (via `reload()` or `go_back()`) and, before the response arrives, the user selects `"Go to library start"` or enters another Plex folder, `self.after_load` remains set and executes on the next Plex listing that finishes loading.
* **Suggested Fix:** Clear `self.after_load = nil` in `Browser:enter()` and `"Go to library start"`.

### 2.9. **B** does not dismiss `Advanced statistics`, and `stats.lua` stays visible over the Library screen
* **Location:** `app/share/deckvideoplayer/mpv/scripts/deckplayer/dvp/player.lua` (`Player:stop_screen` lines 71–79, `Player:handle` lines 174–182, `Player:main_menu_items` lines 421–423)
* **Problem:** *Menu → Advanced statistics* toggles mpv's built-in `stats/display-stats-toggle`. Because `dvp/input.lua` binds controller buttons and keys with `mp.add_forced_key_binding`, pressing **B** during playback does not close `Advanced statistics` (it stops the video instead), and `stats.lua` remains drawn on top of the Library browser after playback stops.
* **Suggested Fix:** Track `self.stats_visible` in `Player`: dismiss it on **B** (`elseif self.stats_visible then self:toggle_stats()`) and turn it off in `stop_screen()` when `self.stats_visible` is `true`.

### 2.10. Multi-account Steam profiles and branch regex edge cases in `scripts/install-steamos.sh` & `scripts/steam_shortcut.py`
* **Location:** `scripts/install-steamos.sh` (`remove_installed_branches` lines 26–30, `add_to_steam` lines 58–66, line 114) and `scripts/steam_shortcut.py` (`BRANCH_RE` line 160)
* **Problems:**
  1. **Second Steam profile skipped:** In `scripts/install-steamos.sh` line 59, `python3 "$here/steam_shortcut.py" status 2>/dev/null | grep -q 'app id'` matches if *any* Steam user on the Deck already has the shortcut, returning early and never adding the shortcut to a second Steam account on the same Deck (`-> not added`). Checking `! ... | grep -q 'not added'` (or running `add` whenever Steam is closed, since `add` already unpins and installs artwork idempotently) handles multi-account Decks.
  2. **Quotes in `BRANCH_RE`:** In `scripts/steam_shortcut.py` line 160, `BRANCH_RE = re.compile(r"\s*--branch(?:=|\s+)(\S+)")` matches a closing quote if `--branch=master` is at the end of a quoted string; `r'\s*--branch(?:=|\s+)([^\s"\']+)'` avoids consuming quotes.
  3. **Uninstalling `stable` before `flatpak install`:** In `scripts/install-steamos.sh` lines 114–115, `remove_installed_branches` uninstalls all branches (including `stable`) *before* `flatpak install --user -y --reinstall "$bundle"`. If `flatpak install` fails (e.g. corrupted download), the user is left with no app installed. Removing only other branches (`grep -v "/stable$"`) before `flatpak install --reinstall` keeps upgrades safe.

---

## 3. Optimization Opportunities (v0.3.5)

### 3.1. `Browser:toggle_sort()` re-fetches the entire Plex listing over the network (and re-reads local folders) instead of sorting `self.entries` in place
* **Location:** `app/share/deckvideoplayer/mpv/scripts/deckplayer/dvp/browser.lua` (`Browser:toggle_sort` lines 319–330)
* **Problem:**
  ```lua
  function M:toggle_sort()
      self.sort = self.sort == "name" and "date" or "name"
      local cur = self.entries[self.selected]
      if cur then self.after_load = function() self:select_path(cur.path) end end
      self:load()
  ```
  Pressing **Y** (or adjusting *Sort by* in the Library menu) calls `self:load()`. In a Plex library, `self:load()` wipes `self.entries = {}`, shows `"Loading…"`, and performs a full HTTP request to the Plex server to re-download the entire library listing—even though sorting is 100% client-side (`library.sort_entries(self.entries, self.sort)`) and every entry in `self.entries` already has `name`, `sort_name`, `label`, and `mtime` (`addedAt`). Furthermore, when triggered from *Menu → Sort by*, replacing `self.entries` detaches the `cur` entry captured by `open_menu()`.
* **Optimization:** When `not self.loading`, sort `self.entries` in place with `library.sort_entries(self.entries, self.sort)` and re-select `cur.path`. Sorting becomes instantaneous (0 ms, zero network or disk I/O).

### 3.2. Continuous 0.5 s overlay redraws and 4 s `hide_timer` churn while paused (`dvp/player.lua`)
* **Location:** `app/share/deckvideoplayer/mpv/scripts/deckplayer/dvp/player.lua` (`Player:update_timer` lines 81–87, `Player:show_overlay` lines 94–109, `Player:on_pause_change` lines 118–121)
* **Problem:**
  While a video is paused:
  1. `self.hide_timer` fires every 4 seconds, sees `pause == true`, and calls `self:show_overlay()`, which re-renders the overlay and re-schedules `self.hide_timer` in an infinite loop.
  2. When `on_pause_change` runs while `self.info_visible` is `true`, `self:render_info()` is not called immediately, delaying the *Keep awake* status update in the info panel.
* **Optimization:** In `self.hide_timer`'s callback, if `mp.get_property_native("pause") or self.ctx.menu:is_open()`, simply return without re-calling `self:show_overlay()` (`on_pause_change(false)` and menu close already re-arm the timeout when resuming or closing the menu). Also call `if self.info_visible then self:render_info() end` in `on_pause_change`.

### 3.3. Duplicate `mp.get_property_native("video-params")` marshaling on every overlay and info-panel tick
* **Location:** `app/share/deckvideoplayer/mpv/scripts/deckplayer/dvp/player.lua` (`Player:badges` lines 447–450, `Player:info_lines` lines 585 & 596)
* **Problem:** Both `Player:badges()` and `Player:info_lines()` call `mp.get_property_native("video-params")` and immediately call `media.hdr_state(self.video_track)`, which calls `mp.get_property_native("video-params")` a second time and returns `vp` as its 3rd return value.
* **Optimization:** Reuse the `vp` returned by `media.hdr_state(self.video_track)` in both `badges()` and `info_lines()`.

### 3.4. `SubDownload:stored(path)` calls `utils.readdir(self.dir, "dirs")` on every Plex video load
* **Location:** `app/share/deckvideoplayer/mpv/scripts/deckplayer/dvp/subdownload.lua` (`SubDownload:stored` lines 141–151)
* **Optimization:** The `utils.readdir(self.dir, "dirs")` check exists only to avoid hashing a local file when no subtitles have ever been downloaded. For Plex items (`self:plex_item(path) ~= nil`) or already-cached keys (`self.keys[path] ~= nil`), `self:key(path)` does no file I/O, so `stored(path)` can go straight to `utils.readdir(util.join(self.dir, key), "files")`.

---

## 4. Release Readiness & Polish (v0.3.5)

1. **AppStream Metainfo feature list (`packaging/flatpak/io.github.nicocarbone.DeckVideoPlayer.metainfo.xml` lines 21–28):**
   * The top-level `<description><ul>` feature list still ends with the v0.2.0 features (headphone surround and OpenSubtitles) and does not mention Plex Media Server streaming, black-bar cropping, or screen-awake inhibition.
2. **Launcher `ini_get` key/value normalization (`app/bin/deckvideoplayer` lines 28–45):**
   * `dvp/config.lua` normalizes `-` to `_` in keys and strips optional quotes around values, whereas `ini_get` in `app/bin/deckvideoplayer` (used for `gpu_context`) does not normalize `-` or strip surrounding quotes.

---

## 5. v0.3.5 (Part V) Summary Checklist

Reviewed and fixed on 2026-10-25 (DECISIONS D45).

- [x] **Security / Helper (`helper/dvp-keep-awake.c`):** Break on `sd_bus_process < 0` (avoid 100% CPU loop on bus disconnect), check `stop` before `sd_bus_wait` with a bounded timeout, and guard `unique[0] == ':'`. *(D45; the `PR_SET_PDEATHSIG` thread claim in 1.1 is not valid: the spawning thread stays blocked on the helper.)*
- [x] **Security / Helper (`dvp/keepawake.lua`, `helper/dvp-keep-awake.c`):** Fall back to `data_dir` before `/tmp`, clean up `self.status_file` in `stop()`, and check `snprintf` bounds in `write_status()`.
- [x] **Security (`dvp/http.lua`):** Strip NUL bytes (`%z`) in `http.curl_quote`.
- [x] **Bug (`dvp/cropdetect.lua`, `dvp/player.lua`):** Require symmetric opposite bars (`math.min(top, bottom)`, `math.min(left, right)`) so dark scene edges aren't cropped; only set `self.crop_bars = true` when a crop was applied. *(D45; 2.1.3 not applicable: detection never runs while a crop is active.)*
- [x] **Bug (`dvp/browser.lua`):** Use `"name"` order in `Browser:recent_playlist` so episodes launched from *Recently played* never auto-play backwards.
- [x] **Bug (`dvp/resume.lua`):** Preserve `e.played` for pre-v0.3.1 entries in `mark_watched` and `mark_unwatched`.
- [x] **Bug (`dvp/plex.lua`):** Track `expired` across both PIN requests in `poll_pin` so a `404` on `pins.short` is not lost when `pins.strong` finishes second.
- [x] **Bug (`main.lua`, `dvp/plex.lua`):** Clear the playlist when `plex:prepare` fails in `on_load`, and keep `self.bases[machine]` when `prepare` succeeded.
- [x] **Bug (`dvp/keepawake.lua`):** Report unexpected helper exits while `self.playing` is `true` instead of only checking `status < 0`.
- [x] **Bug (`dvp/player.lua`, `dvp/menu.lua`):** Add `rebuild` to `open_subtitle_menu()` and use `first_selectable` in `Menu:refresh()`.
- [x] **Bug (`dvp/browser.lua`):** Clear stale `self.after_load` in `enter()` and `"Go to library start"`.
- [x] **Bug (`dvp/player.lua`):** Track `self.stats_visible` so **B** dismisses *Advanced statistics* and `stop_screen()` turns it off.
- [x] **Bug (`scripts/install-steamos.sh`, `scripts/steam_shortcut.py`):** Handle multi-user Steam profiles, avoid eating quotes in `BRANCH_RE`, and only remove non-`stable` branches before `flatpak install --reinstall`.
- [x] **Optimization (`dvp/browser.lua`):** Sort `self.entries` in place in `Browser:toggle_sort()` instead of re-fetching over the network or disk.
- [x] **Optimization (`dvp/player.lua`):** Stop re-arming `hide_timer` every 4 s while paused, update `render_info()` on pause change, and reuse `vp` from `media.hdr_state`.
- [x] **Optimization (`dvp/subdownload.lua`):** Skip `utils.readdir(self.dir, "dirs")` in `stored()` for Plex items and cached keys.
- [x] **Polish (`metainfo.xml`, `app/bin/deckvideoplayer`):** Add v0.3 features to the metainfo `<description>` list and normalize `-`/quotes in `ini_get`.

---
---

# Part IV — v0.3.0 Full Audit: Security, Bugs & Optimizations (2026-10-24)

All 200 Lua checks and 5 Python tests in `tests/run.sh` pass. Below are the security vulnerabilities, functional bugs, optimization opportunities, and release-readiness items identified across the v0.3.0 Plex integration (`dvp/plex.lua`, `dvp/http.lua`, `dvp/qrencode.lua`, `dvp/subdownload.lua`, `dvp/browser.lua`, `dvp/util.lua`, and `main.lua`).

---

## 1. Security & Privacy Vulnerabilities (v0.3.0)

### 1.1. Unbounded download into `/tmp` (RAM exhaustion) in `Plex:fetch_range` if a server ignores `Range`
* **Location:** `app/share/deckvideoplayer/mpv/scripts/deckplayer/dvp/plex.lua` (`Plex:fetch_range` lines 436–445) and `dvp/subdownload.lua` (`SubDownload:hash_for` lines 112–138)
* **Problem:**
  ```lua
  function M:fetch_range(path, from, to, file, cb)
      local item = self.items[path]
      local server = item and self:server(item.machine)
      if not server then return cb(false) end
      local headers = self:headers(server.token)
      headers["Range"] = string.format("bytes=%d-%d", from, to)
      headers["Accept"] = nil
      http.request({url = path, headers = headers, output = file, tag = "plex", timeout = 20},
          function(code) cb(code == 206 or code == 200) end)
  end
  ```
  When `SubDownload:hash_for` computes the OpenSubtitles hash for a Plex video, it calls `fetch_range` twice in parallel (`0..65535` and `size-65536..size-1`) into `/tmp/lua_*` files created by `os.tmpname()`:
  1. `fetch_range` sets **no `max_size`** on `http.request`.
  2. It accepts `code == 200` in addition to `206`.
  * If a server or reverse proxy ignores the `Range` header and responds with `200 OK` and the full file stream (e.g., a 50 GB 4K remux), two parallel `curl` processes will stream gigabytes of video into `/tmp` (which is `tmpfs` in RAM on SteamOS/Linux) for 20 seconds until timeout.
* **Suggested Fix:** Pass `max_size = to - from + 1` (65536) to `http.request` and require `code == 206` (since `hash_for` only runs on files `>= 128 KiB`).

### 1.2. TOCTOU permission window in `util.write_file_atomic` when writing `plex.json`
* **Location:** `app/share/deckvideoplayer/mpv/scripts/deckplayer/dvp/util.lua` (`write_file_atomic` lines 127–149) and `app/bin/deckvideoplayer` (lines 17–21)
* **Problem:**
  ```lua
  function M.write_file_atomic(path, data, private)
      local tmp = path .. ".tmp"
      local f, err = io.open(tmp, "wb")
      if not f then return false, err end
      if private then
          f:close()
          local r = mp.command_native({name = "subprocess", args = {"chmod", "600", tmp}, ...})
          ...
          f, err = io.open(tmp, "wb")
  ```
  * The first `io.open(tmp, "wb")` creates `plex.json.tmp` with default umask (`0644`, world-readable).
  * While `mp.command_native` forks and executes `/usr/bin/chmod`, any local process can `open("plex.json.tmp", O_RDONLY)`.
  * On Linux/POSIX, permissions are checked at `open()` time, not `read()` time. Because the second `io.open(tmp, "wb")` truncates and writes the token into the **same inode**, a file descriptor opened before `chmod 600` completed can still read the Plex account token after it is written.
* **Suggested Fix:** Create `$CONFIG_DIR` and `$DATA_DIR` with mode `0700` (`mkdir -m 700 -p ...`) or set `umask 077` in `app/bin/deckvideoplayer` before `exec "$MPV"` (every file the app creates in `$DATA_DIR` or `/tmp` is private to the user). That makes every file `0600` atomically at creation time and eliminates the blocking `chmod` subprocess spawn.

### 1.3. Unvalidated `c.uri`, `c.address`, and `c.port` in `Plex.server_candidates`
* **Location:** `app/share/deckvideoplayer/mpv/scripts/deckplayer/dvp/plex.lua` (`Plex.server_candidates` lines 92–119)
* **Problems:**
  ```lua
  local function https(uri) return type(uri) == "string" and uri:match("^https://") ~= nil end
  for _, l in ipairs(locals) do
      if https(l.c.uri) then add(l.c.uri, "local") end
      if allow_insecure and l.c.address and l.c.port then
          add(string.format("http://%s:%d", l.c.address, l.c.port), "local")
      end
  end
  ```
  1. `https(uri)` only checks `^https://` without verifying that `uri` is a clean origin (`^https://[%w%-%._]+:%d+$`, with no `@`, `?`, `#`, whitespace, or path). A shared server publishing a custom connection URI like `https://srv@evil.example:32400` or `https://srv:32400/path?x=` would pass `https(uri)` and alter all subsequent `base.url .. key` requests.
  2. When `allow_insecure_lan = yes`, `string.format("http://%s:%d", l.c.address, l.c.port)` does not check that `l.c.address` is a pure IPv4 address (`^%d+%.%d+%.%d+%.%d+$`) or that `tonumber(l.c.port)` is a number—a non-numeric `port` crashes `M:connect` with a Lua error (`bad argument #3 to 'format'`).
* **Suggested Fix:** Validate `https(uri)` with `uri:match("^https://[%w%-%._]+:%d+$") ~= nil` and validate `l.c.address:match("^%d+%.%d+%.%d+%.%d+$")` and `tonumber(l.c.port)` before formatting the `http://` fallback.

### 1.4. `Plex:sign_out()` leaves `self.transient` tokens in memory and can be overwritten by an in-flight `refresh_account`
* **Location:** `app/share/deckvideoplayer/mpv/scripts/deckplayer/dvp/plex.lua` (`Plex:refresh_account` lines 371–389, `Plex:sign_out` lines 391–395)
* **Problems:**
  1. `Plex:sign_out()` resets `self.bases` and `self.items`, but forgets to clear `self.transient = {}` and `self.pin = nil`.
  2. `Plex:refresh_account(cb)` captures `local token = self.account.token` before two async requests (up to 30 s). If the user triggers **"Refresh server list"** and then clicks **"Sign out"** before those requests finish, `refresh_account`'s callback writes `self.account.username` and `self.account.servers` (with the old `token`!) back into `self.account` and calls `self:save()`, re-saving the signed-out credentials to `plex.json`.
* **Suggested Fix:** Clear `self.transient = {}` and `self.pin = nil` in `sign_out()`, and guard `refresh_account`'s callbacks with `if self.account.token ~= token then return end`.

---

## 2. Bugs & Functional Edge Cases (v0.3.0)

### 2.1. Race condition on Stop / Quit: `stop_playback()` and `quit()` send an async `"playing"` report right before `on_unload` sends a sync `"stopped"` report
* **Location:** `app/share/deckvideoplayer/mpv/scripts/deckplayer/main.lua` (`stop_playback` lines 170–174, `quit` lines 176–182, `on_unload` lines 330–333, `shutdown` lines 408–413)
* **Problem:**
  ```lua
  local function stop_playback()
      save_progress()
      resume:flush()
      mp.commandv("stop")
  end
  ```
  When the user presses **B** (`stop_playback()`) or quits (`quit()`) while watching a Plex video:
  1. `stop_playback()` / `quit()` calls `save_progress()` with `ending = nil`, which spawns an **asynchronous** `curl` subprocess reporting `state=playing` (or `paused`) to `/:/timeline`.
  2. Immediately on the next line, `mp.commandv("stop")` / `mp.commandv("quit")` triggers the `on_unload` hook, which calls `save_progress(true)` and runs a **synchronous** `curl` subprocess reporting `state=stopped` (and `/:/scrobble` if finished).
  3. Because the async `state=playing` subprocess from step 1 runs concurrently with step 2, if `state=playing` arrives at the Plex server after `state=stopped`, **the server's state reverts to `playing` (and un-scrobbles/keeps `viewOffset`)**.
  4. For local files, `resume.json` is also written twice on every stop/quit.
* **Suggested Fix:** Remove `save_progress()` and `resume:flush()` from `stop_playback()` and `quit()` (and in `shutdown`, only call them if `state.current_path` is still set), because `on_unload` is guaranteed to run for every unloaded file.

### 2.2. Canceling the Plex sign-in dialog does not cancel in-flight `poll_pin` / `start_pin`
* **Location:** `app/share/deckvideoplayer/mpv/scripts/deckplayer/dvp/browser.lua` (`Browser:plex_sign_in` lines 335–379) and `dvp/plex.lua` (`Plex:poll_pin` lines 345–368)
* **Problems:**
  1. `stop()` only kills `timer`, without clearing `plex.pin` or setting a `cancelled` flag. If a `poll_pin` (or its nested `refresh_account`) request is in flight when the user presses **B** or **Cancel**, and completes a moment later:
     * `poll_pin` still saves `self.account.token` even though the user canceled.
     * `if done then` calls `menu:close_all()` (closing whatever unrelated menu the user opened afterwards) and `self:reload()` (even if the user already started playing a video).
  2. In `Plex:poll_pin` (line 361), if the PIN is claimed (`self.account.token` saved) but `self:refresh_account` fails with a transient error, `cb(false, err)` is called—leaving the sign-in dialog on screen with the error message and a `"Cancel"` button even though the account is now signed in (and `self:reload()` is never called to update the library menu).
* **Suggested Fix:** Set `cancelled = true` and `plex.pin = nil` in `stop()`, check `if cancelled then return end` in `start_pin` and `poll_pin` callbacks, and if `plex:signed_in()` is true when `poll_pin` finishes (even with a server-list error), close the sign-in dialog, toast the error/sign-in, and reload.

### 2.3. Discrepancy between `Plex.item_state`, `Browser:render`, and `Browser:resume_position`
* **Location:** `app/share/deckvideoplayer/mpv/scripts/deckplayer/dvp/plex.lua` (`Plex.item_state` lines 155–161) and `dvp/browser.lua` (`Browser:resume_position` lines 130–140, `Browser:render` lines 535–555)
* **Problem:**
  ```lua
  function M.item_state(md)
      local state = {}
      if md.duration then state.duration = md.duration / 1000 end
      if md.viewOffset and md.viewOffset > 0 then state.pos = md.viewOffset / 1000 end
      if (md.viewCount or 0) > 0 and not state.pos then state.watched = true end
      return state
  end
  ```
  1. **`pos < 30 s` on a watched item:** If a watched movie (`viewCount > 0`) is opened briefly and stopped at `15 s` (`viewOffset = 15000`), `state.pos` is `15` and `state.watched` is `nil`. `Browser:render()` (line 539) only draws a progress bar when `r.pos >= 30`, so the row shows **neither** a watched checkmark nor a progress bar.
  2. **`pos` near the end (`Resume.is_finished` is true):** If a video has `viewOffset` within the finished margin (e.g. 96% when stopped on another client), `Browser:render()` draws a progress bar and resume timestamp (`r.pos >= 30`), but `Browser:resume_position()` returns `nil` (`not Resume.is_finished`), so the `X Play from start` hint is missing and pressing **A** silently starts from `0:00` without a resume dialog.
* **Suggested Fix:** Apply `Resume.MIN_POSITION` and `Resume.is_finished` directly inside `Plex.item_state(md)` (matching `Resume:update` in `dvp/resume.lua`): only set `state.pos` when `pos >= Resume.MIN_POSITION and not Resume.is_finished(pos, duration)`, and set `state.watched = true` when `(md.viewCount or 0) > 0 or Resume.is_finished(pos, duration)`.

### 2.4. Global `"date"` sort order scrambles TV Seasons and Episodes in Plex
* **Location:** `app/share/deckvideoplayer/mpv/scripts/deckplayer/dvp/browser.lua` (`Browser:load_plex` lines 103–105, `Browser:sortable` lines 117–121) and `dvp/plex.lua` (`Plex.entries_from` lines 178–206)
* **Problems:**
  1. `self.sort` (`"name"` or `"date"`) is shared across all folders. If a user presses **Y** in a Movie library to sort by **Date added**, and then opens a Plex TV Show → Season 1, `Browser:load_plex` sorts Seasons and Episodes by `mtime` (`addedAt`, newest first), listing episodes backwards (`E10, E09, …, E01`) and seasons backwards (`Season 4, Season 3, …`).
  2. For Seasons (`md.type == "season"`), `Plex.entries_from` sets `e.name = md.titleSort or label` instead of ordering by `md.index` (season number), so seasons with custom titles (e.g., `"Book Two: Earth"`, `"Book Three: Fire"`) sort alphabetically (`Book Three` before `Book Two`) instead of by season number.
* **Suggested Fix:** Keep season and episode listings in season/episode order (or set `e.name = string.format("%04d %s", md.index or 0, label)` for seasons and episodes and don't sort seasons/episodes by `addedAt`).

### 2.5. Fresh resume position (`prep.pos`) from `plex:prepare` is ignored for the selected video
* **Location:** `app/share/deckvideoplayer/mpv/scripts/deckplayer/main.lua` (`play` lines 162–168, `on_load` lines 279–300)
* **Problem:**
  * When starting playback from the browser, `play(list, start)` sets `state.pending_start[list[1]] = start or 0`.
  * In `on_load` (line 294), `prep.pos` (fetched synchronously from the Plex server via `plex:prepare(item)`) is only used `if start == nil`, which is only true for auto-advanced playlist items (`list[2..N]`) and never for `list[1]`.
* **Suggested Fix:** Either pass `nil` to `play(list, nil)` when the user did not explicitly choose `"Start from the beginning"` (and had no cached `pos` prompt), or skip the redundant `plex:prepare` resume check when `start` was already chosen.

### 2.6. Transient network error in `SubDownload:hash_for` permanently disables hash search for that Plex video
* **Location:** `app/share/deckvideoplayer/mpv/scripts/deckplayer/dvp/subdownload.lua` (`SubDownload:hash_for` lines 118–133)
* **Problem:** Line 133 sets `self.hashes[path] = hash or false`, and line 118 returns immediately if `self.hashes[path] ~= nil`. If either HTTP range request times out or fails once, `self.hashes[path]` is cached as `false` for the rest of the session and never retries when the user searches again.
* **Suggested Fix:** Only cache non-nil hashes (`if hash then self.hashes[path] = hash end`).

---

## 3. Optimization Opportunities (v0.3.0)

### 3.1. Prefetch the Plex transient delegation token asynchronously on `connect` to cut `on_load` blocking in half
* **Location:** `app/share/deckvideoplayer/mpv/scripts/deckplayer/dvp/plex.lua` (`Plex:connect` lines 418–421, `Plex:media_token` lines 508–525) and `main.lua` (`on_load` lines 286–291)
* **Problem:** On the first video played from a Plex server, `on_load` blocks mpv's main thread for **two sequential synchronous `curl` subprocesses** (two separate TCP + TLS handshakes):
  1. `plex:prepare(item)` (`GET /library/metadata/<id>`)
  2. `plex:media_token(item)` (`GET /security/token?type=delegation&scope=all`)
* **Optimization:** Request the transient token **asynchronously** as soon as `plex:connect` settles (since the user always connects while browsing the server before playing a video). That warms `self.transient[machine]` ahead of time, making `plex:media_token(item)` in `on_load` a **0 ms** in-memory lookup.

### 3.2. Avoid blocking the UI for up to 6 seconds in `on_unload` when stopping a Plex video without quitting
* **Location:** `app/share/deckvideoplayer/mpv/scripts/deckplayer/main.lua` (`save_progress` lines 146–154, `on_unload` lines 330–333)
* **Problem:** `on_unload` calls `save_progress(true)`, which executes `plex:report(..., true)` and `plex:set_watched(..., true)` **synchronously** (`http.request_sync`, up to 3 s timeout each) every time a video stops or advances to the next playlist entry. When the user presses **B** (`Stop`) to return to the library browser (`not state.quitting and not state.external`), the mpv process is not exiting—yet synchronous HTTP calls freeze the screen on the last video frame while waiting for the Plex server.
* **Optimization:** Only use `sync = true` when `state.quitting or state.external`. When staying in the app, update the item's state locally and run the `stopped` / `scrobble` requests asynchronously (or refresh the browser listing in the async callback).

### 3.3. Skip `utils.parse_json("")` on empty HTTP bodies and map curl exit code 63
* **Location:** `app/share/deckvideoplayer/mpv/scripts/deckplayer/dvp/http.lua` (`CURL_ERRORS` line 77, `parse_result` lines 93–96)
* **Optimization:** `utils.parse_json(text)` is called even when `text == ""` (every file download with `req.output`, and every `/:/timeline` or `/:/scrobble` call). Guarding `local body = text ~= "" and utils.parse_json(text) or nil` avoids unnecessary JSON parse attempts, and adding `[63] = "The file is too large"` to `CURL_ERRORS` gives a clear error when `max-filesize` triggers.

---

## 4. Release Readiness & Polish (v0.3.0)

1. **Version & AppStream metainfo (`dvp/version.lua`, `packaging/flatpak/io.github.nicocarbone.DeckVideoPlayer.metainfo.xml`):**
   * `dvp/version.lua` is still `"0.2.0"` (sent in `X-Plex-Version`, OpenSubtitles `User-Agent`, and shown in the About panel), and `metainfo.xml` needs the `0.3.0` `<release>` entry and Plex feature bullet when tagging.
2. **About panel credits (`dvp/about.lua` lines 74–79):**
   * `THIRD_PARTY_NOTICES.md` lists `luaqrcode` (BSD-3-Clause), which can also be credited in `About.items(ctx)`.

---

## 5. v0.3.0 (Part IV) Summary Checklist

Reviewed by Claude on 2026-10-24 (DECISIONS D40): all items valid except the asynchronous `on_unload` reports.

- [x] **Security (`dvp/plex.lua`):** Fixed: `max_size` = range size, HTTP 206 required.
- [x] **Security (`dvp/util.lua`, `app/bin/deckvideoplayer`):** Fixed: `umask 077` in the launcher (the `chmod` remains as a fallback).
- [x] **Security (`dvp/plex.lua`):** Fixed: bare https origins only; insecure http only for IPv4 literals with a numeric port.
- [x] **Security (`dvp/plex.lua`):** Fixed: `sign_out` clears transient tokens and PINs; late `refresh_account` answers are dropped.
- [x] **Bug (`main.lua`):** Fixed (verified first that mpv runs `on_unload` on quit).
- [x] **Bug (`dvp/browser.lua`, `dvp/plex.lua`):** Fixed: `cancel_pin`, late answers ignored; a claimed PIN with a failed server list closes the dialog as signed in.
- [x] **Bug (`dvp/plex.lua`, `dvp/browser.lua`):** Fixed in `item_state`.
- [x] **Bug (`dvp/plex.lua`, `dvp/browser.lua`):** Fixed: `seasons`/`episodes` listings keep server order and are not sortable.
- [x] **Bug (`main.lua`):** Fixed: no start position unless the user chose one.
- [x] **Bug (`dvp/subdownload.lua`):** Fixed.
- [x] **Optimization (`dvp/plex.lua`):** Done: `prefetch_token` after `connect`.
- [ ] ~~**Optimization (`main.lua`):**~~ Not adopted: the blocking report keeps the reloaded listing and the next playlist entry in sync (D40).
- [x] **Optimization (`dvp/http.lua`):** Done.
- [x] **Release polish (`dvp/about.lua`, `dvp/version.lua`, `metainfo.xml`):** luaqrcode credited; version and metainfo are bumped when tagging v0.3.0.

---
---

# Part III — v0.3.0 Security & Bug Audit (Claude, 2026-10-24)

Scope: all of the project's own code (Lua modules, launcher, helper, scripts,
manifest, CI), with emphasis on the new Plex sign-in/streaming and the
network code. Claims marked *verified* were reproduced on this machine
(curl 8.18) or against the owner's Plex server; nothing was written to the
server's watch history.

## 1. Security

### 1.1. HIGH — Plex account token sent in cleartext to LAN addresses on any network
* **Where:** `dvp/plex.lua` `server_candidates` (adds `http://<address>:<port>` for every "local" connection) and `connect` (probes every candidate with `X-Plex-Token`).
* **Problem:** for a server the user owns, the per-server token *is the account token* (*verified*). The app sends it unencrypted to whatever answers at the server's LAN address — on any network the Deck joins. On a hotel/café/friend's Wi-Fi that uses the same private range (e.g. 192.168.1.x), any device at that address, or anyone sniffing the network, gets full access to the user's Plex account. The `/identity` probe doesn't even need a token.
* **Fix:** never send a token in probes (`/identity` is unauthenticated) and check the returned `machineIdentifier`; drop plain-http candidates by default (https `*.plex.direct` is certificate-checked, so it is safe on foreign networks); offer plain http only behind an explicit opt-in (`[plex] allow_insecure_lan`) for routers that block plex.direct DNS.

### 1.2. HIGH — Redirects forward the token to other hosts
* **Where:** `dvp/http.lua` `curl_config` (follows redirects for every GET unless `follow = false`), used by all Plex requests and the subtitle download.
* **Problem:** curl forwards custom headers such as `X-Plex-Token` to the redirect target, even on another host (*verified*: a 302 to `localhost:18082` delivered `X-Plex-Token: SECRET` there). A malicious or impersonated server (see 1.1) can redirect any request to collect the account token.
* **Fix:** don't follow redirects by default; enable it only for the subtitle file download, which carries no secrets.

### 1.3. MEDIUM — Server-supplied keys pasted into URLs unchecked
* **Where:** `dvp/plex.lua` `entries_from`, `external_subtitles`, `list` (`base .. key` for section/metadata/part/stream keys).
* **Problem:** a key such as `@evil.example/x` turns `https://srv:32400` + key into `https://srv:32400@evil.example/x`, which curl and mpv send to `evil.example` with the token header. Needs a malicious server (e.g. a server shared by another user) or a man in the middle (1.1).
* **Fix:** accept only keys that start with a single `/` and contain URL-path characters (no `@`, no `//` prefix, no spaces/control characters); skip anything else.

### 1.4. MEDIUM — Any URL scheme accepted (`file://` reads local files)
* **Where:** `dvp/http.lua`; `dvp/opensubtitles.lua` `download` (`body.link` from the API is fetched as is).
* **Problem:** curl fetches `file://` URLs (*verified*). A malicious API response could make the app copy a local file (for example `plex.json` with the account token) into the subtitle folder, from where it is loaded as a subtitle.
* **Fix:** restrict curl to `https`/`http` (`proto`, `proto-redir = =https`); require the download link to start with `https://`.

### 1.5. LOW — `plex.json` briefly world-readable
* **Where:** `dvp/plex.lua` `save` → `util.write_file_atomic` then `chmod 600`.
* **Problem:** the temp file is created with the default mode (0644) and renamed before `chmod`; for a moment the account token is readable by other local users.
* **Fix:** create the temp file, `chmod 600` it, then write and rename (`util.write_private`).

### 1.6. LOW — `config.ini` (OpenSubtitles password) created world-readable
* **Where:** `app/bin/deckvideoplayer` (`cp` of the template).
* **Fix:** create it with mode 600 (existing files untouched; mention in the docs).

### 1.7. LOW — OpenSubtitles `base_url` used unchecked
* **Where:** `dvp/opensubtitles.lua` `ensure_login` (`api_url = "https://" .. body.base_url ..`), then used for authenticated calls.
* **Fix:** accept only hosts ending in `.opensubtitles.com`.

### 1.8. LOW — Subtitle language code and size unchecked
* **Where:** `dvp/subdownload.lua` `download` (`r.language` goes into the file name); `opensubtitles.lua` (no size limit).
* **Problem:** a code containing `/` builds a path outside the video's folder (not exploitable as written: the first component would have to exist), and an endless response could fill the disk.
* **Fix:** accept only letters and `-` (else `und`); `max-filesize` 10 MB for subtitle downloads.

### 1.9. LOW — CI supply chain
* **Where:** `.github/workflows/build.yml`.
* **Problem:** third-party actions referenced by moving tags (`flatpak-github-actions@master`, `action-gh-release@v2`, `actions/*@v4`); no top-level `permissions`. A compromised action could alter the published bundle.
* **Fix:** pin actions to commit SHAs; `permissions: contents: read` at the top, `contents: write` only for the release job.

### 1.10. INFO — Sandbox: whole home readable, plus network
* **Where:** Flatpak `finish-args` (`--filesystem=home:ro`, `--share=network` since v0.2).
* **Risk:** a decoder exploit in a malicious video could read anything in the home folder (SSH keys, other apps' tokens) and send it out.
* **Option:** narrow to `xdg-videos`, `xdg-download`, `/run/media`, `/media`, `/mnt`, and document `flatpak override --filesystem=…` for other folders. Trade-off: folders elsewhere in home stop working until overridden.

### 1.11. INFO — Accepted / documented
* mpv receives a transient token, which appears in `-v` logs (D37); the account token is stored in a plain file (no keyring in game mode; mode 600); signing out doesn't revoke the token at plex.tv (INSTALL tells users how); device-code sign-in can be phished by someone who sees the code (inherent to the flow).

## 2. Bugs

### 2.1. MEDIUM — Truncated files replace good ones on a full disk
* **Where:** `dvp/util.lua` `write_file_atomic` ignores `write`/`close` errors, then renames the temp file over `resume.json` / `plex.json`.
* **Fix:** check both, remove the temp file and keep the old one on failure.

### 2.2. MEDIUM — A finished Plex video may count as watched twice
* **Where:** `main.lua` `save_progress(true)`: reports `stopped`, then calls `/:/scrobble` when finished.
* **Problem:** Plex marks a video watched by itself when a timeline report passes its *Video played threshold* (90 % by default), so the explicit scrobble adds a second play. (Inferred from Plex's documented behaviour; not reproduced, to keep the owner's history untouched.)
* **Fix:** scrobble only when the app considers the video finished but it is below 90 %.

### 2.3. LOW — Stale transient token after a server restart
* **Where:** `dvp/plex.lua` `media_token` (cached 12 h).
* **Problem:** a server restart invalidates the token; every Plex video then fails ("Could not play this file") until the app restarts.
* **Fix:** forget the cached token (and connection) when a Plex file fails to load.

### 2.4. LOW — Sign-in lost if the server list fails right after linking
* **Where:** `dvp/plex.lua` `poll_pin` → `refresh_account` (saves only on success).
* **Fix:** save the token as soon as it arrives.

### 2.5. LOW — Robustness
* `parse_resources` assumes `provides` is a string; on_load can block up to ~10 s when a server has just become unreachable (metadata + transient token, 5 s each) — acceptable, could share one timeout.

## 3. v0.3.0 Summary Checklist

All resolved on 2026-10-24, see DECISIONS D39.

- [x] 1.1 No token on probes, check machineIdentifier, https-only by default (`allow_insecure_lan` opt-in)
- [x] 1.2 No redirects by default (subtitle file download only)
- [x] 1.3 Validate server-supplied keys
- [x] 1.4 curl restricted to http(s), https-only redirects; download link must be https
- [x] 1.5 `plex.json` private before writing
- [x] 1.6 `config.ini` created with mode 600
- [x] 1.7 Validate OpenSubtitles `base_url`
- [x] 1.8 Validate subtitle language; 10 MB download limit
- [x] 1.9 Pin CI actions, read-only default permissions
- [x] 1.10 Sandbox narrowed to Videos, Downloads and removable media
- [x] 2.1 Check writes in `write_file_atomic`
- [x] 2.2 Avoid double scrobble
- [x] 2.3 Forget transient token on Plex load failure
- [x] 2.4 Save token immediately after sign-in
- [x] 2.5 `provides` type check

---
# Part II — v0.2.0 Pre-Release Audit (2026-10-23)

All 139 Lua checks and 5 Python tests in `tests/run.sh` pass. Below are the bugs, edge cases, security/robustness improvements, and release-readiness items identified across the new v0.2.0 features (headphone surround, OpenSubtitles integration, Wayland gamescope refresh helper, text measurement & marquee scrolling, friendly volume naming, and About panel) and core lifecycle.

---

## 1. Bugs & Functional Edge Cases (v0.2.0)

### 1.1. Floating-point precision bug in `Menu:render` prevents long menu labels (like subtitle releases) from marquee-scrolling
* **Location:** `app/share/deckvideoplayer/mpv/scripts/deckplayer/dvp/menu.lua` (`Menu.split_row` lines 36–46, `Menu:render` lines 246–251)
* **Problem:**
  ```lua
  local label_w, value_w = M.split_row((x1 - 18) - tx, label_need, value_need, arrows, 24)
  local value_box = value_w - arrows
  local scroll_value = sel and value and value_need > value_box
  local scroll_label = sel and not scroll_value and label_need > label_w
  ```
  When a menu row has a long `label` and a short `value` (for example, in the **Download subtitles** menu where `label` is a 90-character release name and `value` is `"Exact"`), `Menu.split_row` computes:
  * `label_w = avail - gap - value_need`
  * `value_w = avail - gap - label_w`

  Due to IEEE-754 floating-point subtraction (`432 - 24 - (432 - 24 - 53.38438) = 53.38437999999999 < 53.38438`), `value_need > value_box` evaluates to `true` by `~7e-15`.
  * Consequently, `scroll_value` becomes `true` (which `Marquee:draw` in `dvp/ui.lua` line 276 then ignores because `Marquee:draw` uses a `+ 0.5` slack), while `scroll_label` (`not scroll_value`) becomes **`false`**, so the truncated subtitle release name never scrolls.
* **Suggested Fix:** Add the same `+ 0.5` slack used in `dvp/ui.lua` (lines 230 and 276):
  ```lua
  local scroll_value = sel and value and value_need > value_box + 0.5
  local scroll_label = sel and not scroll_value and label_need > label_w + 0.5
  ```

### 1.2. Downloaded subtitles with identical release names collide and silently skip downloading
* **Location:** `app/share/deckvideoplayer/mpv/scripts/deckplayer/dvp/subdownload.lua` (`SubDownload.file_name` lines 22–27, `SubDownload.parse_file_name` lines 32–41, `SubDownload:download` lines 206–214)
* **Problem:**
  * `SubDownload.file_name(release, lang)` names files `<release>.<lang>.srt` without `r.file_id`.
  * On OpenSubtitles, multiple distinct uploads for the same movie (especially `moviehash` matches, or uploads with an empty release string that fall back to `"Subtitles"`) frequently share the exact same `release` string.
  * In `SubDownload:download(path, r)`:
    ```lua
    local dest = util.join(dir, M.file_name(r.release, lang))
    ...
    if util.file_exists(dest) then
        select_file(dest, title, lang)
        toast(label)
        return
    end
    ```
    If the user downloads Result #1 (`file_id = 1001`) and finds it is out of sync or badly translated, then opens **Download subtitles…** again and picks Result #2 (`file_id = 1002`, same release name), `util.file_exists(dest)` is `true` — so the app silently re-selects the first file and refuses to download Result #2.
* **Suggested Fix:** Include `file_id` in the stored filename when present (e.g., `<release>.<file_id>.<lang>.srt`) and strip the optional `.<file_id>` suffix in `SubDownload.parse_file_name(name)` so the UI track label stays clean while distinct uploads never collide.

### 1.3. Track selections (`aid`, `sid`) and sync adjustments (`sub-delay`, `audio-delay`) leak across files in a session
* **Location:** `app/share/deckvideoplayer/mpv/scripts/deckplayer/dvp/player.lua` (lines 205–315) and `app/share/deckvideoplayer/mpv/scripts/deckplayer/main.lua` (`on_load` lines 225–246)
* **Problem:**
  * Picture mode (`panscan` / `keepaspect`) is reset at the start of every file in `on_load`, and surround resets on `end-file`.
  * However, choosing an audio track (`aid`), choosing a subtitle track or `"Off"` (`sid = "no"`), or adjusting `sub-delay` / `audio-delay` in `dvp/player.lua` mutates mpv's **session-global** properties and is not reset in `on_load` when the next file has no saved `entry.aid` / `entry.sid`.
  * If a user sets Subtitles to **Off** (or picks `sid = 3`) in Video A, and then opens a fresh Video B, `sid` remains `"no"` (or `3`, which may be the wrong language or a non-existent track ID on Video B), breaking `slang` / `subtitles = auto` for the rest of the session. Likewise, any `sub-delay` or `audio-delay` from Video A carries over to Video B.
* **Suggested Fix:** In `on_load` (before applying `entry.aid` / `entry.sid` from `resume.json`), reset `aid` to `"auto"`, `sid` to `cfg:get("playback", "subtitles") == "off" and "no" or "auto"`, `sub-delay` to `0`, and `audio-delay` to `0` (or use `file-local-options/*`).

### 1.4. OpenSubtitles regional language codes fail priority sorting due to case mismatch
* **Location:** `app/share/deckvideoplayer/mpv/scripts/deckplayer/dvp/opensubtitles.lua` (`parse_results` line 212, `rank` lines 229 & 240)
* **Problem:**
  * `OpenSubtitles.languages(slang)` lowercases all language tags (e.g. `pt-BR` → `"pt-br"`).
  * `OpenSubtitles.parse_results` (line 212) stores `language = a.language or ""` without `:lower()`. If the API returns `"pt-BR"` or `"zh-CN"`, `pref[a.language]` in `OpenSubtitles.rank` evaluates to `nil` (fallback rank `99`), losing language-order priority sorting.
* **Suggested Fix:** Normalize `language = (a.language or ""):lower()` in `OpenSubtitles.parse_results`.

### 1.5. Marquee state when menu items change in-place or when closing a menu over the browser
* **Location:** `app/share/deckvideoplayer/mpv/scripts/deckplayer/dvp/ui.lua` (`Marquee:draw` lines 276–280), `dvp/menu.lua` (lines 254, 267), and `main.lua` (lines 217–221)
* **Problems:**
  1. `Menu:render` keys marquee animations by `tostring(spec) .. "#" .. idx` (or `"v"`). When a menu row's text is updated in-place at the same index via `menu:refresh()` or `menu:update(spec, ...)` (e.g., changing the active subtitle track and popping back to the Playback menu), `key == self.key` is still true in `Marquee:draw`, so `self.t0` is not reset for the new text.
  2. In `main.lua` (line 219), the menu `on_close` callback re-renders `player:render()` when `state.screen == "player"`, but does not call `browser:render()` when `state.screen == "browser"`. Because `browser:render()` suppresses its marquee while `menu:is_open()` is true, closing a menu (such as the About panel) over a long filename in the browser leaves its marquee stopped until the cursor moves.
* **Suggested Fix:**
  1. In `Marquee:draw` (`dvp/ui.lua` line 277), check `if key ~= self.key or str ~= self.text then self.key, self.text, self.t0 = key, str, mp.get_time() end`.
  2. In `main.lua` `Menu.new` `on_close`, also call `browser:render()` when `state.screen == "browser"`.

### 1.6. Async subtitle search/download callbacks vs. menu state
* **Location:** `app/share/deckvideoplayer/mpv/scripts/deckplayer/dvp/subdownload.lua` (`SubDownload:open` lines 162–166, `SubDownload:download` lines 216–228)
* **Problems:**
  1. In `SubDownload:open`, if the user closes the `"Download subtitles"` menu with **B** while the search request is still in flight and the request later errors or times out, `self.ctx.menu:update(spec, ...)` returns `false`, yet `self.ctx.toast(err)` still displays an error toast after the user backed out.
  2. In `SubDownload:download`, selecting a subtitle pops the `"Download subtitles"` submenu (`close = true`), leaving the parent **Playback** menu open while the download runs asynchronously. When the download finishes and calls `select_file(dest, title, lang)`, `self.ctx.menu:refresh()` is not called, so the `"Subtitles"` value in the still-open Playback menu stays stale until the user moves the cursor.
* **Suggested Fix:**
  1. Only call `self.ctx.toast(err)` in `SubDownload:open` if `self.ctx.menu:update(...)` returned `true`.
  2. Call `self.ctx.menu:refresh()` after `select_file(dest, title, lang)` in `SubDownload:download`.

### 1.7. `/run/media/<user>` `tmpfs` mount matched as a removable drive
* **Location:** `app/share/deckvideoplayer/mpv/scripts/deckplayer/dvp/library.lua` (`Library.parse_mountinfo` lines 38–51)
* **Problem:**
  `parse_mountinfo` matches any mount point matching `^/run/media/.+` regardless of filesystem type or source (`121 30 8:1 / /run/media/deck rw - tmpfs tmpfs rw`, as seen in `tests/run.lua` line 119). On systems where `/run/media/deck` itself is a `tmpfs` mount point, `parse_mountinfo` returns `/run/media/deck` as a drive (`source = "tmpfs"`), causing `Library:roots()` to list `/run/media/deck` itself as a removable drive named `"deck"` alongside the actual drives inside `/run/media/deck/<label>`.
* **Suggested Fix:** Filter out pseudo-filesystems (e.g. `fstype == "tmpfs"` / `autofs` or mounts whose `source` does not start with `/dev/`) in `parse_mountinfo`.

### 1.8. Minor state resets (`display-fps-override` & `state.resumed_at`)
* **Locations:** `app/share/deckvideoplayer/mpv/scripts/deckplayer/dvp/display.lua` (lines 251–283) and `main.lua` (lines 225–246)
* **Problems:**
  1. **Stale `display-fps-override` during the 2s verification window:** When switching from a 24 fps video (`display-fps-override = 48`) to a 60 fps video, `Display:match()` schedules a 2.0s `verify_timer` before updating `display-fps-override`, leaving `display-fps-override` at `48` for the first 2 seconds of the 60 fps video (or permanently if the helper fails). Reset `mp.set_property_number("display-fps-override", 0)` before starting the new rate change/verification.
  2. **Stale `state.resumed_at` on load failure:** `state.resumed_at` is set in `on_load` when `start == nil` and cleared in `file-loaded`. If a file with a resume entry fails to open (`end-file` before `file-loaded`) and the user next chooses `"Start from beginning"` (`start = 0`), the stale `state.resumed_at` triggers a false `"Resumed at …"` toast. Initialize `state.resumed_at = nil` at the top of `on_load`.

---

## 2. Security, Privacy & Native Helper Robustness (v0.2.0)

### 2.1. OpenSubtitles `Api-Key` header is sent to the file download URL / CDN
* **Location:** `app/share/deckvideoplayer/mpv/scripts/deckplayer/dvp/opensubtitles.lua` (`OpenSubtitles:http` lines 310–321, `OpenSubtitles:download` line 400)
* **Problem:** `OpenSubtitles:http(req, cb)` unconditionally includes `"header = Api-Key: " .. self.api_key` and `"location"` (follow redirects) on every curl invocation, including Step 2 of `OpenSubtitles:download` which downloads the raw `.srt` file from `body.link` (`req.output = tmp`). Because `body.link` is a direct download URL that may live on a CDN or different host (and curl forwards custom `-H` headers across redirects), the user's `Api-Key` should not be attached to the file download request.
* **Suggested Fix:** Only add `Accept: application/json` and `Api-Key: ...` headers when `not req.output`.

### 2.2. `strtol` argument validation in `helper/dvp-gamescope-refresh.c`
* **Location:** `helper/dvp-gamescope-refresh.c` (lines 105–110)
* **Problem:** `long hz = set ? strtol(argv[2], NULL, 10) : 0;` does not inspect `endptr` or check for an empty string. Passing a non-numeric `argv[2]` silently parses as `0` (which the protocol treats as "reset to native") instead of failing with exit code `2`.
* **Suggested Fix:** Pass `&end` to `strtol` and reject `argv[2][0] == '\0' || *end != '\0'`.

---

## 3. Release Readiness & Metadata Mismatches (v0.2.0)

### 3.1. AppStream Metainfo still lists only `0.1.0`
* **Location:** `packaging/flatpak/io.github.nicocarbone.DeckVideoPlayer.metainfo.xml` (lines 18–35)
* **Problem:** `dvp/version.lua` is bumped to `"0.2.0"`, but `io.github.nicocarbone.DeckVideoPlayer.metainfo.xml` only has `<release version="0.1.0" date="2026-10-23"/>` and its feature list `<ul>` does not mention headphone surround or OpenSubtitles subtitle downloads.

### 3.2. Status docs still mark v0.2.0 as "in progress"
* **Location:** `AGENTS.md` (lines 76–80) and `docs/ROADMAP.md` (lines 26–38)
* **Problem:** Both files still describe v0.2.0 as `(next — in progress)`.

---

## 4. v0.2.0 Summary Checklist

Resolution (reviewed by Claude on 2026-10-23; reasoning in `docs/DECISIONS.md` D35):

- [x] **Bug (`dvp/menu.lua`):** Fixed (+0.5 slack in the scroll decision).
- [x] **Bug (`dvp/subdownload.lua`):** Fixed: `<release> #<file_id>.<lang>.srt`; titles strip the id.
- [x] **Bug (`main.lua`, `dvp/player.lua`):** Reproduced and fixed: `aid`, `sid`, `sub-delay`, `audio-delay` are file-local defaults in `on_load`, before the resume.json choice.
- [x] **Bug (`dvp/opensubtitles.lua`):** Fixed (language lowercased in `parse_results`).
- [x] **Bug (`dvp/ui.lua`, `main.lua`):** Fixed (marquee restarts on text change; library re-renders when a menu over it closes).
- [x] **Bug (`dvp/subdownload.lua`):** Fixed (toast only while the menu is open; `menu:refresh()` after a download). Note: the stale Playback-menu case can't occur today because opening a submenu pops its parent; the refresh is kept as a safeguard.
- [x] **Bug (`dvp/library.lua`):** Fixed by filesystem type (`tmpfs`, `autofs`, …). Not adopted: dropping non-`/dev/` sources, which would hide network mounts under `/media`.
- [x] **Bug (`dvp/display.lua`, `main.lua`):** Fixed (both resets).
- [x] **Security (`dvp/opensubtitles.lua`):** Fixed (`Api-Key`/`Accept` only on API calls, not on the file download).
- [x] **Robustness (`helper/dvp-gamescope-refresh.c`):** Fixed (`endptr` checked; non-numeric rates rejected).
- [x] **Release metadata:** metainfo has the 0.2.0 release and new features. ROADMAP/AGENTS status is updated in the release commit.

---
---

# Part I — v0.1.0 Audit (Resolved 2026-10-23)

Overall, the architecture of **Deck Video Player** is remarkably clean, focused, and well-suited to its constraints. Running a single `mpv` process with an ASS vector OSD UI (`vo=gpu-next` + `x11vk` + gamescope WSI layer) is the ideal way to preserve zero-copy VA-API hardware decoding and real HDR10 passthrough under SteamOS Game Mode without toolkit overhead. The strict rule against running timers while the overlay is hidden is also great for battery life.

Below are the bugs, functional edge cases, and missing optimizations identified during the v0.1.0 audit.

---

## 1. Bugs & Functional Edge Cases (v0.1.0)

### 1.1. `"Go to library start"` menu item & SD/USB hotplugging in single-source mode
* **Location:** `app/share/deckvideoplayer/mpv/scripts/deckplayer/dvp/browser.lua` (`Browser:load` lines 41–68, `Browser:open_menu` lines 169–201)
* **Problems:**
  1. **Missing menu option in single-source mode:** In `Browser:open_menu()`, `"Go to library start"` is only added when `#self.stack > 0 and self.sources and #self.sources > 1`. When a user has only one source configured (e.g., the default `~/Videos`), `Browser:load()` auto-enters that source (`self.stack[1] = {..., is_root = true}`). If the user navigates several subfolders deep (e.g., `~/Videos/Series/Show/Season 1`), `"Go to library start"` never appears in the menu because `#self.sources == 1`.
  2. **Dead variable `self.root_forced`:** Line 47 checks `if #self.sources == 1 and not self.root_forced then`, but `self.root_forced` is never assigned anywhere in the codebase.
  3. **Removable media hotplug + `"Reload library"` doesn't refresh sources:** If the app starts with only 1 source (`~/Videos`) and the user later inserts a microSD card or USB drive and selects **"Reload library"** from the menu, `self:load()` sees that `self:location()` is non-nil (`~/Videos` with `is_root = true`) and only re-reads `~/Videos` without calling `library.sources(self.cfg)`. Even worse, pressing **B** at `~/Videos` triggers the Quit dialog (`if loc.is_root and #self.stack == 1`) instead of backing out to the newly available sources list.
* **Suggested Fix:**
  * In `"Reload library"`, re-evaluate `self.sources = library.sources(self.cfg)` and update `self.stack[1].is_root = (#self.sources == 1)`.
  * Show `"Go to library start"` whenever `#self.stack > 1` (resetting to `self.stack = {}` and reloading) or when `#self.stack == 1 and not self.stack[1].is_root`.

### 1.2. Binary VDF serializer crashes on 64-bit integers (`0x07`)
* **Location:** `scripts/steam_shortcut.py` (`vdf_load` lines 44–62, `vdf_dump` lines 65–79)
* **Problem:** `vdf_load` supports type `0x07` (unsigned 64-bit integer, `struct.unpack_from("<Q", ...)`), which becomes a standard Python `int`. However, `vdf_dump` serializes **every** `isinstance(value, int)` as type `0x02` (`struct.pack("<i", value)` — signed 32-bit integer). If a user's `shortcuts.vdf` contains a `0x07` field (or any integer outside `-2147483648..2147483647` added by Steam or another tool), `vdf_dump` will crash with `struct.error: 'i' format requires -2147483648 <= number <= 2147483647`.
* **Suggested Fix:** Wrap `0x07` values in a small `int` subclass (e.g. `class UInt64(int): pass`) during `vdf_load` so `vdf_dump` can write them back losslessly with `b"\x07" + k + struct.pack("<Q", value)`.

### 1.3. Picture / Zoom mode (`fill` / `stretch`) is not reset or synced with `mpv`
* **Location:** `app/share/deckvideoplayer/mpv/scripts/deckplayer/dvp/player.lua` (`Player.new` line 25, `Player:set_zoom` lines 240–244)
* **Problem:** `self.zoom` starts as `"fit"`, and `Player:set_zoom(mode)` sets mpv's global `panscan` and `keepaspect` properties.
  * If a user sets `Picture` to `Fill` or `Stretch` on one video, stops playback, and plays another video, it stays cropped/stretched (or if the user set `panscan` in `~/.config/deckvideoplayer/mpv.conf`, `self.zoom` is out of sync).
* **Suggested Fix:** Either reset `self:set_zoom("fit")` in `Player:stop_screen()` (or use `file-local-options/panscan` and `file-local-options/keepaspect`), or derive the current zoom mode directly from mpv's `panscan` and `keepaspect` properties.

### 1.4. Command-line / `.desktop` file argument edge cases
* **Location:** `packaging/flatpak/io.github.nicocarbone.DeckVideoPlayer.desktop` (`Exec=deckvideoplayer %F`), `app/share/deckvideoplayer/mpv/scripts/deckplayer/main.lua` (lines 217–285)
* **Problem:** When a video file is passed directly to `deckvideoplayer` via CLI or file association:
  1. `start-file` switches `state.screen = "player"`, bypassing `browser:show()`.
  2. `on_load` silently auto-resumes from the saved position (`start == nil and cfg.playback.resume`), whereas opening a file in the UI prompts `"Resume playback?"`.
  3. When the file finishes or the user presses **B** (Stop), `idle-active` transitions to `true` and calls `browser:show()` + `browser:select_path(state.last_played)`. If the file was outside the configured library root, the user is dropped into the top-level library browser instead of either the file's directory or exiting.

### 1.5. `sed` delimiter collision in dev/test scripts
* **Location:** `scripts/dev-run.sh` (line 36) and `tools/headless-run.sh` (lines 46–49)
* **Problem:**
  ```sh
  sed -i "s|^folder = .*|folder = $media|" "$DVP_CONFIG_DIR/config.ini"
  ```
  If the workspace path (`$root` or `$media`) contains `&` (which `sed` expands to the matched LHS) or `|`, the `config.ini` replacement corrupts the path or fails.

---

## 2. Missing Optimizations (Performance & Battery) (v0.1.0)

### 2.1. Unnecessary `stat()` (`utils.file_info`) on every file before checking extensions
* **Location:** `app/share/deckvideoplayer/mpv/scripts/deckplayer/dvp/library.lua` (`library.list` lines 83–105)
* **Problem:**
  ```lua
  local names, err = utils.readdir(path, "all")
  ...
  for _, name in ipairs(names) do
      if cfg.library.show_hidden or name:sub(1, 1) ~= "." then
          local full = util.join(path, name)
          local info = utils.file_info(full)
          if info then
              if info.is_dir then ...
              elseif info.is_file and exts[util.extension(name)] then ...
  ```
  `library.list` calls `utils.file_info(full)` (`stat()`) on **every single entry** in a directory before checking whether the filename even has a video extension. If a folder (e.g. `~/Downloads` or a slow microSD / USB drive) has 2,000 non-video files (subtitles, images, archives), it performs 2,000 unnecessary `stat()` calls.
* **Optimization:**
  * Use `utils.readdir(path, "dirs")` and `utils.readdir(path, "files")` (supported by `mp.utils.readdir`), or when `sort_mode == "name"` (the default), filter files by `exts[util.extension(name)]` **before** calling `utils.file_info(full)` (in fact, when sorting by `"name"`, `mtime` and `size` aren't even used, so `utils.file_info` isn't needed at all if `readdir` separates `"dirs"` and `"files"`!).

### 2.2. Redundant `chapter-list` and `track-list` marshaling on every 0.5s overlay tick
* **Location:** `app/share/deckvideoplayer/mpv/scripts/deckplayer/dvp/player.lua` (`Player:render` lines 344–442) and `dvp/media.lua` (`media.hdr_state` lines 113–130)
* **Problem:** While the playback overlay is visible (including the entire time a video is paused), `Player:tick()` runs every 0.5 seconds and calls `Player:render()`. Inside `render()`:
  1. `mp.get_property_native("chapter-list")` is called **twice** in the same function (line 400 for chapter tick marks, and line 417 for the current chapter title), marshaling the entire chapter table from C to Lua twice per tick.
  2. `self:badges()` calls `media.hdr_state()`, which calls `media.selected_track("video")`, which calls `mp.get_property_native("track-list")` — marshaling all audio, subtitle, and video track metadata across C/Lua every 0.5s just to check `vt["dolby-vision-profile"]`.
  3. `self:title()` re-queries `mp.get_property("path")` and runs string regexes every 0.5s.
* **Optimization:**
  * At minimum, fetch `chapter-list` once into a local variable in `Player:render()`.
  * Better yet, cache `title`, `chapter-list`, and Dolby Vision track presence on `file-loaded` (or via `mp.observe_property`), since they do not change every 0.5s.

### 2.3. Opening and closing a new X11 connection on every refresh-rate call
* **Location:** `app/share/deckvideoplayer/mpv/scripts/deckplayer/dvp/display.lua` (`with_display` lines 65–73)
* **Problem:** Every call to `get_root_cardinal` or `set_root_cardinal` calls `XOpenDisplay(nil)`, `XInternAtom(...)`, and `XCloseDisplay(dpy)`. On the first video load, `Display:match()` calls `get_root_cardinal` (open + intern + get + close) immediately followed by `set_root_cardinal` (open + intern + change + flush + close).
* **Optimization:** Cache the `Display*` pointer, default root `Window`, and interned `GAMESCOPE_DYNAMIC_REFRESH` `Atom` in `X` across the lifetime of the script (or combine the read-and-set into one `with_display` session).

### 2.4. Spawning `mpv --list-options` on every startup in the Flatpak
* **Location:** `app/bin/deckvideoplayer` (lines 66–68)
* **Problem:**
  ```sh
  if "$MPV" --list-options 2>/dev/null | grep -q -- '--input-gamepad '; then
      set -- --input-gamepad=yes "$@"
  fi
  ```
  Every launch spawns a subshell, loads the `mpv` binary and all of its shared libraries (FFmpeg, Vulkan, libplacebo, SDL2, etc.), prints all options, and pipes them to `grep` before `exec`ing `mpv` a second time.
* **Optimization:** Inside the Flatpak (`[ -f /.flatpak-info ]`), `mpv` is guaranteed to be built with `-Dsdl2-gamepad=enabled`. Checking `if [ -f /.flatpak-info ] || "$MPV" --list-options ...` skips the extra process spawn in production while keeping the fallback for development with system `mpv`.

---

## 3. v0.1.0 Summary Checklist

Resolution (reviewed by Claude on 2026-10-23; reasoning in `docs/DECISIONS.md`):

- [x] **Bug (`dvp/browser.lua`):** Fixed. Sources are re-read on show/reload/root, single-source top folder is demoted when a drive appears, "Go to library start" shown whenever not at the top, dead `root_forced` removed (D23).
- [x] **Bug (`scripts/steam_shortcut.py`):** Fixed, together with a more serious related bug: the file was truncated *before* serialisation, so any error erased all non-Steam shortcuts. Now serialise → temp file → atomic replace, `.bak` on add and remove, `0x07` kept as `UInt64`; covered by `tests/test_steam_shortcut.py` (D22).
- [x] **Bug (`dvp/player.lua`):** Fixed. Picture mode is per file and the label is derived from mpv's properties (D20).
- [x] **Bug (`main.lua`):** Fixed. External launches auto-resume with a "Resumed at …" toast and quit when playback ends (D21).
- [x] **Bug (`scripts/dev-run.sh`, `tools/headless-run.sh`):** Fixed. `\`, `&` and `|` are escaped in the sed replacement.
- [ ] ~~**Optimization (`dvp/library.lua`):**~~ Not adopted: mpv's filtered `readdir` stats every entry itself, so the suggestion would double `stat()` calls; one stat per entry is the minimum (D24).
- [x] **Optimization (`dvp/player.lua`):** Done. Title, video track and chapter list are cached per file (D25).
- [ ] ~~**Optimization (`dvp/display.lua`):**~~ Not adopted: about two calls per file load, so a persistent connection adds risk for no measurable gain (D24).
- [x] **Optimization (`app/bin/deckvideoplayer`):** Done. The probe is skipped when `/.flatpak-info` exists (D26).
