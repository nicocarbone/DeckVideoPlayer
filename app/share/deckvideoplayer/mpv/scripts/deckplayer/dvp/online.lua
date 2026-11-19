-- Online videos (v0.9.0, D84): lists of links as a library source.
--
-- A `.m3u` file in a library folder shows as a folder named after the file
-- ("YouTube.m3u" -> "YouTube"); each line is a link to a video, and an
-- "#EXTINF:-1,Title" line above a link names it. Only http(s) links count;
-- other lines are skipped and counted, like DLNA's unplayable videos
-- (D76). The user's file is only ever read.
--
-- Links to a video file (".mp4", ".m3u8"…) play as they are. Everything
-- else (YouTube, archive.org…) goes through mpv's own yt-dlp hook, which
-- is loaded but only acts on addresses this module marks "ytdl://" (the
-- hook's `include` is empty and its `exclude` matches every address, see
-- mpv.conf): Plex, Jellyfin and DLNA addresses never reach yt-dlp, not
-- even when they fail to load. yt-dlp solves YouTube's JavaScript
-- challenges with QuickJS-NG (`qjs`), and may use a cookies file the user
-- exported from a browser ([online] cookies_file): yt-dlp only gets a
-- private copy of it, made again for each run (a name of its own) and
-- deleted after it, so the user's file is never rewritten, two runs never
-- share a copy, and no copy outlives its run (copies left by a crash go
-- at the next start).
--
-- A playlist or a channel (YouTube's, known by its address, or another
-- site's, once yt-dlp says it is one) shows as a folder in the list:
-- opening it asks yt-dlp for its videos (titles only, no video page each:
-- about a second), the most recent PLAYLIST_MAX of a channel.
--
-- Same interface as dvp/dlna.lua (dvp/servers.lua), with progress,
-- watched marks and "Recently played" kept in resume.json under
-- "online:<link>" (one record per video whatever list it is in, and the
-- same when a downloaded copy plays from the list). Titles missing from
-- the list are asked for when the list is opened (YouTube's oEmbed answer,
-- else a yt-dlp run) and cached in online.json.

local utils = require "mp.utils"
local msg = require "mp.msg"
local util = require "dvp.util"
local http = require "dvp.http"
local library = require "dvp.library"
local Resume = require "dvp.resume"
local VideoInfo = require "dvp.videoinfo"
local OpenSubtitles = require "dvp.opensubtitles"

local M = {}
M.__index = M

M.ID = "online"
M.NAME = "Online"
-- Progress and watched marks live in resume.json.
M.LOCAL_STATE = true
-- The one pseudo-server every link belongs to: a link is its own key.
M.MACHINE = "web"
M.LIST_EXT = "m3u"
M.YTDLP = "yt-dlp"

local LIST_MAX = 1024 * 1024   -- bytes of a list file
local MAX_ENTRIES = 5000       -- links of one list, at most
local URL_MAX = 2048
local CACHE_MAX = 3000         -- titles kept in online.json
local OEMBED_JOBS = 4          -- title requests at a time
local BATCH = 15               -- links per yt-dlp title run
local YTDLP_JOBS = 2           -- yt-dlp title runs at a time
local PLAYLIST_MAX = 200       -- videos listed of a playlist or channel
local READ_WAIT = 10           -- seconds a list file may take to read
local RESOLVE_WAIT = 15        -- seconds "Recently played" waits for a list
local TITLES_SHOW = 0.5        -- seconds between redraws while titles arrive
local COOKIES_GLOB = "^online%-cookies%-.*%.txt"   -- copies (and their .tmp)

---------------------------------------------------------------------------
-- Pure helpers (unit-tested)
---------------------------------------------------------------------------

-- Pure: scheme, host (lowercase, without port), path and query of an
-- http(s) address, or nil (also with control characters in it).
function M.split_url(url)
    url = tostring(url or "")
    if url:find("%c") then return nil end
    local scheme, host, rest = url:match("^(%a+)://([^/?#]+)(.*)$")
    if not scheme then return nil end
    scheme = scheme:lower()
    if scheme ~= "http" and scheme ~= "https" then return nil end
    if host:find("[@%s]") then return nil end
    host = host:lower():gsub(":%d*$", "")
    if host == "" then return nil end
    local path, query = rest:match("^([^?#]*)%??([^#]*)")
    return scheme, host, path or "", query or ""
end

local YT_HOSTS = {["youtube.com"] = true, ["www.youtube.com"] = true, ["m.youtube.com"] = true,
                  ["music.youtube.com"] = true, ["youtube-nocookie.com"] = true,
                  ["www.youtube-nocookie.com"] = true}
local SHORT_HOSTS = {["youtu.be"] = true, ["www.youtu.be"] = true}

local function query_param(query, name)
    for pair in tostring(query or ""):gmatch("[^&]+") do
        local k, v = pair:match("^([^=]+)=(.*)$")
        if k == name then return v end
    end
    return nil
end

local function video_id(id)
    if type(id) == "string" and #id == 11 and id:match("^[%w_%-]+$") and id ~= "videoseries" then return id end
    return nil
end

-- Pure: whether the address is YouTube's (a video, a playlist, a channel…).
function M.is_youtube(url)
    local _, host = M.split_url(url)
    return host ~= nil and (YT_HOSTS[host] or SHORT_HOSTS[host]) == true
end

-- Pure: the id of a YouTube video link (watch, youtu.be, shorts, live,
-- embed), or nil.
function M.youtube_id(url)
    local _, host, path, query = M.split_url(url)
    if not host then return nil end
    if SHORT_HOSTS[host] then return video_id(path:match("^/([%w_%-]+)")) end
    if not YT_HOSTS[host] then return nil end
    if path == "/watch" or path == "/watch/" then return video_id(query_param(query, "v")) end
    for _, prefix in ipairs({"/shorts/", "/live/", "/embed/", "/v/"}) do
        if path:sub(1, #prefix) == prefix then return video_id(path:sub(#prefix + 1):match("^([%w_%-]+)")) end
    end
    return nil
end

local CHANNEL_TABS = {videos = true, shorts = true, streams = true, playlists = true}

-- Pure: a YouTube playlist or channel link in the form yt-dlp lists as one
-- playlist (a channel's videos tab unless the link names its shorts,
-- streams, or its playlists), or nil.
function M.youtube_folder(url)
    local _, host, path, query = M.split_url(url)
    if not host or not YT_HOSTS[host] or M.youtube_id(url) then return nil end
    if path == "/playlist" or path == "/playlist/" then
        local list = query_param(query, "list")
        if list and list:match("^[%w_%-]+$") then return "https://www.youtube.com/playlist?list=" .. list end
        return nil
    end
    local base = path:match("^(/@[^/]+)") or path:match("^(/channel/[%w_%-]+)") or path:match("^(/c/[^/]+)")
        or path:match("^(/user/[^/]+)")
    if not base then return nil end
    local tab = path:sub(#base + 1):match("^/(%a+)")
    return "https://www.youtube.com" .. base .. "/" .. ((tab and CHANNEL_TABS[tab]) and tab or "videos")
end

-- Pure: a link with its scheme and host in lowercase, as everything else
-- expects them ("HTTPS://Example.org/A" -> "https://example.org/A"; both
-- are case-insensitive).
function M.normalize(url)
    local scheme, host, rest = tostring(url or ""):match("^(%a+://)([^/?#]+)(.*)$")
    if not scheme then return url end
    return scheme:lower() .. host:lower() .. rest
end

-- Pure: the key of a link: YouTube's own form for a YouTube video (so
-- youtu.be/…, a start time or a playlist around it are the same video),
-- otherwise the link as written (scheme and host in lowercase).
function M.canonical(url)
    local id = M.youtube_id(url)
    if id then return "https://www.youtube.com/watch?v=" .. id end
    return M.youtube_folder(url) or M.normalize(url)
end

-- Extensions of links that are the video itself (mpv opens them directly).
local DIRECT = {}
for e in ("mp4,m4v,mkv,webm,mov,avi,wmv,flv,ts,m2ts,mts,mpg,mpeg,ogv,3gp,m3u8,mpd"):gmatch("[^,]+") do
    DIRECT[e] = true
end

local function unescape(s)
    return (tostring(s):gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end))
end

-- Pure: the file name at the end of a link ("Film.mp4"), or nil.
function M.file_name(url)
    local _, _, path = M.split_url(url)
    local name = path and unescape(path:match("([^/]+)/?$") or "")
    if not name or name == "" or name:find("[%c/\\]") then return nil end
    return name
end

-- Pure: whether a link is a video file (played without yt-dlp).
function M.is_direct(url)
    if M.is_youtube(url) then return false end
    local name = M.file_name(url)
    return name ~= nil and DIRECT[util.extension(name)] == true
end

-- Pure: whether a link is a streaming manifest (HLS, DASH): played as it
-- is, but downloaded by yt-dlp (curl would only fetch the manifest).
function M.is_manifest(url)
    local name = M.file_name(url)
    local ext = name and util.extension(name)
    return ext == "m3u8" or ext == "mpd"
end

-- Pure: what mpv is given to play a link.
function M.play_path(url)
    if M.is_direct(url) then return url end
    return "ytdl://" .. M.canonical(url)
end

-- Pure: the title of an "#EXTINF:" line (the text after "#EXTINF:"):
-- after the first comma outside quotes ("-1 tvg-name=\"a,b\",Title").
function M.extinf_title(info)
    local quoted = false
    for i = 1, #info do
        local c = info:sub(i, i)
        if c == '"' then
            quoted = not quoted
        elseif c == "," and not quoted then
            local t = util.trim(info:sub(i + 1))
            return t ~= "" and t or nil
        end
    end
    return nil
end

-- Pure: the links of a list file. Returns links ({url, key, title,
-- folder}) in the file's order, each key once (`folder`: a YouTube
-- playlist or channel), and the lines skipped ({count, by = {reason =
-- count}}).
function M.parse_m3u(text)
    text = tostring(text or ""):gsub("^\239\187\191", "")
    local links, seen = {}, {}
    local skipped = {count = 0, by = {}}
    local function skip(why)
        skipped.count = skipped.count + 1
        skipped.by[why] = (skipped.by[why] or 0) + 1
    end
    local title
    for line in (text .. "\n"):gmatch("([^\n]*)\n") do
        line = util.trim((line:gsub("\r$", "")))
        if line:sub(1, 1) == "#" then
            local info = line:match("^#[Ee][Xx][Tt][Ii][Nn][Ff]:(.*)$")
            if info then title = M.extinf_title(info) end
        elseif line ~= "" then
            -- (Anything after the link on its line is ignored.)
            local url = M.normalize(line:match("^(%S+)"))
            if not M.split_url(url) then
                skip("not a web address")
            elseif #url > URL_MAX then
                skip("address too long")
            elseif M.is_youtube(url) and not M.youtube_id(url) and not M.youtube_folder(url) then
                skip("not a YouTube video, playlist or channel")
            else
                local key = M.canonical(url)
                if not seen[key] then
                    seen[key] = true
                    links[#links + 1] = {url = url, key = key, title = title,
                                         folder = M.youtube_folder(url) ~= nil or nil}
                    if #links >= MAX_ENTRIES then break end
                end
            end
            title = nil
        end
    end
    return links, skipped
