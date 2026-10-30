-- OpenSubtitles.com REST API client and the pure helpers it needs.
--
-- API (https://opensubtitles.stoplight.io/docs/opensubtitles-api):
--   GET  /subtitles?languages=en&moviehash=…&query=…  search (no quota)
--   POST /login {username, password} -> {token, base_url}  optional
--   POST /download {file_id} -> {link, remaining, reset_time}  counts
--        against the daily quota (a few per IP without an account, more
--        with a free account)
-- Every request carries the app's Api-Key and a User-Agent naming the app.
--
-- HTTP goes through curl (part of the Flatpak runtime and of SteamOS), run
-- asynchronously so the UI never blocks. Secrets and request bodies are
-- passed on curl's stdin (`-K -`), never on its command line.

local utils = require "mp.utils"
local msg = require "mp.msg"
local util = require "dvp.util"
local http = require "dvp.http"
local version = require "dvp.version"

local M = {}
M.__index = M

M.API_URL = "https://api.opensubtitles.com/api/v1"
M.USER_AGENT = "DeckVideoPlayer v" .. version
-- There is deliberately no built-in API key: the source is public, so each
-- user creates their own free key and puts it in config.ini (D29).

---------------------------------------------------------------------------
-- Pure helpers (unit-tested in tests/run.lua)
---------------------------------------------------------------------------

local CHUNK = 65536
local TWO32 = 4294967296

-- Adds the little-endian 64-bit words of `data` to acc = {lo, hi}, using
-- two 32-bit halves so plain Lua 5.1 doubles stay exact.
local function add_words(data, acc)
    local rem = #data % 8
    if rem > 0 then data = data .. string.rep("\0", 8 - rem) end
    for i = 1, #data, 8 do
        local b1, b2, b3, b4, b5, b6, b7, b8 = data:byte(i, i + 7)
        acc[1] = acc[1] + b1 + b2 * 256 + b3 * 65536 + b4 * 16777216
        acc[2] = acc[2] + b5 + b6 * 256 + b7 * 65536 + b8 * 16777216
    end
end

-- OpenSubtitles "moviehash": file size + sum of the 64-bit words of the
-- first and last 64 KiB, modulo 2^64, as 16 hex digits.
function M.moviehash_from(size, head, tail)
    local acc = {size % TWO32, math.floor(size / TWO32)}
    add_words(head, acc)
    add_words(tail, acc)
    local lo = acc[1] % TWO32
    local hi = (acc[2] + math.floor(acc[1] / TWO32)) % TWO32
    return string.format("%08x%08x", hi, lo)
end

-- Returns hash, size; hash is nil for files under 128 KiB (the hash is
-- undefined for them) or unreadable files.
function M.moviehash(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local size = f:seek("end")
    if not size or size < 2 * CHUNK then
        f:close()
        return nil, size
    end
    f:seek("set", 0)
    local head = f:read(CHUNK)
    f:seek("set", size - CHUNK)
    local tail = f:read(CHUNK)
    f:close()
    if not head or not tail then return nil, size end
    return M.moviehash_from(size, head, tail), size
end

-- Release-name words that end the title ("Movie.Name.1080p.BluRay…").
local JUNK = {"480p", "576p", "720p", "1080p", "1080i", "2160p", "4k", "uhd", "bluray", "blu ray",
              "bdrip", "brrip", "web-dl", "web dl", "webdl", "webrip", "hdtv", "dvdrip", "remux",
              "x264", "x265", "h264", "h265", "hevc", "av1", "hdr10", "proper", "repack",
              "unrated", "remastered"}

local function clean_title(s)
    s = s:gsub("%b[]", " "):gsub("[%._]+", " "):gsub("%s+", " ")
    s = util.trim(s)
    local lower, cut = s:lower(), nil
    for _, word in ipairs(JUNK) do
        local pos = lower:find("%f[%w]" .. word:gsub("%p", "%%%0") .. "%f[%W]")
        if pos and pos > 1 and (not cut or pos < cut) then cut = pos end
    end
    if cut then s = s:sub(1, cut - 1) end
    s = util.trim(s):gsub("[%s%-%(%[]+$", "")
    return s
end

-- Splits "Title (2019)" / "Title.2019.1080p" at a plausible year that
-- isn't the first word ("2001 A Space Odyssey 1968" keeps "2001").
local function split_year(s)
    for pos, y in s:gmatch("()[%s%._%(%[]([12]%d%d%d)%f[%D]") do
        local year = tonumber(y)
        if pos > 1 and year >= 1900 and year <= 2099 then
            return s:sub(1, pos - 1), year
        end
    end
    return s, nil
end

local SEASON_DIR = {"^season%s*%d+$", "^s%d+$", "^series%s*%d+$", "^specials$", "^staffel%s*%d+$", "^temporada%s*%d+$"}

local function is_season_dir(name)
    local l = util.trim(name:lower():gsub("[%._]+", " "))
    for _, p in ipairs(SEASON_DIR) do
        if l:match(p) then return true end
    end
    return false
end

-- Guesses what to search for from a name without extension (a file's,
-- or a DLNA server's title): {title, year, season, episode}. Episode
-- titles come from the part before "S01E02"/"1x02" (title "" when there
-- is none).
function M.parse_name(name)
    local info = {}
    local before, s, e = name:match("^(.-)[Ss](%d%d?)[%s%._%-]*[Ee](%d%d?%d?)")
    if not before then
        before, s, e = name:match("^(.-)%f[%d](%d%d?)[xX](%d%d)%f[%D]")
    end
    local title
    if before then
        info.season, info.episode = tonumber(s), tonumber(e)
        title = before
    else
        title = name
    end
    local year
    title, year = split_year(title)
    info.year = year
    info.title = clean_title(title)
    return info
end

-- The same from a file path; an empty title falls back to the show folder.
function M.parse_release(path)
    local info = M.parse_name(util.strip_extension(util.basename(path)))
    local title = info.title
    if title == "" then
        -- "Show/Season 1/S01E02.mkv": use the show folder.
        local dir = util.dirname(path)
        if is_season_dir(util.basename(dir)) then dir = util.dirname(dir) end
        local folder, folder_year = split_year(util.basename(dir))
        title = clean_title(folder)
        info.year = info.year or (not info.season and folder_year) or nil
    end
    info.title = title
    return info
end

-- ISO 639-2 (mpv's slang, Matroska tags) -> OpenSubtitles language codes.
local TO_OS = {
    eng = "en", spa = "es", fre = "fr", fra = "fr", ger = "de", deu = "de", ita = "it",
    por = "pt-pt", pt = "pt-pt", pob = "pt-br", jpn = "ja", kor = "ko",
    chi = "zh-cn", zho = "zh-cn", zh = "zh-cn", rus = "ru", dut = "nl", nld = "nl",
    swe = "sv", nor = "no", nob = "no", nb = "no", dan = "da", fin = "fi", pol = "pl",
    cze = "cs", ces = "cs", hun = "hu", gre = "el", ell = "el", tur = "tr", ara = "ar",
    heb = "he", hin = "hi", tha = "th", vie = "vi", ind = "id", ukr = "uk", rum = "ro",
    ron = "ro", cat = "ca", baq = "eu", eus = "eu", glg = "gl", hrv = "hr", srp = "sr",
    bul = "bg", slv = "sl", slo = "sk", slk = "sk", est = "et", lav = "lv", lit = "lt",
    per = "fa", fas = "fa", may = "ms", msa = "ms",
}

-- "spa,eng" -> {"es", "en"} (order = preference). Defaults to English.
function M.languages(slang)
    local out, seen = {}, {}
    for _, code in ipairs(util.split(slang or "", ",")) do
        code = code:lower()
        local os_code = TO_OS[code]
        if not os_code and (code:match("^%a%a$") or code:match("^%a%a%-%a%a$")) then os_code = code end
        if os_code and not seen[os_code] then
            seen[os_code] = true
            out[#out + 1] = os_code
        end
    end
    if #out == 0 then out[1] = "en" end
    return out
end

-- The API redirects requests whose parameters aren't sorted and lowercase,
-- so build them that way.
function M.query_string(params)
    return http.query_string(params, true)
end

M.curl_quote = http.curl_quote

-- Pure: `base_url` from the login response is acceptable as API host.
function M.valid_base_url(host)
    return type(host) == "string" and (host == "opensubtitles.com"
        or host:match("^[%w%-]+%.opensubtitles%.com$") ~= nil)
end

-- Pure: a download link is fetched only over https, or from the API's own
-- origin (only differs when tests point `api_url` at a local mock).
function M.valid_link(link, api_url)
    if type(link) ~= "string" then return false end
    if link:match("^https://[^/]") then return true end
    local origin = tostring(api_url or ""):match("^https?://[^/]+")
    return origin ~= nil and link:sub(1, #origin + 1) == origin .. "/"
end

-- Flattens a /subtitles response into result records.
function M.parse_results(response)
    local out = {}
    for _, item in ipairs(type(response) == "table" and response.data or {}) do
        local a = item.attributes or {}
        local file = a.files and a.files[1]
        if file and file.file_id then
            out[#out + 1] = {
                file_id = file.file_id,
                language = (a.language or ""):lower(),   -- "pt-BR" -> "pt-br" as in languages()
                release = (a.release and a.release ~= "") and a.release or file.file_name or "",
                downloads = tonumber(a.download_count) or 0,
                hash_match = a.moviehash_match == true,
                hearing_impaired = a.hearing_impaired == true,
                machine = a.machine_translated == true or a.ai_translated == true,
            }
        end
    end
    return out
end

-- Merges result lists (dropping duplicates) and orders them: preferred
-- language first, then exact file matches, then human translations, then
-- popularity.
function M.rank(lists, languages)
    local pref = {}
    for i, l in ipairs(languages or {}) do pref[l] = i end
    local out, seen = {}, {}
    for _, list in ipairs(lists) do
        for _, r in ipairs(list) do
            if not seen[r.file_id] then
                seen[r.file_id] = true
                out[#out + 1] = r
            end
        end
    end
    table.sort(out, function(a, b)
        local pa, pb = pref[a.language] or 99, pref[b.language] or 99
        if pa ~= pb then return pa < pb end
        if a.hash_match ~= b.hash_match then return a.hash_match end
        if a.machine ~= b.machine then return b.machine end
        if a.downloads ~= b.downloads then return a.downloads > b.downloads end
        return tostring(a.file_id) < tostring(b.file_id)
    end)
    return out
end

local function compact_count(n)
    if n >= 1000000 then return (string.format("%.1fM", n / 1000000):gsub("%.0M", "M")) end
    if n >= 1000 then return (string.format("%.1fk", n / 1000):gsub("%.0k", "k")) end
    return tostring(n)
end

-- Short right-hand text for a result row.
function M.result_value(r)
    local parts = {}
    if r.hash_match then parts[#parts + 1] = "Exact" end
    if r.hearing_impaired then parts[#parts + 1] = "SDH" end
    if r.machine then parts[#parts + 1] = "Auto" end
    if #parts == 0 then parts[1] = compact_count(r.downloads) .. " ↓" end
    return table.concat(parts, " · ")
end

-- User-facing text for a failed request.
function M.error_message(code, body, during)
    if code == nil then return body or "No internet connection" end
    local info = type(body) == "table" and body or {}
    if code == 401 or code == 403 then
        if during == "login" then return "OpenSubtitles login failed: check username and password" end
        return "OpenSubtitles rejected the API key"
    elseif code == 406 then
        local reset = info.reset_time and (" (resets in " .. info.reset_time .. ")") or ""
        return "Daily download limit reached" .. reset
    elseif code == 429 then
        return "OpenSubtitles is busy, try again in a moment"
    elseif code >= 500 then
        return "OpenSubtitles is unavailable right now"
    end
    return "OpenSubtitles error " .. code
end

---------------------------------------------------------------------------
-- Client
---------------------------------------------------------------------------

-- opts: api_key, username, password, api_url (tests point it at a mock).
function M.new(opts)
    local self = setmetatable({}, M)
    self.api_key = opts.api_key or ""
    self.username = opts.username or ""
    self.password = opts.password or ""
    self.api_url = (opts.api_url and opts.api_url ~= "") and opts.api_url or M.API_URL
    self.token = nil
    return self
end

function M:enabled()
    return self.api_key ~= ""
end

-- Runs one request (dvp/http.lua). req: url, body (table), auth (bool),
-- output (file path). cb(code, body) as in http.request.
function M:http(req, cb)
    local headers = {["User-Agent"] = M.USER_AGENT}
    -- API calls only: the subtitle file itself comes from a download link
    -- (possibly another host), which must not receive the key.
    if not req.output then
        headers["Api-Key"] = self.api_key
        headers["Accept"] = "application/json"
    end
    if req.auth and self.token then headers["Authorization"] = "Bearer " .. self.token end
    http.request({url = req.url, headers = headers, body = req.body, output = req.output,
                  follow = req.follow, max_size = req.max_size, tag = "opensubtitles"}, cb)
end

-- Searches with one parameter set. cb(results or nil, err).
function M:search(params, cb)
    self:http({url = self.api_url .. "/subtitles?" .. M.query_string(params)}, function(code, body)
        if code ~= 200 then
            cb(nil, M.error_message(code, body, "search"))
            return
        end
        cb(M.parse_results(body))
    end)
end

-- Logs in once per session when credentials are configured. cb(err or nil).
function M:ensure_login(cb)
    if self.token or self.username == "" or self.password == "" then
        cb(nil)
        return
    end
    self:http({url = self.api_url .. "/login", body = {username = self.username, password = self.password}},
        function(code, body)
            if code ~= 200 or type(body) ~= "table" or not body.token then
                cb(M.error_message(code, body, "login"))
                return
            end
            self.token = body.token
            -- Accounts may be served by another host (e.g. VIP), but only
            -- an OpenSubtitles one gets the key and the token (D39).
            if M.valid_base_url(body.base_url) and self.api_url == M.API_URL then
                self.api_url = "https://" .. body.base_url .. "/api/v1"
            end
            cb(nil)
        end)
end

-- Downloads a subtitle file to `dest` (written atomically).
-- cb(ok, err_or_info): info = {remaining = n, reset_time = "…"}.
function M:download(file_id, dest, cb)
    self:ensure_login(function(err)
        if err then
            cb(false, err)
            return
        end
        self:http({url = self.api_url .. "/download", body = {file_id = file_id, sub_format = "srt"}, auth = true},
            function(code, body)
                if code ~= 200 or type(body) ~= "table" or not M.valid_link(body.link, self.api_url) then
                    cb(false, M.error_message(code, body, "download"))
                    return
                end
                local info = {remaining = tonumber(body.remaining), reset_time = body.reset_time}
                local tmp = dest .. ".part"
                -- The link may redirect to a CDN: follow (no secrets go
                -- with it); cap the size (a subtitle is never 10 MB).
                self:http({url = body.link, output = tmp, follow = true, max_size = 10 * 1024 * 1024},
                          function(fcode, fbody)
                    if fcode ~= 200 then
                        os.remove(tmp)
                        cb(false, fcode and ("Download failed (" .. fcode .. ")") or fbody)
                        return
                    end
                    local ok, rename_err = os.rename(tmp, dest)
                    if not ok then
                        cb(false, "Could not save subtitles: " .. tostring(rename_err))
                        return
                    end
                    cb(true, info)
                end)
            end)
    end)
end

return M
