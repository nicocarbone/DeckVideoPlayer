-- Jellyfin as a library source (v0.5, docs/DECISIONS.md D55). Same
-- interface as dvp/plex.lua, used through dvp/servers.lua.
--
-- Finding servers: Jellyfin answers a UDP broadcast on the LAN (helper
-- dvp-discover); servers it can't see (another network, Docker without
-- host networking) go in config.ini ([jellyfin] server = URL).
--
-- Sign-in: Quick Connect. The app shows a code; the user approves it in a
-- Jellyfin app or the web page where they are signed in (profile → Quick
-- Connect). The server gives this device its own access token, listed in
-- the server's dashboard (Devices) and revoked by "Sign out". Servers,
-- users and tokens are kept in <data_dir>/jellyfin.json (owner-only).
--
-- Addresses: plain http only to private (home network) addresses, where
-- Jellyfin servers usually run without a certificate; anything else must
-- be https, so the token never crosses the internet in cleartext. Before
-- the token is sent, the address must answer with the server's own id
-- (GET /System/Info/Public needs no token), so a stranger's device at the
-- same LAN address on another network gets nothing.
--
-- Playback is direct play of the original file (/Videos/<id>/stream?
-- static=true). Jellyfin serves that without a token, so mpv normally gets
-- none (mpv logs header values at -v, and logs end up in bug reports);
-- a server that requires one gets it in a header. Progress goes back with
-- /Sessions/Playing, so other Jellyfin apps stay in sync.

local utils = require "mp.utils"
local msg = require "mp.msg"
local util = require "dvp.util"
local http = require "dvp.http"
local version = require "dvp.version"
local Resume = require "dvp.resume"
local Markers = require "dvp.markers"
local VideoInfo = require "dvp.videoinfo"

local M = {}
M.__index = M

-- Backend id and name (dvp/servers.lua).
M.ID, M.NAME = "jellyfin", "Jellyfin"
M.CLIENT = "Deck Video Player"
M.DISCOVER_HELPER = "dvp-discover"
local TICKS = 1e7
local PROBE_TIMEOUT = 3
-- Fields the listings need besides the defaults (UserData is included).
local FIELDS = "Fields=DateCreated,SortName,ChildCount&EnableImages=false"
-- Library kinds that hold no videos.
local SKIP_COLLECTIONS = {music = true, books = true, photos = true, livetv = true}

---------------------------------------------------------------------------
-- Pure helpers (unit-tested)
---------------------------------------------------------------------------

-- Pure: whether `id` looks like a Jellyfin id (hex GUID, with or without
-- dashes), so it is safe in a URL path.
function M.safe_id(id)
    return type(id) == "string" and #id >= 32 and #id <= 36 and id:match("^[%x%-]+$") ~= nil
end

-- Pure: whether `host` is on a home network: a private, loopback or
-- link-local IPv4 address, a .local (mDNS) name or a single-label name.
function M.private_host(host)
    host = tostring(host or ""):lower()
    local a, b = host:match("^(%d+)%.(%d+)%.%d+%.%d+$")
    a, b = tonumber(a), tonumber(b)
    if a then
        return a == 10 or a == 127 or (a == 192 and b == 168) or (a == 172 and b >= 16 and b <= 31)
            or (a == 169 and b == 254)
    end
    return host:match("%.local$") ~= nil or host:match("^[%w%-]+$") ~= nil
end

-- Pure: a server URL made safe to append paths to: scheme, host, optional
-- port and path prefix (reverse proxies), no trailing "/". http only for
-- home network addresses. Returns url, or nil and the reason.
function M.normalize_url(url)
    url = util.trim(tostring(url or "")):gsub("/+$", "")
    local scheme, host, port, prefix = url:match("^(https?)://([%w%-%.]+)(:?%d*)(/?[%w%-%._~/]*)$")
    if not scheme or host:sub(1, 1) == "." or (prefix ~= "" and prefix:sub(1, 1) ~= "/")
        or prefix:find("//", 1, true) or prefix:find("%.%.") then
        return nil, "Not a server address: " .. url
    end
    if port ~= "" then
        local n = tonumber(port:sub(2))
        if not n or n < 1 or n > 65535 then return nil, "Not a server address: " .. url end
    end
    if scheme == "http" and not M.private_host(host) then
        return nil, "Use https for a server outside your home network"
    end
    return scheme .. "://" .. host:lower() .. port .. prefix
end