end

-- Pure: the reason most lines were skipped for (ties: alphabetical).
function M.main_reason(by)
    local best, n = nil, 0
    for why, count in pairs(by or {}) do
        if count > n or (count == n and best and why < best) then best, n = why, count end
    end
    return best
end

-- Pure: a name for a link while its title is unknown.
function M.fallback_label(url, clean)
    local id = M.youtube_id(url)
    if id then return "YouTube video " .. id end
    local folder = M.youtube_folder(url)
    if folder then
        local list = folder:match("[?&]list=([%w_%-]+)")
        if list then return "YouTube playlist " .. list end
        local name = folder:match("^https://www%.youtube%.com/(.+)/%a+$") or folder
        return "YouTube channel " .. unescape(name:gsub("^channel/", ""):gsub("^[cu]s?e?r?/", ""))
    end
    local name = M.file_name(url)
    if name and M.is_direct(url) then return library.display_name(name, false, clean) end
    local _, host = M.split_url(url)
    host = host and host:gsub("^www%.", "")
    return name and (host .. " · " .. name) or host or url
end

-- Pure: where the link is, for the info panel ("YouTube", "archive.org").
function M.site(url)
    if M.is_youtube(url) then return "YouTube" end
    local _, host = M.split_url(url)
    return host and host:gsub("^www%.", "") or "Web"
