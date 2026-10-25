-- Plex Media Server as a library source (v0.3, docs/DECISIONS.md D37).
--
-- Sign-in: plex.tv PIN flow (a 4-character code entered at plex.tv/link);
-- the account token and the list of servers with their addresses are kept
-- in <data_dir>/plex.json. Servers appear as library sources.
--
-- Connecting: a server lists many addresses (LAN, Docker bridges, public,
-- relay). They are probed in parallel (GET /identity, 3 s, *without* a
-- token, checking the server's machineIdentifier) in order of preference:
-- local https (plex.direct), remote https. The first reachable one in that
-- order wins and is remembered. Only https is used: the plex.direct
-- certificate proves it is the user's server, while plain http would send
-- the token (for an owned server: the account token) in cleartext to
-- whatever answers at that LAN address on any network the Deck joins
-- (D39). Plain http is an opt-in (`[plex] allow_insecure_lan`). Relays are
-- skipped: they are bandwidth-capped and can't carry original quality.
--
-- Playback is direct play: mpv opens the part URL (/library/parts/…) with a
-- token in an HTTP header (file-local `http-header-fields`), so no token is
-- in paths or resume data. That header is a *transient* token from the
-- server (/security/token?type=delegation), not the account token: mpv
-- logs property changes at -v, and users share such logs in bug reports.
-- A transient token expires by itself and can't access the plex.tv
-- account. Progress goes back to the server (/:/timeline, /:/scrobble), so
-- other Plex apps stay in sync.

local utils = require "mp.utils"
local msg = require "mp.msg"
local util = require "dvp.util"
local http = require "dvp.http"
local version = require "dvp.version"
local Resume = require "dvp.resume"

local M = {}
M.__index = M

M.PRODUCT = "Deck Video Player"
M.PLEX_TV = "https://plex.tv"
M.LINK_URL = "plex.tv/link"
local PROBE_TIMEOUT = 3
local LIBRARY = "com.plexapp.plugins.library"

---------------------------------------------------------------------------
-- Pure helpers (unit-tested)
---------------------------------------------------------------------------

-- Pure: whether a path from a server response is safe to append to the
-- server's base URL: a single leading "/", URL-path characters only. Blocks
-- tricks like "@evil.example/x" (-> https://server@evil.example/x) or
-- "//evil.example" that would send requests, token included, elsewhere.
function M.safe_key(key)
    return type(key) == "string" and key:match("^/[%w%-%._~/%%?=&,+]*$") ~= nil
        and key:sub(1, 2) ~= "//"
end

-- Servers from a plex.tv /api/v2/resources response.
function M.parse_resources(list, account_token)
    local servers = {}
    for _, r in ipairs(type(list) == "table" and list or {}) do
        if type(r) == "table" and tostring(r.provides or ""):find("server") then
            local conns = {}
            for _, c in ipairs(r.connections or {}) do
                conns[#conns + 1] = {uri = c.uri, address = c.address, port = c.port,
                                     protocol = c.protocol, ["local"] = c["local"] == true,
                                     relay = c.relay == true}
            end
            servers[#servers + 1] = {
                name = r.name or "Plex", machine = r.clientIdentifier,
                token = r.accessToken or account_token, owned = r.owned == true,
                connections = conns,
            }
        end
    end
    return servers
end

-- Pure: rank of a local address. Home networks (192.168/16, 10/8) first;
-- 172.16/12 last because Docker bridges (172.17–172.31) live there and
-- servers in containers report them as "local" addresses no client can
-- reach.
function M.local_rank(address)
    local a, b = (address or ""):match("^(%d+)%.(%d+)%.")
    a, b = tonumber(a), tonumber(b)
    if a == 172 and b and b >= 16 and b <= 31 then return 3 end
    if a == 192 or a == 10 then return 1 end
    return 2
end

-- Base URLs to try for a server, best first: local https (valid
-- certificate via plex.direct), then remote https. With `allow_insecure`,
-- local plain http too (for routers that block plex.direct DNS; only safe
-- on a trusted network). No relays.
function M.server_candidates(server, allow_insecure)
    local out, seen = {}, {}
    local function add(url, kind)
        if url and not seen[url] then
            seen[url] = true
            out[#out + 1] = {url = url:gsub("/+$", ""), kind = kind}
        end
    end
    local locals = {}
    for i, c in ipairs(server.connections or {}) do
        if c["local"] and not c.relay then locals[#locals + 1] = {c = c, rank = M.local_rank(c.address), i = i} end
    end
    table.sort(locals, function(x, y)
        if x.rank ~= y.rank then return x.rank < y.rank end
        return x.i < y.i
    end)
    -- Bare origins only: anything else (user info, path, query) would
    -- change where `base .. key` requests and the token go.
    local function https(uri)
        return type(uri) == "string" and uri:gsub("/+$", ""):match("^https://[%w%-%.]+:?%d*$") ~= nil
    end
    for _, l in ipairs(locals) do
        if https(l.c.uri) then add(l.c.uri, "local") end
        local address, port = l.c.address, tonumber(l.c.port)
        if allow_insecure and type(address) == "string" and address:match("^%d+%.%d+%.%d+%.%d+$")
            and port and port > 0 and port < 65536 and port % 1 == 0 then
            add(string.format("http://%s:%d", address, port), "local")
        end
    end
    for _, c in ipairs(server.connections or {}) do
        if not c["local"] and not c.relay and https(c.uri) then add(c.uri, "remote") end
    end
    return out
end

-- Index of the connection to use once `results` (index -> true/false, nil =
-- pending) is decided: the first success with no better candidate still
-- pending. Returns nil while undecided, false when all failed.
function M.pick_candidate(results, n)
    for i = 1, n do
        if results[i] == nil then return nil end
        if results[i] == true then return i end
    end
    return false
end

local function title_year(md)
    local t = md.title or "?"
    if md.year then t = t .. " (" .. md.year .. ")" end
    return t
end

-- Pure: display label of a Plex item in a listing of `kind`.
function M.item_label(md, kind)
    if md.type == "episode" then
        local e = md.index and string.format("E%02d", md.index) or "E?"
        if kind == "ondeck" or kind == "recent" then
            local s = md.parentIndex and string.format("S%02d", md.parentIndex) or ""
            return string.format("%s · %s%s · %s", md.grandparentTitle or "?", s, e, md.title or "")
        end
        return e .. " · " .. (md.title or "")
    elseif md.type == "movie" or md.type == "show" then
        return title_year(md)
    end
    return md.title or "?"
end

-- Pure: Plex progress -> the shape the browser uses ({pos, duration,
-- watched}, seconds), with the same rules as dvp/resume.lua entries: no
-- position under Resume.MIN_POSITION, near the end counts as watched.
function M.item_state(md)
    local state = {}
    if tonumber(md.duration) then state.duration = md.duration / 1000 end
    local pos = tonumber(md.viewOffset) and md.viewOffset / 1000
    if pos and Resume.is_finished(pos, state.duration) then
        state.watched = true
    elseif pos and pos >= Resume.MIN_POSITION then
        state.pos = pos
    end
    if (tonumber(md.viewCount) or 0) > 0 and not state.pos then state.watched = true end
    return state
end

-- Pure: browser entries from a Plex MediaContainer. `base` is the server's
-- current URL, `machine` its id, `kind` the kind of listing.
function M.entries_from(container, base, machine, kind)
    local out = {}
    for _, d in ipairs(container.Directory or {}) do
        -- Library sections (movie and show libraries only).
        local key = "/library/sections/" .. tostring(d.key) .. "/all"
        if (d.type == "movie" or d.type == "show") and M.safe_key(key) then
            out[#out + 1] = {label = d.title, name = d.title, is_dir = true,
                path = "plex://" .. machine .. key,
                plex = {machine = machine, key = key, kind = d.type == "show" and "shows" or "items"}}
        end
    end
    for _, md in ipairs(container.Metadata or {}) do
        local label = M.item_label(md, kind)
        local e = {label = label, name = md.titleSort or label, mtime = md.addedAt}
        if (md.type == "show" or md.type == "season") and M.safe_key(md.key) then
            local key = md.key
            -- Seasons and episodes keep the server's order (by number).
            local child_kind = md.type == "show" and "seasons" or "episodes"
            -- One-season shows open straight into their episodes.
            if md.type == "show" and md.childCount == 1 then
                key = key:gsub("/children$", "/allLeaves")
                child_kind = "episodes"
            end
            e.is_dir = true
            e.path = "plex://" .. machine .. key
            e.plex = {machine = machine, key = key, kind = child_kind}
            if md.leafCount and md.viewedLeafCount and md.leafCount > 0 and md.viewedLeafCount >= md.leafCount then
                e.state = {watched = true}
            end
            out[#out + 1] = e
        elseif md.type ~= "show" and md.type ~= "season" then
            local media = md.Media and md.Media[1]
            local part = media and media.Part and media.Part[1]
            if part and M.safe_key(part.key) and M.safe_key(md.key) then
                e.is_dir = false
                e.path = base .. part.key
                e.state = M.item_state(md)
                e.plex = {machine = machine, rating_key = md.ratingKey, key = md.key,
                          duration = md.duration, kind = md.type,
                          -- Full title for the player ("Show · S01E02 · Title").
                          title = M.item_label(md, "ondeck"),
                          -- For the subtitle search (dvp/subdownload.lua).
                          name = md.title, year = md.year, show = md.grandparentTitle,
                          season = md.parentIndex, episode = md.index, size = part.size}
                -- An episode in a season list is sorted by its number.
                if md.type == "episode" and kind ~= "ondeck" then e.name = label end
                out[#out + 1] = e
            end
        end
    end
    return out
end

-- Pure: URL of Plex's sign-in page for a (strong) PIN code: opened on a
-- phone from the QR code, it links the app without typing anything.
function M.auth_url(client_id, code)
    return "https://app.plex.tv/auth#?clientID=" .. client_id .. "&code=" .. code
        .. "&context%5Bdevice%5D%5Bproduct%5D=" .. M.PRODUCT:gsub(" ", "%%20")
end

-- Pure: external subtitle tracks of a full metadata response.
function M.external_subtitles(md, base)
    local subs = {}
    local media = md and md.Media and md.Media[1]
    local part = media and media.Part and media.Part[1]
    for _, s in ipairs(part and part.Stream or {}) do
        if s.streamType == 3 and M.safe_key(s.key) then
            subs[#subs + 1] = {url = base .. s.key, title = s.displayTitle or s.title or "Plex",
                               lang = s.languageTag or s.languageCode or ""}
        end
    end
    return subs
end

---------------------------------------------------------------------------
-- Instance: account, connections, listings, playback
---------------------------------------------------------------------------

local function random_id()
    local f = io.open("/dev/urandom", "rb")
    local bytes = f and f:read(16) or tostring(os.time()) .. tostring(math.random())
    if f then f:close() end
    return (bytes:gsub(".", function(c) return string.format("%02x", c:byte()) end)):sub(1, 32)
end

-- opts: allow_insecure (bool, [plex] allow_insecure_lan).
function M.new(data_dir, opts)
    local self = setmetatable({}, M)
    self.allow_insecure = opts and opts.allow_insecure or false
    self.file = (data_dir and data_dir ~= "") and util.join(data_dir, "plex.json") or nil
    self.account = {}
    local text = self.file and util.read_file(self.file)
    local data = text and utils.parse_json(text)
    if type(data) == "table" then self.account = data end
    if not self.account.client_id then
        self.account.client_id = random_id()
        self:save()
    end
    self.bases = {}   -- machine -> {url, kind} chosen this session
    self.items = {}   -- stream URL -> item info (for playback hooks)
    self.transient = {} -- machine -> {token, time} for mpv's HTTP header
    self.prefetching = {} -- machine -> true while a transient token is requested
    self.readonly = false -- development: log instead of reporting progress
    return self
end

function M:save()
    if not self.file then return end
    -- The token gives access to the user's Plex account: owner-only, from
    -- the moment the file exists (D39).
    local ok, err = util.write_private(self.file, utils.format_json(self.account))
    if not ok then msg.error("plex: could not save " .. self.file .. ": " .. tostring(err)) end
end

function M:signed_in()
    return self.account.token ~= nil and self.account.token ~= ""
end

function M:username()
    return self.account.username
end

-- Headers identifying this app (required by plex.tv and nice for the
-- server's dashboard). `token` adds X-Plex-Token.
function M:headers(token)
    local h = {
        ["Accept"] = "application/json",
        ["X-Plex-Product"] = M.PRODUCT,
        ["X-Plex-Version"] = version,
        ["X-Plex-Client-Identifier"] = self.account.client_id,
        ["X-Plex-Platform"] = "Linux",
        ["X-Plex-Device-Name"] = M.PRODUCT,
    }
    if token then h["X-Plex-Token"] = token end
    return h
end

function M:server(machine)
    for _, s in ipairs(self.account.servers or {}) do
        if s.machine == machine then return s end
    end
    return nil
end

-- Library sources for dvp/library.lua.
function M:sources()
    local out = {}
    if not self:signed_in() then return out end
    for _, s in ipairs(self.account.servers or {}) do
        out[#out + 1] = {name = s.name, path = "plex://" .. s.machine .. "/", kind = "plex",
                         plex = {machine = s.machine, key = "/", kind = "root"}}
    end
    return out
end

---------------------------------------------------------------------------
-- Sign-in (PIN flow) and server list
---------------------------------------------------------------------------

-- Asks plex.tv for two PINs: a short code to type at plex.tv/link and a
-- strong one for the QR code (Plex's auth page takes it straight from the
-- URL). cb(short_code or nil, auth_url or nil, err). Then call poll_pin
-- until it reports success; whichever PIN is claimed first wins.
function M:start_pin(cb)
    local pins, pending = {}, 2
    local function create(strong)
        http.request({url = M.PLEX_TV .. "/api/v2/pins?strong=" .. tostring(strong), method = "POST",
                      headers = self:headers(), tag = "plex", timeout = 15}, function(code, body)
            if (code == 201 or code == 200) and type(body) == "table" and body.code then
                pins[strong and "strong" or "short"] = {id = body.id, code = body.code}
            else
                pins.err = code and ("plex.tv error " .. code) or body
            end
            pending = pending - 1
            if pending > 0 then return end
            if not pins.short then return cb(nil, nil, pins.err) end
            self.pin = pins
            cb(pins.short.code, pins.strong and M.auth_url(self.account.client_id, pins.strong.code))
        end)
    end
    create(false)
    create(true)
end

-- Forgets the PINs (sign-in dialog closed): answers still in flight are
-- then ignored.
function M:cancel_pin()
    self.pin = nil
end

-- cb(done, err): done = true once one of the PINs was claimed and the
-- account is saved; err then tells that the server list could not be read
-- (still signed in: Plex account → Refresh retries).
function M:poll_pin(cb)
    local pins = self.pin
    if not pins then return cb(false, "no code") end
    local list = {pins.short, pins.strong}
    local pending, finished, expired = #list, false, false
    for _, pin in ipairs(list) do
        http.request({url = M.PLEX_TV .. "/api/v2/pins/" .. pin.id, headers = self:headers(),
                      tag = "plex", timeout = 10}, function(code, body)
            pending = pending - 1
            if finished or self.pin ~= pins then return end
            -- The short code is what the user types: its expiry ends the
            -- dialog, whichever answer arrives last.
            if code == 404 and pin == pins.short then expired = true end
            if code == 200 and type(body) == "table" and body.authToken and body.authToken ~= "" then
                finished = true
                self.account.token = body.authToken
                self.pin = nil
                -- Keep the sign-in even if the server list fails next.
                self:save()
                self:refresh_account(function(err) cb(true, err) end)
            elseif pending == 0 then
                cb(false, expired and "The code expired" or nil)
            end
        end)
    end
end

-- Re-reads the user name and the server list from plex.tv. cb(err or nil).
-- Answers that arrive after a sign-out (or a new sign-in) are dropped, so
-- they can't write the old servers and tokens back.
function M:refresh_account(cb)
    local token = self.account.token
    local function current() return token ~= nil and self.account.token == token end
    http.request({url = M.PLEX_TV .. "/api/v2/user", headers = self:headers(token), tag = "plex",
                  timeout = 15}, function(code, body)
        if not current() then return cb("Signed out") end
        if code == 401 then return cb("Plex sign-in is no longer valid") end
        if code == 200 and type(body) == "table" then
            self.account.username = body.username or body.title or body.email
        end
        local url = M.PLEX_TV .. "/api/v2/resources?includeHttps=1&includeRelay=0&includeIPv6=0"
        http.request({url = url, headers = self:headers(token), tag = "plex", timeout = 15},
            function(rcode, list)
                if not current() then return cb("Signed out") end
                if rcode ~= 200 then return cb(rcode and ("plex.tv error " .. rcode) or list) end
                self.account.servers = M.parse_resources(list, token)
                self.bases = {}
                self:save()
                cb(nil)
            end)
    end)
end

function M:sign_out()
    self.account.token, self.account.username, self.account.servers = nil, nil, nil
    self.bases, self.items, self.transient, self.pin = {}, {}, {}, nil
    self:save()
end

---------------------------------------------------------------------------
-- Connections
---------------------------------------------------------------------------

-- cb(base {url, kind} or nil, err).
function M:connect(machine, cb)
    local server = self:server(machine)
    if not server then return cb(nil, "Unknown Plex server") end
    if self.bases[machine] then return cb(self.bases[machine]) end
    local cands = M.server_candidates(server, self.allow_insecure)
    if #cands == 0 then return cb(nil, "The server has no usable address") end
    local results, decided = {}, false
    local function settle()
        if decided then return end
        local i = M.pick_candidate(results, #cands)
        if i == nil then return end
        decided = true
        if i == false then
            cb(nil, "Can't reach " .. server.name)
            return
        end
        self.bases[machine] = cands[i]
        msg.info(string.format("plex: %s via %s (%s)", server.name, cands[i].kind, cands[i].url))
        self:prefetch_token(machine)
        cb(cands[i])
    end
    for i, c in ipairs(cands) do
        -- No token: /identity is public, and a probe may reach a stranger's
        -- device at the same LAN address. The machine id must match.
        http.request({url = c.url .. "/identity", headers = self:headers(nil), tag = "plex",
                      timeout = PROBE_TIMEOUT}, function(code, body)
            local mc = type(body) == "table" and body.MediaContainer
            results[i] = code == 200 and type(mc) == "table" and mc.machineIdentifier == machine
            settle()
        end)
    end
end

-- Downloads bytes [from, to] of a Plex video (`path` = its stream URL) to
-- `file`. cb(ok). Used to compute the OpenSubtitles file hash.
function M:fetch_range(path, from, to, file, cb)
    local item = self.items[path]
    local server = item and self:server(item.machine)
    if not server then return cb(false) end
    local headers = self:headers(server.token)
    headers["Range"] = string.format("bytes=%d-%d", from, to)
    headers["Accept"] = nil
    -- Only the asked range: a server that ignores Range would otherwise
    -- stream the whole film into /tmp (RAM).
    http.request({url = path, headers = headers, output = file, tag = "plex", timeout = 20,
                  max_size = to - from + 1}, function(code) cb(code == 206) end)
end

-- Forgets the connection and the transient token of a server (after a
-- failed load: the server may have restarted or the network changed).
function M:forget_session(machine)
    self.bases[machine] = nil
    self.transient[machine] = nil
end

-- A file failed although the server answered: only the streaming token may
-- be stale (server restart); the connection stays for the next file.
function M:forget_token(machine)
    self.transient[machine] = nil
end

-- Describes how the server of `url` is reached: "local" / "remote".
function M:describe(path)
    local item = self.items[path]
    local base = item and self.bases[item.machine]
    local server = item and self:server(item.machine)
    if not base or not server then return nil end
    return string.format("Plex · %s · %s", server.name, base.kind)
end

---------------------------------------------------------------------------
-- Listings
---------------------------------------------------------------------------

local KIND_TITLES = {ondeck = "Continue watching"}

-- loc: {machine, key, kind}. cb(entries or nil, err).
function M:list(loc, cb)
    self:connect(loc.machine, function(base, err)
        if not base then return cb(nil, err) end
        local server = self:server(loc.machine)
        local key = loc.key == "/" and "/library/sections" or loc.key
        http.request({url = base.url .. key, headers = self:headers(server.token), tag = "plex",
                      timeout = 20}, function(code, body)
            if code == 401 then return cb(nil, "Plex sign-in is no longer valid (sign in again)") end
            if code ~= 200 or type(body) ~= "table" or type(body.MediaContainer) ~= "table" then
                -- The connection may have gone away (e.g. left the house): retry next time.
                self.bases[loc.machine] = nil
                return cb(nil, code and ("Plex error " .. code) or body)
            end
            local entries = M.entries_from(body.MediaContainer, base.url, loc.machine, loc.kind)
            if loc.kind == "root" then
                table.insert(entries, 1, {label = KIND_TITLES.ondeck, name = KIND_TITLES.ondeck, is_dir = true,
                    path = "plex://" .. loc.machine .. "/library/onDeck",
                    plex = {machine = loc.machine, key = "/library/onDeck", kind = "ondeck"}})
            end
            for _, e in ipairs(entries) do
                if not e.is_dir then self.items[e.path] = e.plex end
            end
            cb(entries)
        end)
    end)
end

---------------------------------------------------------------------------
-- Playback
---------------------------------------------------------------------------

function M:item_for(path)
    return path and self.items[path] or nil
end

local TRANSIENT_URL = "/security/token?type=delegation&scope=all"
local TRANSIENT_TTL = 12 * 3600

local function transient_from(code, body)
    local token = code == 200 and type(body) == "table" and type(body.MediaContainer) == "table"
        and body.MediaContainer.token
    return (type(token) == "string" and token ~= "") and token or nil
end

-- Fetches the transient token in the background once a server is reached,
-- so the first playback doesn't wait for it in on_load.
function M:prefetch_token(machine)
    local server, base = self:server(machine), self.bases[machine]
    local t = self.transient[machine]
    if not server or not base or self.prefetching[machine] or (t and os.time() - t.time < TRANSIENT_TTL) then return end
    self.prefetching[machine] = true
    http.request({url = base.url .. TRANSIENT_URL, headers = self:headers(server.token), tag = "plex",
                  timeout = 10}, function(code, body)
        self.prefetching[machine] = nil
        local token = transient_from(code, body)
        if token and self:server(machine) then self.transient[machine] = {token = token, time = os.time()} end
    end)
end

-- Transient token for media requests (blocking unless prefetched, cached
-- ~12 h). Never falls back to the account token: mpv logs it (D37).
-- Without a transient token the stream request fails instead.
function M:media_token(item)
    local server = self:server(item.machine)
    local base = self.bases[item.machine]
    if not server then return "" end
    local t = self.transient[item.machine]
    if t and os.time() - t.time < TRANSIENT_TTL then return t.token end
    if base then
        local code, body = http.request_sync({url = base.url .. TRANSIENT_URL,
                                              headers = self:headers(server.token), tag = "plex", timeout = 5})
        local token = transient_from(code, body)
        if token then
            self.transient[item.machine] = {token = token, time = os.time()}
            return token
        end
        msg.warn("plex: the server gave no streaming token")
    end
    return ""
end

-- mpv `http-header-fields` value for this item (transient token).
function M:header_fields(item)
    return string.format("X-Plex-Token: %s,X-Plex-Client-Identifier: %s,X-Plex-Product: %s",
        self:media_token(item), self.account.client_id, M.PRODUCT)
end

-- Fresh metadata just before playback (blocking, short timeout; called from
-- the on_load hook): resume offset (s) and external subtitles.
-- `unreachable` when there is no connection or the server didn't answer
-- (as opposed to an answer without the item).
function M:prepare(item)
    local base = self.bases[item.machine]
    local server = self:server(item.machine)
    if not base or not server then return {subs = {}, unreachable = true} end
    local code, body = http.request_sync({url = base.url .. item.key, headers = self:headers(server.token),
                                          tag = "plex", timeout = 5})
    if code == nil then return {subs = {}, unreachable = true} end
    local md = code == 200 and type(body) == "table" and body.MediaContainer
        and body.MediaContainer.Metadata and body.MediaContainer.Metadata[1]
    if not md then return {subs = {}} end
    local state = M.item_state(md)
    return {ok = true, pos = state.pos, subs = M.external_subtitles(md, base.url)}
end

-- Reports playback state to the server (Plex's "Now playing", resume
-- position on all clients). state: "playing" | "paused" | "stopped".
function M:report(item, state, time_s, duration_s, sync)
    local base = self.bases[item.machine]
    local server = self:server(item.machine)
    if not base or not server or not time_s then return end
    if self.readonly then
        msg.info(string.format("plex (read-only): would report %s at %.0f s", state, time_s))
        return
    end
    local q = http.query_string({
        ratingKey = item.rating_key, key = item.key, state = state,
        time = math.floor(time_s * 1000), duration = math.floor((duration_s or 0) * 1000),
        identifier = LIBRARY,
    })
    local req = {url = base.url .. "/:/timeline?" .. q, headers = self:headers(server.token),
                 tag = "plex", timeout = sync and 3 or 10}
    if sync then http.request_sync(req) else http.request(req, function() end) end
end

-- Marks an item watched/unwatched on the server. cb(ok).
function M:set_watched(item, watched, cb, sync)
    local base = self.bases[item.machine]
    local server = self:server(item.machine)
    if not base or not server then return cb and cb(false) end
    if self.readonly then
        msg.info("plex (read-only): would mark " .. (watched and "watched" or "unwatched"))
        return cb and cb(true)
    end
    local url = base.url .. (watched and "/:/scrobble?" or "/:/unscrobble?")
        .. http.query_string({identifier = LIBRARY, key = item.rating_key})
    local req = {url = url, headers = self:headers(server.token), tag = "plex", timeout = sync and 3 or 10}
    if sync then
        local code = http.request_sync(req)
        if cb then cb(code == 200) end
    else
        http.request(req, function(code) if cb then cb(code == 200) end end)
    end
end

return M
