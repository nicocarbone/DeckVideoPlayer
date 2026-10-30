-- DLNA / UPnP media servers (D66): found on the LAN with SSDP when the
-- user asks, browsed with ContentDirectory Browse (SOAP through
-- dvp/http.lua), played over plain HTTP. There is no sign-in and nothing
-- secret: progress, watched marks and "Recently played" are kept locally
-- in resume.json, like local files (DLNA has no standard progress sync).
--
-- Anyone on the LAN can answer a search, so everything a server sends is
-- untrusted: an answer only counts when its description URL points at the
-- address that sent it; descriptions and listings are size-capped and
-- read by the small XML reader below (no DTDs; only the predefined
-- entities and numeric references are decoded); a video URL must be
-- http(s) on the server's own host.
--
-- Same interface as dvp/plex.lua and dvp/jellyfin.lua (dvp/servers.lua),
-- including download_info for dvp/downloads.lua (v0.7.1): a video's own
-- URL, asked for again when the download starts.

local utils = require "mp.utils"
local msg = require "mp.msg"
local util = require "dvp.util"
local http = require "dvp.http"
local VideoInfo = require "dvp.videoinfo"
local Resume = require "dvp.resume"
local library = require "dvp.library"

local M = {}
M.__index = M

M.ID = "dlna"
M.NAME = "DLNA"
-- Watched marks and positions live in resume.json, not on the server: the
-- browser marks without reaching the server first.
M.LOCAL_STATE = true
M.DISCOVER_HELPER = "dvp-discover"

local DESCRIPTION_MAX = 256 * 1024   -- bytes of a device description
local BROWSE_MAX = 8 * 1024 * 1024   -- bytes of one Browse answer
local PAGE = 200                     -- entries asked for per Browse
local MAX_ENTRIES = 5000             -- entries of one listing, at most
local MAX_SERVERS = 16               -- servers kept from one search
local BROWSE_TIMEOUT = 20            -- s; a NAS busy indexing is slow

---------------------------------------------------------------------------
-- Pure helpers (unit-tested)
---------------------------------------------------------------------------