end

local function encode(s)
    return (tostring(s):gsub("[^%w%-%._~]", function(c) return string.format("%%%02X", c:byte()) end))
end

-- Pure: YouTube's oEmbed address for a video's title and channel.
function M.oembed_url(url)
    return "https://www.youtube.com/oembed?format=json&url=" .. encode(M.canonical(url))
end

-- Pure: "Recently played" key of a link (resume.json).
function M.recent_key(item)
    if not item or type(item.key) ~= "string" or not M.split_url(item.key) then return nil end
    return "online:" .. item.key
end

function M.parse_recent_key(path)
    local url = tostring(path or ""):match("^online:(https?://.+)$")
    if url then return M.MACHINE, url end
    return nil
end

function M.recent_ref(id, key)
    return {backend = M.ID, machine = id, key = key, rating_key = key, kind = "online"}
end

-- Video heights yt-dlp is asked for: the smallest of these at least as
-- tall as the screen (an 800-line Deck gets 1080p, sharper downscaled than
-- 720p upscaled).
local HEIGHTS = {360, 480, 720, 1080, 1440, 2160}

-- Pure: the height to stream at on a `screen_h`-line screen.
function M.stream_height(screen_h)
    screen_h = tonumber(screen_h) or 1080
    for _, h in ipairs(HEIGHTS) do
        if h >= screen_h * 0.95 then return h end
    end
    return 2160
end

-- Pure: the height downloads are made at ([online] download_quality):
-- "auto" is 1080p on a Steam Deck (also when docked: 4K AV1 stutters on
-- its decoder, D62) and 2160p elsewhere.
function M.download_height(quality, device)
    local n = tonumber(quality)
    if n then return n end
    if quality == "best" then return 4320 end
    return (device == "deck-oled" or device == "deck-lcd") and 1080 or 2160
end

-- Pure: yt-dlp's format choice for `height` lines: `format` (-f) and
-- `sort` (-S). The original audio track first (YouTube's AI dubs only if
-- there is nothing else), then the resolution up to `height`, HDR when
-- the video has it, surround sound when it has it, then yt-dlp's own
-- order. On a Deck above 1080p, no AV1 when there is anything else (D62).
function M.format_spec(height, device)
    local deck = device == "deck-oled" or device == "deck-lcd"
    local format = (deck and height > 1080) and "bv*[vcodec!^=av01]+ba/b[vcodec!^=av01]/bv*+ba/b" or "bv*+ba/b"
    return format, string.format("lang,res:%d,hdr:12,channels", height)
end

-- Pure: yt-dlp's --sub-langs for subtitle_languages ("eng,spa" ->
-- "en($|-.*),es($|-.*)"): YouTube's codes are two letters, often with a
-- region or a suffix ("es-419", "en-orig"). (They are regular expressions:
-- "es.*" would also take Estonian, "est".)
function M.sub_langs(slang)
    local out, seen = {}, {}
    for _, code in ipairs(OpenSubtitles.languages(slang)) do
        local two = code:sub(1, 2)
        if two:match("^%a%a$") and not seen[two] then
            seen[two] = true
            out[#out + 1] = two .. "($|-.*)"
        end
    end
    return table.concat(out, ",")
end

-- Pure: the arguments every yt-dlp run starts with (after the program).
function M.common_args(cookies)
    local args = {"--ignore-config", "--no-warnings", "--no-playlist", "--js-runtimes", "quickjs"}
    if cookies then
        args[#args + 1] = "--cookies"
        args[#args + 1] = cookies
    end
    return args
end

-- Pure: mpv's ytdl-raw-options for streaming (the hook adds -J,
-- --sub-format and --write-srt itself).
function M.raw_options(sort, langs, cookies)
    local o = {["ignore-config"] = "", ["js-runtimes"] = "quickjs", ["format-sort"] = sort,
               ["write-auto-subs"] = ""}
    if langs and langs ~= "" then o["sub-langs"] = langs end
    if cookies then o.cookies = cookies end
    return o
end

-- What yt-dlp's errors mean, most specific first: {pattern (lowercase,
-- plain text), message, retry}. `retry`: a network problem worth trying
-- again (downloads).
local ERRORS = {
    {"confirm you're not a bot", "YouTube asks to sign in on this connection: add a cookies file (see the guide)"},
    {"confirm you’re not a bot", "YouTube asks to sign in on this connection: add a cookies file (see the guide)"},
    {"confirm your age", "Age-restricted: needs a cookies file of a YouTube account (see the guide)"},
    {"age-restricted", "Age-restricted: needs a cookies file of a YouTube account (see the guide)"},
    {"private video", "This video is private"},
    {"members-only", "Only for the channel's members"},
    {"join this channel", "Only for the channel's members"},
    {"not available in your country", "Not available in your country"},
    {"blocked it in your country", "Not available in your country"},
    {"this live event will begin", "This live stream hasn't started yet"},
    {"premieres in", "This video hasn't premiered yet"},
    {"video unavailable", "This video is no longer available"},
    {"has been removed", "This video is no longer available"},
    {"unsupported url", "This site isn't supported"},
    {"requested format is not available", "No playable format for this video"},
    {"sign in", "This video needs a sign-in: a cookies file may help (see the guide)"},
    {"logged-in", "This site needs a sign-in: a cookies file may help (see the guide)"},
    {"http error 403", "The site refused the video (an app update may help)"},
    {"http error 429", "The site is limiting requests: try again later", true},
    {"http error 5", "The site had a server error", true},
    {"temporary failure in name resolution", "No internet connection", true},
    {"name or service not known", "No internet connection", true},
    {"network is unreachable", "No internet connection", true},
    {"timed out", "The site did not answer (timeout)", true},
    {"connection reset", "The connection was interrupted", true},
    {"connection refused", "Cannot connect to the site", true},
    {"incompleteread", "The connection was interrupted", true},
    {"unable to download", "Can't reach the site", true},
}

