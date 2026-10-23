# Code Audit: Findings & Optimization Opportunities

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
