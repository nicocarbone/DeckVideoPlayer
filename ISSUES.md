# Code Audit: Findings & Optimization Opportunities

**Status review (2026-11-22, v0.9.4 work):** every finding in Parts I–XIV was checked
against the code. Each has a **Status** line: *Solved*, *Partly solved*
(the rest declined, with the reason), *Not solved (declined)* with the
reason, *Accepted (by design)*, or *Not a bug* (the finding doesn't match the code). The reasoning for each part is in
`docs/DECISIONS.md` (Part I: D20–D26, II: D35, III: D39, IV: D40, V: D45,
VI: D49, VII: D53, VIII: D59, IX: D68, X: D70, XI: D78, XII: D80, XIII: D85,
XIV: D92).

---

# Part XIV — v0.9.1–v0.9.4 Audit: HDR Format Selection, Online Stream Quality, Trigger Debouncing & Playlist Cache (2026-11-22)

All `1116` Lua checks and `17` Python tests in `tests/run.sh` pass. The point releases since `v0.9.0` (`D86`–`D91`: `dvp/online.lua`, `dvp/player.lua`, `dvp/videomemory.lua`, `dvp/memory.lua`, `dvp/input.lua`, `dvp/browser.lua`, `dvp/config.lua`, `main.lua`, `.github/workflows/build.yml`, and `.github/workflows/update-yt-dlp.yml`) were audited and tested against `yt-dlp 2026.03.17` and `mpv v0.41.0`:
* **CI actions on Node.js 24 (D87):** all four updated action pins (`actions/checkout`, `flatpak/flatpak-github-actions/flatpak-builder`, `actions/download-artifact`, `softprops/action-gh-release`) use full 40-character commit SHAs and retain minimal workflow permissions (`contents: read` default, elevated per job only where needed).
* **Analog trigger debouncing (`dvp/input.lua`, D90):** `M.trigger_pull` uses independent per-trigger state tables, monotonic `mp.get_time()`, and properly updates `st.last` on `up`/`repeat` events without blocking the opposite trigger or delaying the first pull. No issues found.
* **Security / vulnerability check:** no new injection, sandbox-escape, or secret-handling issues were introduced in `v0.9.1`–`v0.9.4`; `VideoMemory.normalize` validates stored `quality` values strictly against `config.STREAM_QUALITIES`.

Below are the verified bugs, optimization opportunities, and pre-release items found in `v0.9.1`–`v0.9.4`.

---

## 1. Functional Bugs (`dvp/online.lua`, `dvp/player.lua`, `main.lua`)

### 1.1. `dvp/online.lua` (v0.9.1, D86): `M.format_spec` (`bv+ba/bv*+ba/b`) fails with *"No playable format"* on silent video-only streams

* **Severity:** Medium (Bug)
* **Location:** `app/share/deckvideoplayer/mpv/scripts/deckplayer/dvp/online.lua` (`M.format_spec`, lines 377–384)
* **Problem:**
  ```lua
  local format = "bv+ba/bv*+ba/b"
  if deck and height > 1080 then
      format = "bv[vcodec!^=av01]+ba/bv*[vcodec!^=av01]+ba/b[vcodec!^=av01]/" .. format
  end
  ```
  In `yt-dlp`, `bv+ba` and `bv*+ba` require a separate audio-only stream (`ba`), and `b` only matches combined streams containing **both** video and audio. For any video that has only a video-only stream and no audio track (`acodec = "none"`, e.g. silent clips on YouTube/Vimeo/Reddit or muted embeds), `yt-dlp` selects nothing and fails with `"No playable format for this video"`.
  Verified directly against `yt_dlp.YoutubeDL.build_format_selector`:
  * `bv+ba/bv*+ba/b` and the Deck `> 1080` variant both return `[]` on a `1080p` video-only stream (`vcodec = 'avc1.640028', acodec = 'none'`).
  * Appending `/bv` (`bv+ba/bv*+ba/b/bv`) selects the stream (`['137']`).
  *(Note: on a site offering both a low-resolution video-only + audio-only pair and a higher-resolution combined stream, `bv+ba` also takes precedence over `b`, verified `['vo360+ao']` over `comb1080`, which is an expected trade-off of D86 for multi-audio YouTube HDR.)*
* **Suggested Fix:** Append `/bv` (or `/b*`) as the final fallback in `M.format_spec` (and `/bv[vcodec!^=av01]` before the AV1 fallback on a Deck above 1080p).


> **Status: Solved** (D92). Confirmed with yt-dlp's own `build_format_selector` (2026.10.26) on made-up format lists: a video with only video streams matched nothing. Now `bv+ba/bv*+ba/b/bv`, and `bv[vcodec!^=av01]` before the AV1 fallback on a Deck above 1080p (such a video gets VP9 there). Normal, combined-only and generic (unknown codec) format lists choose what they chose before. The gap dated from v0.9.0 (`bv*+ba/b`). Unit tests.

---

### 1.2. `dvp/online.lua` & `main.lua` (v0.9.2, D88/D89): `Online.stream_height(0)` returns `360` (360p) instead of falling back to `1080`

* **Severity:** Medium (Bug)
* **Location:**
  * `app/share/deckvideoplayer/mpv/scripts/deckplayer/dvp/online.lua` (`M.stream_height` lines 342–350, `M.quality_label` lines 354–357)
  * `app/share/deckvideoplayer/mpv/scripts/deckplayer/main.lua` (`on_load` priority 5, line 414)
* **Problem:**
  ```lua
  function M.stream_height(screen_h, quality)
      local n = tonumber(quality)
      if n then return n end
      screen_h = tonumber(screen_h) or 1080
      for _, h in ipairs(HEIGHTS) do
          if h >= screen_h * 0.95 then return h end
      end
      return 2160
  end
  ```
  In Lua, `0` is truthy, so `tonumber(0) or 1080` evaluates to `0`, and `HEIGHTS[1]` (`360 >= 0`) matches immediately. `main.lua` line 414 passes `mp.get_property_number("osd-height")` directly (unlike `main.lua` line 610, which explicitly guards `(d.h or 0) > 0` before updating `online.screen_h`). Whenever `osd-height` is `0` (e.g. before the window is sized), streaming silently picks **360p** and the menu shows `"Auto (360p)"`.
  Verified in `mpv`: `Online.stream_height(0)` → `360`, `Online.stream_height(0, "auto")` → `360`, `Online.quality_label("auto", 0)` → `"Auto (360p)"` (whereas `nil` returns `1080` / `"Auto (1080p)"`).
* **Suggested Fix:** Treat non-positive heights as unknown: `screen_h = tonumber(screen_h); if not screen_h or screen_h <= 0 then screen_h = 1080 end` (and optionally fall back to `self.screen_h` in `Online:stream_options`).


> **Status: Solved** (D92). An unknown or non-positive height counts as 1080 in `stream_height` (so also in `quality_label`). Not seen in use (the window is sized before a video plays), but the guard is free. Unit tests.

---

### 1.3. `dvp/online.lua` (v0.9.2, D89): *Video info* from *Recently played* ignores the list's remembered *Quality*

* **Severity:** Medium (Bug)
* **Location:**
  * `app/share/deckvideoplayer/mpv/scripts/deckplayer/dvp/online.lua` (`M.recent_ref` lines 330–332, `M:video_info` line 1157)
  * `app/share/deckvideoplayer/mpv/scripts/deckplayer/dvp/memory.lua` (`M.list_key`, lines 46–52)
* **Problem:**
  Entries in *Recently played* carry `ref = Online.recent_ref("web", url)`, which sets `parent = nil` even when `self.data.lists[url]` knows which `.m3u` list or playlist the video was played from. When the user presses **View** (*Video info*) on a *Recently played* online video, `Online:video_info(ref, cb)` calls `self:stream_format(self.screen_h, ref)` → `Memory.list_key(ref)`, which falls back to `online:web:item:<url>` instead of `online:web:list:<list_path>`.
  Verified in `mpv`: after setting Quality to `1440` for a list, `on:quality_for(list_item)` returns `"1440"`, while `on:quality_for(Online.recent_ref("web", url))` returns `"auto"` (even with `on.data.lists[url] = list_path` set). As a result, *Video info* reports the wrong resolution/codec compared to what playback (via `Online:resolve`, which restores `parent`) will actually play.
* **Suggested Fix:** In `Online:video_info` (or `Online:quality_for`), when `ref.parent` is nil and `self.data.lists[ref.key]` exists, pass a ref with `parent = self.data.lists[ref.key]` (or look up `self.data.lists[item.key]` inside `quality_for`).


> **Status: Solved** (D92). `quality_for` takes the list a ref without one was last played from (`data.lists`), as playback does; the ref itself is left alone. Unit tests.

---

### 1.4. `dvp/player.lua` & `main.lua` (v0.9.2, D89): Changing *Quality* while a video is still opening shows the toast and saves the setting, but `ctx.reopen()` silently does nothing

* **Severity:** Low–Medium (Bug)
* **Location:**
  * `app/share/deckvideoplayer/mpv/scripts/deckplayer/dvp/player.lua` (`M:online_item` lines 774–779, `M:set_quality` lines 800–807)
  * `app/share/deckvideoplayer/mpv/scripts/deckplayer/main.lua` (`ctx.reopen`, lines 342–347)
* **Problem:**
  After `start-file` fires (while `"Opening…"` is shown and `yt-dlp` is still fetching the stream), `state.screen` is `"player"`, `mp.get_property("path")` is already `"ytdl://..."`, and `player:online_item()` returns the item — so the user can open **Menu → Video → Quality** and pick a new quality before `file-loaded` arrives. `set_quality` stores the choice in `videomemory` and shows the 3 s toast `"Quality: 1440p for this list"`, then calls `ctx.reopen()`. Because `state.current_path` is only set in `file-loaded` (line 531), `ctx.reopen()` sees `state.current_path == nil` and returns immediately, leaving the current video loading at the old quality and the Video menu open.
* **Suggested Fix:** In `ctx.reopen`, fall back to `state.loading_path` when `state.current_path` is nil (only storing `state.pending_start[path] = mp.get_property_number("time-pos")` when `state.current_path` is already loaded), or hide/disable *Quality* while `self.opening` is true.


> **Status: Solved** (D92), with the second suggestion: *Quality* is left out of the Video menu while the video is opening (`online_item()` is nil while `opening`), and an open Video menu gains it when the file loads (checked in headless gamescope with real YouTube). Reopening a video that is still opening was not done: its start position has already been taken in the `on_load` hook.

---

### 1.5. `dvp/online.lua` (v0.9.4, D91): `playlist_links` returns empty `name` for `j.title == ""`, and `list_playlist` persists `fallback_label(url)` into `online.json` when `j.title` is missing

* **Severity:** Medium (Bug)
* **Location:** `app/share/deckvideoplayer/mpv/scripts/deckplayer/dvp/online.lua` (`M.playlist_links` lines 498–500, `M:list_playlist` lines 841–842)
* **Problems:**
  1. Line 499 checks `type(j.title) == "string" and j.title or M.fallback_label(url)` without trimming or checking `~= ""` (unlike line 509 for item titles). Verified: `{title = ""}` yields `listing.name = ""` and `{title = "   "}` yields `listing.name = "   "`, which also propagates as an empty `item.show`.
  2. When `j.title` is `nil` (missing from yt-dlp's JSON), `listing.name` falls back to `M.fallback_label(url)` (e.g. `"YouTube playlist PL12345"`), and line 842 unconditionally passes `listing.name` to `self:learned(url, listing.name, listing.channel)` — permanently writing the fallback placeholder string into `online.json` `data.titles[url]` as a learned title.
* **Suggested Fix:** Trim `j.title` in `M.playlist_links` and keep a separate `title` field (`title = trimmed ~= "" and trimmed or nil`, `name = title or M.fallback_label(url)`), calling `self:learned(url, listing.title, listing.channel)` only when `listing.title` is non-nil.


> **Status: Solved** (D92). `playlist_links` trims the title and keeps it apart (`title`, nil without one; `name` = title or the label from the link); only a real title is learned. Unit tests.

---

### 1.6. `dvp/online.lua` (v0.9.4, D91): `keep_listing` pins stale future-dated entries after a backward clock jump, evicting fresh playlists instead

* **Severity:** Low (Bug)
* **Location:** `app/share/deckvideoplayer/mpv/scripts/deckplayer/dvp/online.lua` (`M:keep_listing`, lines 864–873)
* **Problem:**
  `M.listing_fresh(kept, now)` correctly rejects entries with `kept.t > now` (handling a clock set backward, e.g. NTP correcting a fast RTC after boot). However, `M:keep_listing` evicts purely by minimum `l.t` (`l.t < self.listings[oldest].t`) without purging expired/unfresh entries first.
  Verified in `mpv`: caching one playlist at `t = 2000000000`, moving the clock back to `1795000000`, and caching 20 fresh playlists kept the stale future-dated entry (`FUTURE_IS_FRESH = false`, `FUTURE_STILL_KEPT = true`) while evicting a fresh playlist instead.
* **Suggested Fix:** In `M:keep_listing`, remove any entry where `not M.listing_fresh(l, now)` before counting/evicting the oldest remaining entry.


> **Status: Solved** (D92). `keep_listing` drops listings that are no longer fresh (a future one included) before removing the oldest. A unit test fails without it.

---

## 2. Optimization Opportunities & Pre-Release Bookkeeping

### 2.1. `dvp/online.lua` & `dvp/browser.lua` (v0.9.4, D91): Duplicate in-flight `list_playlist` calls and double `browser:render()` on cache hits

* **Severity:** Low (Optimization)
* **Location:**
  * `app/share/deckvideoplayer/mpv/scripts/deckplayer/dvp/online.lua` (`M:list_playlist`, lines 826–850)
  * `app/share/deckvideoplayer/mpv/scripts/deckplayer/dvp/browser.lua` (`M:load_server` lines 232–250, `M:show` lines 297–307, `M:reload` lines 309–316, `M:enter` lines 345–351, `M:go_back` lines 353–374)
* **Notes:**
  1. **Coalescing in-flight playlist fetches:** If a user opens an uncached playlist, backs out before `yt-dlp --flat-playlist -J` finishes (1–3+ s), and opens it again (or plays a video from *Recently played* while it is loading), `list_playlist` spawns a second concurrent `yt-dlp` subprocess for the exact same `url` instead of attaching the new callback to the in-flight request (or aborting the old one).
  2. **Double render on cache hits:** When `self:kept_listing(url)` hits, `list_playlist` invokes `cb(entries)` synchronously inside `Browser:load_server()`, which runs `select_path` and `self:render()`, and then `Browser:show()` / `reload()` / `enter()` / `go_back()` immediately calls `select_path` (when `not self.loading`) and `self:render()` a second time in the same tick. Checking `if not self.loading` or skipping the redundant render in `load_server` avoids drawing the browser OSD twice per cached navigation.


> **Status: Not solved (declined)** (D92). (1) Only when a playlist is left and opened again while its first listing runs (a second or two); both answers are good and the later one is kept. Sharing one run between callers with their own callbacks and `quiet` flags is more code than the extra run costs. (2) Two updates of the same overlay in one call, on a button press; mpv draws once in its next loop and nothing runs while idle. Changing the library's listing flow for it would risk its cursor handling.

---

### 2.2. Pre-Release Bookkeeping (`v0.9.4`)

* **Severity:** Info
* **Location:**
  * `CHANGELOG.md` line 8 (`## v0.9.4 (unreleased)`) vs `app/share/deckvideoplayer/mpv/scripts/deckplayer/dvp/version.lua` (`"0.9.3"`) and `packaging/flatpak/io.github.nicocarbone.DeckVideoPlayer.metainfo.xml` (latest `<release>` is `0.9.3`).
* **Note:** Bump `version.lua`, add `<release version="0.9.4">` to `metainfo.xml`, and date `CHANGELOG.md` when tagging `v0.9.4`.


> **Status: Accepted (by design)**. Done at the v0.9.4 tag, as for every release (`docs/DEVELOPMENT.md` §7; `tests/run.sh` checks the CHANGELOG section and the metainfo `<release>`).

---

## 3. v0.9.1–v0.9.4 (Part XIV) Summary Checklist

> Done in D92, except the two optional items of 2.1 (declined, see there); *Quality* is left out while a video opens rather than reopened; the release bookkeeping is done when tagging.

- [x] **Format Selection (`dvp/online.lua`, v0.9.1):** Add `/bv` (or `/b*`) fallback in `M.format_spec` so silent video-only streams don't fail with *"No playable format"*.
- [x] **Streaming Quality (`dvp/online.lua`, `dvp/player.lua`, `main.lua`, v0.9.2):** Treat `screen_h <= 0` as unknown (`1080`) in `M.stream_height`; resolve `self.data.lists[ref.key]` as `parent` in `Online:video_info` / `quality_for` so *Video info* from *Recently played* uses the list's remembered Quality; handle `ctx.reopen()` (or guard *Quality*) when called while a video is still opening (`state.current_path == nil`).
- [x] **Playlist Cache (`dvp/online.lua`, `dvp/browser.lua`, v0.9.4):** Trim `j.title` in `M.playlist_links` and keep real `title` separate from `fallback_label(url)` so empty titles fall back properly and missing titles aren't persisted to `online.json`; purge non-fresh entries in `M:keep_listing` before evicting by oldest `t`; optionally coalesce duplicate in-flight `list_playlist` runs and avoid double-rendering on synchronous cache hits.
- [x] **Release Bookkeeping (`v0.9.4`):** Update `dvp/version.lua`, `metainfo.xml`, and `CHANGELOG.md` when tagging `v0.9.4`.

---

# Part XIII — v0.9.0 Audit: Online Videos (`.m3u` Lists, yt-dlp, Cookies & Downloads) (2026-11-19)

All `1008` Lua checks and `17` Python tests in `tests/run.sh` pass. The v0.9.0 online video implementation (`D84`: `dvp/online.lua`, `dvp/downloads.lua`, `dvp/videoinfo.lua`, `dvp/browser.lua`, `dvp/library.lua`, `dvp/player.lua`, `main.lua`, `mpv.conf`, `scripts/update-yt-dlp.py`, `.github/workflows/update-yt-dlp.yml`, and the Flatpak manifest) was audited and tested live against `mpv v0.41.0`, `yt-dlp 2026.03.17`, and `ffprobe`:
* **yt-dlp confinement & protocol safety (`mpv.conf`, `dvp/online.lua`):** `ytdl_hook-exclude=.` with `ytdl_hook-include=` and `ytdl_hook-try_ytdl_first=no` keeps non-`ytdl://` streams away from `ytdl_hook`; HTML `<video src="file://...">` embeds are blocked by both `mpv`'s `ytdl_hook` (`Ignoring potentially unsafe url`) and `yt-dlp` downloads (`file:// URLs are disabled by default`); `mp.set_property_native("ytdl-raw-options", raw)` handles commas and `=` in paths cleanly; `VideoInfo.probe_url` (`-protocol_whitelist http,https,tcp,tls`) succeeds on both HTTP HLS (`.m3u8`) and DASH (`.mpd`) streams.
* **CI updater (`.github/workflows/update-yt-dlp.yml`, `scripts/update-yt-dlp.py`):** GitHub Actions are SHA-pinned, `build.yml` has `workflow_dispatch`, `TAG_RE` validates release tags strictly, and `update-yt-dlp.py` verifies the zipapp against `SHA2-256SUMS` without attaching `GITHUB_TOKEN` to release downloads.

Below are the verified security/concurrency issues, functional bugs, optimization opportunities, and pre-release items found in v0.9.0.

---

## 1. Security, Privacy & Concurrency (`dvp/online.lua`, `main.lua`)

### 1.1. `dvp/online.lua` & `main.lua`: Shared per-purpose cookie files race across concurrent `yt-dlp` runs, and `online-cookies-play.txt` leaks on quit

* **Severity:** High (Security / Privacy / Concurrency Bug)
* **Location:**
  * `app/share/deckvideoplayer/mpv/scripts/deckplayer/dvp/online.lua` (`M:cookies` lines 521–528, `M:ytdlp` lines 532–543, `M:stream_options` / `M:stream_done` lines 548–562, `M:list_playlist` line 654, `M:fetch_titles` line 765, `M:video_info` line 905, `M:download_info` line 928)
  * `app/share/deckvideoplayer/mpv/scripts/deckplayer/main.lua` (`shutdown` lines 607–614)
* **Problems:**
  1. **Concurrent deletion and clobbering of the same cookie copy:** `M:cookies(purpose)` always writes to the fixed path `<data_dir>/online-cookies-<purpose>.txt` (via `util.write_private` → `copy .. ".tmp"`). Multiple concurrent `yt-dlp` runs routinely share the same `purpose`:
     * `M:fetch_titles` spawns every 15-link batch simultaneously with `purpose = "titles"`, and `M:list_playlist` also uses `"titles"`.
     * `M:video_info` and `M:download_info` both use `purpose = "info"`.
     When the faster run exits, `M:ytdlp` line 540 runs `os.remove(cookies)` while the slower run is still using (or about to write back via `save_cookies()`) that exact file. Verified live in `mpv` with two concurrent `on:ytdlp(..., "titles", ...)` calls (`0.05 s` and `0.35 s`): the fast run saw `EXISTS:0.05` and deleted the file before the slow run checked it (`MISSING:0.35`), causing `yt-dlp` to lose cookies or fail with `FileNotFoundError` in `save_cookies()` (and risking re-creating an unremoved file on disk if `save_cookies()` writes after the other run deleted it). Concurrent calls also race on `copy .. ".tmp"` inside `util.write_file_atomic`.
  2. **`online-cookies-play.txt` leaks on quit and crashes:** While `mpv` invokes completion callbacks for async `yt-dlp` subprocesses on graceful quit (cleaning up `titles`/`download` copies), `main.lua`'s `shutdown` handler (lines 607–614) does not call `online:stream_done()`, and `Online.new` never sweeps stale copies from a prior crash or SteamOS force-close. Verified live in `mpv`: quitting after `online:stream_options(1080)` left `online-cookies-play.txt` (`mode 600`) on disk.
* **Suggested Fix:**
  * Give every `M:cookies(purpose)` call a unique filename using a monotonic sequence counter (e.g. `online-cookies-<purpose>-<seq>.txt`) so no two runs ever share a cookie copy or `.tmp` path.
  * Call `online:stream_done()` in `main.lua`'s `shutdown` handler, and remove any leftover `online-cookies-*.txt` files in `Online.new` on startup.


> **Status: Solved** (D85). Confirmed. Each yt-dlp run now gets a copy of its own (`online-cookies-<purpose>-<instance>-<n>.txt`); copies of runs still going when the app closes are deleted at shutdown (`Online:shutdown`, the playback copy included), and copies a crash left behind are deleted at the next start (never the user's own file). Tested in mpv with two overlapping runs (0.05 s and 0.35 s: each still had its copy at the end, both gone afterwards), and by quitting while a yt-dlp video was opening (no copy left).

---

### 1.2. `dvp/online.lua`: `fetch_titles` spawns unbounded concurrent `yt-dlp` processes, runs unnecessarily during *Recently played* playback, and withholds all title updates until the slowest batch finishes

* **Severity:** High (Resource Exhaustion / Performance Bug)
* **Location:**
  * `app/share/deckvideoplayer/mpv/scripts/deckplayer/dvp/online.lua` (`M.common_args` line 354, `M:list` lines 644–645, `M:list_playlist` lines 676–677, `M:fetch_titles` lines 712–784, `M:resolve` line 801)
  * `app/share/deckvideoplayer/mpv/scripts/deckplayer/dvp/browser.lua` (`M:download_season` line 603)
* **Problems:**
  1. **Unbounded `yt-dlp` concurrency:** While YouTube oEmbed requests are capped at `OEMBED_JOBS = 4` (lines 749–752), the loop `for first = 1, #other, BATCH do` (`BATCH = 15`, lines 753–783) launches **all `ceil(#other / 15)` `yt-dlp` Python subprocesses at once** with no concurrency limit and no `--socket-timeout` (`yt-dlp`'s default `socket_timeout` is `None`). A `.m3u` with hundreds of non-YouTube URLs or YouTube playlists/channels (up to `MAX_ENTRIES = 5000`) spawns dozens to hundreds of simultaneous `yt-dlp` processes, risking OOM or severe stalls on the Steam Deck.
  2. **Hidden title scraping on playback and bulk download:** `Online:list` (line 645) and `Online:list_playlist` (line 677) unconditionally call `self:fetch_titles(entries)`, even when invoked by `Online:resolve` (playing one video from *Recently played*) or `Browser:download_season` (*Download all videos*), triggering full-list title scraping when the user is not viewing the folder.
  3. **Head-of-line blocking for UI redraws:** `done()` (lines 730–735) only calls `self.on_titles()` once `pending == 0`. A single slow/unresponsive non-YouTube site in `other` prevents fast YouTube oEmbed titles from rendering on screen until that batch finishes.
* **Suggested Fix:**
  * Run `other` batches through a bounded worker queue (e.g. 1–2 concurrent `yt-dlp` processes, just like `oembed()`), and pass `--socket-timeout 15` in `M.common_args`.
  * Call `self.on_titles()` incrementally as oEmbed/batch results arrive (saving once at the end or periodically).
  * Skip `fetch_titles` when `list` / `list_playlist` is called from `Online:resolve` or `Browser:download_season`.


> **Status: Partly solved** (D85). At most two yt-dlp title runs at a time (and four oEmbed requests); titles show as they arrive (a redraw at most every 0.5 s), saved once at the end; no title search for *Recently played* and *Download all videos* listings. Also: no new title run starts once the list is left (another folder, a video playing); the rest are asked for when it opens again. Unit-tested with a stand-in for yt-dlp. Declined: `--socket-timeout`. yt-dlp's default is not "no timeout": its request handlers fall back to 20 s (`DEFAULT_TIMEOUT = 20` in `yt_dlp/networking/common.py`), so an unresponsive site already times out.

---

### 1.3. `dvp/online.lua`: `parse_m3u` and `split_url` accept URLs containing ASCII control characters (including NUL)

* **Severity:** Low (Hardening / Input Validation)
* **Location:** `app/share/deckvideoplayer/mpv/scripts/deckplayer/dvp/online.lua` (`M.split_url` lines 68–78, `M.parse_m3u` lines 222–228)
* **Problem:** `line:match("^(%S+)")` excludes whitespace, not control bytes (`\000`–`\008`, `\014`–`\031`, `\127`), and `M.split_url` only checks `host:find("[@%s]")`. Verified: `Online.parse_m3u("https://example.com/a\001b.mp4\nhttps://example.com/x\000y.mp4\n")` returns `2` accepted links with `0` skipped (`u1_has_ctrl = true`).
* **Suggested Fix:** Reject any URL matching `"%c"` in `M.split_url`.


> **Status: Solved** (D85). `split_url` refuses any control character, so such lines are skipped as "not a web address". Unit tests.

---

## 2. Functional Bugs (`dvp/online.lua`, `dvp/downloads.lua`, `dvp/videoinfo.lua`, `dvp/browser.lua`, `dvp/subdownload.lua`)

### 2.1. `dvp/online.lua`: `Online.sub_langs` emits `xx.*` regexes that match unrelated 3-letter subtitle languages (e.g. Estonian for Spanish, Javanese for Japanese, Filipino for Finnish)

* **Severity:** Medium (Bug)
* **Location:** `app/share/deckvideoplayer/mpv/scripts/deckplayer/dvp/online.lua` (`M.sub_langs`, lines 340–350)
* **Problem:**
  `M.sub_langs` turns two-letter codes into `two .. ".*"` (e.g. `en.*,es.*,ja.*,fi.*`) for `yt-dlp --sub-langs`. Because `yt-dlp` interprets `--sub-langs` entries as regexes where `.` matches any character, `es.*` matches `est` (Estonian), `ja.*` matches `jav` (Javanese), and `fi.*` matches `fil` (Filipino).
  Verified directly against `yt_dlp.YoutubeDL.process_subtitles`: `['es.*', 'ja.*', 'fi.*', 'en.*']` matched `['en', 'en-orig', 'es', 'es-419', 'est', 'fil', 'jav']`, whereas `['es($|-.*)', 'ja($|-.*)', 'fi($|-.*)', 'en($|-.*)']` matched only `['en', 'en-orig', 'es', 'es-419']`.
* **Suggested Fix:** Use `two .. "($|-.*)"` (or `two .. "(-.*)?"`) in `M.sub_langs` so only exact two-letter codes and subtag variants (`es`, `es-419`, `en-orig`) match.


> **Status: Solved** (D85). `xx($|-.*)`. Checked with yt-dlp against a mock page with `es-419`, `est` and `en` tracks: `es.*` took `es-419` and `est`, the new pattern only `es-419`.

---

### 2.2. `dvp/downloads.lua`: Regional YouTube subtitle codes (`es-419`, `pt_BR`) are renamed to `.und.vtt`, and OpenSubtitles files downloaded while streaming are dropped for `yt-dlp` downloads

* **Severity:** Medium (Bug)
* **Location:** `app/share/deckvideoplayer/mpv/scripts/deckplayer/dvp/downloads.lua` (`M.subtitle_paths` lines 110–124, `M.ytdlp_subs` lines 133–141, `M:start` lines 387–391 & 413, `M:ytdlp_done` lines 453–455)
* **Problems:**
  1. `Downloads.ytdlp_subs` extracts `^video%.([%w%-_]+)%.(%a+)$`, accepting digits and `_` (such as YouTube's standard `es-419` Latin American Spanish and `pt_BR`), but `Downloads.subtitle_paths` line 114 requires `s.lang:match("^%a[%a%-]*$")` (letters and `-` only). Verified: `video.es-419.vtt` and `video.pt_BR.vtt` are silently downgraded to `Movie.und.vtt` and `Movie.2.und.vtt` (unknown language in mpv).
  2. `Downloads:start` lines 387–391 collects subtitles previously downloaded via OpenSubtitles (`self.ctx.subtitles:server_files(job)`), but line 413 branches to `self:start_ytdlp(job, run, backend, info.ytdlp)` without passing `subs`, so those OpenSubtitles `.srt` sidecars are never copied next to the downloaded `.mkv`.
* **Suggested Fix:** Allow BCP-47 numeric region subtags (e.g. normalize `_` to `-` and match `^%a[%w%-]*$`, plus lowercase `ext` in `ytdlp_subs`) in `Downloads.subtitle_paths`, and pass `subs` through `start_ytdlp` / `ytdlp_done` (or `fetch_subtitles` for local file copies).


> **Status: Solved** (D85). Subtitle languages may hold letters, digits and `-` (`_` becomes `-`, lowercase): `video.es-419.vtt` → `<Title>.es-419.vtt`, `pt_BR` → `.pt-br.`; `ytdlp_subs` lowercases the extension. The OpenSubtitles files of the video are copied next to a yt-dlp download too. Checked in headless gamescope: `<Title>.es-419.vtt`, `.en.vtt` and the OpenSubtitles `.fr.srt` next to the downloaded video, no Estonian file.

---

### 2.3. `dvp/online.lua` & `dvp/videoinfo.lua`: `Online:video_info` never lists subtitles for `yt-dlp` videos, and `VideoInfo.from_ytdlp` omits `DV` from its `hdr` flag

* **Severity:** Medium (Bug)
* **Location:**
  * `app/share/deckvideoplayer/mpv/scripts/deckplayer/dvp/online.lua` (`M:video_info`, line 905)
  * `app/share/deckvideoplayer/mpv/scripts/deckplayer/dvp/videoinfo.lua` (`M.from_ytdlp`, lines 404–425)
* **Problems:**
  1. `VideoInfo.from_ytdlp` populates `d.subs` from `j.requested_subtitles` (lines 418–425), yet `Online:video_info` runs `yt-dlp -J -f <format> -S <sort> -- <url>` without `--write-subs`, `--write-auto-subs`, or `--sub-langs`. Verified against `yt-dlp`: `j.subtitles` contained `['en']` while `j.requested_subtitles` was `None`; adding `--write-subs --write-auto-subs --sub-langs en.*` populated `j.requested_subtitles = ['en']`. Consequently, *Video info* never shows subtitles for online `yt-dlp` videos.
  2. In `VideoInfo.from_ytdlp` lines 404–410, `local hdr = range:find("HDR") ~= nil or range == "HLG"` omits `range == "DV"`, even though line 409 sets `transfer` for `range == "DV"`. Verified: `dynamic_range = "DV"` produces `bit_depth = nil, primaries = nil, transfer = "smpte2084"`.
* **Suggested Fix:** Pass `--write-subs`, `--write-auto-subs`, and `--sub-langs` (from `M.sub_langs`) in `Online:video_info` (or inspect `j.subtitles`), and add `or range == "DV"` to `hdr` in `VideoInfo.from_ytdlp`.


> **Status: Solved** (D85). Video info asks yt-dlp for the subtitles playback would load (same languages): checked, *English* and *Spanish (Latin America)* listed, Estonian not. `DV` counts as HDR, and Dolby Vision codec names (`dvh1`/`dvhe`, `dav1`, `dva1`/`dvav`) map to HEVC, AV1 and H.264. Found meanwhile: tags with a region had no name (`ES-419`); now "Spanish (Latin America)", "English (US)", "English (original)" (YouTube's `en-orig`), in Video info and the subtitle menu.

---

### 2.4. `dvp/online.lua` & `dvp/downloads.lua`: Undetected playlists download all items into `video.mkv`; stale `job.formats` breaks retries; direct online downloads show `"?"` size; free-space check ignores temporary mux copy

* **Severity:** Medium (Bug)
* **Location:**
  * `app/share/deckvideoplayer/mpv/scripts/deckplayer/dvp/online.lua` (`M.parse_info` lines 425–441, `M:download_info` lines 920–943)
  * `app/share/deckvideoplayer/mpv/scripts/deckplayer/dvp/downloads.lua` (`M:check_space` lines 355–364, `M:transferred` lines 494–499)
* **Problems:**
  1. **Playlist URLs not rejected in `parse_info` / `download_info`:** If a non-YouTube playlist URL is queued for download before `fetch_titles` marks it as a folder, `yt-dlp -J --no-playlist` still returns `_type = "playlist"` with `entries` (verified on a 2-video page: `_type = "playlist"`, `entries_len = 2`). `Online.parse_info` does not check `j._type == "playlist"`, returning `{title = "Multi", formats = nil, live = false}`; `yt-dlp` then downloads every playlist item sequentially into the same `video.mkv` target (`Playlist Multi: Downloading 2 items of 2`).
  2. **Stale `job.formats` permanently poisons retries:** `Online:download_info` line 927 unconditionally reuses `if job.formats then format = job.formats end`. If a site's format IDs change between pause/failure and *Try again*, `job.formats` is never cleared and every retry fails with `"No playable format for this video"`.
  3. **Finished direct online downloads show `"?"` size:** For direct video URLs (`Online:download_info` line 923), `info.size` is `nil`, and `Downloads:transferred` (lines 494–498) never sets `job.size = file_size(job.path)` (unlike `ytdlp_done` line 452), so completed direct downloads permanently display `"?"` in the Downloads menu.
  4. **2× peak disk space during `ffmpeg` remux:** `Downloads.enough_space` checks `avail >= size - have + 256 MiB`, but `yt-dlp` downloads separate video and audio files into `.parts/` and muxes them into `video.mkv` before deleting the inputs, requiring roughly `2 × size` free space during muxing.
* **Suggested Fix:**
  * Reject `j._type == "playlist"` in `Online.parse_info` / `download_info` with a fatal message (and optionally mark `self.data.folders[url] = true`).
  * Clear `job.formats` (and partial files) when a retry fails with `"requested format is not available"` or when no partial files exist on disk.
  * Set `job.size = file_size(job.path)` after `os.rename` in `Downloads:transferred`.
  * Require roughly `size` extra space (or `2 * size - have`) in `check_space` for `job.ytdlp` downloads.


> **Status: Solved** (D85). (1) `parse_info` flags `_type` playlist and multi_video; downloading or Video info of such a link says "A playlist: open it to download its videos" / "…to see its videos", and the link becomes a folder (checked with yt-dlp on a two-video mock page). (2) Kept formats the site no longer offers ("No playable format"): new ones are chosen once and the old partial files deleted (checked with made-up format ids). (3) The size is read from the file after a curl download. (4) yt-dlp downloads need their size twice in the space check (parts plus the joined file).

---

### 2.5. `dvp/online.lua` & `dvp/videoinfo.lua`: Uppercase `HTTP://` / `HTTPS://` schemes break *Recently played* and *Video info*

* **Severity:** Medium (Bug)
* **Location:**
  * `app/share/deckvideoplayer/mpv/scripts/deckplayer/dvp/online.lua` (`M.split_url` line 71, `M.canonical` line 144, `M.recent_key` line 289, `M.parse_recent_key` line 294)
  * `app/share/deckvideoplayer/mpv/scripts/deckplayer/dvp/videoinfo.lua` (`M.probe_url` line 480)
* **Problem:**
  `Online.split_url` accepts case-insensitive `HTTP://` / `HTTPS://`, and `Online.recent_key` saves `"online:HTTPS://..."`, but `Online.parse_recent_key` (`^online:(https?://.+)$`) and `VideoInfo.probe_url` (`^https?://`) only match lowercase schemes. Verified in `mpv`: `Online.parse_recent_key(Online.recent_key({key = "HTTPS://example.com/film.mp4"}))` returns `nil`, and `VideoInfo.probe_url("HTTPS://example.com/film.mp4", ...)` fails with `"not a web address"`.
* **Suggested Fix:** Lowercase the scheme (and host) in `Online.canonical`, or match schemes case-insensitively in `Online.parse_recent_key` and `VideoInfo.probe_url`.


> **Status: Solved** (D85). Links get a lowercase scheme and host when read (`Online.normalize`, also in `canonical`), so keys, *Recently played* and Video info always see `https://…`. Unit tests; an uppercase link played in headless gamescope.

---

### 2.6. `dvp/browser.lua` & `dvp/online.lua`: Completed downloads still stream (`ytdl://`) from an open list, and playing the file from *Downloaded* splits progress depending on session history

* **Severity:** Medium (Bug)
* **Location:**
  * `app/share/deckvideoplayer/mpv/scripts/deckplayer/dvp/browser.lua` (`M:downloads_changed` lines 704–713, `M:delete` lines 642–647)
  * `app/share/deckvideoplayer/mpv/scripts/deckplayer/dvp/online.lua` (`M:entry_for` lines 598–601)
* **Problems:**
  1. When an online download completes while the user is viewing its `.m3u` list or playlist, `Browser:downloads_changed()` line 712 sees `loc and loc.server` and only calls `self:render()` instead of refreshing entries. The row shows `"Downloaded"`, yet `e.path` stays `"ytdl://..."`, so pressing Play streams over the network instead of playing the downloaded file.
  2. `Online:entry_for` caches `self.items[path] = item` for the downloaded local file path. If the user opened the `.m3u` list first and then plays the file from the **Downloaded** folder, `servers:item_for(path)` maps it to `online:<url>`, so the local row in **Downloaded** never gets a resume/watched badge; in a new session where **Downloaded** is opened first, `self.items[path]` is empty, so progress is stored under the local path instead, creating two separate resume and *Recently played* entries for the same video. `Browser:delete(path)` also leaves the deleted path in `online.items`.
* **Suggested Fix:** Refresh `e.path` (or reload when `loc.server.backend == "online"`) in `Browser:downloads_changed()`, clear `online.items[path]` on `delete`, and unify how downloaded online files resolve their resume key (e.g. look up `downloads` by path inside `Online:item_for` or keep local-folder plays separate cleanly).


> **Status: Solved** (D85). (1) A download finishing (or deleted) updates the open list's rows (`Online:refresh_entries` from `Browser:downloads_changed`): checked, a video downloaded while its list was open then played from the file. (2) A downloaded copy is the same video wherever it is opened: `Online:item_for` finds a file through its finished download (no session cache, so nothing stale after a delete), and the library's rows for that file read and set the link's record (`Browser:local_key`). Checked: marked watched in the download folder, the list row showed it; one record in resume.json.

---

### 2.7. `dvp/online.lua`: All-titled `.m3u` lists never persist `data.lists` to `online.json`, and `save()` never prunes `data.lists` / `data.folders` entries absent from `data.titles`

* **Severity:** Low–Medium (Bug)
* **Location:** `app/share/deckvideoplayer/mpv/scripts/deckplayer/dvp/online.lua` (`M:save` lines 478–493, `M:list` lines 634–646)
* **Problems:**
  1. `Online:list` writes `self.data.lists[link.key] = path` (line 636) but relies on `fetch_titles`'s `done()` callback to call `self:save()`. Verified: opening a `.m3u` whose entries already have `#EXTINF` titles (or direct video links) never creates/updates `online.json` (`online_json_exists = false`), so after restart, *Recently played* loses `data.lists[key]` (breaking `autoplay_next` siblings, download list folder naming `item.show`, and Looks/subtitle memory `item.parent`).
  2. `Online:save()` (lines 481–490) only prunes keys present in `self.data.titles`. Verified: adding `3050` keys to `data.lists` and `data.folders` without `data.titles` entries and calling `on:save()` left all `3050` entries unpruned (`lists = 3050`, `folders = 3050`), allowing `online.json` to grow without bound.
* **Suggested Fix:** Call `self:save()` in `Online:list` when `self.data.lists` changed, and prune `data.lists` / `data.folders` independently of `data.titles`.


> **Status: Solved** (D85), differently: a video's list is recorded when it plays (`prepare`) and saved then; at start, entries whose video is no longer in resume.json (at most 1000) are dropped; `folders` is capped at 3000 (videos first). Found while testing this: mpv's `parse_json` marks a table read from `[]`, and `format_json` writes it as `[]` again whatever keys were added. So `online.json` tables saved empty lost everything later, and so did `resume.json` (since v0.1: after the last record was deleted, no progress was kept across restarts). Fixed by copying what is read (`util.plain_table`); a unit test fails without it.

---

### 2.8. `dvp/subdownload.lua`: `SubDownload.server_key` exceeds Linux's 255-byte `NAME_MAX` for online URLs longer than ~244 characters

* **Severity:** Low–Medium (Bug)
* **Location:** `app/share/deckvideoplayer/mpv/scripts/deckplayer/dvp/subdownload.lua` (`M.server_key` lines 64–67, `M:stored` line 161, `M:download` line 304)
* **Problem:** `M.server_key` constructs `"online-web-" .. rating_key` sanitized with `gsub("[^%w%-]", "_")`. Because an online item's `rating_key` is its full URL (up to `URL_MAX = 2048`), URLs longer than ~244 bytes (e.g. signed CDN/query links) produce directory names over Linux's 255-byte limit (verified: a 295-byte URL yields `SUBKEY_LEN = 306`), causing `util.mkdir_p` and `readdir` to fail with `ENAMETOOLONG`.
* **Suggested Fix:** For keys exceeding ~120 bytes, cap the prefix and append a short deterministic hash (preserving existing short keys for backward compatibility).


> **Status: Solved** (D85). Keys over 120 bytes: the first 103 bytes, "-" and a 16-digit hash of the whole id (`util.hash_hex`, arithmetic only for Lua 5.1). Shorter keys are unchanged.

---

### 2.9. `dvp/online.lua` & `dvp/browser.lua`: `Online:read_list` has no timeout on hung shares (wedging `Browser.opening`), and *Download all videos* on folder-only lists displays `"Already in Downloads"`

* **Severity:** Low (Bug / Reliability)
* **Location:**
  * `app/share/deckvideoplayer/mpv/scripts/deckplayer/dvp/online.lua` (`M:read_list` lines 608–620, `M:list_playlist` line 654, `M:resolve` line 801)
  * `app/share/deckvideoplayer/mpv/scripts/deckplayer/dvp/browser.lua` (`M:load_server` line 235, `M:open_server_recent` lines 443–451, `M:download` lines 584–595)
* **Problems:**
  1. Unlike `Browser:load_folder` (`LISTING_GIVE_UP`) and `Browser:recent_playlist` (`PLAYLIST_WAIT`), `Online:read_list` and `Online:list_playlist` discard their subprocess handles and have no timeout. If a `.m3u` lives on a hung SMB/NFS share and is opened from *Recently played*, `Online:resolve` never invokes its callback and `browser.opening` stays `true` permanently, blocking all other *Recently played* server entries until restart.
  2. When *Download all videos* is triggered on a `.m3u` list or channel `/playlists` tab that contains only folders/playlists (no direct video items), `Browser:download` receives 0 items (`added == 0`) and displays `"Already in Downloads"` even though nothing was downloaded.
* **Suggested Fix:** Return subprocess handles from `read_list` / `list_playlist` so `Browser:cancel_listing()` can abort them, add a fallback timeout in `Online:resolve` (falling back to `alone()`), and show `"No videos to download"` when `#items == 0` in `Browser:download`.


> **Status: Solved** (D85). (1) A list file is given up after 10 s ("The list's folder isn't answering", the subprocess aborted), and *Recently played* plays the video alone if its list (or playlist) hasn't answered within 15 s. Tested with a FIFO and with a stand-in yt-dlp that hangs. The handles aren't passed to `cancel_listing`: the browser already ignores late answers. (2) "No videos to download here"; checked in headless gamescope.

---

## 3. Optimization Opportunities & Pre-Release Bookkeeping

### 3.1. `dvp/online.lua`: Offline playback latency from *Recently played* for downloaded playlist videos, and blocking `chmod 600` per cookie copy

* **Severity:** Low (Optimization)
* **Location:** `app/share/deckvideoplayer/mpv/scripts/deckplayer/dvp/online.lua` (`M:cookies` line 526, `M:resolve` lines 788–812), `app/share/deckvideoplayer/mpv/scripts/deckplayer/dvp/util.lua` (`write_file_atomic` lines 131–139)
* **Notes:**
  1. When playing an already-downloaded video from *Recently played* whose `list_path` is a YouTube playlist/channel (`autoplay_next = yes`), `Online:resolve` runs `yt-dlp --flat-playlist -J` over the network before falling back to `alone()`, delaying offline playback until `yt-dlp` fails DNS/connect. A short timeout (or playing the local file directly when offline) improves offline responsiveness.
  2. `Online:cookies` calls `util.write_private`, which spawns a synchronous `chmod 600` subprocess on every `yt-dlp` invocation (including inside the synchronous `on_load` priority 5 hook), even though `app/bin/deckvideoplayer` already runs with `umask 077` (keep `chmod` only when outside `umask 077`, or acceptable as minor defense-in-depth).


> **Status: Partly solved** (D85). (1) Covered by 2.9's 15 s limit (offline, yt-dlp fails at once on name resolution). (2) Declined: the `chmod` takes a few ms, in the on_load hook where playback waits for yt-dlp anyway, and the copy must be private also without the launcher's `umask 077` (development runs).

---

### 3.2. Pre-Release Bookkeeping & Updater Hygiene (`CHANGELOG.md`, Flatpak Manifest, `scripts/update-yt-dlp.py`)

* **Severity:** Info
* **Location:**
  * `CHANGELOG.md` line 8 (`## v0.9.0 (unreleased)`) vs `dvp/version.lua` (`"0.9.0"`) and `packaging/flatpak/io.github.nicocarbone.DeckVideoPlayer.metainfo.xml` line 63 (`date="2026-11-19"`).
  * `packaging/flatpak/io.github.nicocarbone.DeckVideoPlayer.yml` lines 223–233 (`yt-dlp` module fetches `LICENSE` for `make-source-archive.py` but does not install it under `${FLATPAK_DEST}/share/licenses/yt-dlp/LICENSE`, unlike `inter-font` on line 240).
  * `scripts/update-yt-dlp.py` lines 46–57: `current_tag` searches the entire manifest rather than scoping to the `yt-dlp` module block like `rewrite_manifest`, and `sums_entry` matches only lowercase hex `[0-9a-f]{64}`.


> **Status: Partly solved** (D85). The changelog and metainfo dates are set when tagging (release steps, DEVELOPMENT.md §7). LICENSE: not a bug: flatpak-builder installs it by itself (`/app/share/licenses/io.github.nicocarbone.DeckVideoPlayer/yt-dlp/LICENSE`, checked in the build). `current_tag` now reads only the yt-dlp module, and checksums are accepted in either case (lowercased); tests added.

---

## 4. v0.9.0 (Part XIII) Summary Checklist

> Done in D85, except `--socket-timeout` and the `chmod` (declined, see 1.2 and 3.1); the release dates are set when tagging.

- [x] **Cookies (`dvp/online.lua`, `main.lua`):** Use a unique filename per `M:cookies(purpose)` call (monotonic counter) so concurrent `yt-dlp` runs never delete or clobber each other's cookie copy; call `online:stream_done()` in `main.lua`'s `shutdown` handler and sweep leftover `online-cookies-*.txt` files on startup.
- [x] **Title Scraping (`dvp/online.lua`, `dvp/browser.lua`):** Bound concurrent `yt-dlp` batches in `fetch_titles`, pass `--socket-timeout` in `common_args`, trigger `on_titles()` incrementally, and skip `fetch_titles` when called from `Online:resolve` or `Browser:download_season`.
- [x] **URL Validation & Schemes (`dvp/online.lua`, `dvp/videoinfo.lua`):** Reject control characters (`%c`) in `split_url`; lowercase schemes in `canonical` (or match case-insensitively in `parse_recent_key` and `VideoInfo.probe_url`).
- [x] **Subtitles (`dvp/online.lua`, `dvp/downloads.lua`, `dvp/subdownload.lua`):** Change `M.sub_langs` from `xx.*` to `xx($|-.*)` so 3-letter codes (`est`, `jav`, `fil`) aren't matched; allow BCP-47 numeric/underscore language tags (`es-419`, `pt_BR`) in `Downloads.subtitle_paths`; copy OpenSubtitles sidecars on `yt-dlp` downloads; cap/hash `SubDownload.server_key` below 255 bytes.
- [x] **Video Info (`dvp/online.lua`, `dvp/videoinfo.lua`):** Pass `--write-subs --write-auto-subs --sub-langs` in `Online:video_info` so `j.requested_subtitles` is populated, and include `range == "DV"` in `VideoInfo.from_ytdlp`'s `hdr` flag.
- [x] **Downloads & State (`dvp/online.lua`, `dvp/downloads.lua`, `dvp/browser.lua`):** Reject `_type == "playlist"` in `Online.parse_info` / `download_info`; clear stale `job.formats` on retry; set `job.size = file_size(job.path)` in `Downloads:transferred`; account for ~2× peak space during `ffmpeg` muxing; update/reload open online lists when downloads finish and keep resume keys consistent between lists and *Downloaded*; save `data.lists` in `Online:list` and prune `data.lists`/`data.folders` in `save()`; add a timeout/cancel handle to `read_list` / `list_playlist` and handle empty folder-only lists in `Browser:download`.
- [x] **Release & Updater (`CHANGELOG.md`, manifest, `scripts/update-yt-dlp.py`):** Date `CHANGELOG.md` when tagging `v0.9.0`, optionally install `yt-dlp`'s `LICENSE`, and scope `current_tag` to the `yt-dlp` module block.

---

# Part XII — v0.8.5 CRT Shader Audit (2026-11-14)

Audited the uncommitted `v0.8.5` CRT shader changes (`dvp-crt.glsl`, `dvp/looks.lua`, `dvp/player.lua`, `tests/run.lua`, and `docs/DECISIONS.md` D79). All `859` Lua checks and `10` Python tests in `tests/run.sh` pass. In headless gamescope at 4K (`3840×2160`, `Old Show 480p.mp4`), cycling *Look* (`CRT, light lines` → `CRT` → `CRT, strong lines`) updates `file-local-options/glsl-shader-opts` (`dvp_scanlines` `"0"` → `"1"` → `"2"`, `dvp_src_h` `"480"`) without recompiling the shader or logging libplacebo errors, and `beam_mean` matches exact `n`-row sums within `0.4106%` across `n = 2..9` and `s = 0.19..0.46`.

Below are the edge cases and optimization opportunities identified in the `v0.8.5` CRT changes.

---

## 1. Edge Cases & Minor Issues (`dvp-crt.glsl`, `dvp/looks.lua`)

### 1.1. `dvp-crt.glsl`: Aperture-grille `stripe` and `dark` use `HOOKED_size.y` instead of display size, downgrading cropped widescreen video on 4K/1440p

* **Severity:** Low–Medium (Bug / Visual inconsistency)
* **Location:** `app/share/deckvideoplayer/mpv/shaders/dvp-crt.glsl` (`hook`, lines 115–116)
* **Problem:**
  ```glsl
  float dark = h >= 1400.0 ? 0.70 : 0.80;
  float stripe = max(1.0, floor(h / 1080.0 + 0.25));
  ```
  Because `HOOK SCALED` runs on the active video area (`h = HOOKED_size.y`, excluding black bars), a 2.35:1 / 2.39:1 film played with *Picture → Crop black bars* (or encoded without bars) on a 4K TV (`3840×2160`) has `HOOKED_size = 3840×1606`: `floor(1606 / 1080.0 + 0.25) = 1.0`, so `stripe` drops from `2` pixels back to `1` pixel despite the 4K panel width and viewing distance. Likewise, on a 1440p screen (`2560×1071`), `h < 1400.0` flips `dark` from `0.70` to `0.80`.
* **Suggested Fix:** Derive the screen-height proxy from both axes (e.g. `float screen_h = max(h, HOOKED_size.x * 0.5625);`, or `OUTPUT_size.y` if available in `SCALED`) when computing `dark` and `stripe`.


> **Status: Solved** (D80). Confirmed: SCALED sees only the video's area, and libplacebo's `target_size` is that area too, so the shader can't read the screen size. The app now passes the window's height (`dvp_screen_h`, from `osd-dimensions`), and `max(h, width × 9/16)` is only the fallback. Verified across 31 cases (7 video aspect ratios including 2.39:1, portrait and anamorphic DVD; 16:9, 16:10, 5:4 and 4:3 screens from 1280×800 to 4K; Fit and Fill): the mask repeats every 6 pixels at 4K and every 3 below, in every case. Found while checking: with *Fill*, scanlines didn't follow the video's lines (the app passed the full 480 lines while 360 were shown); the shader now takes the shown source height from libplacebo's `input_size` (after Fill's crop or *Crop black bars*), so each scanline is one video line in every mode.

---

### 1.2. `dvp/looks.lua`: `base.opts` does not filter stale `dvp_*` shader options

* **Severity:** Low (Robustness / Hygiene)
* **Location:** `app/share/deckvideoplayer/mpv/scripts/deckplayer/dvp/looks.lua` (`M.option_values`, lines 119–126)
* **Problem:**
  `M.option_values` strips `OUR_SHADERS` from `base.shaders` and `OUR_FILTERS` from `base.vf`, but copies all entries from `base.opts` verbatim (`for k, v in pairs(base.opts or {}) do opts[k] = v end`). If `base.opts` (e.g., from a user's `mpv.conf` or stale state) contains `dvp_scanlines`, `dvp_src_h`, or `dvp_grain`, it stays in `glsl-shader-opts` even when looks are `"off"`. (Harmless unless a user loads `dvp-crt.glsl` outside `Looks`.)
* **Suggested Fix:** Filter `OUR_OPTS` (`dvp_grain`, `dvp_scanlines`, `dvp_src_h`) when copying `base.opts`, matching `OUR_SHADERS` and `OUR_FILTERS`.


> **Status: Solved** (D80). `option_values` drops `dvp_grain`, `dvp_scanlines` and `dvp_src_h` from the starting options, as it already did for our shaders and filters; unit tests added.

---

### 1.3. `dvp-crt.glsl`: Minor tolerance comment mismatch (`0.75%` vs `0.41%`)

* **Severity:** Info (Documentation)
* **Location:** `app/share/deckvideoplayer/mpv/shaders/dvp-crt.glsl` (line 62) vs `docs/DECISIONS.md` (D79, lines 2378–2379)
* **Problem:**
  `dvp-crt.glsl` line 62 states `beam_mean` is `"within 0.75% of summing the rows for widths 0.19-0.46"`, whereas `docs/DECISIONS.md` D79 states `"within 0.41 %"`. Direct evaluation over `n = 2..9` and `s = 0.19..0.46` shows a worst-case relative error of `-0.4106%` (at `n = 4, s = 0.46`).


> **Status: Solved** (D80). After 2.1 the bound is 0.42 % (cubic for the integral); the shader comment says within 0.5 % and D79 has both numbers.

---

## 2. Optimization Opportunities (`dvp-crt.glsl`)

### 2.1. Per-pixel `erf_pos` and repeated divisions in `beam_mean` for `n >= 3` (1440p and 4K)

* **Severity:** Medium (GPU Performance at 4K)
* **Location:** `app/share/deckvideoplayer/mpv/shaders/dvp-crt.glsl` (`erf_pos` lines 52–57, `beam_mean` lines 65–72, `hook` lines 105–108)
* **Problem:**
  At 1440p (`n = 3`) and 4K (`n = 4` or `5`, ~8.3M pixels/frame), `beam_mean(s, n)` takes the `n >= 3.0` branch for every pixel and evaluates `erf_pos(0.70710678 / s)` **twice** per pixel (`s1` and `s2`, both `vec3`). Combined with `beam()` and `s1`/`s2`, the beam/`beam_mean` math for every 1440p/4K fragment executes **12 scalar `exp()` calls**, **6 `sqrt()` calls**, and **24 `vec3`-component divisions** (`0.70710678 / s`, `1 / (1 + ...)`, `d * d / (s * s)`, and `/ beam_mean`), alongside **10 texture fetches** per pixel. Measured in headless gamescope at 4K on an RTX 4090 (`vo-passes`), `Deck Video Player: CRT` averages `89.1 µs/frame` (`89084 ns`); cost will be substantially higher on the Steam Deck's RDNA2 iGPU when docked at 4K.
* **Suggested Fix:**
  1. Precompute `vec3 is1 = 1.0 / s1;` and `vec3 is2 = 1.0 / s2;` once in `hook()` so `beam` and `beam_mean` multiply by `is1`/`is2` instead of performing repeated `vec3` divisions.
  2. Over the shader's narrow width range `s ∈ [0.20, 0.46]` (`1 / (s * sqrt(2)) ∈ [1.537, 3.536]`), `s * sqrt(2 * pi) * erf(1 / (s * sqrt(2)))` is smooth and monotonic (`0.501` to `1.119`); replacing `erf_pos` with a low-degree polynomial fit in `s` eliminates both `vec3` `exp`s and divisions inside `beam_mean` at 1440p/4K with negligible error.


> **Status: Partly solved** (D80). Not a regression: measured with `vo-passes` at 4K, the v0.8.5 shader took 88 µs per frame against 101 µs for the released v0.8.4 one. Both suggestions applied anyway: 1/(2σ²) is computed once per beam and shared by the beam and its average, and `erf` is replaced by a cubic in σ (0.08 % from the integral). Now 81 µs, with gap depth and brightness unchanged to two decimals at 1280×800, 1440p and 4K.

---

### 2.2. Redundant per-scanline `line_color` / `sqrt` / `beam_mean` work across rows

* **Severity:** Low (GPU Performance, trade-off)
* **Location:** `app/share/deckvideoplayer/mpv/shaders/dvp-crt.glsl` (`hook`, lines 96–108)
* **Problem:**
  For every scanline `k`, `c1`/`c2` (`6` texture fetches), `sqrt`, and `beam_mean` are identical across all `n` rows of the scanline and are evaluated again as neighbour `c2` (`10×` redundant per-scanline evaluations at 4K `n = 5`, `4×` at `n = 2`). A 2-pass split would trade ALU for an extra render target/pass, so `2.1` is the lower-risk optimization first unless docked 4K GPU cost on Deck proves high.


> **Status: Not solved (declined)** (D80). A second pass would need its own render target and a hook order to keep right, for a shader that is already cheaper than the released one; to revisit if a docked Deck at 4K drops frames with the CRT look.

---

# Part XI — v0.8.4 Audit: TV Speakers Mix, DLNA Host Handling & Flatpak Fontconfig (2026-11-14)

All unit tests in `tests/run.sh` pass, and the v0.8.4 changes (`D75`–`D77`) were verified against FFmpeg `n9.0.1` (`org.freedesktop.Platform//26.08`), live `mpv`, and `dvp.dlna`:
* **TV speakers stereo mix (`dvp/tvmix.lua`, D75):** 31 of the 32 channel layouts in `TvMix.LAYOUTS` generate valid FFmpeg `pan=stereo|...,alimiter` graphs in FFmpeg `n9.0.1`, `dvp-night` (`af pre`) stays ordered ahead of `dvp-tvmix` (`af add`), and headphone surround / TV speakers toggle mutually exclusively.
* **DLNA LAN-host acceptance (`dvp/dlna.lua`, D76):** cross-subnet private IPv4 `<res>` URLs are accepted while the server's own host stays preferred, internet addresses stay rejected, and `entries.skipped` survives `library.sort_entries` in-place sorting.
* **Flatpak fontconfig (`app/bin/deckvideoplayer`, D77):** writing a host-cache-free `fonts.conf` in `org.freedesktop.Platform//26.08` resolves `Inter` to `/app/share/fonts/inter/Inter-Regular.ttf` (instead of falling back to `/run/host/fonts/woff/ebgaramond/EBGaramond08-Italic.woff`), and rewriting `fonts.conf` on start does not invalidate the XDG font cache (~680 ms cold vs ~21 ms warm in tests).

Below are the verified bugs, hardening issues, optimization opportunities, and pre-release bookkeeping found in v0.8.4.

---

## 1. TV Speakers Mix, Headphone Surround & Playback Info (`dvp/tvmix.lua`, `dvp/surround.lua`, `dvp/player.lua`)

### 1.1. `dvp/tvmix.lua` & `dvp/surround.lua`: `22.2` channel layout fails FFmpeg filter creation and permanently locks out the filter for the entire session

* **Severity:** Medium (Bug)
* **Location:**
  * `app/share/deckvideoplayer/mpv/scripts/deckplayer/dvp/tvmix.lua` (`M.LAYOUTS["22.2"]` line 55, `SPEAKERS` line 66, `M.graph` lines 92–107, `M:update` lines 139–146)
  * `app/share/deckvideoplayer/mpv/scripts/deckplayer/dvp/surround.lua` (`M:update`)
* **Problem:**
  1. `TvMix.LAYOUTS["22.2"]` includes `lfe` and `lfe2`, both mapped to `LFE`, and `TvMix.graph` emits `num(gain) .. "*" .. name:upper()` (`... +0.354*LFE+...+0.354*LFE2+...`). Against FFmpeg `n9.0.1` (`org.freedesktop.Platform//26.08`), **31/32 layouts pass** while **`22.2` fails**: FFmpeg's `pan` filter rejects `LFE2` (`Can not reference in channel 3 twice`; isolated `FC+LFE2` gives `Syntax error near "2"`, and mixing named channels with indices such as `FL+LFE+c18` gives `Can not mix named and numbered channels`, whereas all-indexed `c0..c23` succeeds).
  2. In `TvMix:update()`, any failure of `mp.commandv("af", "add", M.filter_string(graph))` logs `"TV speaker mix: the pan/alimiter filters are not available"` and executes `self.available, self.enabled = false, false`. When verified live in `mpv` playing a multi-track file (`22.2` -> `5.1(side)`), encountering the `22.2` track permanently disabled **TV speakers** (`available = false`, `enabled = false`) for the subsequent `5.1(side)` track and the rest of the session.
  3. Sibling bug in `dvp/surround.lua`: FFmpeg `n9.0.1`'s `sofalizer` (with `mit_kemar_normal_pinna_dfeq.sofa`) works on `5.1(side)`, `7.1`, and `octagonal`, but fails on `22.2` (`Couldn't get speaker positions. Input channel configuration not supported.`), triggering the identical `self.available, self.enabled = false, false` session-wide lockout.
* **Suggested Fix:**
  * Separate per-layout filter rejection from global `pan`/`alimiter`/`sofalizer` availability: do not set `self.available = false, self.enabled = false` for the rest of the session when `af add` fails on a single track/layout (clear `self.active = false` and optionally ignore that layout for the track instead).
  * In `dvp/tvmix.lua`, either exclude `22.2` / skip `lfe2` when using named channels (note that switching to positional `c0..c23` indices would assume channel order matches `M.LAYOUTS["22.2"]`, unlike FFmpeg's named channel matching). In `dvp/surround.lua`, reject unsupported layouts such as `22.2` before invoking `sofalizer` (or fall back gracefully without disabling `self.available`).


> **Status: Solved** (D78). Confirmed: `pan` reads channel names as letters only, so `LFE2` is a syntax error. The TV mix leaves the second LFE out (the same bass as the first); all 27 generated graphs (every layout with a centre channel) now run in FFmpeg, and a 22.2 track plays with the mix in the app. Both filters no longer give up for the session when FFmpeg refuses one layout: that layout is remembered and plays with the usual downmix, and the option stays on for other tracks. Only a failure before the filter ever worked, on a layout of at most 8 channels, still means the filter is missing from the build and turns the option off, as before. In the Flatpak, sofalizer's refusal of 22.2 doesn't make `af add` fail at all: mpv accepts the filter, then disables it when FFmpeg can't configure it (`Disabling filter dvp-surround because it has failed`), so there was no lockout there, but the app went on reporting headphone surround as active. The app now subscribes to error-level log messages and, on that line for one of its filters, remembers the layout and removes the filter (verified: 22.2 left as it is, 5.1 rendered, 22.2 again not retried).

---

### 1.2. `dvp/player.lua` & `main.lua`: Switching audio tracks while paused leaves *Playback info* (`Audio out` and filter tag) stale

* **Severity:** Low–Medium (Bug)
* **Location:**
  * `app/share/deckvideoplayer/mpv/scripts/deckplayer/dvp/player.lua` (`M.new`, `audio_items` line 391, `info_lines`)
  * `app/share/deckvideoplayer/mpv/scripts/deckplayer/main.lua` (`render` / `render_info` on menu actions, lines 357–359)
* **Problem:**
  `Player.new` observes `chapter-list`, `hwdec-current`, `video-target-params/gamma`, and `frame-drop-count` (with `deinterlace-active` observed in `main.lua`), but does not observe `audio-params`, `audio-out-params`, or `af`.
  When switching audio tracks in `audio_items` (`mp.set_property_number("aid", t.id)`), `main.lua` calls `player:render()` and `player:render_info()` synchronously before `mpv` finishes reconfiguring its audio filter graph. Verified in paused `mpv` switching from `5.1(side)` (`aid=1`) to `stereo` (`aid=3`): immediately after `set_property_number("aid", 3)`, `aid` is `3` while `audio-params/channels` is `nil`, `audio-out-params/channels` still reads `5.1`, and `af` still holds `dvp-tvmix`; the swap to `stereo` and filter removal happen asynchronously ~0.2 s later, leaving *Playback info* stale until another trigger redraws it.
* **Suggested Fix:**
  Observe `audio-out-params` (or `audio-params/channels`) and `af` in `Player.new`, calling `self:render_info()` only when the info panel is open (preserving the idle/battery rule).


> **Status: Solved** (D78). Confirmed: the 0.5 s refresh doesn't run while paused. `Player.new` now observes `af` and `audio-out-params/channels` and redraws the info panel when it is open (event-driven, no timer).

---

## 2. DLNA LAN Filtering & Skipped-Video Messages (`dvp/dlna.lua`, `dvp/browser.lua`)

### 2.1. `dvp/dlna.lua`: `Dlna.pick_res` matches `http-get:` and `video/` case-sensitively

* **Severity:** Medium (Bug)
* **Location:** `app/share/deckvideoplayer/mpv/scripts/deckplayer/dvp/dlna.lua` (`pick_res`, lines 260–268)
* **Problem:**
  `Dlna.pick_res` checks `proto:match("^http%-get:")` and `mime:match("^video/")` (plus `!mime:match("^text/")` and `!mime:match("^image/")`) without lowercasing, unlike `Dlna.download_file` (lines 344–345), which already uses `mime:lower()`, and `Dlna.safe_id`, which accepts mixed-case `UUID:`.
  Verified with `dvp.dlna`: `pick_res({{url = "http://192.168.1.50:8200/v.mp4", protocol = "http-get:*:VIDEO/MP4:*"}}, "192.168.1.50")` rejects the video and returns `nil, "sent as VIDEO/MP4, not as video"`.
* **Suggested Fix:**
  Lowercase the parsed protocol/MIME values (`local lproto = proto:lower()`, `local lmime = mime:lower()`) when matching prefixes while preserving the original `mime` for diagnostics if desired.


> **Status: Solved** (D78). `protocolInfo` and the MIME type are lowercased before matching, including `DLNA.ORG_CI`.

---

### 2.2. `dvp/dlna.lua`: Empty `<res>` URLs produce `"address outside the home network ()"`, and failed `split_url` falls back to printing raw `r.url` in the UI

* **Severity:** Low–Medium (Bug / Hardening)
* **Location:** `app/share/deckvideoplayer/mpv/scripts/deckplayer/dvp/dlna.lua` (`pick_res`, lines 257–271) and `dvp/browser.lua` (`render` skipped empty state, lines 1306–1307)
* **Problem:**
  1. `pick_res` initializes `why = "the server gives no address"`, yet for an empty `<res protocolInfo="http-get:*:video/mp4:*"></res>`, `http_get` and `mime` pass, `M.lan_host(nil, host)` fails, and `why` is overwritten with `"address outside the home network (" .. tostring(rhost or r.url) .. ")"` — verified to return `"address outside the home network ()"` instead of `"the server gives no address"`.
  2. When `M.split_url(r.url)` returns `nil, nil` (for any non-empty malformed or non-HTTP URL), `rhost or r.url` embeds the unvalidated `r.url` text verbatim into `skipped.why`, which `browser.lua` displays in `"%d %s skipped: %s."`.
* **Suggested Fix:**
  Check `(r.url or "") == ""` first (keeping `"the server gives no address"`), and when `rhost == nil`, report a fixed label (or truncated sanitized string) instead of raw `r.url`.


> **Status: Solved** (D78). An empty URL reports *the server gives no address*; a URL that isn't a readable http(s) address reports *not a web address* instead of the server's text; host and MIME type in messages are cut to 40 characters.

---

### 2.3. `dvp/dlna.lua`: `private_ipv4` accepts out-of-range IPv4 octets (`> 255`), and `split_url` / `lan_host` reject bracketed IPv6 ULA literals (`[fd00::/8]`)

* **Severity:** Low (Bug / Compatibility)
* **Location:** `app/share/deckvideoplayer/mpv/scripts/deckplayer/dvp/dlna.lua` (`private_ipv4` lines 128–133, `lan_host` lines 247–249)
* **Problem:**
  1. `private_ipv4` parses `a, b` with `"^(%d+)%.(%d+)%.%d+%.%d+$"` and checks `a == 10`, `a == 192 and b == 168`, `172.16..31`, and `169.254` without bounds-checking all four octets to `0..255`. Verified: `lan_host("192.168.999.1", "192.168.1.50")` returns `true`.
  2. Verified: `lan_host("fd00::1", "192.168.1.50")` returns `false` and `split_url("http://[fd00::1]:8200/v.mp4")` returns `nil, nil`. While `helper/dvp-discover.c` discovers servers over IPv4 SSDP today, dual-stack DLNA servers can still advertise local ULA (`fc00::/7`) or link-local (`fe80::`) URLs in `<res>`.
* **Suggested Fix:**
  Validate all four octets (`0 <= o <= 255`) in `private_ipv4`. Optionally support bracketed IPv6 hosts in `split_url` alongside `fc00::/7` / `fe80::/10` if IPv6 DLNA URLs are ever encountered.


> **Status: Partly solved** (D78). All four octets are checked (0–255). IPv6 declined for now: servers are found over IPv4 SSDP and every server tested lists IPv4 URLs; supporting bracketed IPv6 hosts would also need `split_url`, the browse requests and the download path. To revisit on a report.

---

### 2.4. `dvp/dlna.lua`: `entries_from` keeps only the first skipped item's reason in the folder empty-state summary

* **Severity:** Low (Diagnostic UX)
* **Location:** `app/share/deckvideoplayer/mpv/scripts/deckplayer/dvp/dlna.lua` (`entries_from`, lines 576–579) and `dvp/browser.lua` (`render`, lines 1306–1307)
* **Problem:**
  `skipped.why = skipped.why or why` retains the reason from the first skipped item only, while incrementing `skipped.count` for all subsequent skipped videos (verified: mixed skipped entries produce `count = 2` with only the first item's reason). A single malformed promo/placeholder item at the top of a folder masks the reason all remaining videos were skipped in `"%d %s skipped: %s."`.
* **Suggested Fix:**
  Track counts per reason and display the dominant reason (or include distinct reasons if few) when all videos are skipped.


> **Status: Solved** (D78). Reasons are counted; the message shows the most common one (`main_reason`, ties alphabetical for a stable message).

---

## 3. Flatpak Fontconfig Launcher & Pre-Release Bookkeeping (`app/bin/deckvideoplayer`, `CHANGELOG.md`)

### 3.1. `app/bin/deckvideoplayer`: `conf.d` evaluation order and per-launch `fonts.conf` rewrite

* **Severity:** Low (Robustness / Optimization)
* **Location:** `app/bin/deckvideoplayer` (lines 86–112) and `packaging/flatpak/io.github.nicocarbone.DeckVideoPlayer.yml`
* **Problem & Verified Behavior:**
  1. In `org.freedesktop.Platform//26.08`, `app/bin/deckvideoplayer` inserts all `/etc/fonts/conf.d/*.conf` files (except `50-flatpak.conf`) **before** `<dir>/app/share/fonts</dir>`, `/app/etc/fonts/local.conf`, `/run/host/*-fonts`, and `<cachedir prefix="xdg">fontconfig</cachedir>` (whereas standard `/etc/fonts/fonts.conf` lists directories and cache paths around `conf.d` so `50-user.conf` / `51-local.conf` apply after the base `<dir>` entries). Also, `/usr/local/share/fonts` and `~/.fontconfig` from `/etc/fonts/fonts.conf` are dropped.
  2. `deckvideoplayer` rewrites `$XDG_CACHE_HOME/deckvideoplayer/fonts.conf` on every startup (`mv "$fc_file.tmp" "$fc_file"`), and the Flatpak image has no prebuilt `/app/cache/fontconfig` for the bundled `/app/share/fonts/inter` directory. (Testing in 26.08 confirmed that `touch "$fc_file"` keeps warm `fc-match Inter` at ~21 ms vs ~680 ms cold, so rewriting `fonts.conf` does **not** trigger cache rebuilds, making the per-launch rewrite only minor unnecessary I/O.)
* **Suggested Fix:**
  * Preserve `/etc/fonts/fonts.conf` ordering (base `<dir>`s and aliases before `conf.d/*.conf`, with `50-flatpak.conf`'s safe host `<dir>`/`<cachedir>` entries before user/local overrides).
  * Only write `$fc_file` when missing or changed, and optionally run `fc-cache` on `/app/share/fonts` into `/app/cache/fontconfig` during the Flatpak build so immutable app fonts ship pre-indexed.


> **Status: Partly solved** (D78). The replacement of `50-flatpak.conf` now stands where that file does among the `conf.d` rules, the runtime's cache folders follow `conf.d` as in its `fonts.conf`, `/usr/local/share/fonts` and `~/.fontconfig` are back, and the file is replaced only when its content changes. Pre-indexing `/app/share/fonts` at build time declined: two font files, indexed in a few milliseconds once.

---

### 3.2. `CHANGELOG.md`: Heading still reads `(unreleased)` alongside dated metainfo and bumped version

* **Severity:** Info (Release checklist)
* **Location:** `CHANGELOG.md` line 8 (`## v0.8.4 (unreleased)`), vs `app/share/deckvideoplayer/mpv/scripts/deckplayer/dvp/version.lua` (`"0.8.4"`) and `packaging/flatpak/io.github.nicocarbone.DeckVideoPlayer.metainfo.xml` line 63 (`date="2026-11-14"`).
* **Note:** `scripts/release-notes.sh 0.8.4` already extracts the section cleanly; replace `(unreleased)` with the release date when tagging `v0.8.4`.


> **Status: Accepted** (release checklist). The date goes in when `v0.8.4` is tagged.

---

## 4. v0.8.4 (Part XI) Summary Checklist

- [x] **Audio DSP (`dvp/tvmix.lua`, `dvp/surround.lua`):** Handle `22.2` cleanly (avoid invalid `LFE2` `pan` graph / unsupported `sofalizer` layout) and do not permanently set `self.available = false` for the rest of the session when `af add` rejects a specific track's layout.
- [x] **Playback Info (`dvp/player.lua`):** Observe `audio-out-params` (or `audio-params/channels`) and `af` when the info panel is open so switching audio tracks while paused updates `Audio out` and filter tags once `mpv` reconfigures audio.
- [x] **DLNA Filtering (`dvp/dlna.lua`):** Match `http-get:` and `video/` case-insensitively in `pick_res`; report empty `<res>` URLs as `"the server gives no address"` without leaking raw malformed `r.url` values into the UI; validate all four IPv4 octets (`0–255`) in `private_ipv4`; consider showing the dominant skip reason when all items in a folder are skipped.
- [x] **Flatpak Launcher & Release (`app/bin/deckvideoplayer`, `CHANGELOG.md`):** Keep base font `<dir>` ordering ahead of `conf.d` rules (avoid rewriting `fonts.conf` when unchanged, optionally pre-cache `/app/share/fonts` into `/app/cache/fontconfig`), and update `CHANGELOG.md` `(unreleased)` when tagging `v0.8.4`.

---

# Part X — v0.8.0 Audit: Old SD Video Filters (Deinterlacing, CRT Look, Film Grain & Clean-up) (2026-11-03)

All 695 Lua checks and 10 Python unit tests in `tests/run.sh` pass, and the v0.8.0 filter architecture (`dvp/looks.lua`, `mpv/shaders/dvp-crt.glsl`, `mpv/shaders/dvp-grain.glsl`, `mpv/mpv.conf`, `dvp/display.lua`, `dvp/player.lua`, `main.lua`, D69) was audited for mathematical correctness, GPU/CPU optimality, and state management:

* **Overall filter choices & pipeline order (D69):**
  * **`deinterlace=auto` (`mpv/mpv.conf`):** Correct. Frame-per-field deinterlacing (`29.97i → 59.94 fps`, `25i → 50 fps`) using VA-API `vavpp` where supported and `bwdif` on CPU otherwise, active only on frames flagged interlaced.
  * **Clean-up (`fspp=qp=4` for Light, `fspp=qp=8,hqdn3d=2:1.5:3:2.25` for Strong + libplacebo `deband` 1 or 2 iterations):** Well-tuned for SD video, and restricting `fspp`/`hqdn3d` to SD (`<= 1024×576`) is the right call because FFmpeg's `fspp` is single-threaded on CPU. However, **on hardware-decoded SD videos (`hwdec=vaapi`, e.g. SD H.264/x264, HEVC, VP9, AV1), `vf_lavfi` fails to configure the filter graph and disables `dvp-cleanup`** unless `mpv`'s native `format:fmt=yuv420p` filter precedes it to trigger `autoconvert` hardware download (see **§2.1** below).
  * **Shader hook point (`//!HOOK SCALED`, grain before CRT):** Correct. Under `vo=gpu-next` (`libplacebo`), `SCALED` contains only the scaled video area (excluding black bars, subtitles, and the OSD) in linear light. Running `dvp-grain.glsl` before `dvp-crt.glsl` ensures the CRT scanlines and aperture-grille mask modulate the grainy image rather than adding digital noise on top of the dark scanline gaps.

Below are the shader bugs, GPU optimizations, and Lua state synchronization issues found in the new v0.8.0 code.

---

## 1. Shader Correctness & GPU Optimizations (`dvp-grain.glsl`, `dvp-crt.glsl`)

### 1.1. `mpv/shaders/dvp-grain.glsl`: `gl_FragCoord.xy` is at half-integer pixel centers `(x + 0.5, y + 0.5)`, making 16:9 videos on the Steam Deck (`HOOKED_size.y <= 720`, `cell == 1.0`) 2.2× weaker (`3.33` RMS vs `7.37` RMS) and 2×2 box-blurred (*verified mathematically*)

* **Location:** `app/share/deckvideoplayer/mpv/shaders/dvp-grain.glsl` (lines 47–53)
* **Problem (*verified*):**
  ```glsl
  float cell = max(1.0, HOOKED_size.y / 720.0);
  vec2 seed = vec2(float(frame % 509) * 17.0, float(frame % 397) * 29.0);
  float n = grain(gl_FragCoord.xy / cell, seed);
  // Interpolated noise is weaker than per-pixel noise: the same amount
  // looks the same on any screen.
  if (cell > 1.0) n *= 1.5;
  ```
  1. **Half-integer `gl_FragCoord.xy` when `cell == 1.0`:**
     In GLSL fragment shaders, `gl_FragCoord.xy` at pixel `(x, y)` is `(x + 0.5, y + 0.5)`, not integer `(x, y)`.
     When `cell == 1.0`, `p = gl_FragCoord.xy / 1.0 = (x + 0.5, y + 0.5)`, so `fract(p)` inside `grain()` is **`vec2(0.5, 0.5)` for every single pixel on screen**.
     Instead of producing per-pixel independent noise (where `f = (0, 0)` has $\text{RMS} = 1/\sqrt{12} \approx 0.289$, or `6.63` levels out of 255 for Medium grain), `mix(mix(a, b, 0.5), mix(c, d, 0.5), 0.5)` computes the **4-corner average `(a + b + c + d) / 4`**—which blurs the grain over 2×2 pixel blocks and cuts the standard deviation in half ($\text{RMS} = 1 / (2\sqrt{12}) \approx 0.144$).
  2. **Large jump between 16:9 (`HOOKED_size.y <= 720`) and 4:3 (`HOOKED_size.y = 800`) on the Steam Deck (`1280×800`):**
     Because `SCALED` is the video area without letterbox bars:
     * A **16:9** (or 1.85:1 / 2.35:1 / cropped) video on the 1280×800 Steam Deck has `HOOKED_size.y <= 720`, so `cell = 1.000`. It gets the 4-corner average **without** `n *= 1.5`, yielding a mid-tone RMS of only **`3.33` levels** (out of 255) for Medium grain.
     * A **4:3** video on the 1280×800 Steam Deck has `HOOKED_size.y = 800`, so `cell = 800.0 / 720.0 = 1.111 > 1.0`. It triggers `if (cell > 1.0) n *= 1.5`, yielding **`7.37` levels RMS** (**2.2× stronger** than a 16:9 video on the same screen!) and a 9-pixel spatial beat pattern (`800 / 720 = 10 / 9`) where every 9th pixel hits `fract ≈ 0` and 4.5 pixels away hits `fract ≈ 0.5`.
* **Suggested Fix:**
  Divide by `800.0` (the Steam Deck's vertical resolution) so all videos on the Deck have `cell == 1.0`, and when `cell <= 1.0` sample `hash(floor(gl_FragCoord.xy) + seed) - 0.5` directly (which gives true 1-pixel grain with `6.63` levels RMS for both 4:3 and 16:9 on the Deck, eliminates the 9-pixel beat pattern, and executes 1 `hash()` call per pixel instead of 4):
  ```glsl
  float cell = max(1.0, HOOKED_size.y / 800.0);
  vec2 seed = vec2(float(frame % 509) * 17.0, float(frame % 397) * 29.0);
  float n = cell <= 1.0 ? hash(floor(gl_FragCoord.xy) + seed) - 0.5
                        : 1.5 * grain((gl_FragCoord.xy - 0.5) / cell, seed);
  ```

> **Status: Solved** (D70). Confirmed: with one-pixel cells every pixel read `fract == 0.5`. One pixel per grain up to 800 lines (`hash(floor(gl_FragCoord.xy))`), interpolated grains above at `(gl_FragCoord.xy - 0.5) / cell`. The per-pixel noise gets ×1.1 so it measures as strong as the interpolated grains and as the 4:3 case the strengths were tuned on: Medium on mid-grey at 1280×800 is 7.5 levels RMS for 16:9 and 4:3 (was 3.4 and 7.6), with no neighbour correlation, and 7.6 at 4K (unchanged).

---

### 1.2. `mpv/shaders/dvp-crt.glsl`: `beam_mean` loop can be replaced with a closed-form expression (eliminating up to 90 `exp()` calls per pixel at 4K), `row = HOOKED_pos.y * h` has float sign jitter at `d == 0`, and `col` is not clamped to `[0, 1]` before `SDR to HDR`

* **Location:** `app/share/deckvideoplayer/mpv/shaders/dvp-crt.glsl` (`beam_mean` lines 46–54, `hook` lines 67–99)
* **Problems & Optimizations:**
  1. **Closed-form `beam_mean` (GPU ALU optimization & 2-beam vs 3-beam normalization):**
     ```glsl
     vec3 beam_mean(vec3 s, float n, float centre) {
         vec3 sum = vec3(0.0);
         for (int j = 0; j < 16; j++) {
             if (float(j) >= n) break;
             float d = (float(j) + 0.5 - centre) / n;
             sum += beam(d, s) + beam(d - 1.0, s) + beam(d + 1.0, s);
         }
         return sum / n;
     }
     ```
     * `beam_mean` is called twice per pixel (`s1` and `s2`). At 4K (`n = 5`), each call runs 5 iterations × 3 `vec3` `exp()` evaluations = 45 scalar `exp()` calls (**90 scalar `exp()` calls per pixel**, or ~746M `exp()` calls per 4K frame).
     * For $n \ge 3$ and $\sigma \in [0.24, 0.42]$, by the Poisson summation formula ($\exp(-2\pi^2 \sigma^2 n^2) \le e^{-10.23} = 3.6 \times 10^{-5}$), the Riemann sum of the Gaussian over a scanline equals the continuous Gaussian integral $\sigma\sqrt{2\pi} \approx 2.5066283 \cdot s$ to within **0.05%** (`< 0.0006`, well below 1/255).
     * For $n = 2$ (`centre = 0.5`, $j \in \{0, 1\}$), with $q = \exp(-0.125 / (s \cdot s))$, $\exp(-0.5 / (s \cdot s)) = q^4$ and $0.5 \cdot q^9 < 3 \times 10^{-5}$, so `beam_mean` is `0.5 + q + q * q * q * q` using only **1** `vec3 exp()` call instead of 6.
     * *(Note also that `beam_mean` sums 3 beams `d`, `d - 1`, and `d + 1`, whereas `col` on lines 82–83 only sums the 2 nearest beams `d` and `d2`; for the exact 2-beam mean at $n = 2$, the $d = \pm 1$ tail occurs once rather than twice, i.e. `0.5 + q + 0.5 * q * q * q * q`.)*
  2. **Float interpolation jitter on the scanline center row (`d == 0.0`):**
     ```glsl
     float centre = floor((n - 1.0) / 2.0) + 0.5;
     float row = HOOKED_pos.y * h;
     float k = floor(row / n);
     float d = (row - k * n - centre) / n;
     float k2 = d < 0.0 ? k - 1.0 : k + 1.0;
     ```
     Because `HOOKED_pos.y` is an interpolated vertex attribute, at pixel centers `HOOKED_pos.y * h` is `m + 0.5 ± 1e-7`. On the center row of a scanline (every even row when $n = 2$ on the Steam Deck, or the middle row for any odd $n$), exact `d` is `0.0`, so `d` fluctuates between `-1e-7` and `+1e-7` across the row, causing `k2 = d < 0.0 ? k - 1.0 : k + 1.0` to flip randomly between the upper and lower neighbor scanlines from pixel to pixel. Snapping `float row = floor(HOOKED_pos.y * h) + 0.5;` makes `d` exact.
  3. **Unclamped super-white output (`> 1.0`) when combined with *SDR to HDR*:**
     At the center of a bright scanline (`d = 0`), dividing by `beam_mean` and the aperture-grille mean produces linear values up to `~1.70`. On an SDR swapchain this clips at `1.0`, but `SCALED` in `vo=gpu-next` is a floating-point `rgba16f` texture: when the user enables **SDR to HDR** on an HDR display (Steam Deck OLED or HDR TV), unclamped values up to `1.70` are fed into libplacebo's inverse tone mapper / PQ output. Clamping `return vec4(clamp(col, 0.0, 1.0), 1.0);` (as `dvp-grain.glsl` does on line 54) keeps the output within SDR `[0, 1]`.

> **Status: Solved** (D70). Closed-form `beam_mean` (`0.5 + q + q^4` with 2 rows, `s * sqrt(2 pi)` above), checked against the loop over the shader's whole sigma range (worst 0.05 %); the row is snapped to the pixel centre; the output is clamped to `[0, 1]`. Screenshots match the previous build to 1 level (1280×800) and 3 levels (4K). The "exact two-beam" mean was not taken: the current normalization (a third beam's tail, under 1 % brighter) is the look the owner approved.

---

## 2. Filter Graph, State Synchronization & Lifecycle Bugs (`dvp/looks.lua`, `dvp/player.lua`, `dvp/display.lua`, `main.lua`)

### 2.1. `dvp/looks.lua`: *Clean-up* (`lavfi` `fspp` / `hqdn3d`) fails to configure and disables itself on all hardware-decoded SD videos (`hwdec=vaapi`, e.g. SD H.264, HEVC, VP9, AV1) (*verified in headless gamescope*)

* **Location:** `app/share/deckvideoplayer/mpv/scripts/deckplayer/dvp/looks.lua` (`Looks.option_values`, lines 110–113 and 125–129)
* **Problem (*verified*):**
  In `Looks.option_values`:
  ```lua
  local clean = CLEANUP[choice.cleanup]
  if clean then
      out.deband, out["deband-iterations"] = "yes", clean.iterations
      vf[#vf + 1] = {name = "lavfi", label = M.FILTER_LABEL, enabled = true, params = {graph = clean.graph}}
  end
  ```
  On MPEG-4 Part 2 (XviD) and MPEG-2 videos, `mpv`'s default `hwdec-codecs` list leaves them in software (`yuv420p`), so `fspp` works.
  However, on **any SD video that is hardware-decoded by `hwdec=vaapi`** (every SD H.264/x264, HEVC/x265, VP9, or AV1 file or server stream), `mpv`'s `vf_lavfi` wrapper advertises support for `vaapi` hardware surfaces (in case the `lavfi` graph is a VA-API graph), and `libavfilter`'s `auto_scale_0` (`swscale`) cannot convert `src: vaapi` to `dst: yuv420p` without a hardware download:
  ```
  Using hardware decoding (vaapi).
  [ffmpeg] Impossible to convert between the formats supported by the filter 'mpv_src_in0' and the filter 'auto_scale_0'
  [ffmpeg] Link 'mpv_src_in0.default' -> 'auto_scale_0.default':
  [ffmpeg]   src: vaapi
  [ffmpeg]   dst: yuv420p ...
  [lavfi] failed to configure the filter graph
  Disabling filter dvp-cleanup because it has failed.
  ```
  As a result, `dvp-cleanup` (`fspp` and `hqdn3d`) **completely fails and disables itself** on every hardware-decoded SD video while the Video menu and Playback info panel continue to claim `Clean-up: Light` or `Strong` is active.
* **Suggested Fix (*verified in headless gamescope*):**
  Precede the `lavfi` entry with `mpv`'s native `format` filter (`{name = "format", label = M.FORMAT_LABEL, enabled = true, params = {fmt = "yuv420p"}}`). Because `mpv`'s `vf_format` only accepts CPU `yuv420p`, `mpv`'s `autoconvert` automatically inserts `[autoconvert] HW-downloading from vaapi` + `[autoconvert] Converting nv12 -> yuv420p` when `hwdec=vaapi` is active (after `deinterlace=auto` has already run `vavpp` on the GPU if interlaced), and is a no-op when the video is already software-decoded `yuv420p`. When `Clean-up` is turned back to `Off`, removing both `M.FORMAT_LABEL` and `M.FILTER_LABEL` from `vf` restores zero-copy `vaapi[nv12]` immediately without restarting the decoder.

> **Status: Solved** (D70). Reproduced in headless gamescope with a 640×480 H.264 file ("Disabling filter dvp-cleanup because it has failed"). mpv's `format` filter (`yuv420p`, labelled `dvp-cleanup-format`) now precedes the lavfi entry: `HW-downloading from vaapi`, no failure, 0 dropped frames; also checked with interlaced H.264 (VA-API, deinterlaced to 59.94 fps), XviD (software, unchanged) and an HD file afterwards (both entries removed, zero-copy VA-API). Unit tests cover the order and the removal.

---

### 2.2. `dvp/looks.lua`: `Looks:start` captures `self.base` at `file-loaded` instead of startup (`Looks.new`), and `option_values` does not strip `CRT_SHADER` / `GRAIN_SHADER` from `base.shaders`

* **Location:** `app/share/deckvideoplayer/mpv/scripts/deckplayer/dvp/looks.lua` (`Looks.option_values` lines 104–114, `Looks.new` lines 164–182, `Looks:start` lines 193–211) and `main.lua` (`file-loaded` line 454)
* **Problems:**
  1. Unlike `Hdr.new` (`dvp/hdr.lua` lines 148–152) and `Player.new` (`dvp/player.lua` lines 41–48), which snapshot the user's configured defaults once at startup after `mpv.conf` is loaded, `Looks:start` re-reads `self.base` (`glsl-shaders`, `glsl-shader-opts`, `vf`, `deband`, `deband-iterations`) from mpv on every `file-loaded`.
  2. If `video-params` or `video-crop` fires during a file transition before `file-loaded` runs (while `self.base` is still non-nil from the previous file), `Looks:video_changed` applies the previous file's shaders/deband to the new file *before* `Looks:start` reads `self.base`.
  3. While `Looks.option_values` filters `f.label ~= M.FILTER_LABEL` out of `base.vf` (line 112), it does not filter `CRT_SHADER` or `GRAIN_SHADER` out of `base.shaders`, nor can it tell if `base.deband` was mutated before `Looks:start`.
  4. Conversely, if `video-params` is already populated before `Looks:start` runs in `file-loaded`, `Looks:start` sets `self.sdr, self.sd, self.lines = nil, nil, nil` without calling `self:video_changed(mp.get_property_native("video-params"))` at the end of `start()`.
* **Suggested Fix:**
  Capture `self.base` once in `Looks.new` (after `display:apply_profile()` in `main.lua`), filter `CRT_SHADER` and `GRAIN_SHADER` out of `base.shaders` in `option_values` (just like `M.FILTER_LABEL` in `base.vf`), reset `self.key = nil; self.sdr = nil` in `on_load`, and call `self:video_changed(mp.get_property_native("video-params"))` at the end of `Looks:start(key)`.

> **Status: Partly solved** (D70). Done: `option_values` leaves our shaders out of the base, as it already did our filters; `self.base` is cleared at `end-file`, so nothing is applied between files; `start()` calls `video_changed` with the current `video-params`. Declined: reading the base once at startup. When the next file loads, mpv has already restored the file-local values, so the options read then are the user's own (including changes made during the session). Also, `file-local-options` can't be written while no file is playing.

---

### 2.3. `dvp/looks.lua`, `dvp/player.lua` & `main.lua`: Changing `Look`, `Grain`, `Clean-up`, or `Decoding` while paused (or when `video-params` arrives) does not refresh the Playback info panel, open menus, or `[HW]` badge

* **Location:** `app/share/deckvideoplayer/mpv/scripts/deckplayer/dvp/looks.lua` (`video_changed` lines 213–219), `dvp/player.lua` (`hwdec-current` observer lines 49–52, `main_menu_items` line 753), and `main.lua` (menu input handling lines 326–334)
* **Problems:**
  1. **Playback info panel (`View`) stays stale while paused:** When a video is paused, `player.timer` (`0.5 s`) is stopped to save battery. In `main.lua` line 329, handling a menu action over the player calls `player:render()` but not `player:render_info()`. Adjusting **Look**, **Grain**, **Clean-up**, or **Match refresh rate** in the Video menu while paused leaves the `Look` and `Display` rows in an open Playback info panel outdated.
  2. **`hwdec-current` observer does not redraw the overlay or info panel:** In `dvp/player.lua` lines 49–52:
     ```lua
     mp.observe_property("hwdec-current", "string", function()
         -- The decoder switches a moment after the choice: update the row.
         if self.video_menu and self.ctx.menu:shows(self.video_menu) then self.ctx.menu:refresh() end
     end)
     ```
     When the user toggles **Decoding** (`Hardware` ↔ `Software`) while paused (or when `hwdec-current` becomes known a moment after `file-loaded` on a file started paused), `hwdec-current` changes asynchronously, but neither `self:render()` (the `[HW]` badge) nor `self:render_info()` (the `Decoder` row) is called.
  3. **`Looks:video_changed` does not refresh an open menu or info panel:** As verified with `mpv`, `video-params` is still `nil` when `file-loaded` runs and only becomes non-nil when the first video frame is decoded. If the **Video** or **Playback** menu (or **Playback info** panel) is opened before the first frame is decoded—or when switching video tracks (`vid`)—`Looks:video_changed` sets `self.sdr` and `self.sd` and applies the remembered look without calling `menu:refresh()` or `player:render_info()`. Also, in `Player:main_menu_items()` (`dvp/player.lua` line 753), `Video` uses `value = self:video_summary()` (a static string) instead of `value = function() return self:video_summary() end`.
* **Suggested Fix:**
  * In `main.lua` line 329, also call `player:render_info()` when `state.screen == "player"`.
  * In `dvp/player.lua`'s `hwdec-current` observer, also call `if self.overlay_visible then self:render() end` and `if self.info_visible then self:render_info() end`.
  * Pass an `on_change` callback to `Looks.new` (like `Hdr.new`) that calls `if menu:is_open() then menu:refresh() end` and `player:render_info()` when `self.sdr` or `self.sd` changes in `Looks:video_changed`, and make `Video`'s `value` in `main_menu_items()` a function `function() return self:video_summary() end`.

> **Status: Solved** (D70). The info panel is redrawn after every menu action over the player; the `hwdec-current` observer redraws the overlay (HW badge) and the info panel; `looks.on_change` refreshes an open menu and the info panel when the video turns out SDR/HDR or SD/HD; the main menu's Video row is a function. (That row could not show a stale value in practice: B on the Video menu closes all menus, and the main menu is rebuilt when it opens.)

---

### 2.4. `dvp/display.lua` & `main.lua`: `Display:rematch` exits early if `self.requested_hz` was `nil`, and the `deinterlace-active` observer ignores transitions back to `false`

* **Location:** `app/share/deckvideoplayer/mpv/scripts/deckplayer/dvp/display.lua` (`Display:rematch` lines 319–324) and `main.lua` (`deinterlace-active` observer lines 485–489)
* **Problems:**
  1. In `Display:rematch`:
     ```lua
     function M:rematch(fps, on_result)
         if not self.requested_hz or not self.rates then return nil end
         local hz = M.choose_rate(fps, self.rates, self.cfg.display.refresh_prefer)
         if not hz or hz == self.requested_hz then return nil end
         return self:match(fps, on_result)
     end
     ```
     If `display:match()` at `file-loaded` returned `nil` (for example, `container-fps` was not yet known or had no match in `self.rates`, leaving `self.requested_hz = nil`), `rematch` refuses to run when `deinterlace-active` becomes `true` even if the doubled frame rate *does* have a match in `self.rates`.
  2. In `main.lua` lines 485–489:
     ```lua
     mp.observe_property("deinterlace-active", "bool", function(_, active)
         if active and state.current_path then
             display:rematch(Display.video_fps(), function() player:render() end)
         end
     end)
     ```
     Only calls `display:rematch` when `active` is `true` (ignoring transitions from interlaced to progressive content where `active` becomes `false`), and does not call `player:render_info()` to update the `Deinterlacing` row in the Playback info panel.
* **Suggested Fix:**
  * In `Display:rematch`, check `if not (self.refresh_possible and self.refresh_on) or not self.rates then return nil end`.
  * In `main.lua`, call `display:rematch` whenever `state.current_path` is set (whether `active` is `true` or `false`) and call `player:render_info()`.

> **Status: Partly solved** (D70). `rematch()` now runs whenever matching is on and the rates are known, also when the container's rate gave no refresh rate. The `deinterlace-active` observer redraws the info panel. Declined: matching again when deinterlacing stops. The doubled rate is still a multiple of the frame rate, and on material that mixes interlaced and progressive parts every change would blank the screen for a refresh switch.

---

## 3. v0.8.0 (Part X) Summary Checklist

- [x] **Grain shader (`mpv/shaders/dvp-grain.glsl`):** Fix `cell == 1.0` half-integer `gl_FragCoord.xy` (`fract == 0.5`) and `HOOKED_size.y / 800.0` threshold so 16:9 and 4:3 videos on the Steam Deck have the same grain strength and 1-pixel grain size.
- [x] **CRT shader (`mpv/shaders/dvp-crt.glsl`):** Snap `row = floor(HOOKED_pos.y * h) + 0.5` to prevent `d == 0` sign jitter, replace the `beam_mean` loop with the closed-form expression (1 `exp` for $n=2$, $\sigma\sqrt{2\pi}$ for $n \ge 3$), and clamp `col` to `[0, 1]`.
- [x] **Clean-up with hardware decoding (`dvp/looks.lua`):** Precede the `lavfi` filter (`fspp` / `hqdn3d`) with `mpv`'s `format:fmt=yuv420p` filter so `autoconvert` downloads `vaapi` hardware frames on SD H.264/HEVC/VP9/AV1 videos instead of failing and disabling `dvp-cleanup`.
- [x] **Looks lifecycle (`dvp/looks.lua`, `main.lua`):** *(Partly: the base is still read per file, by design.)* Snapshot `self.base` once in `Looks.new`, strip `CRT_SHADER` / `GRAIN_SHADER` from `base.shaders`, and call `video_changed` from `Looks:start`.
- [x] **UI sync (`dvp/looks.lua`, `dvp/player.lua`, `main.lua`):** Refresh open menus and `player:render_info()` when `Looks:video_changed` or `hwdec-current` fires or when menu items are adjusted while paused.
- [x] **Deinterlace refresh matching (`dvp/display.lua`, `main.lua`):** *(Partly: no new switch when deinterlacing stops.)* Allow `Display:rematch` when `self.requested_hz` is `nil`, and handle `deinterlace-active` transitions to `false`.
- [ ] **Release metadata (`dvp/version.lua`, `CHANGELOG.md`, `metainfo.xml`):** *(Expected while in development: done at release, as for every version; the check exists so a `-dev` version can't be released.)* Bump from `"0.8.0-dev"` to `"0.8.0"` with `CHANGELOG.md` and `<release>` entries when tagging (`tests/run.sh` currently fails on the `-dev` check).
---
---

# Part IX — v0.6.0–v0.7.1 Audit: Offline Downloads, Local Video Deletion, Per-Video Decoding, Async Folder Listings & DLNA Servers (2026-10-30)

All 636 Lua checks and 10 Python unit tests in `tests/run.sh` pass, and the v0.6.0–v0.7.1 additions were reviewed across the codebase:
* **Offline downloads (`dvp/downloads.lua`, `dvp/plex.lua`, `dvp/jellyfin.lua`, `dvp/dlna.lua`, D60, D67):** Sequential queue, `.part` resume via `curl`, free-space checks, subtitle sidecar transfers, and persistence in `downloads.json`.
* **Local video deletion (`dvp/library.lua`, `dvp/browser.lua`, D60):** Path validation (`delete_refusal`), sidecar subtitle removal (`sidecar_subtitles`), and empty parent folder cleanup.
* **Per-video hardware/software decoding (`dvp/player.lua`, `dvp/resume.lua`, `main.lua`, D62):** Sustained dropped-frame detection (`sustained_drops`) and per-video `hwdec` override.
* **Async subprocess folder listings & network share handling (`dvp/library.lua`, `dvp/browser.lua`, D64, D65):** Non-blocking `find` listing with 60 s timeout, `B` cancellation, and zero `stat()` calls on network/automount paths during startup.
* **DLNA servers (`dvp/dlna.lua`, `helper/dvp-discover.c`, `tools/mock-dlna.py`, D66, D67):** SSDP `--ssdp` discovery, SOAP `ContentDirectory` browsing/paging, DIDL-Lite parsing, host-checked resource selection, local progress/watched tracking, and DLNA downloads.

Below are the bugs, edge cases, and robustness issues found in the new and existing code (`dvp/downloads.lua`, `dvp/http.lua`, `dvp/dlna.lua`, `dvp/subdownload.lua`, `dvp/library.lua`, `dvp/browser.lua`, `dvp/videoinfo.lua`, `dvp/resume.lua`, and `main.lua`).

---

## 1. Offline Downloads & HTTP Transfer Bugs (v0.6.0–v0.7.1)

### 1.1. `dvp/downloads.lua` & `dvp/http.lua`: `Downloads.outcome(code, status)` returns `"done"` whenever `code == 200` or `206` even if `curl` exited with a non-zero error `status` mid-transfer (*verified with `curl`*)

> **Status: Not a bug** (D68). The quoted `outcome` is not the code in the repository: `downloads.lua` returns `"done"` for 200/206 only when curl's status is 0 (`status == 0 and (code == 200 or code == 206)`), so a transfer cut off after the headers is retried with curl's reason and a full disk (23) fails. Tests added for both cases (`DL.outcome(200, 18)`, `DL.outcome(200, 23)`).

* **Location:** `app/share/deckvideoplayer/mpv/scripts/deckplayer/dvp/downloads.lua` (`Downloads.outcome` lines 194–204, `Downloads:transferred` lines 384–407) and `app/share/deckvideoplayer/mpv/scripts/deckplayer/dvp/http.lua` (`http.download` lines 139–152)
* **Problem (*verified with `curl`*):**
  In `http.download`, `curl` runs with `write-out = "\n%{http_code}\n"`. Whenever `curl` receives the HTTP `200 OK` or `206 Partial Content` response headers and then fails mid-stream—for example with exit status `18` (`Transferred a partial file`), `23` (`Failed writing received data to disk`), `28` (`Operation timeout` from `speed-limit = 1024` / `speed-time = 30`), `56` (`Failure when receiving data from the peer`), or `92` (`Stream error in the HTTP/2 framing layer`)—`curl` still prints `\n200\n` (or `\n206\n`) to `stdout` alongside `res.status ~= 0`.
  In `Downloads.outcome(code, status)`:
  ```lua
  function M.outcome(code, status)
      if code == 200 or code == 206 or status == 33 then return "done" end
      if code == 416 then return "restart" end
      if code == 401 or code == 403 then return "fail", "The server refused the download (" .. code .. ")" end
      if code == 404 or code == 410 then return "fail", "No longer on the server" end
      if code and code >= 400 and code < 500 and code ~= 408 and code ~= 429 then
          return "fail", "HTTP error " .. code
      end
      if status == 23 then return "fail", "Disk full or write error" end
      if status == 63 then return "fail", "File too large" end
      return "retry", code and ("Server error " .. code) or M.CURL_REASONS[status] or "Connection lost"
  end
  ```
  Because line 195 checks `code == 200 or code == 206` without requiring `status == 0`:
  1. **Truncated file marked as `"done"` (`Completed`) when `job.size` is `nil`:** If a server omits the file size (e.g. a DLNA server that omits the optional `size` attribute on `<res>`), a mid-stream connection drop (`code = 200, status = 18` or `56` or `28`) returns `what = "done"`. Line 389 (`if what == "done" and job.size and have ~= job.size`) is skipped because `job.size` is `nil`, and `Downloads:transferred` renames the truncated `.part` file to `job.path` and marks the incomplete download as `"done"`.
  2. **Disk full (`status == 23`) retries 3 times instead of failing:** A full disk or write error happens while writing the `200`/`206` response body (`code = 200`, `status = 23`). Line 195 returns `"done"` before line 201 (`if status == 23`) can ever be reached, and line 390 turns it into `"retry", "Incomplete download"`.
  3. **v0.7.1 retry reasons (`M.CURL_REASONS[status]`) are masked as `"Incomplete download"`:** Whenever a transfer fails after the HTTP `200`/`206` header arrives (`status = 18`, `28`, `56`, `92`), `M.outcome` returns `"done"` and line 390 overwrites `why` with `"Incomplete download"`, hiding the actual `curl` error code (`M.CURL_REASONS[status]`).
* **Suggested Fix:**
  Require `status == 0 or status == nil` when `code == 200 or code == 206` in `Downloads.outcome(code, status)`, and check `status == 23` / `status == 63` before returning `"done"`:
  ```lua
  function M.outcome(code, status)
      if status == 23 then return "fail", "Disk full or write error" end
      if status == 63 then return "fail", "File too large" end
      if ((code == 200 or code == 206) and (status == 0 or status == nil)) or status == 33 then
          return "done"
      end
      if code == 416 then return "restart" end
      if code == 401 or code == 403 then return "fail", "The server refused the download (" .. code .. ")" end
      if code == 404 or code == 410 then return "fail", "No longer on the server" end
      if code and code >= 400 and code < 500 and code ~= 408 and code ~= 429 then
          return "fail", "HTTP error " .. code
      end
      return "retry", (code and code >= 500 and ("Server error " .. code))
          or M.CURL_REASONS[status] or "Connection lost"
  end
  ```

---

### 1.2. `dvp/browser.lua`: *"Show in the library"* (`Browser:open_folder`) replaces `self.stack` with a 1-element stack, breaking `Back` navigation and breadcrumbs for downloaded TV episodes

> **Status: Solved** (D68). `open_folder` builds the stack from the folder's source down (`Library › downloads › Show › Season 01`); B goes up level by level. Checked in headless gamescope.

* **Location:** `app/share/deckvideoplayer/mpv/scripts/deckplayer/dvp/browser.lua` (`Browser:open_folder` lines 658–666)
* **Problem:**
  Downloaded TV episodes are stored in `<download_folder>/<Show>/Season XX/<Episode>.mkv`. When the user selects a completed episode in *Menu → Downloads* and chooses **Show in the library**, `Browser:open_folder(path, select)` sets:
  ```lua
  self.stack = {{path = path, label = util.basename(path)}}
  ```
  Instead of building the folder stack from the source root (`Downloaded` → `<Show>` → `Season XX`), `self.stack` has only a single entry (`Season XX`):
  1. The breadcrumb header shows `Library › Season 01` instead of `Library › Downloaded › <Show> › Season 01`.
  2. Pressing **B (`Back`)** jumps straight out to the Start screen, skipping both `<Show>` and `Downloaded`.
* **Suggested Fix:**
  Refresh `self.sources`, find the enclosing source with `library.source_for(path, self.sources)`, and push each directory level from `source.path` down to `path` onto `self.stack`.

---

### 1.3. `dvp/downloads.lua`: Cancelling a download (or failing `check_space`) leaves empty `<Show>/<Season XX>` directories inside `download_folder`

> **Status: Solved** (D68). `library.prune_folders` (shared with `delete_video`) removes the empty folders made for a download when it is cancelled or refused for lack of space, never the download folder itself.

* **Location:** `app/share/deckvideoplayer/mpv/scripts/deckplayer/dvp/downloads.lua` (`Downloads:start` lines 349–357, `Downloads:cancel` lines 503–522)
* **Problem:**
  `Downloads:start` creates `<download_folder>/<Show>/Season XX` via `util.mkdir_p(dir)` before checking free space and before the download completes. If `check_space` fails or the user cancels the download via **Cancel download**, `Downloads:cancel(job)` removes `.part` (and `job.path` if `job.saved`), but leaves the empty `<Show>/Season XX` and `<Show>` directories behind.
  Because `library.sources` (`dvp/library.lua` line 127) includes the `Downloaded` source whenever `#(util.readdir(downloads, "all") or {}) > 0`, a cancelled episode download leaves `Downloaded` visible on the Start screen containing only empty `<Show>/<Season XX>` folders that cannot be deleted from the UI.
* **Suggested Fix:**
  After removing files in `Downloads:cancel` (and when `check_space` fails in `Downloads:start`), walk upward from `util.dirname(job.path)` removing empty directories up to `download_folder` (just as `library.delete_video` does in `dvp/library.lua` lines 317–322).

---

### 1.4. `dvp/browser.lua`: Deleting a downloaded video from the Downloads menu can fail when `self.sources` is stale, and `downloads_changed()` drops library refreshes while a menu is open

> **Status: Solved** (D68). `delete` re-reads the sources before and after deleting; the browser goes up past a folder that is gone or no longer inside a source; a download that ends while a menu is open reloads the library when the menu closes (`menu_closed`).

* **Location:** `app/share/deckvideoplayer/mpv/scripts/deckplayer/dvp/browser.lua` (`Browser:confirm_delete` lines 626–634, `Browser:delete_file` lines 636–656, `Browser:downloads_changed` lines 677–681)
* **Problems:**
  1. **Stale `self.sources` in `confirm_delete` / `delete_file`:** When the app starts with an empty `download_folder`, `Downloaded` is not in `self.sources`. If the first download completes and the user selects **Delete from this device…** from *Menu → Downloads* before `self.sources` has been refreshed, `self.sources = self.sources or library.sources(...)` does not re-read `library.sources` because `self.sources` is already non-nil. Whenever `download_folder` is not inside another configured `folder` (e.g. `download_folder` on an SD card with `removable_media = no`, or in `~/Downloads/Downloaded`), `library.delete_video` rejects the deletion with `"Only videos on this device can be deleted"`.
  2. **Library view not refreshed when a download completes while a menu is open:** `Browser:downloads_changed()` returns early when `self.ctx.menu:is_open()` is `true`. If a download finishes while the user is viewing the **Downloads** menu (or any other menu) over the library and the user then closes the menu with **B**, `main.lua`'s `on_close` only calls `browser:render()`, not `browser:reload()`, so the newly created `Downloaded` source (or the new file / `"Downloaded"` tag) does not appear until a manual reload.
  3. **Deleting the last file inside `Downloaded`:** `library.delete_video` removes empty `<Show>/<Season>` subfolders but keeps the empty `download_folder` root itself (`dir ~= downloads`). When the user deletes the last file in `Downloaded`, `while self:location() and not util.is_dir(self:location().path)` stops at `download_folder` even though `refresh_sources()` removes `Downloaded` from `self.sources`, leaving the browser inside the now-unlisted empty folder.
* **Suggested Fix:**
  * Call `self:refresh_sources()` in `Browser:confirm_delete` and `Browser:delete_file`.
  * In `Browser:delete_file`, also pop `self.stack` when `not library.source_for(self:location().path, self.sources)`.
  * When `Browser:downloads_changed()` runs while `self.ctx.menu:is_open()`, set a flag (e.g. `self.needs_reload = true`) and trigger `self:reload()` when the menu closes.

---

## 2. DLNA Integration & Subtitle Search Bugs (v0.7.0–v0.7.1)

### 2.1. `dvp/subdownload.lua` & `dvp/dlna.lua`: Selecting *"Download subtitles…"* while playing a DLNA video crashes with `attempt to call method 'fetch_range' (a nil value)`

> **Status: Partly solved** (D68). The crash does not exist: `Dlna:fetch_range` is implemented (`dlna.lua`, with a Range request, as for Plex and Jellyfin). The title point is right: DLNA titles are now parsed like file names (`OpenSubtitles.parse_name`) for the search's title, year, season and episode.

* **Location:** `app/share/deckvideoplayer/mpv/scripts/deckplayer/dvp/subdownload.lua` (`SubDownload:hash_for` lines 115–142, `SubDownload.server_info` lines 71–76) and `app/share/deckvideoplayer/mpv/scripts/deckplayer/dvp/dlna.lua` (`Dlna:entries_from` lines 528–530)
* **Problems:**
  1. **`backend:fetch_range` crash:** `Dlna:entries_from` sets `server = {backend = "dlna", ..., size = r.size}`. When the user plays a DLNA video with `r.size >= 131072` (128 KiB) and opens **Download subtitles…** in the Subtitle menu (`X`), `SubDownload:hash_for(path, cb)` sees `item, backend = self:server_item(path)` and `tonumber(item.size) >= 2 * 65536`, and calls:
     ```lua
     backend:fetch_range(path, 0, 65535, head, done)
     backend:fetch_range(path, size - 65536, size - 1, tail, done)
     ```
     However, `dvp/dlna.lua` does not implement `fetch_range`! Lua throws `attempt to call method 'fetch_range' (a nil value)`, leaving the **Download subtitles** menu stuck forever on `"Searching…"` and leaking both `os.tmpname()` files (`head` and `tail`) in `/tmp`.
  2. **Unparsed DLNA title in `SubDownload.server_info(item)`:** Unlike Plex and Jellyfin, DLNA items have no structured `year`, `season`, or `episode` fields (`item.kind` is always `"movie"`). `SubDownload:open` calls `M.server_info(item)` which returns `{title = item.name, year = nil}`, so a DLNA item titled `"Show Name S01E02"` or `"The Matrix 1999"` is searched as a literal movie query without `season_number`, `episode_number`, or `year`.
* **Suggested Fix:**
  * Implement `Dlna:fetch_range(path, from, to, file, cb)` in `dvp/dlna.lua` (using `http.request` with `Range: bytes=from-to` and `max_size = to - from + 1`, just like `Plex:fetch_range` and `Jellyfin:fetch_range`), or guard `if not backend.fetch_range then return cb(nil) end` in `SubDownload:hash_for`.
  * In `SubDownload.server_info(item)`, when `item.backend == "dlna"` (or when `not item.year and not item.season`), parse `item.name` with `OpenSubtitles.parse_release(item.name or "")`.

---

### 2.2. `dvp/dlna.lua`: Self-closing XML tags (`<res .../>`, `<dc:title/>`) in DIDL-Lite responses cause `Dlna.parse_didl` and `Dlna.element_text` to swallow the following element

> **Status: Solved** (D68). Elements written as one tag (`<res .../>`, `<item .../>`, `<dc:title/>`) are dropped before matching, in `parse_didl` and `element_text`.

* **Location:** `app/share/deckvideoplayer/mpv/scripts/deckplayer/dvp/dlna.lua` (`Dlna.element_text` lines 89–95, `Dlna.parse_didl` lines 252–273)
* **Problem:**
  In `Dlna.parse_didl`:
  ```lua
  for rattrs, url in inner:gmatch("<res([^>]*)>(.-)</res>") do
  ```
  and in `Dlna.element_text`:
  ```lua
  local inner = xml:match("<" .. name .. "[%s>].-</" .. name .. ">")
      or xml:match("<[%w_%-]+:" .. name .. "[%s>].-</[%w_%-]+:" .. name .. ">")
  ```
  Because `[^>]*` and `[%s>].-` match across the trailing `/` of a self-closing tag (`<res protocolInfo="..."/>` or `<dc:title/>`), if an `<item>` contains a self-closing `<res .../>` (e.g. an empty thumbnail/metadata resource) before the real video `<res ...>http://.../video.mkv</res>`, `rattrs` matches the first tag's attributes and `url` (`(.-)</res>`) swallows the second `<res>` opening tag and its URL into a single corrupted entry, hiding the video from the library.
* **Suggested Fix:**
  * In `Dlna.parse_didl`, use `"<res([^/>]*)>(.-)</res>"` (or ignore matches where `rattrs:sub(-1) == "/"`).
  * In `Dlna.element_text`, exclude `/` before `>` in the opening tag (e.g. `"<" .. name .. "%f[^%w_%-][^/>]*>(.-)</" .. name .. ">"` and the namespace-prefixed equivalent).

---

### 2.3. `dvp/dlna.lua`: `Dlna.safe_id` is case-sensitive on `"uuid:"`, returning `"UUID"` for any UPnP server whose `USN` or `UDN` uses uppercase `"UUID:"`

> **Status: Solved** (D68). The `uuid:` prefix is stripped in any case.

* **Location:** `app/share/deckvideoplayer/mpv/scripts/deckplayer/dvp/dlna.lua` (`Dlna.safe_id` lines 104–108)
* **Problem:**
  ```lua
  function M.safe_id(id)
      id = tostring(id or ""):gsub("^uuid:", ""):match("^([%w%-]+)")
      if id and #id >= 4 and #id <= 64 then return id end
      return nil
  end
  ```
  UPnP 1.0/1.1 allows case-insensitive `uuid:` prefixes in `USN` headers and `<UDN>` elements. If a server sends `UUID:12345678-...`, `:gsub("^uuid:", "")` does not strip `UUID:`, and `:match("^([%w%-]+)")` matches `"UUID"` (length `4`, passing `#id >= 4`), assigning the colliding ID `"UUID"` to every such server.
* **Suggested Fix:**
  Use case-insensitive prefix stripping: `id = util.trim(tostring(id or "")):gsub("^[Uu][Uu][Ii][Dd]:", ""):match("^([%w%-_]+)")`.

---

### 2.4. `dvp/dlna.lua`: `Dlna.parse_description` reads the root device's `<UDN>` / `<friendlyName>` instead of the embedded `MediaServer` `<device>` on combo UPnP devices, and `Dlna:connect` does not check if the server was removed

> **Status: Solved** (D68). `parse_description` reads the id, name and services of the MediaServer device itself when it is embedded in another device; `connect` stops if the server was removed while its description or a search was in flight. (A removed server was not written back to the file: `save` writes the list it is no longer in.)

* **Location:** `app/share/deckvideoplayer/mpv/scripts/deckplayer/dvp/dlna.lua` (`Dlna.parse_description` lines 163–185, `Dlna:connect` lines 450–471)
* **Problems:**
  1. **Multi-device UPnP descriptions (routers / NAS gateways):** When a router or NAS exposes an `InternetGatewayDevice` root `<device>` with an embedded `MediaServer:1` `<device>` inside `<deviceList>`, `M.element_text(xml, "UDN")` and `M.element_text(xml, "friendlyName")` match the first `<UDN>` in `xml` (the gateway's UDN) instead of the `MediaServer` `<device>`'s UDN. In `Dlna:discover()` (line 414), `a.id == info.id` then fails because the SSDP `USN` advertised the `MediaServer` UDN, preventing the server from being discovered.
  2. **Removed server resurrected by in-flight `Dlna:connect`:** In `Dlna:connect(id, cb)` (lines 459–466), if `self:remove(id)` is called while `self:discover(...)` is in flight, the discovery callback still writes `self.control[id] = f.control` and calls `self:save()` without checking `self:server(id) == s` (unlike `Jellyfin:connect` line 571).
* **Suggested Fix:**
  * In `Dlna.parse_description`, narrow `UDN`, `friendlyName`, and `<service>` extraction to the `<device>` block containing `urn:schemas-upnp-org:device:MediaServer:` when present.
  * In `Dlna:connect`, check `if f.id == id and self:server(id) == s then` before updating `s` and saving.

---

## 3. Network Shares, Mount Detection, Video Info & Per-Video Decoding (v0.6.0–v0.7.0)

### 3.1. `dvp/library.lua`: `library.mount_for` returns `autofs` instead of `cifs` on `systemd` automounts (`D65`), allowing `library.delete_refusal` to permit deleting files when an automounted share is inside a local folder

> **Status: Solved** (D68). Of two mounts on the same point the later one wins (the share over its automount point); `delete_refusal` refuses anything on a slow path (network filesystem or automount point); `fuse.kio-fuse` added to the network filesystems.

* **Location:** `app/share/deckvideoplayer/mpv/scripts/deckplayer/dvp/library.lua` (`NETWORK_FS` lines 196–199, `mount_for` lines 204–212, `delete_refusal` lines 251–268)
* **Problem:**
  When a share is mounted with a `systemd` `.automount` unit (as in the D65 SMB guide in `docs/INSTALL.md` and `tests/run.lua` lines 1189–1190), `/proc/self/mountinfo` contains two lines for the same mount point: first `fstype = "autofs"`, followed by the mounted `fstype = "cifs"`.
  1. In `library.mount_for(mounts, path)` (line 209), `and (not best or #p > #best.path)` uses strict `>`, so the first entry (`autofs`) wins over the later mounted filesystem (`cifs`) of the same path length.
  2. In `library.delete_refusal` (lines 265–266):
     ```lua
     local mount = M.mount_for(mounts, path)
     if mount and M.is_network_fs(mount.fstype) then return "Videos on a network share can't be deleted" end
     ```
     If a user mounts a `systemd` automount inside a configured local folder (e.g. `~/Videos/NAS`), `source.kind` is `"folder"` (in `LOCAL_KINDS`), `M.mount_for` returns the `autofs` entry, and `M.is_network_fs("autofs")` is `false` (unlike `M.is_slow_path`, which checks `m.fstype == "autofs" or M.is_network_fs(m.fstype)`). `delete_refusal` therefore returns `nil` and allows deleting files on the network share.
  3. Also, KDE's `kio-fuse` network mounts in Desktop Mode (`fstype = "fuse.kio-fuse"`) are not listed in `NETWORK_FS`.
* **Suggested Fix:**
  * Use `#p >= #best.path` in `library.mount_for` so later (top-most) mounts in `/proc/self/mountinfo` win on ties.
  * Check `M.is_slow_path(mounts, path)` (or `mount.fstype == "autofs" or M.is_network_fs(mount.fstype)`) in `library.delete_refusal`.
  * Add `["fuse.kio-fuse"] = true` to `NETWORK_FS`.

---

### 3.2. `dvp/resume.lua` & `main.lua`: Switching *Video → Decoding* to *Software* on a newly opened video before the first progress save (first 30 s) silently fails to persist the choice

> **Status: Not a bug** (D68). The menu does not call `set_decoder`: `save_progress` stores the decoder from mpv's current `hwdec` every time, right after `resume:update`, which creates the entry; it runs on unload too, so a choice made in the first 30 s is kept.

* **Location:** `app/share/deckvideoplayer/mpv/scripts/deckplayer/dvp/resume.lua` (`Resume:set_decoder` lines 118–125) and `app/share/deckvideoplayer/mpv/scripts/deckplayer/main.lua` (`set_decoding` lines 309–315)
* **Problem:**
  ```lua
  function M:set_decoder(path, decoder)
      local e = path and self.entries[path]
      if not e or e.decoder == decoder then return end
      e.decoder = decoder
      self.dirty = true
      self:save()
  end
  ```
  When a video is played for the first time, `self.entries[key]` does not exist in `resume.json` until `save_progress()` runs (on pause, after 30 s of playback, or on `on_unload`).
  However, `Player:check_dropped_frames` suggests *"Dropping frames — try Video → Decoding: Software"* after just 6 seconds (`DROP_WINDOW = 6`). When the user opens **Menu → Video → Decoding** and switches to **Software** during the first 30 seconds (without pausing), `resume:set_decoder(key, "software")` sees `self.entries[key] == nil` and returns without saving anything. Later, when `save_progress()` creates the entry on pause, 30 s tick, or `on_unload`, `e.decoder` is `nil`—so the per-video decoder choice is forgotten.
* **Suggested Fix:**
  Call `save_progress()` before `resume:set_decoder(...)` in `main.lua` (or also persist `player:remembered_decoder()` inside `save_progress()`), or allow `Resume:set_decoder(path, decoder)` to create a minimal table `{decoder = decoder}` when `decoder ~= nil`.

---

### 3.3. `dvp/videoinfo.lua`: `VideoInfo.open` does not cancel `ffprobe` when closed with `B`, and `VideoInfo.probe_url` has no `-rw_timeout` for hanging DLNA servers

> **Status: Partly solved** (D68). `probe_url` passes `-rw_timeout 15000000` (checked: ffprobe gives up on a server that never answers). Aborting ffprobe on B is declined: a closed panel ignores the late answer, the probe ends by itself, and on a local share a stuck read can't be killed anyway.

* **Location:** `app/share/deckvideoplayer/mpv/scripts/deckplayer/dvp/videoinfo.lua` (`ffprobe` lines 357–365, `probe` lines 379–392, `probe_url` lines 403–406, `open` lines 411–431)
* **Problem:**
  When the user opens **Video info** (`View`) on a DLNA video or a file on a slow/unresponsive network share, `VideoInfo.open` spawns an async `ffprobe` subprocess. Unlike `library.list_async` (D64) and `Dlna:browse` (D66), `VideoInfo.probe_url` passes no `-rw_timeout` to `ffprobe`, and `VideoInfo.open` does not set `spec.on_cancel` to `mp.abort_async_command(handle)` when the user presses **B** to close the panel.
* **Suggested Fix:**
  Pass `"-rw_timeout", "15000000"` (15 s) in `VideoInfo.probe_url`, return the async command handle from `ffprobe`, and abort it in `spec.on_cancel` in `VideoInfo.open`.

---

### 3.4. AppStream Metainfo (`packaging/flatpak/io.github.nicocarbone.DeckVideoPlayer.metainfo.xml`)

> **Status: Solved** (D68). The metainfo feature list mentions downloads, DLNA servers and network folders, and the decoding choice.

* **Location:** `packaging/flatpak/io.github.nicocarbone.DeckVideoPlayer.metainfo.xml` (`<description><ul>` lines 21–32)
* **Note:** The `<releases>` tags for `0.6.0`, `0.7.0`, and `0.7.1` are up to date, and `dvp/version.lua` is `"0.7.1"`. The top-level `<description><ul>` summary list still ends at v0.5.0 features and can optionally mention DLNA servers, offline downloads, and per-video hardware/software decoding.

---

## 4. v0.6.0–v0.7.1 (Part IX) Summary Checklist

Reviewed and fixed on 2026-10-30 (DECISIONS D68).

- [x] **Downloads (`dvp/downloads.lua`):** *(Not a bug: the code already requires status 0; tests added.)* Require `status == 0` for `code == 200` / `206` in `Downloads.outcome` and check `status == 23` / `63` first so mid-stream errors are not treated as `"done"` or masked as `"Incomplete download"`.
- [x] **Downloads (`dvp/browser.lua`):** Build the full folder stack from the source root in `Browser:open_folder` (*Show in the library*).
- [x] **Downloads (`dvp/downloads.lua`):** Remove empty `<Show>/<Season>` parent directories inside `download_folder` when a download is cancelled or fails the free-space check.
- [x] **Downloads / Delete (`dvp/browser.lua`):** Refresh `self.sources` in `confirm_delete` / `delete_file`, pop `self.stack` if the current folder is no longer in `self.sources`, and reload the library when a menu closes after a download finished.
- [x] **DLNA Subtitles (`dvp/subdownload.lua`, `dvp/dlna.lua`):** *(`fetch_range` already existed: no crash.)* Implement `Dlna:fetch_range` (or guard `backend.fetch_range` in `SubDownload:hash_for`) so *Download subtitles…* does not crash on DLNA videos, and parse DLNA titles with `OpenSubtitles.parse_release` in `SubDownload.server_info`.
- [x] **DLNA XML (`dvp/dlna.lua`):** Guard `Dlna.parse_didl` and `Dlna.element_text` against self-closing tags (`<res .../>`, `<dc:title/>`), make `Dlna.safe_id` case-insensitive for `UUID:`, scope `Dlna.parse_description` to the `MediaServer` `<device>`, and check `self:server(id) == s` in `Dlna:connect`.
- [x] **Network Mounts (`dvp/library.lua`):** Use `#p >= #best.path` in `library.mount_for` (so `cifs` wins over `autofs` on `systemd` automounts), use `is_slow_path` in `delete_refusal`, and add `fuse.kio-fuse` to `NETWORK_FS`.
- [x] **Decoding (`dvp/resume.lua`, `main.lua`):** *(Not a bug: `save_progress` stores the live decoder after creating the entry.)* Persist `player:remembered_decoder()` even when toggled during the first 30 s of a newly played video before `resume.entries[key]` exists.
- [x] **Video Info (`dvp/videoinfo.lua`):** *(Declined: aborting on B.)* Pass `-rw_timeout` in `VideoInfo.probe_url`.

---
---

# Part VIII — v0.5.0 Audit: Jellyfin Integration, 5.1 Surround Placement, Source Tags & Subtitle Brightness (2026-10-27)

All 440 Lua checks and 10 Python unit tests in `tests/run.sh` pass, and the v0.5.0 additions were verified:
* **5.1 headphone surround at 120° (`dvp/surround.lua`, D57):** `speakers=4 120|5 240` for both `5.1(side)` and `5.1` was verified against FFmpeg's `sofalizer` filter with `mit_kemar_normal_pinna_dfeq.sofa` (channel indices `4` and `5` map both `SL`/`SR` and `BL`/`BR` to bit-identical 120°/240° virtual speaker positions, and observing `audio-params` in a single native table observer avoids adding the filter twice).
* **Subtitle brightness (`dvp/player.lua`, `dvp/media.lua`, D58):** `media.sub_brightness(level, 203)` scales `sub-color` linearly (`#4D4D4D`–`#FFFFFF`) and scales `image-subs-hdr-peak` with `level ^ 2.2` (`14`–`203` nits) so bitmap subtitles on HDR displays track the luminance of text subtitles.
* **Source tags & Video info (`dvp/library.lua`, `dvp/browser.lua`, `dvp/videoinfo.lua`, D56):** Source matching (`library.source_for`) and tags on *Recently played* rows work cleanly across local folders, SD card, USB drives, Plex, and Jellyfin.

Below are the bugs, security/discovery edge cases, and release-readiness items found in the v0.5.0 code (`dvp/jellyfin.lua`, `dvp/browser.lua`, `dvp/videoinfo.lua`, `helper/dvp-discover.c`, `dvp/version.lua`, and `packaging/flatpak/io.github.nicocarbone.DeckVideoPlayer.metainfo.xml`).

---

## 1. Jellyfin Integration Bugs & Edge Cases (v0.5.0)

### 1.1. `dvp/jellyfin.lua`: `Jellyfin:streams_anonymously` passes `max_size = 1`, which causes `curl` to exit with code `63` (`code = nil`) whenever a `401` / `403` response has a body > 1 byte (*verified with curl*)

> **Status: Solved** (D59). The body goes to `/dev/null` with a 64 KB cap, so 401/403 error pages come back as codes; a server that ignores `Range` and hits the cap counts as "streams without a token".

* **Location:** `app/share/deckvideoplayer/mpv/scripts/deckplayer/dvp/jellyfin.lua` (`streams_anonymously` lines 651–663) and `app/share/deckvideoplayer/mpv/scripts/deckplayer/dvp/http.lua` (`curl_config` line 58, `parse_result` lines 97–100)
* **Problem (*verified*):**
  ```lua
  function M:streams_anonymously(item, path)
      local id = item.machine
      if self.anonymous[id] == nil then
          local code = http.request_sync({url = path, headers = {"Range: bytes=0-0"}, tag = "jellyfin",
                                          timeout = 3, max_size = 1})
          if code == 200 or code == 206 then
              self.anonymous[id] = true
          elseif code == 401 or code == 403 then
              self.anonymous[id] = false
          end
      end
      return self.anonymous[id]
  end
  ```
  1. `max_size = 1` sets `max-filesize = 1` in `curl`.
  2. When a server responds to `Range: bytes=0-0` with `206 Partial Content` and `Content-Length: 1`, `curl` exits with `0` and `code` is `206`.
  3. However, if a Jellyfin server or reverse proxy requires authentication on `/Videos/<id>/stream` and returns `401 Unauthorized` or `403 Forbidden`, its response body is almost always > 1 byte (e.g. `Content-Length: 12` `"Unauthorized"` or an HTML/JSON error page).
  4. Whenever `Content-Length > 1` (or > 1 byte is received), `curl --max-filesize 1` exits with status **`63`** (`CURLE_FILESIZE_EXCEEDED`). In `http.parse_result`, `res.status ~= 0` causes `http.request_sync` to return **`nil, "The file is too large"`** instead of `401` or `403`.
  5. Because `code` is `nil`, `self.anonymous[id]` stays `nil` instead of becoming `false`—so `Jellyfin:prepare(item)` repeats the blocking synchronous HTTP probe before **every single video** played from that server.
  6. In addition, only `code == 206` confirms a 1-byte range response (a `200 OK` that ignored `Range` would only pass `max-filesize` if the entire video file were <= `max_size`).
* **Suggested Fix:**
  Pass `output = "/dev/null"` and a larger `max_size` (e.g. `max_size = 65536`) so `401`/`403` error pages do not trigger exit code `63`, and set `self.anonymous[id] = true` on `code == 206` and `self.anonymous[id] = false` on `code == 401 or code == 403`.

---

### 1.2. `dvp/browser.lua` & `dvp/jellyfin.lua`: One-season Jellyfin shows (`kind = "series_episodes"`) are missing from `SERVER_ORDER` in `dvp/browser.lua`, so `date` sort reverses episodes

> **Status: Solved** (D59). `series_episodes` is in `SERVER_ORDER` (kept in the server's order, not sortable); `resolve` falls back to the whole show for an episode outside any season.

* **Location:** `app/share/deckvideoplayer/mpv/scripts/deckplayer/dvp/browser.lua` (`SERVER_ORDER` line 183) and `app/share/deckvideoplayer/mpv/scripts/deckplayer/dvp/jellyfin.lua` (`entries_from` lines 178–180)
* **Problem:**
  In `dvp/jellyfin.lua` line 180:
  ```lua
  if t == "Series" then
      -- One-season shows open straight into their episodes.
      ref = {kind = it.ChildCount == 1 and "series_episodes" or "seasons", key = id}
  ```
  In `dvp/browser.lua` line 183:
  ```lua
  -- Server listings kept in the server's order: the server page, "Continue
  -- watching", "Next up", and seasons/episodes (by number, whatever the sort).
  local SERVER_ORDER = {root = true, ondeck = true, nextup = true, seasons = true, episodes = true}
  ```
  Unlike Plex (where one-season shows use `kind = "episodes"` with `/allLeaves`), Jellyfin one-season shows use `kind = "series_episodes"`, which is missing from `SERVER_ORDER`:
  1. `Browser:sortable()` returns **`true`** inside any one-season Jellyfin show (showing `"Sorted by …"` and offering `Y Sort`).
  2. `Browser:load_server()` runs `library.sort_entries(self.entries, self.sort)`.
  3. If `self.sort == "date"` (from `config.ini` or from pressing `Y` in a Movies/Shows library), opening a one-season show in Jellyfin sorts its episodes by `DateCreated` (`mtime`, newest first), listing and auto-playing the episodes backwards (`E10, E09, …, E01`).
  4. Even when `self.sort == "name"`, if a show with `ChildCount == 1` has both Specials (`Season 0`, `E01 · …`) and Season 1 (`E01 · …`), `/Shows/<id>/Episodes` returns them in season+episode order, whereas `library.sort_entries` re-sorts them alphabetically by `e.name = "E01 · …"`, interleaving Specials with Season 1.
  5. Also, in `Jellyfin:resolve` (`dvp/jellyfin.lua` lines 625–628), if an episode belongs to a flat series without season items (`M.safe_id(it.SeriesId)` is true, `it.SeasonId` is nil), falling back to `kind = "series_episodes", key = it.SeriesId` queues the rest of the series for auto-play.
* **Suggested Fix:**
  Add `series_episodes = true` to `SERVER_ORDER` in `dvp/browser.lua` (and in `Jellyfin:resolve`, fall back to `kind = "series_episodes", key = it.SeriesId` when `not M.safe_id(it.SeasonId)`).

---

### 1.3. `dvp/jellyfin.lua`: `Jellyfin:discover` and `Jellyfin:connect` do not verify UDP broadcast addresses with `GET /System/Info/Public`

> **Status: Solved** (D59). Every broadcast answer is probed (`/System/Info/Public`, no token) and kept only if that address answers with the same id; `config.ini` addresses win over broadcast ones; `parse_discovery` keeps at most 16 answers and `dvp-discover` stops after 64 packets.

* **Location:** `app/share/deckvideoplayer/mpv/scripts/deckplayer/dvp/jellyfin.lua` (`discover` lines 368–401, `connect` lines 495–517)
* **Problems:**
  ```lua
  mp.command_native_async({name = "subprocess", args = {M.DISCOVER_HELPER, "1500"},
                           capture_stdout = true, playback_only = false}, function(_, res)
      if not res or res.status ~= 0 then
          msg.warn("jellyfin: discovery failed: " .. tostring(res and (res.error_string or res.status)))
      end
      for _, s in ipairs(M.parse_discovery(res and res.stdout)) do add(s) end
      done()
  end)
  ```
  In `Jellyfin:discover(cb)`, URLs from `self.config_urls` (`config.ini`) are probed via `self:probe(url, ...)` (`GET <url>/System/Info/Public`), whereas UDP broadcast responses from `dvp-discover` (`M.parse_discovery`) are added directly via `add(s)` **without calling `self:probe(s.url, ...)`**:
  1. **Unverified address in `Jellyfin:connect(id, cb)` (lines 504–516):**
     When `self:probe(server.url)` fails (e.g. the user is on a foreign Wi-Fi network, or the saved server URL timed out), `connect()` falls back to `self:discover(...)`. If a UDP packet on port 7359 claims `s.id == id`, `connect()` immediately overwrites `server.url = s.url`, saves it to `jellyfin.json`, and calls `use(s.url)`—which then sends `Authorization: MediaBrowser …, Token="<secret>"` to `s.url` without ever having verified `s.url` with `GET /System/Info/Public` (contrary to the header comment on lines 16–19 and DECISIONS D55).
  2. **Unreachable Docker / multi-NIC UDP broadcast address shadows a working `config.ini` URL:**
     When a Jellyfin server runs in Docker bridge mode (or on a host with multiple interfaces/subnets) without `LocalAddress` configured, its UDP broadcast packet often advertises its internal container IP (e.g. `http://172.17.0.2:8096`), so the user configures `server = http://192.168.1.50:8096` (or `https://…`) in `config.ini`.
     Because `discover()` deduplicates by `seen[s.id]` and does not probe UDP broadcast URLs, if `dvp-discover` finishes before the `config.ini` HTTP probe (or if `connect()` falls back to `discover()` after a transient timeout), the unreachable UDP `Address` wins `seen[s.id]` and hides or overwrites the working `config.ini` URL.
* **Suggested Fix:**
  In `Jellyfin:discover(cb)`, probe each entry from `M.parse_discovery(res and res.stdout)` with `self:probe(s.url, function(info) if info and info.Id == s.id then add(...) end; done() end)` so only reachable, verified HTTP/HTTPS endpoints are added to `found` (and in `helper/dvp-discover.c` line 77, cap the `for (;;)` loop at e.g. 64 packets so a UDP flood on the LAN cannot buffer unbounded stdout).

---

### 1.4. `dvp/jellyfin.lua` & `main.lua`: `self.started[item.key]` state in `Jellyfin:report` is not cleared if a file unloads when `time-pos` is `nil` or when a session is forgotten

> **Status: Partly solved** (D59). Fixed: `prepare()` resets the item's "started" state and sign-out clears all of it. Declined: reporting "playing" as soon as the file loads (for Jellyfin and Plex). The first report at the first pause or 30 s tick is tested behaviour, servers show the session from then, and an earlier report only changes when the dashboard shows it.

* **Location:** `app/share/deckvideoplayer/mpv/scripts/deckplayer/dvp/jellyfin.lua` (`forget_server` lines 461–469, `forget_session` lines 521–524, `prepare` lines 669–690, `report` lines 702–715) and `app/share/deckvideoplayer/mpv/scripts/deckplayer/main.lua` (`save_progress` lines 160–185)
* **Problem:**
  In `Jellyfin:report`:
  ```lua
  if state == "stopped" then
      endpoint = "/Sessions/Playing/Stopped"
      self.started[item.key] = nil
  elseif self.started[item.key] then
      endpoint = "/Sessions/Playing/Progress"
  else
      endpoint = "/Sessions/Playing"
      self.started[item.key] = true
  end
  ```
  1. If `self.started[item.key]` is set to `true` (after a pause or 30-second progress tick) and the stream later fails or unloads when `mp.get_property_number("time-pos")` is `nil` (or `self.bases[item.machine]` was cleared), `save_progress(true)` returns early at `if not pos then return end` without calling `backend:report(item, "stopped", ...)`. `self.started[item.key]` remains `true`, so re-playing that item sends `/Sessions/Playing/Progress` without ever sending `/Sessions/Playing`.
  2. Also, `file-loaded` in `main.lua` does not call `save_progress()`, so `POST /Sessions/Playing` (and Plex's initial `playing` timeline report) is not sent until the user pauses or 30 seconds of playback elapse.
* **Suggested Fix:**
  Clear `self.started[item.key] = nil` in `Jellyfin:prepare(item)` and reset `self.started = {}` in `forget_session` / `forget_server` (and optionally call `save_progress()` in `file-loaded` so the server dashboard shows `"Now Playing"` immediately).

---

## 2. Video Info Panel & Browser Polish (v0.5.0)

### 2.1. `dvp/videoinfo.lua`: `VideoInfo.from_jellyfin` reports `"SDR"` (or omits `" · HDR10"` / `" · HLG"`) when `s.ColorTransfer` is `nil` and HDR is only indicated in `s.VideoRangeType`

> **Status: Solved** (D59). The HDR type falls back to `VideoRangeType` (HDR10, HDR10Plus, HLG, DOVIWith…) when `ColorTransfer` is missing.

* **Location:** `app/share/deckvideoplayer/mpv/scripts/deckplayer/dvp/videoinfo.lua` (`hdr_label` lines 54–65, `from_jellyfin` lines 324–335)
* **Problem:**
  `VideoInfo.hdr_label(h)` checks `h.transfer == "smpte2084"` (for `HDR10` / `HDR10+`) and `h.transfer == "arib-std-b67"` (for `HLG`).
  In `VideoInfo.from_jellyfin`:
  ```lua
  local range = tostring(s.VideoRangeType or "")
  d.video = { ...
             primaries = s.ColorPrimaries and tostring(s.ColorPrimaries):lower(),
             transfer = s.ColorTransfer and tostring(s.ColorTransfer):lower(),
             dv_profile = tonumber(s.DvProfile),
             hdr10plus = range:find("HDR10Plus") ~= nil, ... }
  ```
  As noted in `videoinfo.lua` lines 205–206, `ffprobe -show_streams` (which Jellyfin runs on the server to populate `MediaStreams`) can leave `ColorTransfer` unset on some HEVC streams while Jellyfin sets `s.VideoRangeType` to `"HDR10"`, `"HDR10Plus"`, `"DOVIWithHDR10"`, `"DOVIWithHDR10Plus"`, `"HLG"`, or `"DOVIWithHLG"`. When `s.ColorTransfer` is `nil`, `d.video.transfer` is `nil`, so `hdr_label` misreports `"HDR10"` / `"HDR10Plus"` / `"HLG"` as `"SDR"` (and `"DOVIWithHDR10"` as `"Dolby Vision 8"` without `" · HDR10"`).
* **Suggested Fix:**
  In `VideoInfo.from_jellyfin`, fall back to `s.VideoRangeType` when `s.ColorTransfer` is nil:
  ```lua
  local transfer = s.ColorTransfer and tostring(s.ColorTransfer):lower()
      or (range:find("HDR10") and "smpte2084")
      or (range:find("HLG") and "arib-std-b67") or nil
  ```

---

### 2.2. `dvp/browser.lua`: Adding a Jellyfin or Plex server while in single-source mode (`top.is_root == true`) leaves the browser inside the local folder instead of showing the new server

> **Status: Solved** (D59). Signing in to Plex or Jellyfin goes to the start screen (`reload_to_start`); other reloads (an SD card inserted while browsing) keep the folder.

* **Location:** `app/share/deckvideoplayer/mpv/scripts/deckplayer/dvp/browser.lua` (`refresh_sources` lines 58–63, `plex_sign_in` line 591, `jellyfin_sign_in` line 690)
* **Problem:**
  When a user starts the app with only one local folder (`~/Videos`) and no *Recently played* entries (`self:single_source() == true`), `Browser:load()` skips the Start screen and opens `~/Videos` directly (`self.stack = {{path = s.path, label = s.name, is_root = true}}`).
  If the user then selects **Menu → Add a Jellyfin server…** (or **Sign in to Plex…**) and completes sign-in, `jellyfin_sign_in` / `plex_sign_in` calls `self:reload()`. `refresh_sources()` clears `top.is_root = nil` (because `#self.sources` is now > 1), and `self:load()` reloads `self.stack[1]` (`~/Videos`)—leaving the user inside `~/Videos` instead of showing the Start screen where their new Jellyfin or Plex server was added.
* **Suggested Fix:**
  When `top and top.is_root and not self:single_source()` in `Browser:refresh_sources()` (or before `self:reload()` in `plex_sign_in` and `jellyfin_sign_in` when `self:at_start()`), clear `self.stack = {}` so the Start screen with the newly added server is shown.

---

### 2.3. Release Readiness (`dvp/version.lua`, `packaging/flatpak/io.github.nicocarbone.DeckVideoPlayer.metainfo.xml`)

> **Status: Solved**. Done at release time, as for every release (v0.5.0 on 2026-10-27; `version.lua` is now 0.6.0 with its metainfo entry).

* **`dvp/version.lua`:** Still `"0.4.2"` (sent in Jellyfin's `Authorization: MediaBrowser …, Version="0.4.2"`, Plex's `X-Plex-Version`, OpenSubtitles `User-Agent`, and shown in the About panel).
* **`packaging/flatpak/io.github.nicocarbone.DeckVideoPlayer.metainfo.xml`:** Needs the `<release version="0.5.0">` entry and a `<description><ul>` bullet covering Jellyfin streaming, source tags, 5.1 surround placement, and subtitle brightness when tagging v0.5.0.

## 3. v0.5.0 (Part VIII) Summary Checklist

Reviewed and fixed on 2026-10-27 (DECISIONS D59).

- [x] **Jellyfin (`dvp/jellyfin.lua`):** Anonymous-stream check: body to `/dev/null` with a 64 KB cap, so 401/403 come back as codes.
- [x] **Jellyfin (`dvp/browser.lua`, `dvp/jellyfin.lua`):** One-season shows keep the server's order; *Recently played* falls back to the whole show.
- [x] **Jellyfin (`dvp/jellyfin.lua`, `helper/dvp-discover.c`):** Broadcast answers probed and kept only with the same id; `config.ini` addresses win; at most 16 answers, 64 packets.
- [x] **Jellyfin (`dvp/jellyfin.lua`):** `prepare()` resets the "playing" state; sign-out clears it. *(Declined: reporting "playing" at file load; the first report at the first pause or 30 s tick is tested behaviour.)*
- [x] **Video info (`dvp/videoinfo.lua`):** HDR type from `VideoRangeType` when `ColorTransfer` is missing.
- [x] **Browser (`dvp/browser.lua`):** Sign-in from the only folder goes to the start screen.
- [x] **Release:** version and metainfo updated when tagging v0.5.0.

---
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

> **Status: Solved** (D53). `video-target-params/gamma` is observed; badges and the info panel redraw when it changes, also while paused.

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

> **Status: Solved** (D53). No HDR choice is effective on a screen not in HDR mode, and an open Video menu is rebuilt whenever the screen turns out to be SDR.

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

> **Status: Partly solved** (D53). A known HDR screen is checked again with each file, and a known SDR screen is promoted as soon as mpv outputs HDR. Declined: re-checking an SDR screen with every file, which would flash every SDR file on an SDR TV with *SDR to HDR* set. A change in the middle of a file applies from the next file.

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

> **Status: Solved** (D53). Section headers are not selectable and scrolling up shows a section's header; the Video info workaround was removed. (The highlight didn't disappear on headers as reported; the cursor stopped on them.)

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

> **Status: Solved** (D53). `colorPrimaries` / `colorTrc` are lowercased.

* **Location:** `app/share/deckvideoplayer/mpv/scripts/deckplayer/dvp/videoinfo.lua` (`hdr_label` lines 53–64, `PRIMARIES` lines 66–67, `from_plex` lines 273–281)
* **Problem:**
  `from_plex` passes `primaries = s.colorPrimaries` and `transfer = s.colorTrc` verbatim into `PRIMARIES[v.primaries or ""]` and `M.hdr_label(v)`. If a Plex server reports uppercase/mixed-case strings (e.g. `"BT709"` or `"SMPTE2084"`), `PRIMARIES` returns `nil` and `hdr_label` falls back to `"SDR"`. Normalizing `s.colorPrimaries` and `s.colorTrc` with `:lower()` makes Plex metadata handling resilient.

---

### 2.3. `dvp/browser.lua`: Opening a Plex item from *Recently played* (`open_plex_recent`) has no loading feedback, does not guard `open_file` on local entries while in flight, and leaves stale `resume.json` progress if the Resume prompt is canceled

> **Status: Solved** (D53). "Opening from Plex…" toast; the item opens only if the cursor is still on that row and nothing else opened; the server's progress is synced into `resume.json` (`resume:sync`).

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

> **Status: Solved** (D49). `link=maximum` on `acompressor` (loud centre-only 5.1 measured 4 dB louder with night mode before; now −6.4 dB like stereo).

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

> **Status: Solved** (D49). `sofalizer` at gain 0, then `volume` and `alimiter` at −1 dBFS. (Confirmed with a smaller margin than reported: +2.7 dBFS peaks; now −1.0 dBFS, no warnings, same dialogue loudness.)

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

> **Status: Solved** (D49). The filter is added once audio is open, not while idle.

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

> **Status: Solved** (D49). *R2 Next episode* counts the episode as finished (`ctx.finished()`).

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

> **Status: Solved** (D49). No auto-repeat on the triggers; R2 checks the marker at the current position; the marker timer stops during a skip and restarts on `playback-restart`. (The prompt flashing during an exact seek doesn't happen: mpv reports the seek target as `time-pos` while seeking.)

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

> **Status: Partly solved** (D49). Fixed: markers are cleared at the start of `on_load`, the prompt is redrawn on resize, and "Resumed at" shows before the automatic intro skip. Declined: skipping an intro at 0:00 inside `on_load`, because the extra seek happens before the first frame is shown anyway.

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

> **Status: Solved** (D49). No status write and no portal call after SIGTERM or when orphaned.

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

> **Status: Solved** (D45). Breaks on `sd_bus_process < 0`, checks `stop` before a bounded `sd_bus_wait`, guards `unique[0] == ':'`. The `PR_SET_PDEATHSIG` thread claim doesn't apply: the thread that spawns the helper stays blocked on it, so the death signal fires as intended.

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

> **Status: Solved** (D45). Falls back to `data_dir` before `/tmp`, removes the status file in `stop()`, checks `snprintf` bounds.

* **Location:** `app/share/deckvideoplayer/mpv/scripts/deckplayer/dvp/keepawake.lua` (`KeepAwake.new` lines 34–36, `KeepAwake:stop` lines 58–64) and `helper/dvp-keep-awake.c` (`write_status` lines 30–39)
* **Problems:**
  1. When `XDG_RUNTIME_DIR` is unset, `KeepAwake.new` falls back to `/tmp/dvp-keep-awake-<pid>.status`, and `write_status()` opens `/tmp/dvp-keep-awake-<pid>.status.tmp` with `fopen(tmp, "w")` (without `O_EXCL` or `O_NOFOLLOW`) in world-writable `/tmp`. Falling back to `data_dir` (which is already private under `umask 077`) avoids `/tmp`.
  2. `KeepAwake:stop()` does not remove `self.status_file`, leaving `/run/user/1000/dvp-keep-awake-<pid>.status` behind in `XDG_RUNTIME_DIR` (RAM `tmpfs`) after the app exits.
  3. `write_status()` in `dvp-keep-awake.c` does not check `snprintf(tmp, sizeof tmp, "%s.tmp", status_file)` for truncation before `fopen`.
* **Suggested Fix:** Pass `opts.data_dir` to `KeepAwake.new(cfg, opts.data_dir)` as the fallback before `/tmp`, call `os.remove(self.status_file)` in `KeepAwake:stop()`, and check the `snprintf` return value in `write_status()`.

### 1.3. `http.curl_quote`: NUL byte (`\0`) not stripped

> **Status: Solved** (D45). NUL bytes (`%z`) are stripped in `http.curl_quote`.

* **Location:** `app/share/deckvideoplayer/mpv/scripts/deckplayer/dvp/http.lua` (`http.curl_quote` lines 16–19)
* **Problem:** `curl_quote` escapes `\`, `"`, `\n`, `\r`, `\t`, but does not strip NUL bytes (`%z`). Because curl reads `-K -` lines as C strings, a NUL byte in any string would truncate the line in curl's config parser.
* **Suggested Fix:** Strip `%z` (`:gsub("%z", "")`) in `http.curl_quote`.

---

## 2. Bugs & Functional Edge Cases (v0.3.5)

### 2.1. Three bugs in *Crop black bars* (`dvp/cropdetect.lua` & `dvp/player.lua`)

> **Status: Solved** (D45). Opposite bars must both be present (`math.min`), and `crop_bars` is set only when a crop was applied. 2.1.3 doesn't apply: detection never runs while a crop is active.

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

> **Status: Solved** (D45). `recent_playlist` uses name order, so episodes never auto-play backwards.

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

> **Status: Solved** (D45). `played` is preserved for pre-v0.3.1 entries.

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

> **Status: Solved** (D45). `expired` is tracked across both PIN requests.

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

> **Status: Solved** (D45). The playlist is cleared when `prepare` fails in `on_load`; `bases[machine]` is kept when `prepare` succeeded.

* **Location:** `app/share/deckvideoplayer/mpv/scripts/deckplayer/main.lua` (`on_load` lines 286–303, `end-file` lines 361–371) and `dvp/plex.lua` (`forget_session` lines 483–486)
* **Problems:**
  When starting a video in a Plex folder/season with `autoplay_next = true`, `play()` appends all remaining videos in the folder (`list[2..N]`) to mpv's playlist:
  1. **Unreachable server blocks `on_load` across the entire playlist:** If the server is unreachable (`not prep.ok` in `on_load`), `list[1]` fails, `end-file` calls `plex:forget_session(item.machine)` (setting `self.bases[machine] = nil`), and mpv immediately advances through `list[2..N]`, attempting to open every remaining item in the playlist without a token header and failing each one in a loop.
  2. **Single-file stream failure wipes `self.bases[machine]` for the rest of the playlist:** If `plex:prepare(item)` succeeded (`prep.ok == true`, proving `self.bases[machine]` is reachable) and mpv then fails to open that file (`ev.reason == "error"` in `end-file`, e.g. stale transient token or one missing file), `plex:forget_session` clears `self.bases[machine] = nil`, breaking `plex:prepare` for all subsequent playlist entries.
* **Suggested Fix:**
  * In `on_load`: when `not prep.ok`, call `plex:forget_session(item.machine)` and `mp.commandv("playlist-clear")` so mpv stops immediately instead of stepping through `list[2..N]`.
  * When `prep.ok` was `true` and `end-file` fails with `ev.reason == "error"`, only clear `self.transient[item.machine] = nil` (keeping `self.bases[item.machine]`).

### 2.6. `KeepAwake:start()` ignores positive exit codes and unexpected helper termination

> **Status: Solved** (D45). Unexpected helper exits while playing are reported.

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

> **Status: Solved** (D45). `open_subtitle_menu()` has `rebuild`; `Menu:refresh()` uses `first_selectable`.

* **Location:** `app/share/deckvideoplayer/mpv/scripts/deckplayer/dvp/player.lua` (`Player:open_subtitle_menu` lines 294–299) and `dvp/menu.lua` (`Menu:refresh` lines 83–90)
* **Problem:** `open_audio_menu()` and `open_main_menu()` pass `rebuild = function() ... end`, but `open_subtitle_menu()` omits `rebuild = function() return self:subtitle_items() end`. If a subtitle download finishes while the user has the **Subtitles** menu open, `self.ctx.menu:refresh()` (`dvp/subdownload.lua` line 297) does not rebuild the track list. Also, in `Menu:refresh()`, `spec.selected = math.min(spec.selected, #spec.items)` does not call `first_selectable`, which can leave the cursor on a separator if the rebuilt item count changes.
* **Suggested Fix:** Add `rebuild = function() return self:subtitle_items() end` in `Player:open_subtitle_menu()`, and use `spec.selected = first_selectable(spec.items, math.min(spec.selected, #spec.items), -1)` in `Menu:refresh()`.

### 2.8. Stale `self.after_load` callback in `Browser` when navigating away from a loading Plex folder

> **Status: Solved** (D45). `after_load` is cleared in `enter()` and *Go to library start*.

* **Location:** `app/share/deckvideoplayer/mpv/scripts/deckplayer/dvp/browser.lua` (`Browser:enter` lines 230–235, `"Go to library start"` lines 361–366)
* **Problem:** If `self.after_load` is set while a Plex folder is loading (via `reload()` or `go_back()`) and, before the response arrives, the user selects `"Go to library start"` or enters another Plex folder, `self.after_load` remains set and executes on the next Plex listing that finishes loading.
* **Suggested Fix:** Clear `self.after_load = nil` in `Browser:enter()` and `"Go to library start"`.

### 2.9. **B** does not dismiss `Advanced statistics`, and `stats.lua` stays visible over the Library screen

> **Status: Solved** (D45). `stats_visible` is tracked: B closes the statistics, and `stop_screen()` turns them off.

* **Location:** `app/share/deckvideoplayer/mpv/scripts/deckplayer/dvp/player.lua` (`Player:stop_screen` lines 71–79, `Player:handle` lines 174–182, `Player:main_menu_items` lines 421–423)
* **Problem:** *Menu → Advanced statistics* toggles mpv's built-in `stats/display-stats-toggle`. Because `dvp/input.lua` binds controller buttons and keys with `mp.add_forced_key_binding`, pressing **B** during playback does not close `Advanced statistics` (it stops the video instead), and `stats.lua` remains drawn on top of the Library browser after playback stops.
* **Suggested Fix:** Track `self.stats_visible` in `Player`: dismiss it on **B** (`elseif self.stats_visible then self:toggle_stats()`) and turn it off in `stop_screen()` when `self.stats_visible` is `true`.

### 2.10. Multi-account Steam profiles and branch regex edge cases in `scripts/install-steamos.sh` & `scripts/steam_shortcut.py`

> **Status: Solved** (D45). Multi-user Steam profiles are handled, `BRANCH_RE` no longer eats quotes, and only non-`stable` branches are removed.

* **Location:** `scripts/install-steamos.sh` (`remove_installed_branches` lines 26–30, `add_to_steam` lines 58–66, line 114) and `scripts/steam_shortcut.py` (`BRANCH_RE` line 160)
* **Problems:**
  1. **Second Steam profile skipped:** In `scripts/install-steamos.sh` line 59, `python3 "$here/steam_shortcut.py" status 2>/dev/null | grep -q 'app id'` matches if *any* Steam user on the Deck already has the shortcut, returning early and never adding the shortcut to a second Steam account on the same Deck (`-> not added`). Checking `! ... | grep -q 'not added'` (or running `add` whenever Steam is closed, since `add` already unpins and installs artwork idempotently) handles multi-account Decks.
  2. **Quotes in `BRANCH_RE`:** In `scripts/steam_shortcut.py` line 160, `BRANCH_RE = re.compile(r"\s*--branch(?:=|\s+)(\S+)")` matches a closing quote if `--branch=master` is at the end of a quoted string; `r'\s*--branch(?:=|\s+)([^\s"\']+)'` avoids consuming quotes.
  3. **Uninstalling `stable` before `flatpak install`:** In `scripts/install-steamos.sh` lines 114–115, `remove_installed_branches` uninstalls all branches (including `stable`) *before* `flatpak install --user -y --reinstall "$bundle"`. If `flatpak install` fails (e.g. corrupted download), the user is left with no app installed. Removing only other branches (`grep -v "/stable$"`) before `flatpak install --reinstall` keeps upgrades safe.

---

## 3. Optimization Opportunities (v0.3.5)

### 3.1. `Browser:toggle_sort()` re-fetches the entire Plex listing over the network (and re-reads local folders) instead of sorting `self.entries` in place

> **Status: Solved** (D45). `toggle_sort()` sorts `self.entries` in place.

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

> **Status: Solved** (D45). `hide_timer` is not re-armed while paused; `render_info()` updates on pause change.

* **Location:** `app/share/deckvideoplayer/mpv/scripts/deckplayer/dvp/player.lua` (`Player:update_timer` lines 81–87, `Player:show_overlay` lines 94–109, `Player:on_pause_change` lines 118–121)
* **Problem:**
  While a video is paused:
  1. `self.hide_timer` fires every 4 seconds, sees `pause == true`, and calls `self:show_overlay()`, which re-renders the overlay and re-schedules `self.hide_timer` in an infinite loop.
  2. When `on_pause_change` runs while `self.info_visible` is `true`, `self:render_info()` is not called immediately, delaying the *Keep awake* status update in the info panel.
* **Optimization:** In `self.hide_timer`'s callback, if `mp.get_property_native("pause") or self.ctx.menu:is_open()`, simply return without re-calling `self:show_overlay()` (`on_pause_change(false)` and menu close already re-arm the timeout when resuming or closing the menu). Also call `if self.info_visible then self:render_info() end` in `on_pause_change`.

### 3.3. Duplicate `mp.get_property_native("video-params")` marshaling on every overlay and info-panel tick

> **Status: Solved** (D45). `vp` from `media.hdr_state` is reused.

* **Location:** `app/share/deckvideoplayer/mpv/scripts/deckplayer/dvp/player.lua` (`Player:badges` lines 447–450, `Player:info_lines` lines 585 & 596)
* **Problem:** Both `Player:badges()` and `Player:info_lines()` call `mp.get_property_native("video-params")` and immediately call `media.hdr_state(self.video_track)`, which calls `mp.get_property_native("video-params")` a second time and returns `vp` as its 3rd return value.
* **Optimization:** Reuse the `vp` returned by `media.hdr_state(self.video_track)` in both `badges()` and `info_lines()`.

### 3.4. `SubDownload:stored(path)` calls `utils.readdir(self.dir, "dirs")` on every Plex video load

> **Status: Solved** (D45). `stored()` skips the folder listing for server items and cached keys.

* **Location:** `app/share/deckvideoplayer/mpv/scripts/deckplayer/dvp/subdownload.lua` (`SubDownload:stored` lines 141–151)
* **Optimization:** The `utils.readdir(self.dir, "dirs")` check exists only to avoid hashing a local file when no subtitles have ever been downloaded. For Plex items (`self:plex_item(path) ~= nil`) or already-cached keys (`self.keys[path] ~= nil`), `self:key(path)` does no file I/O, so `stored(path)` can go straight to `utils.readdir(util.join(self.dir, key), "files")`.

---

## 4. Release Readiness & Polish (v0.3.5)

> **Status: Solved** (D45). v0.3 features in the metainfo `<description>`; `ini_get` normalizes `-` and quotes like `config.lua`.

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

> **Status: Solved** (D40). `max_size` equals the range size and HTTP 206 is required.

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

> **Status: Solved** (D40). `umask 077` in the launcher (the `chmod` stays as a fallback).

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

> **Status: Solved** (D40). Bare https origins only; insecure http only for IPv4 literals with a numeric port.

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

> **Status: Solved** (D40). `sign_out` clears transient tokens and PINs; late `refresh_account` answers are dropped.

* **Location:** `app/share/deckvideoplayer/mpv/scripts/deckplayer/dvp/plex.lua` (`Plex:refresh_account` lines 371–389, `Plex:sign_out` lines 391–395)
* **Problems:**
  1. `Plex:sign_out()` resets `self.bases` and `self.items`, but forgets to clear `self.transient = {}` and `self.pin = nil`.
  2. `Plex:refresh_account(cb)` captures `local token = self.account.token` before two async requests (up to 30 s). If the user triggers **"Refresh server list"** and then clicks **"Sign out"** before those requests finish, `refresh_account`'s callback writes `self.account.username` and `self.account.servers` (with the old `token`!) back into `self.account` and calls `self:save()`, re-saving the signed-out credentials to `plex.json`.
* **Suggested Fix:** Clear `self.transient = {}` and `self.pin = nil` in `sign_out()`, and guard `refresh_account`'s callbacks with `if self.account.token ~= token then return end`.

---

## 2. Bugs & Functional Edge Cases (v0.3.0)

### 2.1. Race condition on Stop / Quit: `stop_playback()` and `quit()` send an async `"playing"` report right before `on_unload` sends a sync `"stopped"` report

> **Status: Solved** (D40). Verified first that mpv runs `on_unload` on quit; no async report races the final one.

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

> **Status: Solved** (D40). `cancel_pin`, late answers ignored; a claimed PIN with a failed server list closes the dialog as signed in.

* **Location:** `app/share/deckvideoplayer/mpv/scripts/deckplayer/dvp/browser.lua` (`Browser:plex_sign_in` lines 335–379) and `dvp/plex.lua` (`Plex:poll_pin` lines 345–368)
* **Problems:**
  1. `stop()` only kills `timer`, without clearing `plex.pin` or setting a `cancelled` flag. If a `poll_pin` (or its nested `refresh_account`) request is in flight when the user presses **B** or **Cancel**, and completes a moment later:
     * `poll_pin` still saves `self.account.token` even though the user canceled.
     * `if done then` calls `menu:close_all()` (closing whatever unrelated menu the user opened afterwards) and `self:reload()` (even if the user already started playing a video).
  2. In `Plex:poll_pin` (line 361), if the PIN is claimed (`self.account.token` saved) but `self:refresh_account` fails with a transient error, `cb(false, err)` is called—leaving the sign-in dialog on screen with the error message and a `"Cancel"` button even though the account is now signed in (and `self:reload()` is never called to update the library menu).
* **Suggested Fix:** Set `cancelled = true` and `plex.pin = nil` in `stop()`, check `if cancelled then return end` in `start_pin` and `poll_pin` callbacks, and if `plex:signed_in()` is true when `poll_pin` finishes (even with a server-list error), close the sign-in dialog, toast the error/sign-in, and reload.

### 2.3. Discrepancy between `Plex.item_state`, `Browser:render`, and `Browser:resume_position`

> **Status: Solved** (D40). Fixed in `item_state`.

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

> **Status: Solved** (D40). Season and episode listings keep the server's order and are not sortable.

* **Location:** `app/share/deckvideoplayer/mpv/scripts/deckplayer/dvp/browser.lua` (`Browser:load_plex` lines 103–105, `Browser:sortable` lines 117–121) and `dvp/plex.lua` (`Plex.entries_from` lines 178–206)
* **Problems:**
  1. `self.sort` (`"name"` or `"date"`) is shared across all folders. If a user presses **Y** in a Movie library to sort by **Date added**, and then opens a Plex TV Show → Season 1, `Browser:load_plex` sorts Seasons and Episodes by `mtime` (`addedAt`, newest first), listing episodes backwards (`E10, E09, …, E01`) and seasons backwards (`Season 4, Season 3, …`).
  2. For Seasons (`md.type == "season"`), `Plex.entries_from` sets `e.name = md.titleSort or label` instead of ordering by `md.index` (season number), so seasons with custom titles (e.g., `"Book Two: Earth"`, `"Book Three: Fire"`) sort alphabetically (`Book Three` before `Book Two`) instead of by season number.
* **Suggested Fix:** Keep season and episode listings in season/episode order (or set `e.name = string.format("%04d %s", md.index or 0, label)` for seasons and episodes and don't sort seasons/episodes by `addedAt`).

### 2.5. Fresh resume position (`prep.pos`) from `plex:prepare` is ignored for the selected video

> **Status: Solved** (D40). No start position unless the user chose one, so the server's fresh position is used.

* **Location:** `app/share/deckvideoplayer/mpv/scripts/deckplayer/main.lua` (`play` lines 162–168, `on_load` lines 279–300)
* **Problem:**
  * When starting playback from the browser, `play(list, start)` sets `state.pending_start[list[1]] = start or 0`.
  * In `on_load` (line 294), `prep.pos` (fetched synchronously from the Plex server via `plex:prepare(item)`) is only used `if start == nil`, which is only true for auto-advanced playlist items (`list[2..N]`) and never for `list[1]`.
* **Suggested Fix:** Either pass `nil` to `play(list, nil)` when the user did not explicitly choose `"Start from the beginning"` (and had no cached `pos` prompt), or skip the redundant `plex:prepare` resume check when `start` was already chosen.

### 2.6. Transient network error in `SubDownload:hash_for` permanently disables hash search for that Plex video

> **Status: Solved** (D40). A failed hash fetch is not cached; a later search retries.

* **Location:** `app/share/deckvideoplayer/mpv/scripts/deckplayer/dvp/subdownload.lua` (`SubDownload:hash_for` lines 118–133)
* **Problem:** Line 133 sets `self.hashes[path] = hash or false`, and line 118 returns immediately if `self.hashes[path] ~= nil`. If either HTTP range request times out or fails once, `self.hashes[path]` is cached as `false` for the rest of the session and never retries when the user searches again.
* **Suggested Fix:** Only cache non-nil hashes (`if hash then self.hashes[path] = hash end`).

---

## 3. Optimization Opportunities (v0.3.0)

### 3.1. Prefetch the Plex transient delegation token asynchronously on `connect` to cut `on_load` blocking in half

> **Status: Solved** (D40). `prefetch_token` after `connect`.

* **Location:** `app/share/deckvideoplayer/mpv/scripts/deckplayer/dvp/plex.lua` (`Plex:connect` lines 418–421, `Plex:media_token` lines 508–525) and `main.lua` (`on_load` lines 286–291)
* **Problem:** On the first video played from a Plex server, `on_load` blocks mpv's main thread for **two sequential synchronous `curl` subprocesses** (two separate TCP + TLS handshakes):
  1. `plex:prepare(item)` (`GET /library/metadata/<id>`)
  2. `plex:media_token(item)` (`GET /security/token?type=delegation&scope=all`)
* **Optimization:** Request the transient token **asynchronously** as soon as `plex:connect` settles (since the user always connects while browsing the server before playing a video). That warms `self.transient[machine]` ahead of time, making `plex:media_token(item)` in `on_load` a **0 ms** in-memory lookup.

### 3.2. Avoid blocking the UI for up to 6 seconds in `on_unload` when stopping a Plex video without quitting

> **Status: Not solved (declined)** (D40). The blocking report on stop keeps the reloaded listing and the next playlist entry in sync with the server; an asynchronous report could arrive after the listing is reloaded and show stale progress.

* **Location:** `app/share/deckvideoplayer/mpv/scripts/deckplayer/main.lua` (`save_progress` lines 146–154, `on_unload` lines 330–333)
* **Problem:** `on_unload` calls `save_progress(true)`, which executes `plex:report(..., true)` and `plex:set_watched(..., true)` **synchronously** (`http.request_sync`, up to 3 s timeout each) every time a video stops or advances to the next playlist entry. When the user presses **B** (`Stop`) to return to the library browser (`not state.quitting and not state.external`), the mpv process is not exiting—yet synchronous HTTP calls freeze the screen on the last video frame while waiting for the Plex server.
* **Optimization:** Only use `sync = true` when `state.quitting or state.external`. When staying in the app, update the item's state locally and run the `stopped` / `scrobble` requests asynchronously (or refresh the browser listing in the async callback).

### 3.3. Skip `utils.parse_json("")` on empty HTTP bodies and map curl exit code 63

> **Status: Solved** (D40). Empty bodies are not parsed and curl exit 63 is mapped to a message.

* **Location:** `app/share/deckvideoplayer/mpv/scripts/deckplayer/dvp/http.lua` (`CURL_ERRORS` line 77, `parse_result` lines 93–96)
* **Optimization:** `utils.parse_json(text)` is called even when `text == ""` (every file download with `req.output`, and every `/:/timeline` or `/:/scrobble` call). Guarding `local body = text ~= "" and utils.parse_json(text) or nil` avoids unnecessary JSON parse attempts, and adding `[63] = "The file is too large"` to `CURL_ERRORS` gives a clear error when `max-filesize` triggers.

---

## 4. Release Readiness & Polish (v0.3.0)

> **Status: Solved** (D40). luaqrcode credited in About; version and metainfo bumped when tagging v0.3.0.

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

> **Status: Solved** (D39). No token on probes, `machineIdentifier` checked, https only by default (`allow_insecure_lan` opt-in).

* **Where:** `dvp/plex.lua` `server_candidates` (adds `http://<address>:<port>` for every "local" connection) and `connect` (probes every candidate with `X-Plex-Token`).
* **Problem:** for a server the user owns, the per-server token *is the account token* (*verified*). The app sends it unencrypted to whatever answers at the server's LAN address — on any network the Deck joins. On a hotel/café/friend's Wi-Fi that uses the same private range (e.g. 192.168.1.x), any device at that address, or anyone sniffing the network, gets full access to the user's Plex account. The `/identity` probe doesn't even need a token.
* **Fix:** never send a token in probes (`/identity` is unauthenticated) and check the returned `machineIdentifier`; drop plain-http candidates by default (https `*.plex.direct` is certificate-checked, so it is safe on foreign networks); offer plain http only behind an explicit opt-in (`[plex] allow_insecure_lan`) for routers that block plex.direct DNS.

### 1.2. HIGH — Redirects forward the token to other hosts

> **Status: Solved** (D39). No redirects by default (only the subtitle file download follows them, https only).

* **Where:** `dvp/http.lua` `curl_config` (follows redirects for every GET unless `follow = false`), used by all Plex requests and the subtitle download.
* **Problem:** curl forwards custom headers such as `X-Plex-Token` to the redirect target, even on another host (*verified*: a 302 to `localhost:18082` delivered `X-Plex-Token: SECRET` there). A malicious or impersonated server (see 1.1) can redirect any request to collect the account token.
* **Fix:** don't follow redirects by default; enable it only for the subtitle file download, which carries no secrets.

### 1.3. MEDIUM — Server-supplied keys pasted into URLs unchecked

> **Status: Solved** (D39). Server-supplied keys are validated before they go into a URL.

* **Where:** `dvp/plex.lua` `entries_from`, `external_subtitles`, `list` (`base .. key` for section/metadata/part/stream keys).
* **Problem:** a key such as `@evil.example/x` turns `https://srv:32400` + key into `https://srv:32400@evil.example/x`, which curl and mpv send to `evil.example` with the token header. Needs a malicious server (e.g. a server shared by another user) or a man in the middle (1.1).
* **Fix:** accept only keys that start with a single `/` and contain URL-path characters (no `@`, no `//` prefix, no spaces/control characters); skip anything else.

### 1.4. MEDIUM — Any URL scheme accepted (`file://` reads local files)

> **Status: Solved** (D39). curl restricted to http(s), https-only redirects; the download link must be https.

* **Where:** `dvp/http.lua`; `dvp/opensubtitles.lua` `download` (`body.link` from the API is fetched as is).
* **Problem:** curl fetches `file://` URLs (*verified*). A malicious API response could make the app copy a local file (for example `plex.json` with the account token) into the subtitle folder, from where it is loaded as a subtitle.
* **Fix:** restrict curl to `https`/`http` (`proto`, `proto-redir = =https`); require the download link to start with `https://`.

### 1.5. LOW — `plex.json` briefly world-readable

> **Status: Solved** (D39). `plex.json` is made private before the token is written.

* **Where:** `dvp/plex.lua` `save` → `util.write_file_atomic` then `chmod 600`.
* **Problem:** the temp file is created with the default mode (0644) and renamed before `chmod`; for a moment the account token is readable by other local users.
* **Fix:** create the temp file, `chmod 600` it, then write and rename (`util.write_private`).

### 1.6. LOW — `config.ini` (OpenSubtitles password) created world-readable

> **Status: Solved** (D39). `config.ini` is created with mode 600 (`umask 077` in the launcher).

* **Where:** `app/bin/deckvideoplayer` (`cp` of the template).
* **Fix:** create it with mode 600 (existing files untouched; mention in the docs).

### 1.7. LOW — OpenSubtitles `base_url` used unchecked

> **Status: Solved** (D39). The OpenSubtitles `base_url` is validated.

* **Where:** `dvp/opensubtitles.lua` `ensure_login` (`api_url = "https://" .. body.base_url ..`), then used for authenticated calls.
* **Fix:** accept only hosts ending in `.opensubtitles.com`.

### 1.8. LOW — Subtitle language code and size unchecked

> **Status: Solved** (D39). Subtitle language validated; 10 MB download limit.

* **Where:** `dvp/subdownload.lua` `download` (`r.language` goes into the file name); `opensubtitles.lua` (no size limit).
* **Problem:** a code containing `/` builds a path outside the video's folder (not exploitable as written: the first component would have to exist), and an endless response could fill the disk.
* **Fix:** accept only letters and `-` (else `und`); `max-filesize` 10 MB for subtitle downloads.

### 1.9. LOW — CI supply chain

> **Status: Solved** (D39). CI actions pinned by commit; read-only default permissions.

* **Where:** `.github/workflows/build.yml`.
* **Problem:** third-party actions referenced by moving tags (`flatpak-github-actions@master`, `action-gh-release@v2`, `actions/*@v4`); no top-level `permissions`. A compromised action could alter the published bundle.
* **Fix:** pin actions to commit SHAs; `permissions: contents: read` at the top, `contents: write` only for the release job.

### 1.10. INFO — Sandbox: whole home readable, plus network

> **Status: Solved** (D39). Sandbox narrowed to Videos, Downloads and removable media (`flatpak override` documented for other folders).

* **Where:** Flatpak `finish-args` (`--filesystem=home:ro`, `--share=network` since v0.2).
* **Risk:** a decoder exploit in a malicious video could read anything in the home folder (SSH keys, other apps' tokens) and send it out.
* **Option:** narrow to `xdg-videos`, `xdg-download`, `/run/media`, `/media`, `/mnt`, and document `flatpak override --filesystem=…` for other folders. Trade-off: folders elsewhere in home stop working until overridden.

### 1.11. INFO — Accepted / documented

> **Status: Accepted (by design)**. Listed as accepted risks, not defects: the transient token mpv receives is short-lived and only appears in `-v` logs (the account token never reaches mpv); there is no keyring in game mode, so the account token is a mode-600 file; INSTALL explains how to revoke the device at Plex (*Authorized Devices*) and Jellyfin (*Devices*); a device code can be phished by someone who sees it, which is inherent to the sign-in flow.

* mpv receives a transient token, which appears in `-v` logs (D37); the account token is stored in a plain file (no keyring in game mode; mode 600); signing out doesn't revoke the token at plex.tv (INSTALL tells users how); device-code sign-in can be phished by someone who sees the code (inherent to the flow).

## 2. Bugs

### 2.1. MEDIUM — Truncated files replace good ones on a full disk

> **Status: Solved** (D39). `write_file_atomic` checks the write and close and keeps the old file on failure.

* **Where:** `dvp/util.lua` `write_file_atomic` ignores `write`/`close` errors, then renames the temp file over `resume.json` / `plex.json`.
* **Fix:** check both, remove the temp file and keep the old one on failure.

### 2.2. MEDIUM — A finished Plex video may count as watched twice

> **Status: Solved** (D39). Scrobbled only when finished below Plex's 90 % threshold.

* **Where:** `main.lua` `save_progress(true)`: reports `stopped`, then calls `/:/scrobble` when finished.
* **Problem:** Plex marks a video watched by itself when a timeline report passes its *Video played threshold* (90 % by default), so the explicit scrobble adds a second play. (Inferred from Plex's documented behaviour; not reproduced, to keep the owner's history untouched.)
* **Fix:** scrobble only when the app considers the video finished but it is below 90 %.

### 2.3. LOW — Stale transient token after a server restart

> **Status: Solved** (D39). The cached transient token and connection are forgotten when a Plex file fails to load.

* **Where:** `dvp/plex.lua` `media_token` (cached 12 h).
* **Problem:** a server restart invalidates the token; every Plex video then fails ("Could not play this file") until the app restarts.
* **Fix:** forget the cached token (and connection) when a Plex file fails to load.

### 2.4. LOW — Sign-in lost if the server list fails right after linking

> **Status: Solved** (D39). The token is saved as soon as it arrives.

* **Where:** `dvp/plex.lua` `poll_pin` → `refresh_account` (saves only on success).
* **Fix:** save the token as soon as it arrives.

### 2.5. LOW — Robustness

> **Status: Solved** (D39) for the `provides` type check. Accepted: the worst-case ~10 s block in `on_load` only happens when a server has just become unreachable, inside a hook where playback waits anyway; an unreachable server now fails at once and clears the playlist (D45).

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

> **Status: Solved** (D35). +0.5 slack in the scroll decision.

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

> **Status: Solved** (D35). Files are named `<release> #<file_id>.<lang>.srt`; titles strip the id.

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

> **Status: Solved** (D35). `aid`, `sid`, `sub-delay`, `audio-delay` are file-local defaults in `on_load`, before the saved choice.

* **Location:** `app/share/deckvideoplayer/mpv/scripts/deckplayer/dvp/player.lua` (lines 205–315) and `app/share/deckvideoplayer/mpv/scripts/deckplayer/main.lua` (`on_load` lines 225–246)
* **Problem:**
  * Picture mode (`panscan` / `keepaspect`) is reset at the start of every file in `on_load`, and surround resets on `end-file`.
  * However, choosing an audio track (`aid`), choosing a subtitle track or `"Off"` (`sid = "no"`), or adjusting `sub-delay` / `audio-delay` in `dvp/player.lua` mutates mpv's **session-global** properties and is not reset in `on_load` when the next file has no saved `entry.aid` / `entry.sid`.
  * If a user sets Subtitles to **Off** (or picks `sid = 3`) in Video A, and then opens a fresh Video B, `sid` remains `"no"` (or `3`, which may be the wrong language or a non-existent track ID on Video B), breaking `slang` / `subtitles = auto` for the rest of the session. Likewise, any `sub-delay` or `audio-delay` from Video A carries over to Video B.
* **Suggested Fix:** In `on_load` (before applying `entry.aid` / `entry.sid` from `resume.json`), reset `aid` to `"auto"`, `sid` to `cfg:get("playback", "subtitles") == "off" and "no" or "auto"`, `sub-delay` to `0`, and `audio-delay` to `0` (or use `file-local-options/*`).

### 1.4. OpenSubtitles regional language codes fail priority sorting due to case mismatch

> **Status: Solved** (D35). Language codes are lowercased in `parse_results`.

* **Location:** `app/share/deckvideoplayer/mpv/scripts/deckplayer/dvp/opensubtitles.lua` (`parse_results` line 212, `rank` lines 229 & 240)
* **Problem:**
  * `OpenSubtitles.languages(slang)` lowercases all language tags (e.g. `pt-BR` → `"pt-br"`).
  * `OpenSubtitles.parse_results` (line 212) stores `language = a.language or ""` without `:lower()`. If the API returns `"pt-BR"` or `"zh-CN"`, `pref[a.language]` in `OpenSubtitles.rank` evaluates to `nil` (fallback rank `99`), losing language-order priority sorting.
* **Suggested Fix:** Normalize `language = (a.language or ""):lower()` in `OpenSubtitles.parse_results`.

### 1.5. Marquee state when menu items change in-place or when closing a menu over the browser

> **Status: Solved** (D35). The marquee restarts on text change; the library re-renders when a menu over it closes.

* **Location:** `app/share/deckvideoplayer/mpv/scripts/deckplayer/dvp/ui.lua` (`Marquee:draw` lines 276–280), `dvp/menu.lua` (lines 254, 267), and `main.lua` (lines 217–221)
* **Problems:**
  1. `Menu:render` keys marquee animations by `tostring(spec) .. "#" .. idx` (or `"v"`). When a menu row's text is updated in-place at the same index via `menu:refresh()` or `menu:update(spec, ...)` (e.g., changing the active subtitle track and popping back to the Playback menu), `key == self.key` is still true in `Marquee:draw`, so `self.t0` is not reset for the new text.
  2. In `main.lua` (line 219), the menu `on_close` callback re-renders `player:render()` when `state.screen == "player"`, but does not call `browser:render()` when `state.screen == "browser"`. Because `browser:render()` suppresses its marquee while `menu:is_open()` is true, closing a menu (such as the About panel) over a long filename in the browser leaves its marquee stopped until the cursor moves.
* **Suggested Fix:**
  1. In `Marquee:draw` (`dvp/ui.lua` line 277), check `if key ~= self.key or str ~= self.text then self.key, self.text, self.t0 = key, str, mp.get_time() end`.
  2. In `main.lua` `Menu.new` `on_close`, also call `browser:render()` when `state.screen == "browser"`.

### 1.6. Async subtitle search/download callbacks vs. menu state

> **Status: Solved** (D35). Toast only while the menu is open; `menu:refresh()` after a download.

* **Location:** `app/share/deckvideoplayer/mpv/scripts/deckplayer/dvp/subdownload.lua` (`SubDownload:open` lines 162–166, `SubDownload:download` lines 216–228)
* **Problems:**
  1. In `SubDownload:open`, if the user closes the `"Download subtitles"` menu with **B** while the search request is still in flight and the request later errors or times out, `self.ctx.menu:update(spec, ...)` returns `false`, yet `self.ctx.toast(err)` still displays an error toast after the user backed out.
  2. In `SubDownload:download`, selecting a subtitle pops the `"Download subtitles"` submenu (`close = true`), leaving the parent **Playback** menu open while the download runs asynchronously. When the download finishes and calls `select_file(dest, title, lang)`, `self.ctx.menu:refresh()` is not called, so the `"Subtitles"` value in the still-open Playback menu stays stale until the user moves the cursor.
* **Suggested Fix:**
  1. Only call `self.ctx.toast(err)` in `SubDownload:open` if `self.ctx.menu:update(...)` returned `true`.
  2. Call `self.ctx.menu:refresh()` after `select_file(dest, title, lang)` in `SubDownload:download`.

### 1.7. `/run/media/<user>` `tmpfs` mount matched as a removable drive

> **Status: Partly solved** (D35). Fixed by filesystem type (`tmpfs`, `autofs`, …). Declined: dropping every source not backed by `/dev/`, which would hide network mounts under `/media`.

* **Location:** `app/share/deckvideoplayer/mpv/scripts/deckplayer/dvp/library.lua` (`Library.parse_mountinfo` lines 38–51)
* **Problem:**
  `parse_mountinfo` matches any mount point matching `^/run/media/.+` regardless of filesystem type or source (`121 30 8:1 / /run/media/deck rw - tmpfs tmpfs rw`, as seen in `tests/run.lua` line 119). On systems where `/run/media/deck` itself is a `tmpfs` mount point, `parse_mountinfo` returns `/run/media/deck` as a drive (`source = "tmpfs"`), causing `Library:roots()` to list `/run/media/deck` itself as a removable drive named `"deck"` alongside the actual drives inside `/run/media/deck/<label>`.
* **Suggested Fix:** Filter out pseudo-filesystems (e.g. `fstype == "tmpfs"` / `autofs` or mounts whose `source` does not start with `/dev/`) in `parse_mountinfo`.

### 1.8. Minor state resets (`display-fps-override` & `state.resumed_at`)

> **Status: Solved** (D35). Both resets done.

* **Locations:** `app/share/deckvideoplayer/mpv/scripts/deckplayer/dvp/display.lua` (lines 251–283) and `main.lua` (lines 225–246)
* **Problems:**
  1. **Stale `display-fps-override` during the 2s verification window:** When switching from a 24 fps video (`display-fps-override = 48`) to a 60 fps video, `Display:match()` schedules a 2.0s `verify_timer` before updating `display-fps-override`, leaving `display-fps-override` at `48` for the first 2 seconds of the 60 fps video (or permanently if the helper fails). Reset `mp.set_property_number("display-fps-override", 0)` before starting the new rate change/verification.
  2. **Stale `state.resumed_at` on load failure:** `state.resumed_at` is set in `on_load` when `start == nil` and cleared in `file-loaded`. If a file with a resume entry fails to open (`end-file` before `file-loaded`) and the user next chooses `"Start from beginning"` (`start = 0`), the stale `state.resumed_at` triggers a false `"Resumed at …"` toast. Initialize `state.resumed_at = nil` at the top of `on_load`.

---

## 2. Security, Privacy & Native Helper Robustness (v0.2.0)

### 2.1. OpenSubtitles `Api-Key` header is sent to the file download URL / CDN

> **Status: Solved** (D35). `Api-Key`/`Accept` only on API calls, not on the file download.

* **Location:** `app/share/deckvideoplayer/mpv/scripts/deckplayer/dvp/opensubtitles.lua` (`OpenSubtitles:http` lines 310–321, `OpenSubtitles:download` line 400)
* **Problem:** `OpenSubtitles:http(req, cb)` unconditionally includes `"header = Api-Key: " .. self.api_key` and `"location"` (follow redirects) on every curl invocation, including Step 2 of `OpenSubtitles:download` which downloads the raw `.srt` file from `body.link` (`req.output = tmp`). Because `body.link` is a direct download URL that may live on a CDN or different host (and curl forwards custom `-H` headers across redirects), the user's `Api-Key` should not be attached to the file download request.
* **Suggested Fix:** Only add `Accept: application/json` and `Api-Key: ...` headers when `not req.output`.

### 2.2. `strtol` argument validation in `helper/dvp-gamescope-refresh.c`

> **Status: Solved** (D35). `endptr` checked; non-numeric rates rejected.

* **Location:** `helper/dvp-gamescope-refresh.c` (lines 105–110)
* **Problem:** `long hz = set ? strtol(argv[2], NULL, 10) : 0;` does not inspect `endptr` or check for an empty string. Passing a non-numeric `argv[2]` silently parses as `0` (which the protocol treats as "reset to native") instead of failing with exit code `2`.
* **Suggested Fix:** Pass `&end` to `strtol` and reject `argv[2][0] == '\0' || *end != '\0'`.

---

## 3. Release Readiness & Metadata Mismatches (v0.2.0)

### 3.1. AppStream Metainfo still lists only `0.1.0`

> **Status: Solved** (D35). The metainfo has every release since 0.2.0.

* **Location:** `packaging/flatpak/io.github.nicocarbone.DeckVideoPlayer.metainfo.xml` (lines 18–35)
* **Problem:** `dvp/version.lua` is bumped to `"0.2.0"`, but `io.github.nicocarbone.DeckVideoPlayer.metainfo.xml` only has `<release version="0.1.0" date="2026-10-23"/>` and its feature list `<ul>` does not mention headphone surround or OpenSubtitles subtitle downloads.

### 3.2. Status docs still mark v0.2.0 as "in progress"

> **Status: Solved**. ROADMAP and AGENTS status are updated in each release commit.

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

> **Status: Solved** (D23). Sources are re-read on show/reload/root; the single-source top folder is demoted when a drive appears.

* **Location:** `app/share/deckvideoplayer/mpv/scripts/deckplayer/dvp/browser.lua` (`Browser:load` lines 41–68, `Browser:open_menu` lines 169–201)
* **Problems:**
  1. **Missing menu option in single-source mode:** In `Browser:open_menu()`, `"Go to library start"` is only added when `#self.stack > 0 and self.sources and #self.sources > 1`. When a user has only one source configured (e.g., the default `~/Videos`), `Browser:load()` auto-enters that source (`self.stack[1] = {..., is_root = true}`). If the user navigates several subfolders deep (e.g., `~/Videos/Series/Show/Season 1`), `"Go to library start"` never appears in the menu because `#self.sources == 1`.
  2. **Dead variable `self.root_forced`:** Line 47 checks `if #self.sources == 1 and not self.root_forced then`, but `self.root_forced` is never assigned anywhere in the codebase.
  3. **Removable media hotplug + `"Reload library"` doesn't refresh sources:** If the app starts with only 1 source (`~/Videos`) and the user later inserts a microSD card or USB drive and selects **"Reload library"** from the menu, `self:load()` sees that `self:location()` is non-nil (`~/Videos` with `is_root = true`) and only re-reads `~/Videos` without calling `library.sources(self.cfg)`. Even worse, pressing **B** at `~/Videos` triggers the Quit dialog (`if loc.is_root and #self.stack == 1`) instead of backing out to the newly available sources list.
* **Suggested Fix:**
  * In `"Reload library"`, re-evaluate `self.sources = library.sources(self.cfg)` and update `self.stack[1].is_root = (#self.sources == 1)`.
  * Show `"Go to library start"` whenever `#self.stack > 1` (resetting to `self.stack = {}` and reloading) or when `#self.stack == 1 and not self.stack[1].is_root`.

### 1.2. Binary VDF serializer crashes on 64-bit integers (`0x07`)

> **Status: Solved** (D22). Serialise, then temp file, then atomic replace, with a `.bak`; `0x07` kept as UInt64; covered by `tests/test_steam_shortcut.py`.

* **Location:** `scripts/steam_shortcut.py` (`vdf_load` lines 44–62, `vdf_dump` lines 65–79)
* **Problem:** `vdf_load` supports type `0x07` (unsigned 64-bit integer, `struct.unpack_from("<Q", ...)`), which becomes a standard Python `int`. However, `vdf_dump` serializes **every** `isinstance(value, int)` as type `0x02` (`struct.pack("<i", value)` — signed 32-bit integer). If a user's `shortcuts.vdf` contains a `0x07` field (or any integer outside `-2147483648..2147483647` added by Steam or another tool), `vdf_dump` will crash with `struct.error: 'i' format requires -2147483648 <= number <= 2147483647`.
* **Suggested Fix:** Wrap `0x07` values in a small `int` subclass (e.g. `class UInt64(int): pass`) during `vdf_load` so `vdf_dump` can write them back losslessly with `b"\x07" + k + struct.pack("<Q", value)`.

### 1.3. Picture / Zoom mode (`fill` / `stretch`) is not reset or synced with `mpv`

> **Status: Solved** (D20). Picture mode is per file and its label comes from mpv's properties.

* **Location:** `app/share/deckvideoplayer/mpv/scripts/deckplayer/dvp/player.lua` (`Player.new` line 25, `Player:set_zoom` lines 240–244)
* **Problem:** `self.zoom` starts as `"fit"`, and `Player:set_zoom(mode)` sets mpv's global `panscan` and `keepaspect` properties.
  * If a user sets `Picture` to `Fill` or `Stretch` on one video, stops playback, and plays another video, it stays cropped/stretched (or if the user set `panscan` in `~/.config/deckvideoplayer/mpv.conf`, `self.zoom` is out of sync).
* **Suggested Fix:** Either reset `self:set_zoom("fit")` in `Player:stop_screen()` (or use `file-local-options/panscan` and `file-local-options/keepaspect`), or derive the current zoom mode directly from mpv's `panscan` and `keepaspect` properties.

### 1.4. Command-line / `.desktop` file argument edge cases

> **Status: Solved** (D21). External launches auto-resume with a toast and quit when playback ends.

* **Location:** `packaging/flatpak/io.github.nicocarbone.DeckVideoPlayer.desktop` (`Exec=deckvideoplayer %F`), `app/share/deckvideoplayer/mpv/scripts/deckplayer/main.lua` (lines 217–285)
* **Problem:** When a video file is passed directly to `deckvideoplayer` via CLI or file association:
  1. `start-file` switches `state.screen = "player"`, bypassing `browser:show()`.
  2. `on_load` silently auto-resumes from the saved position (`start == nil and cfg.playback.resume`), whereas opening a file in the UI prompts `"Resume playback?"`.
  3. When the file finishes or the user presses **B** (Stop), `idle-active` transitions to `true` and calls `browser:show()` + `browser:select_path(state.last_played)`. If the file was outside the configured library root, the user is dropped into the top-level library browser instead of either the file's directory or exiting.

### 1.5. `sed` delimiter collision in dev/test scripts

> **Status: Solved**. `\`, `&` and `|` are escaped in the sed replacement.

* **Location:** `scripts/dev-run.sh` (line 36) and `tools/headless-run.sh` (lines 46–49)
* **Problem:**
  ```sh
  sed -i "s|^folder = .*|folder = $media|" "$DVP_CONFIG_DIR/config.ini"
  ```
  If the workspace path (`$root` or `$media`) contains `&` (which `sed` expands to the matched LHS) or `|`, the `config.ini` replacement corrupts the path or fails.

---

## 2. Missing Optimizations (Performance & Battery) (v0.1.0)

### 2.1. Unnecessary `stat()` (`utils.file_info`) on every file before checking extensions

> **Status: Not solved (declined)** (D24). mpv's filtered `readdir` already stats every entry, so checking extensions first would double the `stat()` calls; one stat per entry is the minimum.

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

> **Status: Solved** (D25). Title, video track and chapter list are cached per file.

* **Location:** `app/share/deckvideoplayer/mpv/scripts/deckplayer/dvp/player.lua` (`Player:render` lines 344–442) and `dvp/media.lua` (`media.hdr_state` lines 113–130)
* **Problem:** While the playback overlay is visible (including the entire time a video is paused), `Player:tick()` runs every 0.5 seconds and calls `Player:render()`. Inside `render()`:
  1. `mp.get_property_native("chapter-list")` is called **twice** in the same function (line 400 for chapter tick marks, and line 417 for the current chapter title), marshaling the entire chapter table from C to Lua twice per tick.
  2. `self:badges()` calls `media.hdr_state()`, which calls `media.selected_track("video")`, which calls `mp.get_property_native("track-list")` — marshaling all audio, subtitle, and video track metadata across C/Lua every 0.5s just to check `vt["dolby-vision-profile"]`.
  3. `self:title()` re-queries `mp.get_property("path")` and runs string regexes every 0.5s.
* **Optimization:**
  * At minimum, fetch `chapter-list` once into a local variable in `Player:render()`.
  * Better yet, cache `title`, `chapter-list`, and Dolby Vision track presence on `file-loaded` (or via `mp.observe_property`), since they do not change every 0.5s.

### 2.3. Opening and closing a new X11 connection on every refresh-rate call

> **Status: Not solved (declined)** (D24). About two calls per file load; a persistent X11 connection adds risk for no measurable gain.

* **Location:** `app/share/deckvideoplayer/mpv/scripts/deckplayer/dvp/display.lua` (`with_display` lines 65–73)
* **Problem:** Every call to `get_root_cardinal` or `set_root_cardinal` calls `XOpenDisplay(nil)`, `XInternAtom(...)`, and `XCloseDisplay(dpy)`. On the first video load, `Display:match()` calls `get_root_cardinal` (open + intern + get + close) immediately followed by `set_root_cardinal` (open + intern + change + flush + close).
* **Optimization:** Cache the `Display*` pointer, default root `Window`, and interned `GAMESCOPE_DYNAMIC_REFRESH` `Atom` in `X` across the lifetime of the script (or combine the read-and-set into one `with_display` session).

### 2.4. Spawning `mpv --list-options` on every startup in the Flatpak

> **Status: Solved** (D26). The probe is skipped when `/.flatpak-info` exists.

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
