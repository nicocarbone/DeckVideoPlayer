# Code Audit: Findings & Optimization Opportunities

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
