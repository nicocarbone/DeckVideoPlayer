-- Downloads for offline playback (v0.6, docs/DECISIONS.md D60).
--
-- Plex and Jellyfin videos are saved in the download folder ([library]
-- download_folder) with names a media library would use:
--   Title (Year).mkv
--   Show/Season 01/Show - S01E02 - Title.mkv
-- and the server's external text subtitles next to them ("….en.srt"), so
-- they play like any local file, without the server.
--
-- One download at a time, with curl (dvp/http.lua), into "<file>.part",
-- renamed once complete and the size checked. A stopped or interrupted
-- download continues where it ended (HTTP ranges). Network errors are
-- retried a few times; after that, and after the app was closed, the
-- download waits for the user (Downloads → Resume): network work only
-- happens on request.
--
-- The list is kept in <data_dir>/downloads.json: waiting, stopped and
-- failed downloads, and finished ones (server videos show "Downloaded").
-- Server tokens are asked for at every start and never stored there.

local utils = require "mp.utils"
local msg = require "mp.msg"
local util = require "dvp.util"
local http = require "dvp.http"
local library = require "dvp.library"

local M = {}
M.__index = M

M.RETRIES = 3          -- network errors in a row before a download stops
M.RETRY_DELAY = 15     -- seconds
M.SPACE_MARGIN = 256 * 1024 * 1024   -- left free on the drive
M.SUB_MAX = 20 * 1024 * 1024
local NAME_BYTES = 120

---------------------------------------------------------------------------
-- Pure helpers (unit-tested)
---------------------------------------------------------------------------

-- At most `n` bytes of UTF-8 text, never cutting a character.
local function truncate_bytes(s, n)
    if #s <= n then return s end
    s = s:sub(1, n)
    local i = #s
    while i > 0 and s:byte(i) >= 0x80 and s:byte(i) < 0xC0 do i = i - 1 end
    local lead = i > 0 and s:byte(i) or 0
    if lead >= 0xC0 then
        local need = lead >= 0xF0 and 4 or (lead >= 0xE0 and 3 or 2)
        if #s - i + 1 < need then s = s:sub(1, i - 1) end
    end
    return s
end

-- Text made safe as one file or folder name, also on FAT/exFAT microSD
-- cards: no / \ : * ? " < > | or control characters, no leading dots
-- (hidden files, ".."), no trailing dots or spaces. nil if nothing is left.
function M.clean_name(s)
    s = tostring(s or ""):gsub("[%c/\\:*?\"<>|]", " "):gsub("%s+", " ")
    s = util.trim(s):gsub("^[%.%s]+", "")
    s = truncate_bytes(s, NAME_BYTES):gsub("[%.%s]+$", "")
    if s == "" then return nil end
    return s
end

-- The extension for a download, from the server's file name ("/x/Film.MKV")
-- or container ("mp4"); "mkv" when unknown.
function M.safe_ext(file)
    local name = util.basename(tostring(file or ""))
    local ext = name:find(".", 1, true) and util.extension(name) or name:lower()
    if ext:match("^%w+$") and #ext <= 5 then return ext end
    return "mkv"
end