-- Pure: a short message for yt-dlp's error output, and whether it is a
-- network problem worth trying again.
function M.error_text(stderr)
    local text = tostring(stderr or "")
    local low = text:lower()
    for _, e in ipairs(ERRORS) do
        if low:find(e[1], 1, true) then return e[2], e[3] == true end
    end
    local line = text:match("ERROR:%s*([^\n]+)")
    if line then
        line = line:gsub("^%[[^%]]*%]%s*[%w_%-]*:%s*", "")
        return util.utf8_truncate(util.trim(line), 90), false
    end
    if util.trim(text) == "" then return "yt-dlp didn't answer", false end
    return "yt-dlp failed", false
end

-- Pure: what a yt-dlp -J answer describes: {title, channel, duration,
-- live, size (bytes, the chosen formats), formats ("137+140"), ext,
-- playlist (several videos: a playlist, or one video in parts)}.
function M.parse_info(j)
    if type(j) ~= "table" then return nil end
    local parts = type(j.requested_formats) == "table" and j.requested_formats or {j}
    local ids, size = {}, 0
    for _, f in ipairs(parts) do
        if type(f.format_id) == "string" then ids[#ids + 1] = f.format_id end
        local s = tonumber(f.filesize) or tonumber(f.filesize_approx)
        if s and size then size = size + s else size = nil end
    end
    local title = type(j.title) == "string" and util.trim(j.title) or nil
    return {title = title ~= "" and title or nil,
            channel = type(j.channel) == "string" and j.channel or (type(j.uploader) == "string" and j.uploader or nil),
            duration = tonumber(j.duration), live = j.is_live == true or j.live_status == "is_live"
                or j.live_status == "is_upcoming",
            size = size and size > 0 and math.floor(size) or nil,
            formats = #ids > 0 and table.concat(ids, "+") or nil, ext = j.ext,
            playlist = (j._type == "playlist" or j._type == "multi_video") or nil}
end

---------------------------------------------------------------------------
-- Instance
---------------------------------------------------------------------------

-- opts: resume (the Resume store), cfg, config_dir (where cookies_file is
-- looked for when it is a relative name), device (dvp/display.lua).
function M.new(data_dir, opts)
    opts = opts or {}
    local self = setmetatable({}, M)
    self.resume = opts.resume
    self.cfg = opts.cfg
    self.device = opts.device
    self.clean_names = opts.cfg and opts.cfg.interface.clean_names
    self.data_dir = (data_dir and data_dir ~= "") and data_dir or nil
    self.file = self.data_dir and util.join(self.data_dir, "online.json") or nil
    local text = self.file and util.read_file(self.file)
    local data = text and utils.parse_json(text)
    data = type(data) == "table" and data or {}
    -- (Copies: a table saved empty reads back as a JSON array, D85.)
    self.data = {titles = util.plain_table(data.titles),
                 -- The list each played video was played from, for
                 -- "Recently played": only while resume.json still has it.
                 lists = util.plain_table(data.lists),
                 -- Other sites' links yt-dlp was asked about: true for a
                 -- playlist, false for a video.
                 folders = util.plain_table(data.folders)}
    if self.resume then
        for key in pairs(self.data.lists) do
            if not self.resume:get("online:" .. key) then self.data.lists[key] = nil end
        end
    end
    local name = opts.cfg and opts.cfg.online and opts.cfg.online.cookies_file or ""
    if name ~= "" then
        name = util.expand_path(name)
        if name:sub(1, 1) ~= "/" and opts.config_dir then name = util.join(opts.config_dir, name) end
        self.cookies_src = name:sub(1, 1) == "/" and name or nil
    end
    self.items = {}         -- path played for a link -> item
    self.no_title = {}      -- links whose title was asked for (this session)
    self.titles_run = 0     -- the title search going on (stop_titles ends it)
    self.downloads = nil    -- dvp/downloads.lua, set by main.lua
    self.on_titles = nil    -- called when titles arrived (main.lua: redraw)
    -- Cookies copies: a name of their own per run (an id for this
    -- instance, a count); those a crash left behind go now.
    self.copy_id = tostring(self):match("0x(%x+)") or tostring(os.time())
    self.copies = 0
    self.live_copies = {}   -- path -> true while its run goes on
    if self.data_dir then
        for _, n in ipairs(util.readdir(self.data_dir, "files") or {}) do
            local path = util.join(self.data_dir, n)
            if n:match(COOKIES_GLOB) and path ~= self.cookies_src then os.remove(path) end
        end
    end
    return self
end

function M:save()
    if not self.file then return end
    -- Only the most recent titles.
    local list = {}
    for key, e in pairs(self.data.titles) do list[#list + 1] = {key = key, t = type(e) == "table" and e.t or 0} end
    if #list > CACHE_MAX then
        table.sort(list, function(a, b) return a.t > b.t end)
        for i = CACHE_MAX + 1, #list do
            self.data.titles[list[i].key] = nil
            self.data.folders[list[i].key] = nil
        end
    end
    -- Links asked about (titled in their list, so not in titles): if too
    -- many, the videos are forgotten first, then all (asked again once).
    local n = 0
    for _ in pairs(self.data.folders) do n = n + 1 end
    if n > CACHE_MAX then
        for key, v in pairs(self.data.folders) do
            if v == false then
                self.data.folders[key] = nil
                n = n - 1
            end
        end
        if n > CACHE_MAX then self.data.folders = {} end
    end
    local ok, err = util.write_file_atomic(self.file, utils.format_json(self.data))
    if not ok then msg.warn("online: could not save " .. self.file .. ": " .. tostring(err)) end
end

function M:sources()
    return {}
end

-- The router asks whether a server is signed in: links need nothing.
function M:signed_in()
    return true
end

function M:server(id)
    if id == M.MACHINE then return {id = M.MACHINE, name = "Online videos"} end
    return nil
end

function M:connect(_, cb)
    cb({kind = "web"})
end

function M:forget_session()
end

function M:forget_token()
end

-- A private copy of the user's cookies file for one yt-dlp run ("play",
-- "info", "titles", "download"), made now under a name no other run has
-- (runs overlap: yt-dlp writes its copy back, and each run deletes its
-- own); nil without a cookies file.
function M:cookies(purpose)
    if not self.cookies_src or not self.data_dir then return nil end
    local data = util.read_file(self.cookies_src)
    if not data or data == "" then return nil end
    self.copies = self.copies + 1
    local copy = util.join(self.data_dir, string.format("online-cookies-%s-%s-%d.txt", purpose, self.copy_id,
                                                        self.copies))
    local ok = util.write_private(copy, data)
    if not ok then return nil end
    self.live_copies[copy] = true
    return copy
end

-- A run is over: its copy goes.
function M:drop_copy(copy)
    if not copy then return end
    os.remove(copy)
    self.live_copies[copy] = nil
end

-- Closing the app: runs still going are ended by mpv; their copies go now.
function M:shutdown()
    for copy in pairs(self.live_copies) do os.remove(copy) end
    self.live_copies, self.play_cookies = {}, nil
end

-- Runs yt-dlp with `args` after the common ones. cb(res). Returns the
-- handle (mp.abort_async_command).
function M:ytdlp(args, purpose, cb)
    local cmd = {M.YTDLP}
    local cookies = self:cookies(purpose)
    for _, a in ipairs(M.common_args(cookies)) do cmd[#cmd + 1] = a end
    for _, a in ipairs(args) do cmd[#cmd + 1] = a end
    return mp.command_native_async({name = "subprocess", args = cmd, capture_stdout = true,
                                    capture_stderr = true, playback_only = false},
        function(_, res)
            self:drop_copy(cookies)
            cb(res or {})
        end)
end

-- mpv's options for the yt-dlp hook, for a screen `screen_h` lines tall:
-- format (ytdl-format) and raw (ytdl-raw-options), with a fresh copy of
-- the cookies file. main.lua sets them just before the hook runs.
function M:stream_options(screen_h)
    local format, sort = M.format_spec(M.stream_height(screen_h), self.device)
    local langs = self.cfg and M.sub_langs(self.cfg.playback.subtitle_languages) or nil
    self:stream_done()
    self.play_cookies = self:cookies("play")
    return format, M.raw_options(sort, langs, self.play_cookies)
end

-- The hook's yt-dlp run is over (the video opened, or didn't, or the app
-- is closing): its copy of the cookies file goes.
function M:stream_done()
    self:drop_copy(self.play_cookies)
    self.play_cookies = nil
end

-- Local progress of an item ({pos, duration, watched}), from resume.json.
function M:state_of(item)
    local e = self.resume and self.resume:get(M.recent_key(item) or "")
    if not e then return nil end
    return {pos = e.pos, duration = e.duration, watched = e.watched}
end

-- The downloaded copy of an item, if it is complete and still there.
function M:downloaded(item)
    local job = self.downloads and self.downloads:find(item)
    if job and job.status == "done" and job.path and util.file_exists(job.path) then return job.path end
    return nil
end

-- A known title of a link: the list's, else the cache's.
function M:title_of(key)
    local c = self.data.titles[key]
    return type(c) == "table" and type(c.title) == "string" and c.title or nil
end

-- The item and browser entry of one link of list `list_path` (a file, or
-- the address of a playlist), named `list_name`.
function M:entry_for(link, list_path, list_name, pos)
    local key = link.key
    local title = link.title or self:title_of(key)
    local label = title or M.fallback_label(link.url, self.clean_names)
    if link.folder or self.data.folders[key] then
        return {label = label, name = label, is_dir = true, list = true, path = key, pos = pos,
                server = {backend = M.ID, machine = M.MACHINE, key = key, kind = "playlist", url = link.url,
                          title = label, untitled = title == nil or nil, parent = list_path}}
    end
    local item = {backend = M.ID, machine = M.MACHINE, key = key, rating_key = key, kind = "online",
                  url = link.url, title = label, name = label, untitled = title == nil or nil,
                  parent = list_path, show = list_name}
    local play = M.play_path(link.url)
    self.items[play] = item
    -- (A downloaded copy is found by item_for through its download.)
    return {label = label, name = label, is_dir = false, path = self:downloaded(item) or play, pos = pos,
            server = item, state = self:state_of(item)}
end

-- Downloads that finished (or were deleted) since the entries were made:
-- their videos play from the file now (or from the link again).
function M:refresh_entries(entries)
    for _, e in ipairs(entries or {}) do
        local item = e.server
        if item and item.backend == M.ID and not e.is_dir and item.url then
            e.path = self:downloaded(item) or M.play_path(item.url)
        end
    end
end

-- Reads a list file in a subprocess (it may be on a network share that
-- stopped answering: given up after READ_WAIT seconds). cb(text or nil,
-- err).
function M:read_list(path, cb)
    if type(path) ~= "string" or path:sub(1, 1) ~= "/" then return cb(nil, "Not a list file") end
    local over, timer = false, nil
    local handle = mp.command_native_async({name = "subprocess", args = {"head", "-c", tostring(LIST_MAX + 1), "--", path},
                                            capture_stdout = true, capture_stderr = true, playback_only = false},
        function(_, res)
            if over then return end
            over = true
            if timer then timer:kill() end
            if not res or res.status ~= 0 then
                local err = util.trim(tostring(res and res.stderr or "")):gsub("^head: ", ""):gsub("^.-: ", "")
                return cb(nil, err ~= "" and err or "Can't read the list")
            end
            if #(res.stdout or "") > LIST_MAX then return cb(nil, "The list is too long (over 1 MB)") end
            cb(res.stdout or "")
        end)
    if over then return end
    timer = mp.add_timeout(READ_WAIT, function()
        if over then return end
        over = true
        mp.abort_async_command(handle)
        cb(nil, "The list's folder isn't answering")
    end)
end

-- loc: {key = list file path} (kind "list"), or {key = playlist address}
-- (kind "playlist"). cb(entries or nil, err). In the file's (playlist's)
-- order; `entries.skipped` = {count, why} when lines were left out (the
-- browser says so when nothing else is there). Missing titles follow,
-- unless `quiet` (the list isn't shown: "Recently played", downloads).
function M:list(loc, cb, quiet)
    if loc.kind == "playlist" then return self:list_playlist(loc, cb, quiet) end
    local path = loc.key
    self:read_list(path, function(text, err)
        if not text then return cb(nil, err) end
        local links, skipped = M.parse_m3u(text)
        local list_name = library.display_name(util.basename(path), false, false)
        local entries = {}
        for i, link in ipairs(links) do
            entries[#entries + 1] = self:entry_for(link, path, list_name, i)
        end
        if skipped.count > 0 then
            skipped.why = M.main_reason(skipped.by)
            msg.info(string.format("online: %d lines of %s skipped (%s)", skipped.count, util.basename(path),
                                   tostring(skipped.why)))
            entries.skipped = skipped
        end
        cb(entries)
        if not quiet then self:fetch_titles(entries) end
    end)
end

-- The videos of a playlist or channel, as yt-dlp lists them (flat: no
-- page of each video is fetched). Playlists inside it (a channel's
-- playlists tab) are folders too.
function M:list_playlist(loc, cb, quiet)
    local url = loc.key
    self:ytdlp({"--flat-playlist", "-J", "--playlist-end", tostring(PLAYLIST_MAX), "--", url}, "titles", function(res)
        local j = res.status == 0 and utils.parse_json(res.stdout or "") or nil
        if type(j) ~= "table" then return cb(nil, (M.error_text(res.stderr))) end
        local name = type(j.title) == "string" and j.title or M.fallback_label(url)
        if loc.untitled or not self:title_of(url) then self:learned(url, name, j.channel or j.uploader) end
        local entries, seen = {}, {}
        for _, e in ipairs(type(j.entries) == "table" and j.entries or {}) do
            local link = type(e) == "table" and (e.url or e.webpage_url)
            if type(link) == "string" and M.split_url(link) then
                local key = M.canonical(link)
                if not seen[key] then
                    seen[key] = true
                    local folder = e._type == "playlist" or (e.ie_key == "YoutubeTab") or M.youtube_folder(link) ~= nil
                    local title = type(e.title) == "string" and util.trim(e.title) ~= "" and util.trim(e.title) or nil
                    if title and not folder then self.data.titles[key] = {title = title, t = os.time()} end
                    entries[#entries + 1] = self:entry_for({url = link, key = key, title = title, folder = folder or nil},
                                                           url, name, #entries + 1)
                end
            end
        end
        self:save()
        cb(entries)
        if not quiet then self:fetch_titles(entries) end
    end)
end

-- A title arrived for `key`: kept, and shown on the entries that have it.
function M:learned(key, title, channel, entries)
    if type(title) ~= "string" or util.trim(title) == "" then return end
    title = util.trim(title)
    self.data.titles[key] = {title = title, channel = channel, t = os.time()}
    for _, e in ipairs(entries or {}) do
        local item = e.server
        if item and item.key == key and item.untitled then
            item.title, item.name, item.untitled = title, title, nil
            e.label, e.name = title, title
        end
    end
end

-- yt-dlp said link `key` is a playlist: its entries become folders (now
-- and the next time the list is read).
function M:became_folder(key, entries)
    self.data.folders[key] = true
    for _, e in ipairs(entries or {}) do
        local item = e.server
        if item and item.key == key and not e.is_dir then
            e.is_dir, e.list, e.path, e.state = true, true, key, nil
            item.kind = "playlist"
        end
    end
end

-- Titles of the entries without one: YouTube's oEmbed answers (a few at a
-- time), yt-dlp for other sites and playlists (in batches, a couple at a
-- time, which also tells which links are playlists); links to files keep
-- their file name. Network work only because the user opened the list,
-- and only while it is open (stop_titles). Titles show as they arrive.
function M:fetch_titles(entries)
    self.titles_run = self.titles_run + 1
    local run = self.titles_run
    local youtube, other = {}, {}
    for _, e in ipairs(entries) do
        local item = e.server
        local ask = item and item.untitled
            -- (Another site's link: is it a playlist? Asked once.)
            or (item and not e.is_dir and not M.is_youtube(item.url) and not M.is_direct(item.url)
                and self.data.folders[item.key] == nil)
        if ask and not self.no_title[item.key] then
            if M.youtube_id(item.url) then
                youtube[#youtube + 1] = item
            elseif not M.is_direct(item.url) then
                other[#other + 1] = item
            end
        end
    end
    local pending, redraw = 0, nil
    local function show()
        if redraw or not self.on_titles then return end
        redraw = mp.add_timeout(TITLES_SHOW, function()
            redraw = nil
            self.on_titles()
        end)
    end
    local function done()
        pending = pending - 1
        if pending > 0 then return end
        if redraw then
            redraw:kill()
            redraw = nil
        end
        self:save()
        if self.on_titles then self.on_titles() end
    end
    local next_yt = 0
    local function oembed()
        next_yt = next_yt + 1
        local item = youtube[next_yt]
        if not item or run ~= self.titles_run then return done() end
        self.no_title[item.key] = true   -- asked once per session
        http.request({url = M.oembed_url(item.url), tag = "online", timeout = 10}, function(code, body)
            if code == 200 and type(body) == "table" then
                self:learned(item.key, body.title, body.author_name, entries)
                show()
            end
            oembed()
        end)
    end
    local next_batch = 1
    local function batch()
        local first = next_batch
        next_batch = next_batch + BATCH
        if first > #other or run ~= self.titles_run then return done() end
        -- Flat and one entry deep: a playlist answers with its own line
        -- ("P"), cheaply; lines of its entries are ignored.
        local args = {"--skip-download", "--ignore-errors", "--flat-playlist", "--playlist-end", "1",
                      "--print", "playlist:P\t%(original_url)s\t%(title)s\t%(channel,uploader)s",
                      "--print", "video:V\t%(original_url)s\t%(title)s\t%(channel,uploader)s", "--"}
        local asked = {}
        for i = first, math.min(first + BATCH - 1, #other) do
            args[#args + 1] = other[i].url
            asked[other[i].key] = other[i]
            self.no_title[other[i].key] = true
        end
        self:ytdlp(args, "titles", function(res)
            local seen = {}
            for line in tostring(res.stdout or ""):gmatch("[^\n]+") do
                local kind, url, title, channel = line:match("^([PV])\t([^\t]*)\t([^\t]*)\t?(.*)$")
                local key = url and M.canonical(url)
                local item = key and asked[key]
                if item and not seen[key] then
                    seen[key] = true
                    if kind == "P" then self:became_folder(key, entries) end
                    if title ~= "NA" and (item.untitled or kind == "P") then
                        self:learned(key, title, channel ~= "NA" and channel or nil, entries)
                    end
                    if kind == "V" then self.data.folders[key] = false end
                end
            end
            show()
            batch()
        end)
    end
    for _ = 1, math.min(OEMBED_JOBS, #youtube) do
        pending = pending + 1
        oembed()
    end
    for _ = 1, math.min(YTDLP_JOBS, math.ceil(#other / BATCH)) do
        pending = pending + 1
        batch()
    end
end

-- The list was left (another folder, a video playing): no more title
-- requests are started for it (those running finish; the rest are asked
-- for the next time it opens).
function M:stop_titles()
    self.titles_run = self.titles_run + 1
end

-- A video from "Recently played": with the rest of its list after it when
-- the list is still there (if it answers within RESOLVE_WAIT seconds; a
-- list file on a share that stopped answering, a playlist while offline:
-- alone). cb(entry or nil, paths or nil, err).
function M:resolve(id, key, siblings, cb)
    local list_path = self.data.lists[key]
    local playlist = list_path and M.split_url(list_path) ~= nil
    local answered, timer = false, nil
    local function answer(e, paths)
        if answered then return end
        answered = true
        if timer then timer:kill() end
        cb(e, paths)
    end
    local function alone()
        local title = self:title_of(key)
        local name = list_path and (playlist and self:title_of(list_path)
            or library.display_name(util.basename(list_path), false, false)) or nil
        local e = self:entry_for({url = key, key = key, title = title}, list_path, name, 1)
        answer(e, {e.path})
    end
    if not list_path then return alone() end
    -- (Not a playlist's whole listing just to play one of its videos alone.)
    if playlist and not siblings then return alone() end
    self:list({machine = id, key = list_path, kind = playlist and "playlist" or "list"}, function(entries)
        if answered then return end
        local paths, found
        for _, e in ipairs(entries or {}) do
            if e.server and e.server.key == key then
                found, paths = e, {}
            end
            -- (Videos only: playlists in the list are folders.)
            if paths and not e.is_dir then paths[#paths + 1] = e.path end
        end
        if not found then return alone() end
        answer(found, siblings and paths or {found.path})
    end, true)
    if not answered then timer = mp.add_timeout(RESOLVE_WAIT, alone) end
end

-- The item playing from `path`: a link, or a downloaded copy (wherever it
-- is opened from: the list, the download folder), so a video keeps one
-- progress record.
function M:item_for(path)
    if type(path) ~= "string" then return nil end
    local item = self.items[path]
    if item or path:sub(1, 1) ~= "/" or not self.downloads then return item end
    local job = self.downloads:find_path(path)
    if not job or job.backend ~= M.ID or type(job.key) ~= "string" then return nil end
    return {backend = M.ID, machine = M.MACHINE, key = job.key, rating_key = job.key, kind = "online",
            url = job.url or job.key, title = job.title, name = job.title, parent = job.parent, show = job.show}
end

-- Before playback (on_load hook): the local position; nothing to fetch.
-- The list it plays from is kept for "Recently played".
function M:prepare(item)
    if item.parent and self.data.lists[item.key] ~= item.parent then
        self.data.lists[item.key] = item.parent
        self:save()
    end
    local state = self:state_of(item) or {}
    local pos = state.pos
    if pos and Resume.is_finished(pos, state.duration or 0) then pos = nil end
    return {ok = true, pos = pos, subs = {}}
end

function M:header_fields()
    return ""
end

function M:report()
end

-- Watched marks are local. cb(ok).
function M:set_watched(item, watched, cb)
    local key = M.recent_key(item)
    if key and self.resume then
        if watched then self.resume:mark_watched(key) else self.resume:mark_unwatched(key) end
        self.resume:flush()
    end
    if cb then cb(key ~= nil) end
end

function M:describe(path)
    local item = self:item_for(path)
    if not item then return nil end
    if path:sub(1, 1) == "/" then return "Online · downloaded copy" end
    return "Online · " .. M.site(item.url)
end

-- No OpenSubtitles hash for online videos.
function M:fetch_range(_, _, _, _, cb)
    cb(false)
end

-- The video once it plays (file-loaded): the title yt-dlp found, for the
-- overlay, "Recently played" and the next listing.
function M:loaded(item)
    if not item or not item.untitled then return end
    local res = mp.get_property_native("user-data/mpv/ytdl/json-subprocess-result")
    local j = type(res) == "table" and res.stdout and utils.parse_json(res.stdout)
    local info = M.parse_info(j)
    local title = info and info.title or nil
    if not title then
        title = mp.get_property("media-title")
        if title and title:find("://", 1, true) then title = nil end
    end
    if not title then return end
    self:learned(item.key, title, info and info.channel)
    item.title, item.name, item.untitled = title, title, nil
    self:save()
end

-- Why the last link failed to play, from the hook's yt-dlp run, or nil.
function M:play_error(path)
    if type(path) ~= "string" or path:sub(1, 7) ~= "ytdl://" then return nil end
    local res = mp.get_property_native("user-data/mpv/ytdl/json-subprocess-result")
    if type(res) ~= "table" or res.status == nil then return nil end
    if res.error_string == "init" then return "yt-dlp is missing" end
    if res.status == 0 then return nil end
    return (M.error_text(res.stderr))
end

-- The Video info panel: the downloaded file, the video file, or what
-- yt-dlp would play now (its first answer can take a few seconds).
function M:video_info(ref, cb)
    local url = ref.url or ref.key
    local file = self:downloaded(ref)
    if file then
        return VideoInfo.probe_local(file, function(d, err)
            if d then d.file.source = "Online · downloaded copy" end
            cb(d, err)
        end)
    end
    if M.is_direct(url) then
        return VideoInfo.probe_url(url, function(d, err)
            if d then
                d.file.source = "Online · " .. M.site(url)
                d.file.folder = nil
            end
            cb(d, err)
        end)
    end
    local format, sort = M.format_spec(M.stream_height(self.screen_h), self.device)
    local args = {"-J", "-f", format, "-S", sort}
    -- (The subtitles playback would load, as in raw_options.)
    local langs = self.cfg and M.sub_langs(self.cfg.playback.subtitle_languages) or ""
    if langs ~= "" then
        for _, a in ipairs({"--write-subs", "--write-auto-subs", "--sub-langs", langs}) do args[#args + 1] = a end
    end
    args[#args + 1] = "--"
    args[#args + 1] = M.canonical(url)
    self:ytdlp(args, "info", function(res)
        local j = res.status == 0 and utils.parse_json(res.stdout or "") or nil
        if type(j) ~= "table" then return cb(nil, (M.error_text(res.stderr))) end
        local info = M.parse_info(j)
        if info.playlist then
            self:found_playlist(ref.key, info)
            return cb(nil, "This link is a playlist: open it to see its videos")
        end
        if info.title and ref.untitled then self:learned(ref.key, info.title, info.channel) end
        cb(VideoInfo.from_ytdlp(j, "Online · " .. M.site(url)))
    end)
end

-- A link taken for a video is a playlist (yt-dlp's answer): a folder the
-- next time the list is shown.
function M:found_playlist(key, info)
    self:became_folder(key)
    if info.title then self:learned(key, info.title, info.channel) end
    self:save()
end

-- For dvp/downloads.lua: cb(info or nil, err, fatal). A video file is a
-- plain download ({url, file, follow}); anything else (a page, an HLS or
-- DASH manifest) is fetched by yt-dlp
-- ({ytdlp = {url, formats, fresh}, size, file}), with the formats chosen
-- now kept in the job so a download that continues later fetches the same
-- ones; if the site no longer has them, new ones are chosen (`fresh`: the
-- partial files are of no use). An untitled job gets its title here (the
-- file is named after it). A playlist isn't downloaded as one video.
function M:download_info(job, cb)
    local url = job.key
    if M.is_direct(url) and not M.is_manifest(url) then
        return cb({url = url, file = M.file_name(url), follow = true, subs = {}})
    end
    local height = M.download_height(self.cfg and self.cfg.online.download_quality, self.device)
    local format, sort = M.format_spec(height, self.device)
    local function ask(formats, fresh)
        self:ytdlp({"-J", "-f", formats, "-S", sort, "--", url}, "info", function(res)
            local j = res.status == 0 and utils.parse_json(res.stdout or "") or nil
            local info = M.parse_info(j)
            if not info then
                local why, retry = M.error_text(res.stderr)
                if formats ~= format and why == "No playable format for this video" then
                    return ask(format, true)
                end
                return cb(nil, why, not retry)
            end
            if info.playlist then
                self:found_playlist(job.key, info)
                return cb(nil, "A playlist: open it to download its videos", true)
            end
            if info.live then return cb(nil, "Live streams can't be downloaded", true) end
            if job.untitled and info.title then
                job.title, job.name, job.untitled = info.title, info.title, nil
                self:learned(job.key, info.title, info.channel)
                self:save()
            end
            cb({ytdlp = {url = url, formats = info.formats or formats, fresh = fresh}, size = info.size,
                file = "video.mkv", subs = {}})
        end)
    end
    ask(job.formats or format, nil)
end

-- Pure: yt-dlp's arguments (after the common ones) to download `url` in
-- `formats` into folder `dir` as "video.mkv", with subtitles in `langs`
-- next to it ("video.en.vtt").
function M.download_args(url, formats, dir, langs)
    local args = {"-f", formats, "--merge-output-format", "mkv", "--remux-video", "mkv",
                  "-o", util.join(dir, "video.%(ext)s"), "--no-mtime", "--continue", "--no-progress",
                  "--retries", "3", "--fragment-retries", "3"}
    if langs and langs ~= "" then
        for _, a in ipairs({"--write-subs", "--write-auto-subs", "--sub-langs", langs, "--sub-format", "vtt/srt/best"}) do
            args[#args + 1] = a
        end
    end
    args[#args + 1] = "--"
    args[#args + 1] = url
    return args
end

-- Downloads a yt-dlp job into `dir`. cb(res). Returns the handle.
function M:download(spec, dir, cb)
    local langs = self.cfg and M.sub_langs(self.cfg.playback.subtitle_languages) or nil
    return self:ytdlp(M.download_args(spec.url, spec.formats, dir, langs), "download", cb)
end

return M