-- Pure: the Authorization header Jellyfin identifies clients by.
function M.auth_header(device, device_id, token)
    local h = string.format('MediaBrowser Client="%s", Device="%s", DeviceId="%s", Version="%s"',
        M.CLIENT, device, device_id, version)
    if token then h = h .. string.format(', Token="%s"', token) end
    return h
end

-- Pure: servers from dvp-discover's output (one JSON answer per line),
-- checked, one per id and address, at most MAX_ANSWERS: {{id, name, url}}.
M.MAX_ANSWERS = 16

function M.parse_discovery(text)
    local out, seen = {}, {}
    for line in tostring(text or ""):gmatch("[^\n]+") do
        local d = utils.parse_json(line)
        local url = type(d) == "table" and M.normalize_url(d.Address)
        -- One entry per id and address: an answer can't hide another
        -- with the same id (discover() checks which one is real).
        local key = url and M.safe_id(d.Id) and (d.Id .. " " .. url)
        if key and not seen[key] and #out < M.MAX_ANSWERS then
            seen[key] = true
            out[#out + 1] = {id = d.Id, name = type(d.Name) == "string" and d.Name or "Jellyfin", url = url}
        end
    end
    return out
end

-- Pure: progress in the browser's shape ({pos, duration, watched}, s), with
-- the rules of dvp/resume.lua (and Plex): no position under
-- Resume.MIN_POSITION, near the end counts as watched.
function M.item_state(it)
    local state = {}
    local ud = type(it.UserData) == "table" and it.UserData or {}
    if tonumber(it.RunTimeTicks) then state.duration = it.RunTimeTicks / TICKS end
    local pos = tonumber(ud.PlaybackPositionTicks)
    pos = pos and pos > 0 and pos / TICKS or nil
    if pos and Resume.is_finished(pos, state.duration) then
        state.watched = true
    elseif pos and pos >= Resume.MIN_POSITION then
        state.pos = pos
    end
    if ud.Played == true and not state.pos then state.watched = true end
    return state
end

-- Pure: "2024-05-01T12:34:56.0000000Z" -> 20240501123456 (only compared,
-- for "sort by date").
function M.date_key(iso)
    local y, mo, d, h, mi, s = tostring(iso or ""):match("^(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d):(%d%d):(%d%d)")
    if not y then return nil end
    return tonumber(y .. mo .. d .. h .. mi .. s)
end

local function title_year(it)
    local t = it.Name or "?"
    if it.ProductionYear then t = t .. " (" .. it.ProductionYear .. ")" end
    return t
end

-- Pure: display label of an item in a listing of `kind` (as dvp/plex.lua).
function M.item_label(it, kind)
    if it.Type == "Episode" then
        local e = it.IndexNumber and string.format("E%02d", it.IndexNumber) or "E?"
        if kind == "ondeck" or kind == "nextup" or kind == "recent" then
            local s = it.ParentIndexNumber and string.format("S%02d", it.ParentIndexNumber) or ""
            return string.format("%s · %s%s · %s", it.SeriesName or "?", s, e, it.Name or "")
        end
        return e .. " · " .. (it.Name or "")
    elseif it.Type == "Movie" or it.Type == "Series" then
        return title_year(it)
    end
    return it.Name or "?"
end

-- Pure: the direct-play URL of an item (its first version).
function M.stream_url(base, id)
    return base .. "/Videos/" .. id .. "/stream?static=true"
end

-- Pure: browser entries from a list of Jellyfin items (BaseItemDto).
-- `base` is the server's URL, `server_id` its id, `kind` the listing's.
function M.entries_from(items, base, server_id, kind)
    local out = {}
    for _, it in ipairs(type(items) == "table" and items or {}) do
        local id, t = type(it) == "table" and it.Id, type(it) == "table" and it.Type
        if M.safe_id(id) then
            local label = M.item_label(it, kind)
            local e = {label = label, name = it.SortName or label, mtime = M.date_key(it.DateCreated)}
            local ref
            if t == "Series" then
                -- One-season shows open straight into their episodes.
                ref = {kind = it.ChildCount == 1 and "series_episodes" or "seasons", key = id}
            elseif t == "Season" and M.safe_id(it.SeriesId) then
                ref = {kind = "episodes", key = id, series = it.SeriesId}
            elseif it.IsFolder == true and not SKIP_COLLECTIONS[it.CollectionType or ""] then
                ref = {kind = "items", key = id}
            end
            if ref then
                ref.backend, ref.machine = M.ID, server_id
                e.is_dir = true
                e.path = "jellyfin://" .. server_id .. "/" .. ref.kind .. "/" .. id
                e.server = ref
                if (t == "Series" or t == "Season") and type(it.UserData) == "table" and it.UserData.Played then
                    e.state = {watched = true}
                end
                out[#out + 1] = e
            elseif it.IsFolder ~= true and it.MediaType == "Video" then
                e.is_dir = false
                e.path = M.stream_url(base, id)
                e.state = M.item_state(it)
                e.server = {backend = M.ID, machine = server_id, key = id, rating_key = id,
                            kind = t == "Episode" and "episode" or "movie",
                            duration = tonumber(it.RunTimeTicks) and it.RunTimeTicks / 1e4,   -- ms, as Plex
                            -- Full title for the player ("Show · S01E02 · Title").
                            title = M.item_label(it, "recent"),
                            -- For the subtitle search (dvp/subdownload.lua).
                            name = it.Name, year = it.ProductionYear, show = it.SeriesName,
                            season = it.ParentIndexNumber, episode = it.IndexNumber,
                            series = it.SeriesId, season_id = it.SeasonId}
                -- An episode in a season list is sorted by its number.
                if t == "Episode" and kind ~= "ondeck" and kind ~= "nextup" then e.name = label end
                out[#out + 1] = e
            end
        end
    end
    return out
end

-- Pure: the request path of a listing `loc` = {kind, key, series} for
-- user `user`.
function M.listing_path(loc, user)
    local u = "userId=" .. user
    local k = loc.kind
    if k == "root" then return "/UserViews?" .. u end
    if k == "ondeck" then return "/UserItems/Resume?" .. u .. "&MediaTypes=Video&" .. FIELDS end
    -- Without resumable episodes: those are in "Continue watching".
    if k == "nextup" then return "/Shows/NextUp?" .. u .. "&EnableResumable=false&" .. FIELDS end
    if k == "seasons" then return "/Shows/" .. loc.key .. "/Seasons?" .. u .. "&" .. FIELDS end
    if k == "series_episodes" then return "/Shows/" .. loc.key .. "/Episodes?" .. u .. "&" .. FIELDS end
    if k == "episodes" then
        return "/Shows/" .. loc.series .. "/Episodes?" .. u .. "&SeasonId=" .. loc.key .. "&" .. FIELDS
    end
    return "/Items?" .. u .. "&ParentId=" .. loc.key .. "&SortBy=SortName&" .. FIELDS
end

-- Text subtitle formats the server can hand out as files mpv reads.
local SUB_FORMATS = {subrip = "srt", srt = "srt", ass = "ass", ssa = "ass", webvtt = "vtt", vtt = "vtt"}

-- Pure: external (sidecar) text subtitles of a full item.
function M.external_subtitles(it, base)
    local subs = {}
    local ms = type(it.MediaSources) == "table" and it.MediaSources[1]
    if not ms or not M.safe_id(ms.Id) or not M.safe_id(it.Id) then return subs end
    for _, s in ipairs(type(ms.MediaStreams) == "table" and ms.MediaStreams or {}) do
        local fmt = SUB_FORMATS[tostring(s.Codec or ""):lower()]
        local index = tonumber(s.Index)
        if s.Type == "Subtitle" and s.IsExternal == true and fmt and index and index % 1 == 0 then
            subs[#subs + 1] = {
                url = string.format("%s/Videos/%s/%s/Subtitles/%d/Stream.%s", base, it.Id, ms.Id, index, fmt),
                title = s.Title or s.DisplayTitle or "Jellyfin", lang = s.Language or ""}
        end
    end
    return subs
end

-- Pure: what to download for a full item: the original file through
-- /Items/<id>/Download (the server checks the user may download) and its
-- external text subtitles. {url, size, file, subs = {{url, lang, ext}}},
-- or nil and the reason.
function M.download_parts(it, base)
    if type(it) ~= "table" or not M.safe_id(it.Id) then return nil, "Not a Jellyfin item" end
    if it.IsFolder == true or (it.MediaType ~= nil and it.MediaType ~= "Video") then return nil, "Not a video" end
    if it.CanDownload == false then return nil, "Downloads are turned off for your Jellyfin user" end
    local ms = type(it.MediaSources) == "table" and it.MediaSources[1] or {}
    local subs = {}
    for _, sub in ipairs(M.external_subtitles(it, base)) do
        subs[#subs + 1] = {url = sub.url, lang = sub.lang, ext = sub.url:match("%.(%a+)$")}
    end
    local file = type(ms.Path) == "string" and ms.Path or (type(it.Path) == "string" and it.Path)
        or tostring(ms.Container or ""):match("^[^,]*")
    return {url = base .. "/Items/" .. it.Id .. "/Download", size = tonumber(ms.Size), file = file, subs = subs}
end

-- What to download for an item (dvp/downloads.lua, D60); the token goes
-- in a header, on curl's stdin. cb(info or nil, err, fatal): info =
-- download_parts() plus `headers`; `fatal` when trying again won't help.
function M:download_info(item, cb)
    self:metadata(item.machine, item.key, function(it, err, _, code)
        if not it then
            if code == 401 then return cb(nil, "Jellyfin sign-in is no longer valid (sign in again)", true) end
            if code == 404 or code == 400 then return cb(nil, "No longer on the server", true) end
            if not code or code >= 500 then self.bases[item.machine] = nil end
            return cb(nil, err, code ~= nil and code < 500)
        end
        local base, server = self.bases[item.machine], self:server(item.machine)
        if not base or not server then return cb(nil, "Can't reach the Jellyfin server") end
        local info, why = M.download_parts(it, base.url)
        if not info then return cb(nil, why, true) end
        info.headers = self:headers(server)
        info.headers["Accept"] = nil
        cb(info)
    end)
end

-- Pure: the key of a Jellyfin item in "Recently played" (resume.json):
-- "jellyfin://<server id>/<item id>". Stable, unlike the stream URL.
function M.recent_key(item)
    if not item or not M.safe_id(item.machine) or not M.safe_id(item.key) then return nil end
    return "jellyfin://" .. item.machine .. "/" .. item.key
end

-- Pure: server id and item id of a recent_key, or nil.
function M.parse_recent_key(path)
    local id, key = tostring(path or ""):match("^jellyfin://([%x%-]+)/([%x%-]+)$")
    if id and M.safe_id(id) and M.safe_id(key) then return id, key end
    return nil
end

-- Pure: the `server_recent` reference of a "Recently played" entry.
function M.recent_ref(id, key)
    return {backend = M.ID, machine = id, key = key, rating_key = key}
end

---------------------------------------------------------------------------
-- Instance: servers, connections, listings, playback
---------------------------------------------------------------------------

local function random_id()
    local f = io.open("/dev/urandom", "rb")
    local bytes = f and f:read(16) or tostring(os.time()) .. tostring(math.random())
    if f then f:close() end
    return (bytes:gsub(".", function(c) return string.format("%02x", c:byte()) end)):sub(1, 32)
end

-- The device name shown in Jellyfin's dashboard (the machine's host name).
local function device_name()
    for _, path in ipairs({"/run/host/etc/hostname", "/etc/hostname"}) do
        local name = util.trim(util.read_file(path) or ""):gsub("[^%w%-_. ]", "")
        if name ~= "" then return name:sub(1, 40) end
    end
    return "SteamOS"
end

-- opts: urls (list, [jellyfin] server in config.ini).
function M.new(data_dir, opts)
    local self = setmetatable({}, M)
    self.config_urls = opts and opts.urls or {}
    self.file = (data_dir and data_dir ~= "") and util.join(data_dir, "jellyfin.json") or nil
    self.data = {}
    local text = self.file and util.read_file(self.file)
    local data = text and utils.parse_json(text)
    if type(data) == "table" then self.data = data end
    if type(self.data.servers) ~= "table" then self.data.servers = {} end
    if not self.data.device_id then
        self.data.device_id = random_id()
        self:save()
    end
    self.device = device_name()
    self.bases = {}     -- server id -> {url, kind} checked this session
    self.items = {}     -- stream URL -> item info (for playback hooks)
    self.anonymous = {} -- server id -> true when streams need no token
    self.started = {}   -- item id -> true once "playing" was reported
    self.readonly = false -- development: log instead of reporting progress
    return self
end

function M:save()
    if not self.file then return end
    -- Tokens give access to the user's Jellyfin account: owner-only.
    local ok, err = util.write_private(self.file, utils.format_json(self.data))
    if not ok then msg.error("jellyfin: could not save " .. self.file .. ": " .. tostring(err)) end
end

function M:signed_in()
    return #self.data.servers > 0
end

function M:server(id)
    for _, s in ipairs(self.data.servers) do
        if s.id == id then return s end
    end
    return nil
end

function M:servers()
    return self.data.servers
end

function M:headers(server)
    return {["Accept"] = "application/json",
            ["Authorization"] = M.auth_header(self.device, self.data.device_id, server and server.token)}
end

-- Library sources for dvp/library.lua.
function M:sources()
    local out = {}
    for _, s in ipairs(self.data.servers) do
        out[#out + 1] = {name = s.name, path = "jellyfin://" .. s.id .. "/", kind = "jellyfin",
                         server = {backend = M.ID, machine = s.id, key = "", kind = "root"}}
    end
    return out
end

---------------------------------------------------------------------------
-- Finding servers, signing in (Quick Connect), signing out
---------------------------------------------------------------------------

-- cb(info or nil, err): the public info of the server at `url` (no token).
function M:probe(url, cb, timeout)
    http.request({url = url .. "/System/Info/Public", headers = self:headers(nil), tag = "jellyfin",
                  timeout = timeout or PROBE_TIMEOUT}, function(code, body)
        if code == 200 and type(body) == "table" and M.safe_id(body.Id) then return cb(body) end
        cb(nil, code and ("Not a Jellyfin server (" .. code .. ")") or body)
    end)
end

-- Servers on the LAN (broadcast) and in config.ini, each probed for its id
-- and name: a broadcast answer only counts when its address answers with
-- the same id (anyone on the LAN can answer a broadcast, and connect() sends
-- the token to the address found here; a server in a container may also
-- announce an address that can't be reached). When both find a server,
-- the config.ini address wins. cb(list of {id, name, url}).
function M:discover(cb)
    local from_config, from_lan = {}, {}
    local pending = 1 + #self.config_urls
    local function done()
        pending = pending - 1
        if pending > 0 then return end
        local found, seen = {}, {}
        local function take(s)
            if s and not seen[s.id] then
                seen[s.id] = true
                found[#found + 1] = s
            end
        end
        -- (from_config has holes where a server didn't answer: no ipairs.)
        for i = 1, #self.config_urls do take(from_config[i]) end
        for _, s in ipairs(from_lan) do take(s) end
        cb(found)
    end
    for i, raw in ipairs(self.config_urls) do
        local url, err = M.normalize_url(raw)
        if not url then
            msg.warn("jellyfin: config.ini server: " .. tostring(err))
            done()
        else
            self:probe(url, function(info)
                if info then from_config[i] = {id = info.Id, name = info.ServerName or "Jellyfin", url = url} end
                done()
            end, 5)
        end
    end
    mp.command_native_async({name = "subprocess", args = {M.DISCOVER_HELPER, "1500"},
                             capture_stdout = true, playback_only = false}, function(_, res)
        if not res or res.status ~= 0 then
            msg.warn("jellyfin: discovery failed: " .. tostring(res and (res.error_string or res.status)))
        end
        local answers = M.parse_discovery(res and res.stdout)
        pending = pending + #answers
        for _, s in ipairs(answers) do
            self:probe(s.url, function(info)
                if info and info.Id == s.id then
                    from_lan[#from_lan + 1] = {id = s.id, name = info.ServerName or s.name, url = s.url}
                end
                done()
            end)
        end
        done()
    end)
end

-- Starts a Quick Connect sign-in on `server` = {id, name, url}. cb(code or
-- nil, err). Then call poll_quick_connect until it reports success.
function M:start_quick_connect(server, cb)
    local qc = {server = server}
    self.qc = qc
    http.request({url = server.url .. "/QuickConnect/Enabled", headers = self:headers(nil), tag = "jellyfin",
                  timeout = 10}, function(code, enabled)
        if self.qc ~= qc then return end
        if code ~= 200 then return cb(nil, code and ("Jellyfin error " .. code) or enabled) end
        if enabled ~= true then return cb(nil, "Quick Connect is off on this server (Dashboard → General)") end
        http.request({url = server.url .. "/QuickConnect/Initiate", method = "POST",
                      headers = self:headers(nil), tag = "jellyfin", timeout = 10}, function(icode, body)
            if self.qc ~= qc then return end
            if icode ~= 200 or type(body) ~= "table" or not body.Secret or not body.Code then
                return cb(nil, icode and ("Jellyfin error " .. icode) or body)
            end
            qc.secret = body.Secret
            cb(tostring(body.Code))
        end)
    end)
end

-- Forgets the sign-in in progress (dialog closed).
function M:cancel_quick_connect()
    self.qc = nil
end

-- cb(done, err): done = true once the code was approved and the server is
-- saved; err ends the dialog (expired code, server error).
function M:poll_quick_connect(cb)
    local qc = self.qc
    if not qc or not qc.secret then return cb(false, "No code") end
    local url = qc.server.url
    http.request({url = url .. "/QuickConnect/Connect?" .. http.query_string({secret = qc.secret}),
                  headers = self:headers(nil), tag = "jellyfin", timeout = 10}, function(code, body)
        if self.qc ~= qc then return end
        if code == 404 or code == 401 then return cb(false, "The code expired") end
        if code ~= 200 or type(body) ~= "table" or body.Authenticated ~= true then return cb(false) end
        http.request({url = url .. "/Users/AuthenticateWithQuickConnect", method = "POST",
                      body = {Secret = qc.secret}, headers = self:headers(nil), tag = "jellyfin",
                      timeout = 15}, function(acode, auth)
            if self.qc ~= qc then return end
            self.qc = nil
            local user = type(auth) == "table" and type(auth.User) == "table" and auth.User
            if acode ~= 200 or not user or not M.safe_id(user.Id) or type(auth.AccessToken) ~= "string" then
                return cb(false, acode and ("Jellyfin error " .. acode) or auth)
            end
            local s = qc.server
            self:forget_server(s.id)
            table.insert(self.data.servers, {id = s.id, name = s.name, url = url, user_id = user.Id,
                                             username = user.Name, token = auth.AccessToken})
            self:save()
            cb(true)
        end)
    end)
end

-- Drops a server from the saved list (no network).
function M:forget_server(id)
    for i, s in ipairs(self.data.servers) do
        if s.id == id then
            table.remove(self.data.servers, i)
            break
        end
    end
    self.bases[id], self.anonymous[id] = nil, nil
    self.started = {}
end

-- Signs out of a server: its token is revoked on the server (best effort)
-- and forgotten here.
function M:sign_out(id)
    local server = self:server(id)
    if not server then return end
    local base = self.bases[id]
    http.request({url = (base and base.url or server.url) .. "/Sessions/Logout", method = "POST",
                  headers = self:headers(server), tag = "jellyfin", timeout = 10}, function() end)
    self:forget_server(id)
    self:save()
end

---------------------------------------------------------------------------
-- Connections
---------------------------------------------------------------------------

local function kind_of(url)
    local host = url:match("^https?://([^:/]+)")
    return M.private_host(host) and "local" or "remote"
end

-- cb(base {url, kind} or nil, err). The saved address must answer with the
-- server's id; if it doesn't (the server got another address), the LAN is
-- searched for the same server.
function M:connect(id, cb)
    local server = self:server(id)
    if not server then return cb(nil, "Unknown Jellyfin server") end
    if self.bases[id] then return cb(self.bases[id]) end
    local function use(url)
        self.bases[id] = {url = url, kind = kind_of(url)}
        msg.info("jellyfin: " .. server.name .. " (" .. self.bases[id].kind .. ")")
        cb(self.bases[id])
    end
    self:probe(server.url, function(info)
        if info and info.Id == id then return use(server.url) end
        self:discover(function(found)
            for _, s in ipairs(found) do
                if s.id == id and self:server(id) == server then
                    server.url = s.url
                    self:save()
                    return use(s.url)
                end
            end
            cb(nil, "Can't reach " .. server.name)
        end)
    end)
end

-- Forgets the connection of a server (after a failed load: the server may
-- have restarted or the network changed).
function M:forget_session(id)
    self.bases[id] = nil
    self.anonymous[id] = nil
end

-- A file failed although the server answered: check again whether streams
-- need the token.
function M:forget_token(id)
    self.anonymous[id] = nil
end

-- Describes how the server of a stream URL is reached.
function M:describe(path)
    local item = self.items[path]
    local base = item and self.bases[item.machine]
    local server = item and self:server(item.machine)
    if not base or not server then return nil end
    return string.format("Jellyfin · %s · %s", server.name, base.kind)
end

-- Downloads bytes [from, to] of a video (`path` = its stream URL) to
-- `file`. cb(ok). Used for the OpenSubtitles file hash.
function M:fetch_range(path, from, to, file, cb)
    local item = self.items[path]
    local server = item and self:server(item.machine)
    if not server then return cb(false) end
    local headers = self:headers(server)
    headers["Range"] = string.format("bytes=%d-%d", from, to)
    headers["Accept"] = nil
    http.request({url = path, headers = headers, output = file, tag = "jellyfin", timeout = 20,
                  max_size = to - from + 1}, function(code) cb(code == 206) end)
end

---------------------------------------------------------------------------
-- Listings
---------------------------------------------------------------------------

local ROOT_ENTRIES = {{kind = "ondeck", label = "Continue watching"}, {kind = "nextup", label = "Next up"}}

-- loc: {machine, key, kind, series}. cb(entries or nil, err).
function M:list(loc, cb)
    self:connect(loc.machine, function(base, err)
        if not base then return cb(nil, err) end
        local server = self:server(loc.machine)
        http.request({url = base.url .. M.listing_path(loc, server.user_id), headers = self:headers(server),
                      tag = "jellyfin", timeout = 20}, function(code, body)
            if code == 401 then return cb(nil, "Jellyfin sign-in is no longer valid (sign in again)") end
            if code ~= 200 or type(body) ~= "table" or type(body.Items) ~= "table" then
                -- The connection may have gone away (e.g. left the house): retry next time.
                self.bases[loc.machine] = nil
                return cb(nil, code and ("Jellyfin error " .. code) or body)
            end
            local entries = M.entries_from(body.Items, base.url, loc.machine, loc.kind)
            if loc.kind == "root" then
                for i, r in ipairs(ROOT_ENTRIES) do
                    table.insert(entries, i, {label = r.label, name = r.label, is_dir = true,
                        path = "jellyfin://" .. loc.machine .. "/" .. r.kind,
                        server = {backend = M.ID, machine = loc.machine, key = "", kind = r.kind}})
                end
            end
            for _, e in ipairs(entries) do
                if not e.is_dir then self.items[e.path] = e.server end
            end
            cb(entries)
        end)
    end)
end

-- Full item (MediaSources with streams, user data). cb(item or nil, err,
-- server_name, code): `code` is the HTTP status of a failed answer.
function M:metadata(id, item_id, cb)
    if not M.safe_id(item_id) then return cb(nil, "Not a Jellyfin item") end
    self:connect(id, function(base, err)
        if not base then return cb(nil, err) end
        local server = self:server(id)
        http.request({url = base.url .. "/Items/" .. item_id .. "?userId=" .. server.user_id,
                      headers = self:headers(server), tag = "jellyfin", timeout = 15}, function(code, body)
            if code ~= 200 or type(body) ~= "table" or not M.safe_id(body.Id) then
                return cb(nil, code and ("Jellyfin error " .. code) or tostring(body), nil, code)
            end
            cb(body, nil, server.name)
        end)
    end)
end

-- The Video info panel's description of an item. cb(description or nil, err).
function M:video_info(ref, cb)
    self:metadata(ref.machine, ref.key, function(it, err, server_name)
        if not it then return cb(nil, err) end
        local base = self.bases[ref.machine]
        cb(VideoInfo.from_jellyfin(it, VideoInfo.server_source(M.NAME, server_name, base and base.kind)))
    end)
end

-- A video in "Recently played" ready to play: fresh state from the server,
-- and (`siblings`) the rest of its season after an episode, for auto-play.
-- cb(entry, paths or nil, err); paths starts with entry.path.
function M:resolve(id, item_id, siblings, cb)
    self:metadata(id, item_id, function(it, err)
        if not it then return cb(nil, nil, err) end
        local base = self.bases[id]
        local entry = base and M.entries_from({it}, base.url, id, "ondeck")[1]
        if not entry or entry.is_dir then return cb(nil, nil, "Not a video") end
        self.items[entry.path] = entry.server
        if not siblings or it.Type ~= "Episode" or not M.safe_id(it.SeriesId) then
            return cb(entry, {entry.path})
        end
        -- The rest of its season; an episode outside any season: of the show.
        local loc = M.safe_id(it.SeasonId)
            and {backend = M.ID, machine = id, key = it.SeasonId, series = it.SeriesId, kind = "episodes"}
            or {backend = M.ID, machine = id, key = it.SeriesId, kind = "series_episodes"}
        self:list(loc,
            function(entries)
                local paths
                for _, e in ipairs(entries or {}) do
                    if e.server and e.server.key == item_id then paths = {} end
                    if paths and not e.is_dir then paths[#paths + 1] = e.path end
                end
                if not paths or paths[1] ~= entry.path then paths = {entry.path} end
                cb(entry, paths)
            end)
    end)
end

---------------------------------------------------------------------------
-- Playback
---------------------------------------------------------------------------

function M:item_for(path)
    return path and self.items[path] or nil
end

-- Whether the server streams without a token (checked once per connection
-- with a 1-byte range request; blocking, short). nil = unknown.
function M:streams_anonymously(item, path)
    local id = item.machine
    if self.anonymous[id] == nil then
        -- The body goes nowhere; the size cap only has to stop a server that
        -- ignores Range from sending the whole file. Error pages fit under
        -- it, so 401/403 come back as codes (curl ends a download past
        -- max-filesize with an error and no code).
        local code, err = http.request_sync({url = path, headers = {"Range: bytes=0-0"}, tag = "jellyfin",
                                             timeout = 3, max_size = 65536, output = "/dev/null"})
        if code == 200 or code == 206 or err == http.CURL_ERRORS[63] then
            -- 63: the server started sending a video larger than the cap.
            self.anonymous[id] = true
        elseif code == 401 or code == 403 then
            self.anonymous[id] = false
        end
    end
    return self.anonymous[id]
end

-- Fresh state just before playback (blocking, short timeouts; called from
-- the on_load hook): resume position (s), external subtitles, intro and
-- credits segments. `unreachable` when there is no connection or the
-- server didn't answer.
function M:prepare(item)
    -- A new playback: its first report is "playing" again, even if the
    -- last one of this item ended without a "stopped" (no position).
    self.started[item.key] = nil
    local base = self.bases[item.machine]
    local server = self:server(item.machine)
    if not base or not server then return {subs = {}, unreachable = true} end
    local code, it = http.request_sync({url = base.url .. "/Items/" .. item.key .. "?userId=" .. server.user_id,
                                        headers = self:headers(server), tag = "jellyfin", timeout = 5})
    if code == nil then return {subs = {}, unreachable = true} end
    if code ~= 200 or type(it) ~= "table" then return {subs = {}} end
    local ms = type(it.MediaSources) == "table" and it.MediaSources[1] or {}
    item.size = tonumber(ms.Size)
    item.media_source = M.safe_id(ms.Id) and ms.Id or nil
    local markers = {}
    if ms.HasSegments then
        local scode, segments = http.request_sync({url = base.url .. "/MediaSegments/" .. item.key,
                                                   headers = self:headers(server), tag = "jellyfin", timeout = 3})
        if scode == 200 then markers = Markers.from_jellyfin(segments) end
    end
    local path = M.stream_url(base.url, item.key)
    self:streams_anonymously(item, path)
    local state = M.item_state(it)
    return {ok = true, pos = state.pos, subs = M.external_subtitles(it, base.url), markers = markers}
end

-- mpv `http-header-fields` for this item: nothing when the server streams
-- without a token (the usual case), else the token (D55).
function M:header_fields(item)
    if self.anonymous[item.machine] then return "" end
    local server = self:server(item.machine)
    return server and string.format('Authorization: MediaBrowser Token="%s"', server.token) or ""
end

-- Reports playback state to the server ("now playing" in its dashboard,
-- resume position on all apps). state: "playing" | "paused" | "stopped".
function M:report(item, state, time_s, duration_s, sync)
    local base = self.bases[item.machine]
    local server = self:server(item.machine)
    if not base or not server or not time_s then return end
    local endpoint
    if state == "stopped" then
        endpoint = "/Sessions/Playing/Stopped"
        self.started[item.key] = nil
    elseif self.started[item.key] then
        endpoint = "/Sessions/Playing/Progress"
    else
        endpoint = "/Sessions/Playing"
        self.started[item.key] = true
    end
    if self.readonly then
        msg.info(string.format("jellyfin (read-only): would report %s at %.0f s", state, time_s))
        return
    end
    local req = {url = base.url .. endpoint, method = "POST", headers = self:headers(server), tag = "jellyfin",
                 timeout = sync and 3 or 10,
                 body = {ItemId = item.key, MediaSourceId = item.media_source, CanSeek = true,
                         IsPaused = state == "paused", PlayMethod = "DirectPlay",
                         PositionTicks = math.floor(time_s * TICKS)}}
    if sync then http.request_sync(req) else http.request(req, function() end) end
end

-- Marks an item watched/unwatched on the server (unwatched also clears
-- the position). cb(ok).
function M:set_watched(item, watched, cb, sync)
    local base = self.bases[item.machine]
    local server = self:server(item.machine)
    if not base or not server then return cb and cb(false) end
    if self.readonly then
        msg.info("jellyfin (read-only): would mark " .. (watched and "watched" or "unwatched"))
        return cb and cb(true)
    end
    local req = {url = base.url .. "/UserPlayedItems/" .. item.key .. "?userId=" .. server.user_id,
                 method = watched and "POST" or "DELETE", headers = self:headers(server), tag = "jellyfin",
                 timeout = sync and 3 or 10}
    if sync then
        local code = http.request_sync(req)
        if cb then cb(code == 200) end
    else
        http.request(req, function(code) if cb then cb(code == 200) end end)
    end
end

return M