-- Where an item goes inside the download folder (`item`: a server entry's
-- `server` table: kind, name, title, year, show, season, episode).
function M.relative_path(item, ext)
    local name = M.clean_name(item.name)
    if item.kind == "episode" then
        local show = M.clean_name(item.show) or "Unknown show"
        local s, e = tonumber(item.season), tonumber(item.episode)
        local code = (s and e and string.format("S%02dE%02d", s, e)) or (e and string.format("E%02d", e)) or nil
        local parts = {show}
        if code then parts[#parts + 1] = code end
        if name then parts[#parts + 1] = name end
        local file = M.clean_name(table.concat(parts, " - ")) .. "." .. ext
        local season = (s == 0 and "Specials") or (s and string.format("Season %02d", s)) or nil
        return season and (show .. "/" .. season .. "/" .. file) or (show .. "/" .. file)
    end
    local title = name or M.clean_name(item.title) or "Video"
    local year = tonumber(item.year)
    if year then title = M.clean_name(title .. " (" .. math.floor(year) .. ")") end
    return title .. "." .. ext
end

local SUB_EXTS = {srt = true, ass = true, vtt = true}

-- Subtitle files next to the video at `video`: "<video>.<lang>.<ext>"
-- (mpv loads them with the video and reads the language), numbered when a
-- language has several. subs: {{url or file, lang, ext}} (a URL to fetch,
-- or a file to copy). Returns {{url, file, path}}.
function M.subtitle_paths(video, subs)
    local base = util.strip_extension(video)
    local seen, out = {}, {}
    for _, s in ipairs(subs or {}) do
        local lang = type(s.lang) == "string" and #s.lang <= 12 and s.lang:match("^%a[%a%-]*$") and s.lang:lower()
            or "und"
        if SUB_EXTS[s.ext] then
            local key = lang .. "." .. s.ext
            seen[key] = (seen[key] or 0) + 1
            local n = seen[key] > 1 and ("." .. seen[key]) or ""
            out[#out + 1] = {url = s.url, file = s.file, path = base .. n .. "." .. lang .. "." .. s.ext}
        end
    end
    return out
end

-- The id of a server item's download: backend, server, item.
function M.job_id(item)
    return tostring(item.backend) .. ":" .. tostring(item.machine) .. ":" .. tostring(item.key)
end

function M.format_size(bytes)
    if not bytes then return "?" end
    if bytes >= 1e9 then return string.format("%.1f GB", bytes / 1e9) end
    if bytes >= 1e6 then return string.format("%.0f MB", bytes / 1e6) end
    return string.format("%.0f KB", bytes / 1e3)
end

-- Whether a download of `size` bytes, `have` of them already on disk,
-- fits in `avail` free bytes with the margin left over.
function M.enough_space(avail, size, have)
    return avail >= (size or 0) - (have or 0) + M.SPACE_MARGIN
end

-- What to do once curl ends: "done" (complete, if the size matches),
-- "restart" (the server can't continue the partial file: start over),
-- "retry" (network trouble) or "fail"; and why.
function M.outcome(code, status)
    if code == 416 then return "done" end   -- nothing left to fetch
    if status == 0 and (code == 200 or code == 206) then return "done" end
    if status == 33 then return "restart" end
    if code == 401 or code == 403 then return "fail", "The server refused the download" end
    if code == 404 then return "fail", "No longer on the server" end
    if status == 23 then return "fail", "Can't write the file (drive full or read-only)" end
    if code and code >= 500 then return "retry", "Server error " .. code end
    if status == 0 or (code and code >= 300) then
        return "fail", "Unexpected answer from the server (" .. tostring(code) .. ")"
    end
    return "retry", http.CURL_ERRORS[status] or "Network error"
end

-- Status of a download for the Downloads menu. `have`: bytes on disk,
-- `speed`: bytes/s (nil while unknown).
function M.status_text(job, have, speed)
    local s = job.status
    if s == "done" then return M.format_size(job.size) end
    if s == "queued" then return "Waiting" end
    if s == "paused" then return job.error and ("Stopped: " .. job.error) or "Stopped" end
    if s == "failed" then return job.error or "Failed" end
    if job.retry_at then return "Connection lost, trying again…" end
    if not have or have == 0 then return "Starting…" end
    local done = job.size and job.size > 0 and string.format("%d%%", math.floor(100 * have / job.size))
        or M.format_size(have)
    if speed and speed > 0 then return done .. " · " .. M.format_size(speed) .. "/s" end
    return done
end

---------------------------------------------------------------------------
-- Instance
---------------------------------------------------------------------------

-- ctx: cfg, servers, menu, subtitles; set later by main.lua: changed(job) (a
-- download started, ended or was removed; `job` when one finished),
-- play_path(path), browse(folder, select), delete(path, label).
function M.new(ctx, data_dir)
    local self = setmetatable({ctx = ctx, jobs = {}, running = nil}, M)
    self.file = (data_dir and data_dir ~= "") and util.join(data_dir, "downloads.json") or nil
    local text = self.file and util.read_file(self.file)
    local data = text and utils.parse_json(text)
    for _, job in ipairs(type(data) == "table" and type(data.jobs) == "table" and data.jobs or {}) do
        if type(job) == "table" and job.backend and job.machine and job.key then
            if job.status == "done" then
                -- Deleted outside the app: forget it.
                if job.path and util.file_exists(job.path) then self.jobs[#self.jobs + 1] = job end
            else
                -- Interrupted by closing the app: continues when the user asks.
                if job.status == "downloading" or job.status == "queued" then job.status = "paused" end
                self.jobs[#self.jobs + 1] = job
            end
        end
    end
    return self
end

function M:save()
    if not self.file then return end
    local list = {}
    for _, job in ipairs(self.jobs) do
        local copy = {}
        for k, v in pairs(job) do
            -- Only the description; nothing of a run in progress.
            if type(v) ~= "table" and type(v) ~= "function" and k ~= "handle" and k ~= "retry_at" then copy[k] = v end
        end
        list[#list + 1] = copy
    end
    local ok, err = util.write_file_atomic(self.file, utils.format_json({version = 1, jobs = list}))
    if not ok then msg.warn("downloads: could not save the list: " .. tostring(err)) end
end

function M:find(item)
    local id = M.job_id(item)
    for _, job in ipairs(self.jobs) do
        if job.id == id then return job end
    end
    return nil
end

-- Whether a server item can be downloaded: its backend supports it and
-- there is a download folder (an empty download_folder turns them off).
function M:can_download(item)
    local backend = item and self.ctx.servers:for_ref(item)
    return backend ~= nil and backend.download_info ~= nil and item.key ~= nil
        and library.download_folder(self.ctx.cfg) ~= nil
end

local TAGS = {done = "Downloaded", downloading = "Downloading", queued = "Waiting to download",
              paused = "Download stopped", failed = "Download failed"}

-- Tag shown on a server video's row: "Downloaded", "Downloading"…, or nil.
function M:tag(item)
    local job = item and item.backend and self:find(item)
    return job and TAGS[job.status] or nil
end

local FIELDS = {"backend", "machine", "key", "rating_key", "kind", "title", "name", "year", "show",
                "season", "episode"}

-- Adds server items (entries' `server` tables) to the queue. Returns how
-- many were new.
function M:add(items)
    local added = 0
    for _, item in ipairs(items) do
        if self:can_download(item) and not self:find(item) then
            local job = {id = M.job_id(item), status = "queued", added = os.time()}
            for _, k in ipairs(FIELDS) do
                if type(item[k]) == "string" or type(item[k]) == "number" then job[k] = item[k] end
            end
            if not job.title then job.title = job.name or "Video" end
            self.jobs[#self.jobs + 1] = job
            added = added + 1
        end
    end
    if added > 0 then
        self:save()
        self:pump()
    end
    return added
end

function M:changed(finished)
    if self.ctx.changed then self.ctx.changed(finished) end
end

-- Starts the next waiting download if none is running.
function M:pump()
    if self.running then return end
    for _, job in ipairs(self.jobs) do
        if job.status == "queued" then return self:start(job) end
    end
    self:changed()
end

-- A path for a new file: "Name (2).mkv" when the name is taken (a file,
-- a partial download, another download in the list).
function M:free_path(path)
    local base, ext = path:match("^(.*)(%.[^%./]+)$")
    if not base then base, ext = path, "" end
    local function taken(p)
        if util.file_exists(p) or util.file_exists(p .. ".part") then return true end
        for _, job in ipairs(self.jobs) do
            if job.path == p then return true end
        end
        return false
    end
    local p, n = path, 1
    while taken(p) do
        n = n + 1
        p = base .. " (" .. n .. ")" .. ext
    end
    return p
end

local function file_size(path)
    local info = path and utils.file_info(path)
    return info and info.size or 0
end

-- Free space where the download goes. cb(ok, avail).
function M:check_space(dir, job, cb)
    if not job.size then return cb(true) end
    mp.command_native_async({name = "subprocess", args = {"df", "-B1", "--output=avail", dir},
                             capture_stdout = true, capture_stderr = true, playback_only = false},
        function(_, res)
            local avail = res and res.status == 0 and tonumber(tostring(res.stdout or ""):match("(%d+)%s*$"))
            if not avail then return cb(true) end
            cb(M.enough_space(avail, job.size, file_size(job.path .. ".part")), avail)
        end)
end

function M:start(job)
    local backend = self.ctx.servers:get(job.backend)
    if not backend or not backend:signed_in() or not backend:server(job.machine) then
        return self:finish(job, "fail", "Not signed in to this server")
    end
    local run = {}   -- this attempt: a stop or cancel meanwhile makes it stale
    job.run, job.status, job.error, job.retry_at = run, "downloading", nil, nil
    self.running = job
    self:changed()
    backend:download_info(job, function(info, err, fatal)
        if job.run ~= run then return end
        if not info then
            if fatal then return self:finish(job, "fail", err) end
            -- The server may be out of reach for a moment (Wi-Fi after sleep).
            return self:retry(job, err or "Can't reach the server")
        end
        job.size = info.size or job.size
        -- Also the subtitles downloaded (OpenSubtitles) while streaming it.
        local subs = {}
        for _, s in ipairs(info.subs or {}) do subs[#subs + 1] = s end
        for _, s in ipairs(self.ctx.subtitles and self.ctx.subtitles:server_files(job) or {}) do
            subs[#subs + 1] = s
        end
        if not job.path then
            local folder = library.download_folder(self.ctx.cfg)
            if not folder then return self:finish(job, "fail", "No download_folder in config.ini") end
            job.path = self:free_path(util.join(folder, M.relative_path(job, M.safe_ext(info.file))))
        end
        self:save()
        if job.size and util.file_exists(job.path) and file_size(job.path) == job.size then
            -- Stopped while its subtitles were fetched: only those are left.
            return self:fetch_subtitles(job, run, M.subtitle_paths(job.path, subs), info.headers)
        end
        local dir = util.dirname(job.path)
        if not util.mkdir_p(dir) then
            return self:finish(job, "fail", "Can't create " .. dir .. " (see download_folder in config.ini)")
        end
        self:check_space(dir, job, function(ok, avail)
            if job.run ~= run then return end
            if not ok then
                return self:finish(job, "fail", "Not enough free space (" .. M.format_size(avail) .. " free)")
            end
            job.before = file_size(job.path .. ".part")
            job.handle = http.download({url = info.url, headers = info.headers, output = job.path .. ".part",
                                        timeout = 0, resume = true, fail = true, tag = "download"},
                function(code, status, killed)
                    if job.run ~= run or killed then return end
                    job.handle = nil
                    self:transferred(job, run, code, status, M.subtitle_paths(job.path, subs), info.headers)
                end)
        end)
    end)
end

-- A network problem: try again in a while, a few times in a row (any
-- progress resets the count); then stop and wait for the user.
function M:retry(job, why)
    job.tries = (job.tries or 0) + 1
    if job.tries > M.RETRIES then return self:finish(job, "pause", why) end
    local run = job.run
    job.retry_at = os.time() + M.RETRY_DELAY
    msg.info("downloads: " .. tostring(why) .. "; trying again in " .. M.RETRY_DELAY .. " s")
    self.retry_timer = mp.add_timeout(M.RETRY_DELAY, function()
        self.retry_timer = nil
        if job.run == run and self.running == job then self:start(job) end
    end)
end

function M:transferred(job, run, code, status, subs, headers)
    local what, why = M.outcome(code, status)
    local part = job.path .. ".part"
    local have = file_size(part)
    if have > (job.before or 0) then job.tries = 0 end
    if what == "done" and job.size and have ~= job.size then
        what, why = have > job.size and "restart" or "retry", "Incomplete download"
    end
    if what == "restart" then
        os.remove(part)
        job.restarts = (job.restarts or 0) + 1
        if job.restarts > 1 then return self:finish(job, "fail", "The server sent a different file") end
        return self:start(job)
    elseif what == "retry" then
        return self:retry(job, why)
    elseif what == "fail" then
        return self:finish(job, "fail", why)
    end
    local ok, err = os.rename(part, job.path)
    if not ok then return self:finish(job, "fail", "Can't save the file: " .. tostring(err)) end
    job.saved = true   -- the file is ours (cancel removes it)
    self:save()
    self:fetch_subtitles(job, run, subs, headers)
end

-- The video's subtitle files, one by one (best effort), then done.
function M:fetch_subtitles(job, run, subs, headers)
    local i = 0
    local function next_sub()
        if job.run ~= run then return end
        i = i + 1
        local s = subs[i]
        if not s then return self:finish(job, "done") end
        if s.file then
            local data = util.read_file(s.file)
            local f = data and io.open(s.path, "wb")
            if f then
                f:write(data)
                f:close()
            end
            return next_sub()
        end
        http.request({url = s.url, headers = headers, output = s.path, max_size = M.SUB_MAX, fail = true,
                      tag = "download", timeout = 30}, function(scode)
            if scode ~= 200 then os.remove(s.path) end
            next_sub()
        end)
    end
    next_sub()
end

-- result: "done", "pause" (stopped, continues on request) or "fail".
function M:finish(job, result, why)
    job.run, job.handle, job.retry_at, job.tries, job.restarts, job.before = nil, nil, nil, nil, nil, nil
    if self.running == job then self.running = nil end
    if result == "done" then
        job.status, job.error, job.done = "done", nil, os.time()
        -- (Names only at -v: logs end up in bug reports.)
        msg.info("downloads: finished")
        msg.verbose("downloads: saved " .. job.path)
    else
        job.status, job.error = result == "pause" and "paused" or "failed", why
        msg.warn("downloads: " .. job.status .. ": " .. tostring(why))
    end
    self:save()
    self:changed(job)
    self:pump()
end

-- Stops a running download (the partial file stays, to continue later).
local function halt(self, job)
    job.run = nil
    if job.handle then http.abort(job.handle) end
    job.handle, job.retry_at, job.tries, job.before = nil, nil, nil, nil
    if self.running == job then
        self.running = nil
        if self.retry_timer then
            self.retry_timer:kill()
            self.retry_timer = nil
        end
    end
end

function M:pause(job)
    if job.status ~= "downloading" and job.status ~= "queued" then return end
    halt(self, job)
    job.status, job.error = "paused", nil
    self:save()
    self:pump()
end

function M:resume(job)
    if job.status ~= "paused" and job.status ~= "failed" then return end
    job.status, job.error = "queued", nil
    self:save()
    self:pump()
end

function M:pause_all()
    for _, job in ipairs(self.jobs) do
        if job.status == "downloading" or job.status == "queued" then
            halt(self, job)
            job.status, job.error = "paused", nil
        end
    end
    self:save()
    self:changed()
end

function M:resume_all()
    for _, job in ipairs(self.jobs) do
        if job.status == "paused" or job.status == "failed" then job.status, job.error = "queued", nil end
    end
    self:save()
    self:pump()
end

-- Cancels a download that isn't finished, deleting its partial file.
function M:cancel(job)
    if job.status == "done" then return end
    halt(self, job)
    if job.path then
        os.remove(job.path .. ".part")
        -- Saved, but stopped while fetching its subtitles.
        if job.saved then
            os.remove(job.path)
            for _, s in ipairs(library.sidecar_subtitles(util.basename(job.path),
                                                         util.readdir(util.dirname(job.path), "files") or {})) do
                os.remove(util.join(util.dirname(job.path), s))
            end
        end
    end
    for i, j in ipairs(self.jobs) do
        if j == job then table.remove(self.jobs, i) break end
    end
    self:save()
    self:pump()
end

-- A downloaded file was deleted (dvp/library.lua delete_video).
function M:forget_path(path)
    for i, job in ipairs(self.jobs) do
        if job.status == "done" and job.path == path then
            table.remove(self.jobs, i)
            self:save()
            self:changed()
            return
        end
    end
end

-- Closing the app: stop curl (the partial file stays).
function M:shutdown()
    if self.running then
        local job = self.running
        halt(self, job)
        job.status = "paused"
        self:save()
    end
end

-- Downloads not finished, and finished ones.
function M:counts()
    local active, other, done = 0, 0, 0
    for _, job in ipairs(self.jobs) do
        if job.status == "done" then done = done + 1
        elseif job.status == "downloading" or job.status == "queued" then active = active + 1
        else other = other + 1 end
    end
    return active, other, done
end

---------------------------------------------------------------------------
-- Downloads menu
---------------------------------------------------------------------------

-- Measures the speed of the running download (called once a second while
-- the menu is open).
function M:sample()
    local job = self.running
    if not job or not job.path or job.retry_at then
        self.speed = nil
        return
    end
    local have, now = file_size(job.path .. ".part"), mp.get_time()
    local last = self.last_sample
    if last and last.job == job and now > last.t and have >= last.have then
        local rate = (have - last.have) / (now - last.t)
        self.speed = self.speed and (self.speed * 0.7 + rate * 0.3) or rate
    else
        self.speed = nil
    end
    self.last_sample = {job = job, have = have, t = now}
end

function M:status_of(job)
    local running = job == self.running
    return M.status_text(job, running and job.path and file_size(job.path .. ".part") or nil,
                         running and self.speed or nil)
end

function M:job_menu(job)
    local items = {}
    if job.status == "downloading" or job.status == "queued" then
        items[#items + 1] = {label = "Stop", action = function() self:pause(job) end}
    else
        items[#items + 1] = {label = job.status == "failed" and "Try again" or "Resume",
                             action = function() self:resume(job) end}
    end
    items[#items + 1] = {label = "Cancel download", action = function() self:cancel(job) end}
    self.ctx.menu:open({title = job.title, subtitle = self:status_of(job), style = "side", items = items})
end

function M:done_menu(job)
    local ctx = self.ctx
    ctx.menu:open({title = job.title, subtitle = M.format_size(job.size), style = "side", items = {
        {label = "Play", action = function() ctx.play_path(job.path) end},
        {label = "Show in the library", action = function() ctx.browse(util.dirname(job.path), job.path) end},
        {label = "Delete from this device…", action = function() ctx.delete(job.path, job.title) end},
    }})
end

function M:menu_items()
    local items, done = {}, {}
    for _, job in ipairs(self.jobs) do
        if job.status == "done" then
            table.insert(done, 1, job)
        else
            -- (keep_open: B in the download's menu comes back here.)
            items[#items + 1] = {label = job.title, value = function() return self:status_of(job) end,
                                 action = function() self:job_menu(job) end, keep_open = true}
        end
    end
    local active, other = self:counts()
    if #items == 0 then items[1] = {label = "Nothing downloading", disabled = true} end
    if active > 0 then
        items[#items + 1] = {label = "Stop all", action = function() self:pause_all() end, keep_open = true}
    end
    if other > 0 then
        items[#items + 1] = {label = "Resume all", action = function() self:resume_all() end, keep_open = true}
    end
    if #done > 0 then
        items[#items + 1] = {label = "Downloaded", header = true}
        for _, job in ipairs(done) do
            items[#items + 1] = {label = job.title, value = M.format_size(job.size),
                                 action = function() self:done_menu(job) end, keep_open = true}
        end
    end
    local folder = library.download_folder(self.ctx.cfg)
    if folder and util.is_dir(folder) then
        items[#items + 1] = {separator = true}
        items[#items + 1] = {label = "Open the download folder", action = function() self.ctx.browse(folder) end}
    end
    return items
end

function M:open_menu()
    local menu = self.ctx.menu
    local folder = library.download_folder(self.ctx.cfg) or "No download_folder in config.ini"
    local home = os.getenv("HOME")
    if home and home ~= "" and folder:sub(1, #home + 1) == home .. "/" then folder = "~" .. folder:sub(#home + 1) end
    local spec = {title = "Downloads", subtitle = folder, style = "side", wide = true}
    spec.rebuild = function() return self:menu_items() end
    spec.items = spec.rebuild()
    menu:open(spec)
    -- Progress updates once a second, only while this menu is open.
    if self.timer then self.timer:kill() end
    self.last_sample, self.speed = nil, nil
    self.timer = mp.add_periodic_timer(1, function()
        if not menu:shows(spec) then
            self.timer:kill()
            self.timer = nil
            return
        end
        self:sample()
        if menu:top() == spec then menu:refresh() end
    end)
end

return M