local function utf8_char(cp)
    if not cp or cp <= 0 or cp > 0x10FFFF or (cp >= 0xD800 and cp <= 0xDFFF) then return nil end
    if cp < 0x80 then return string.char(cp) end
    if cp < 0x800 then return string.char(0xC0 + math.floor(cp / 0x40), 0x80 + cp % 0x40) end
    if cp < 0x10000 then
        return string.char(0xE0 + math.floor(cp / 0x1000), 0x80 + math.floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
    end
    return string.char(0xF0 + math.floor(cp / 0x40000), 0x80 + math.floor(cp / 0x1000) % 0x40,
                       0x80 + math.floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
end

local ENTITIES = {lt = "<", gt = ">", amp = "&", quot = '"', apos = "'"}

-- Pure: XML text with the predefined entities and numeric character
-- references decoded, in one pass ("&amp;lt;" stays "&lt;"); anything
-- else is left as it is.
function M.xml_unescape(s)
    return (tostring(s or ""):gsub("&(#?)([xX]?)(%w+);", function(num, hex, v)
        if num == "#" then
            local cp = hex ~= "" and tonumber(v, 16) or (v:match("^%d+$") and tonumber(v))
            return utf8_char(cp)
        end
        if hex ~= "" then return nil end
        return ENTITIES[v]
    end))
end

function M.xml_escape(s)
    return (tostring(s or ""):gsub("[&<>\"']", {["&"] = "&amp;", ["<"] = "&lt;", [">"] = "&gt;",
                                                ['"'] = "&quot;", ["'"] = "&apos;"}))
end

-- Text content of an element: CDATA as is, otherwise unescaped.
local function text_of(inner)
    local cdata = inner:match("^%s*<!%[CDATA%[(.-)%]%]>%s*$")
    if cdata then return cdata end
    return util.trim(M.xml_unescape(inner))
end

-- Pure: the text of the first element `name` in `xml`, written either
-- without a namespace prefix or with any prefix ("dc:title" is found by
-- "title"), or nil.
function M.element_text(xml, name)
    local inner = xml:match("<" .. name .. "[%s>].-</" .. name .. ">")
        or xml:match("<[%w_%-]+:" .. name .. "[%s>].-</[%w_%-]+:" .. name .. ">")
    if not inner then return nil end
    inner = inner:match("^<[^>]*>(.*)</[^>]*>$")
    return inner and text_of(inner) or nil
end

-- Pure: an attribute of an element's attribute text (`attrs`), unescaped.
function M.attr(attrs, name)
    local v = attrs:match("%s" .. name .. '%s*=%s*"([^"]*)"') or attrs:match("%s" .. name .. "%s*=%s*'([^']*)'")
    return v and M.xml_unescape(v) or nil
end

-- Pure: a server id (the UUID of a UDN or USN), or nil.
function M.safe_id(id)
    id = tostring(id or ""):gsub("^uuid:", ""):match("^([%w%-]+)")
    if id and #id >= 4 and #id <= 64 then return id end
    return nil
end

-- Pure: scheme, host, port and path of an http(s) URL, or nil.
function M.split_url(url)
    local scheme, host, rest = tostring(url or ""):match("^(https?)://([^/:?#%[%]@]+)(.*)$")
    if not scheme then return nil end
    local port, path = rest:match("^:(%d+)(.*)$")
    if not port then path = rest end
    if path ~= "" and not path:match("^[/?]") then return nil end
    return scheme, host:lower(), tonumber(port), path
end

local function private_ipv4(host)
    local a, b = tostring(host):match("^(%d+)%.(%d+)%.%d+%.%d+$")
    a, b = tonumber(a), tonumber(b)
    return a ~= nil and (a == 10 or (a == 192 and b == 168) or (a == 172 and b >= 16 and b <= 31)
        or (a == 169 and b == 254))
end

-- Pure: answers of `dvp-discover --ssdp` (one per line: sender address,
-- LOCATION, USN, SERVER, tab-separated). Kept: answers whose LOCATION is
-- http(s) on the very address that answered, a home-network address;
-- one per LOCATION, at most MAX_SERVERS.
function M.parse_ssdp(text)
    local out, seen = {}, {}
    for line in tostring(text or ""):gmatch("[^\n]+") do
        local from, location, usn, server = line:match("^([^\t]+)\t([^\t]+)\t([^\t]*)\t?(.*)$")
        local _, host = M.split_url(location)
        if host and host == from and private_ipv4(host) and not seen[location] and #out < MAX_SERVERS then
            seen[location] = true
            out[#out + 1] = {location = location, id = M.safe_id(usn), server = server}
        end
    end
    return out
end

-- Pure: absolute URL of `ref` (a description's controlURL), relative to
-- `base` (URLBase or the description's own URL). Only on base's host.
function M.resolve_url(base, ref)
    ref = util.trim(tostring(ref or ""))
    local scheme, host, port, path = M.split_url(base)
    if not scheme or ref == "" then return nil end
    local origin = scheme .. "://" .. host .. (port and (":" .. port) or "")
    if ref:match("^https?://") then
        local _, rhost = M.split_url(ref)
        return rhost == host and ref or nil
    end
    if ref:match("^%a[%w+.-]*:") then return nil end   -- another scheme
    if ref:sub(1, 1) == "/" then return origin .. ref end
    local dir = (path or ""):gsub("[?#].*$", ""):match("^(.*/)") or "/"
    return origin .. dir .. ref
end

-- Pure: a device description (XML) fetched from `location` → {id, name,
-- control} (control = the ContentDirectory control URL), or nil, err.
function M.parse_description(xml, location)
    xml = tostring(xml or "")
    if not xml:find("MediaServer", 1, true) then return nil, "Not a media server" end
    local id = M.safe_id(M.element_text(xml, "UDN"))
    if not id then return nil, "No server id" end
    local control
    for service in xml:gmatch("<service>(.-)</service>") do
        local stype = M.element_text(service, "serviceType") or ""
        if stype:find("ContentDirectory", 1, true) then
            local base = M.element_text(xml, "URLBase")
            control = M.resolve_url((base and base ~= "") and base or location, M.element_text(service, "controlURL"))
            break
        end
    end
    if not control then return nil, "No content directory" end
    -- The control URL must be on the description's host (a fake base can't
    -- send the browse requests elsewhere).
    local _, chost = M.split_url(control)
    local _, lhost = M.split_url(location)
    if chost ~= lhost then return nil, "Content directory on another host" end
    local name = M.element_text(xml, "friendlyName") or "DLNA server"
    return {id = id, name = util.utf8_truncate(name, 60), control = control}
end

-- Pure: the SOAP body of a ContentDirectory Browse request.
function M.browse_body(object_id, flag, start, count)
    return '<?xml version="1.0" encoding="utf-8"?>'
        .. '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" '
        .. 's:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body>'
        .. '<u:Browse xmlns:u="urn:schemas-upnp-org:service:ContentDirectory:1">'
        .. "<ObjectID>" .. M.xml_escape(object_id) .. "</ObjectID>"
        .. "<BrowseFlag>" .. flag .. "</BrowseFlag><Filter>*</Filter>"
        .. "<StartingIndex>" .. tostring(start) .. "</StartingIndex>"
        .. "<RequestedCount>" .. tostring(count) .. "</RequestedCount>"
        .. "<SortCriteria></SortCriteria></u:Browse></s:Body></s:Envelope>"
end

-- Pure: a Browse answer → {didl, returned, total}, or nil, err (a SOAP
-- fault's description).
function M.parse_browse(xml)
    xml = tostring(xml or "")
    if xml:find("Fault>", 1, true) then
        return nil, M.element_text(xml, "errorDescription") or M.element_text(xml, "faultstring") or "Server error"
    end
    local didl = M.element_text(xml, "Result")
    if not didl then return nil, "Not a DLNA answer" end
    return {didl = didl, returned = tonumber(M.element_text(xml, "NumberReturned")) or 0,
            total = tonumber(M.element_text(xml, "TotalMatches"))}
end

-- Pure: "1:23:45.678" → seconds.
function M.parse_duration(s)
    local h, m, sec = tostring(s or ""):match("^(%d+):(%d%d):(%d%d%.?%d*)$")
    if not h then return nil end
    return tonumber(h) * 3600 + tonumber(m) * 60 + tonumber(sec)
end

-- Pure: "2024-05-01" (or with a time) → 20240501000000 (compared only).
local function date_key(s)
    local y, mo, d = tostring(s or ""):match("^(%d%d%d%d)%-(%d%d)%-(%d%d)")
    return y and tonumber(y .. mo .. d .. "000000") or nil
end

-- Pure: the <res> of an item to play, or nil: http(s) on `host`, a video
-- type; the original before a converted copy (DLNA.ORG_CI=1), then the
-- largest.
function M.pick_res(res_list, host)
    local best
    for _, r in ipairs(res_list) do
        local proto = r.protocol or ""
        local mime = proto:match("^[^:]*:[^:]*:([^:]*)") or ""
        local _, rhost = M.split_url(r.url)
        local http_get = proto == "" or proto:match("^http%-get:") ~= nil
        if rhost and rhost == host and http_get and (mime == "" or mime:match("^video/")) then
            r.converted = proto:find("DLNA.ORG_CI=1", 1, true) ~= nil
            if not best or (best.converted and not r.converted)
                or (best.converted == r.converted and (r.size or 0) > (best.size or 0)) then
                best = r
            end
        end
    end
    return best
end

-- Pure: a DIDL-Lite document → containers {id, title, parent, count}
-- and videos {id, title, parent, date, res = {url, protocol, size,
-- duration, resolution}}; `pos` keeps the document order of both.
function M.parse_didl(didl)
    local containers, items = {}, {}
    didl = tostring(didl or "")
    for pos, attrs, inner in didl:gmatch("()<container(%s[^>]*)>(.-)</container>") do
        local id = M.attr(attrs, "id")
        if id and id ~= "" then
            containers[#containers + 1] = {id = id, pos = pos, parent = M.attr(attrs, "parentID"),
                                           count = tonumber(M.attr(attrs, "childCount") or ""),
                                           title = M.element_text(inner, "title") or id}
        end
    end
    for pos, attrs, inner in didl:gmatch("()<item(%s[^>]*)>(.-)</item>") do
        local id = M.attr(attrs, "id")
        local class = M.element_text(inner, "class") or ""
        local res = {}
        for rattrs, url in inner:gmatch("<res([^>]*)>(.-)</res>") do
            if rattrs == "" or rattrs:match("^%s") then
                res[#res + 1] = {url = text_of(url), protocol = M.attr(rattrs, "protocolInfo"),
                                 size = tonumber(M.attr(rattrs, "size") or ""),
                                 duration = M.parse_duration(M.attr(rattrs, "duration")),
                                 resolution = M.attr(rattrs, "resolution")}
            end
        end
        local video = class:match("^object%.item%.videoItem") ~= nil
        if not video then
            for _, r in ipairs(res) do
                if (r.protocol or ""):match("^[^:]*:[^:]*:video/") then video = true end
            end
        end
        if id and id ~= "" and video then
            items[#items + 1] = {id = id, pos = pos, parent = M.attr(attrs, "parentID"),
                                 title = M.element_text(inner, "title") or id,
                                 date = date_key(M.element_text(inner, "date")), res = res}
        end
    end
    return containers, items
end

-- File extensions of video MIME types (for a download whose URL has none).
local MIME_EXT = {["video/mp4"] = "mp4", ["video/x-matroska"] = "mkv", ["video/matroska"] = "mkv",
                  ["video/x-msvideo"] = "avi", ["video/avi"] = "avi", ["video/mpeg"] = "mpg",
                  ["video/mp2t"] = "ts", ["video/vnd.dlna.mpeg-tts"] = "ts", ["video/quicktime"] = "mov",
                  ["video/webm"] = "webm", ["video/x-ms-wmv"] = "wmv", ["video/x-flv"] = "flv",
                  ["video/3gpp"] = "3gp", ["video/x-m4v"] = "m4v"}

-- Pure: the "file" a download is named after (dvp/downloads.lua takes its
-- extension): the URL's file name when it ends in a short extension, else
-- "video.<ext>" from the MIME type of protocolInfo, else nil.
function M.download_file(url, protocol)
    local path = tostring(url or ""):match("^https?://[^/]+(/[^?#]*)") or ""
    local name = path:match("([^/]+)$") or ""
    if name:match("%.%w%w?%w?%w?$") then return name end
    local mime = tostring(protocol or ""):match("^[^:]*:[^:]*:([^:;]*)")
    local ext = mime and MIME_EXT[mime:lower()]
    return ext and ("video." .. ext) or nil
end

local function encode(s)
    return (tostring(s):gsub("[^%w%-%._~]", function(c) return string.format("%%%02X", c:byte()) end))
end

local function decode(s)
    return (s:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end))
end

-- Pure: the key of a DLNA item in "Recently played" (resume.json):
-- "dlna://<server id>/<object id, percent-encoded>". Object ids are the
-- server's and may change when it rebuilds its index.
function M.recent_key(item)
    if not item or not M.safe_id(item.machine) or not item.key or item.key == "" then return nil end
    return "dlna://" .. item.machine .. "/" .. encode(item.key)
end

function M.parse_recent_key(path)
    local id, key = tostring(path or ""):match("^dlna://([%w%-]+)/(.+)$")
    if id and M.safe_id(id) == id then return id, decode(key) end
    return nil
end

function M.recent_ref(id, key)
    return {backend = M.ID, machine = id, key = key, rating_key = key}
end

---------------------------------------------------------------------------
-- Instance: saved servers, listings, playback
---------------------------------------------------------------------------

-- opts: resume (the Resume store, for local progress), clean_names
-- ([interface] clean_names, applied to titles as to file names).
function M.new(data_dir, opts)
    local self = setmetatable({}, M)
    self.resume = opts and opts.resume
    self.clean_names = opts and opts.clean_names
    self.file = (data_dir and data_dir ~= "") and util.join(data_dir, "dlna.json") or nil
    self.data = {}
    local text = self.file and util.read_file(self.file)
    local data = text and utils.parse_json(text)
    if type(data) == "table" then self.data = data end
    if type(self.data.servers) ~= "table" then self.data.servers = {} end
    self.control = {}   -- server id -> ContentDirectory control URL (this session)
    self.items = {}     -- media URL -> item (for the playback hooks)
    return self
end

function M:save()
    if not self.file then return end
    local ok, err = util.write_private(self.file, utils.format_json(self.data))
    if not ok then msg.error("dlna: could not save " .. self.file .. ": " .. tostring(err)) end
end

function M:servers()
    return self.data.servers
end

function M:server(id)
    for _, s in ipairs(self.data.servers) do
        if s.id == id then return s end
    end
    return nil
end

-- "Signed in" for the router: at least one server was added.
function M:signed_in()
    return #self.data.servers > 0
end

function M:sources()
    local out = {}
    for _, s in ipairs(self.data.servers) do
        out[#out + 1] = {name = s.name, path = "dlna://" .. s.id .. "/", kind = M.ID,
                         server = {backend = M.ID, machine = s.id, key = "0", kind = "root"}}
    end
    return out
end

-- cb(info or nil, err): the description at `location`.
function M:describe_device(location, cb)
    http.request({url = location, tag = "dlna", timeout = 8, max_size = DESCRIPTION_MAX}, function(code, body)
        if code ~= 200 or type(body) ~= "string" then
            return cb(nil, code and ("DLNA server error " .. code) or body)
        end
        cb(M.parse_description(body, location))
    end)
end

-- Media servers on the LAN: an SSDP search, then each answer's
-- description. cb(list of {id, name, location, control}).
function M:discover(cb)
    mp.command_native_async({name = "subprocess", args = {M.DISCOVER_HELPER, "--ssdp", "2500"},
                             capture_stdout = true, playback_only = false}, function(_, res)
        if not res or res.status ~= 0 then
            msg.warn("dlna: discovery failed: " .. tostring(res and (res.error_string or res.status)))
        end
        local answers = M.parse_ssdp(res and res.stdout)
        local found, seen, pending = {}, {}, #answers + 1
        local function done()
            pending = pending - 1
            if pending > 0 then return end
            table.sort(found, function(a, b) return a.name:lower() < b.name:lower() end)
            cb(found)
        end
        for _, a in ipairs(answers) do
            self:describe_device(a.location, function(info)
                -- The description must name the device that answered.
                if info and (not a.id or a.id == info.id) and not seen[info.id] then
                    seen[info.id] = true
                    info.location = a.location
                    found[#found + 1] = info
                end
                done()
            end)
        end
        done()
    end)
end

-- Keeps a found server (added from the library menu).
function M:add(info)
    local s = self:server(info.id)
    if not s then
        s = {id = info.id}
        table.insert(self.data.servers, s)
    end
    s.name, s.location = info.name, info.location
    self.control[info.id] = info.control
    self:save()
end

function M:remove(id)
    for i, s in ipairs(self.data.servers) do
        if s.id == id then table.remove(self.data.servers, i) break end
    end
    self.control[id] = nil
    self:save()
end

-- The control URL of server `id`, from its description; if that address
-- no longer answers (a new address from the router), a search finds it
-- again by id. cb(base = {url} or nil, err) (the shape the browser's
-- connect() callers expect).
function M:connect(id, cb)
    local s = self:server(id)
    if not s then return cb(nil, "Unknown DLNA server") end
    if self.control[id] then return cb({url = self.control[id], kind = "local"}) end
    self:describe_device(s.location, function(info, err)
        if info and info.id == id then
            self.control[id] = info.control
            return cb({url = info.control, kind = "local"})
        end
        self:discover(function(found)
            for _, f in ipairs(found) do
                if f.id == id then
                    s.location, s.name = f.location, f.name
                    self:save()
                    self.control[id] = f.control
                    return cb({url = f.control, kind = "local"})
                end
            end
            cb(nil, err or ("Can't reach " .. s.name))
        end)
    end)
end

function M:forget_session(id)
    self.control[id] = nil
end

function M:forget_token()
end

-- One Browse request. cb(page or nil, err, answered): `answered` when the
-- server itself refused (a SOAP fault, e.g. no such object), not a
-- network problem.
function M:browse(id, object_id, flag, start, cb)
    self:connect(id, function(base, err)
        if not base then return cb(nil, err) end
        http.request({url = base.url, method = "POST", tag = "dlna", timeout = BROWSE_TIMEOUT,
                      max_size = BROWSE_MAX, content_type = 'text/xml; charset="utf-8"',
                      headers = {SOAPACTION = '"urn:schemas-upnp-org:service:ContentDirectory:1#Browse"'},
                      raw_body = M.browse_body(object_id, flag, start, PAGE)}, function(code, body)
            if type(body) ~= "string" or (code ~= 200 and code ~= 500) then
                -- No answer: the address may have changed; find it next time.
                if not code then self.control[id] = nil end
                return cb(nil, code and ("DLNA server error " .. code) or body)
            end
            local page, err = M.parse_browse(body)
            cb(page, err, page == nil)
        end)
    end)
end

-- Local progress of an item ({pos, duration, watched}), from resume.json.
function M:state_of(item)
    local e = self.resume and self.resume:get(M.recent_key(item) or "")
    if not e then return nil end
    return {pos = e.pos, duration = e.duration, watched = e.watched}
end

-- Browser entries from one page of a listing, in the server's order.
-- Titles are often file names ("The.Movie.2024.1080p"): cleaned like
-- local names when clean_names is on (never an extension cut: they have
-- none, or a dot in the title would look like one).
function M:entries_from(id, containers, videos)
    local out = {}
    local host = select(2, M.split_url(self.control[id] or ""))
    local function label(title)
        return library.display_name(title, true, self.clean_names)
    end
    for _, c in ipairs(containers) do
        local l = label(c.title)
        out[#out + 1] = {label = l, name = l, is_dir = true, path = "dlna://" .. id .. "/" .. c.id, pos = c.pos,
                         server = {backend = M.ID, machine = id, key = c.id, kind = "container"}}
    end
    for _, v in ipairs(videos) do
        local r = M.pick_res(v.res, host)
        if r then
            local l = label(v.title)
            -- name: the cleaned title (subtitle search, download file name).
            local item = {backend = M.ID, machine = id, key = v.id, rating_key = v.id, kind = "movie",
                          title = l, name = l, url = r.url, size = r.size, parent = v.parent,
                          protocol = r.protocol, duration = r.duration and r.duration * 1000}   -- ms, as Plex
            out[#out + 1] = {label = l, name = l, is_dir = false, path = r.url, size = r.size, pos = v.pos,
                             mtime = v.date, server = item, state = self:state_of(item)}
        end
    end
    table.sort(out, function(a, b) return (a.pos or 0) < (b.pos or 0) end)
    return out
end

-- loc: {machine, key}. cb(entries or nil, err). Pages through the
-- container (at most MAX_ENTRIES entries).
function M:list(loc, cb)
    local all = {}
    local function page(start)
        self:browse(loc.machine, loc.key, "BrowseDirectChildren", start, function(p, err)
            if not p then return cb(nil, err) end
            local containers, videos = M.parse_didl(p.didl)
            for _, e in ipairs(self:entries_from(loc.machine, containers, videos)) do
                all[#all + 1] = e
                if not e.is_dir then self.items[e.path] = e.server end
            end
            local next_start = start + p.returned
            if p.returned > 0 and next_start < (p.total or 0) and next_start < MAX_ENTRIES then
                return page(next_start)
            end
            cb(all)
        end)
    end
    page(0)
end

-- A video's current entry (BrowseMetadata). cb(entry or nil, err, gone):
-- `gone` when the server answered that it isn't there (any more).
function M:metadata(id, object_id, cb)
    self:browse(id, object_id, "BrowseMetadata", 0, function(p, err, answered)
        if not p then return cb(nil, err, answered) end
        local _, videos = M.parse_didl(p.didl)
        local entry = self:entries_from(id, {}, videos)[1]
        if not entry then return cb(nil, "This video is no longer on the server", true) end
        cb(entry)
    end)
end

-- For dvp/downloads.lua: cb({url, size, file, subs} or nil, err, fatal).
-- The URL is the one the server gives now (checked like any other: http(s)
-- on the server's host); no headers, no subtitles (DLNA has no standard
-- for them).
function M:download_info(item, cb)
    self:metadata(item.machine, item.key, function(entry, err, gone)
        if not entry then return cb(nil, err or "Can't reach the DLNA server", gone == true) end
        local it = entry.server
        cb({url = it.url, size = it.size, file = M.download_file(it.url, it.protocol), subs = {}})
    end)
end

-- A video in "Recently played" ready to play, and (`siblings`) the
-- videos after it in its folder. cb(entry, paths or nil, err).
function M:resolve(id, object_id, siblings, cb)
    self:metadata(id, object_id, function(entry, err)
        if not entry then return cb(nil, nil, err) end
        self.items[entry.path] = entry.server
        local parent = entry.server.parent
        if not siblings or not parent or parent == "" then return cb(entry, {entry.path}) end
        self:list({machine = id, key = parent}, function(entries)
            local paths
            for _, e in ipairs(entries or {}) do
                if e.server and e.server.key == object_id then paths = {} end
                if paths and not e.is_dir then paths[#paths + 1] = e.path end
            end
            if not paths or paths[1] ~= entry.path then paths = {entry.path} end
            cb(entry, paths)
        end)
    end)
end

function M:item_for(path)
    return path and self.items[path] or nil
end

-- Before playback (on_load hook): nothing to fetch; the position is the
-- local one.
function M:prepare(item)
    local state = self:state_of(item) or {}
    local pos = state.pos
    if pos and Resume.is_finished(pos, state.duration or 0) then pos = nil end
    return {ok = true, pos = pos, subs = {}}
end

function M:header_fields()
    return ""
end

-- Progress is saved locally by main.lua (resume.json, under recent_key).
function M:report()
end

-- Watched marks are local too. cb(ok).
function M:set_watched(item, watched, cb)
    local key = M.recent_key(item)
    if key and self.resume then
        if watched then self.resume:mark_watched(key) else self.resume:mark_unwatched(key) end
        self.resume:flush()
    end
    if cb then cb(key ~= nil) end
end

function M:describe(path)
    local item = self.items[path]
    local server = item and self:server(item.machine)
    return server and ("DLNA · " .. server.name) or nil
end

-- Bytes [from, to] of a video to `file` (OpenSubtitles hash). cb(ok).
function M:fetch_range(path, from, to, file, cb)
    if not self.items[path] then return cb(false) end
    http.request({url = path, headers = {Range = string.format("bytes=%d-%d", from, to)}, output = file,
                  tag = "dlna", timeout = 20, max_size = to - from + 1}, function(code) cb(code == 206) end)
end

-- The Video info panel: ffprobe on the video's URL.
function M:video_info(ref, cb)
    local server = self:server(ref.machine)
    local source = VideoInfo.server_source(M.NAME, server and server.name, "local")
    local function probe(item)
        VideoInfo.probe_url(item.url, function(d, err)
            if d then
                d.file.name = item.title
                d.file.folder = nil
                d.file.source = source
            end
            cb(d, err)
        end)
    end
    if ref.url then return probe(ref) end
    self:metadata(ref.machine, ref.key, function(entry, err)
        if not entry then return cb(nil, err) end
        probe(entry.server)
    end)
end

return M
