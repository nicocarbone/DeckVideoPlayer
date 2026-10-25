-- Online subtitles: "Download subtitles…" in the subtitle menu searches
-- OpenSubtitles for the playing file, downloads the chosen result into the
-- app's data folder and selects it.
--
-- Downloads are kept per video in <data_dir>/subtitles/<key>/ as
-- "<release>.<lang>.srt". <key> is the OpenSubtitles hash of the video, so
-- renaming or moving the file keeps its subtitles (video folders are
-- read-only in the Flatpak anyway). They are added again, before track
-- selection, every time that video plays. See docs/DECISIONS.md D28.

local utils = require "mp.utils"
local util = require "dvp.util"
local media = require "dvp.media"
local OpenSubtitles = require "dvp.opensubtitles"

local M = {}
M.__index = M

local MAX_RESULTS = 40

-- Pure: file name for a downloaded subtitle: "<release> #<file_id>.<lang>.srt".
-- The OpenSubtitles file id keeps different uploads with the same release
-- name apart (and lets a re-pick of the same upload skip the download).
function M.file_name(release, lang, file_id)
    local base = release:gsub("%.[Ss][Rr][Tt]$", ""):gsub("[%c/\\:*?\"<>|#]", " "):gsub("%s+", " ")
    base = util.trim(base)
    if base == "" then base = "Subtitles" end
    local id = file_id and (" #" .. tostring(file_id):gsub("%D", "")) or ""
    return util.utf8_truncate(base, 100) .. id .. "." .. lang .. ".srt"
end

-- Pure: a language code from the API, usable in a file name ("pt-br"), or
-- "und". Letters and "-" only: anything else could build another path.
function M.safe_lang(lang)
    if type(lang) == "string" and #lang <= 12 and lang:match("^%a[%a%-]*$") then return lang end
    return "und"
end

-- Pure: {title, lang, file_id} from a stored file name (files from before
-- the id was added have no file_id).
function M.parse_file_name(name)
    local title, lang = name:match("^(.*)%.(%a[%a%-]*)%.srt$")
    if not title then return {title = util.strip_extension(name)} end
    local bare, id = title:match("^(.-) #(%d+)$")
    if bare then return {title = bare, lang = lang, file_id = id} end
    return {title = title, lang = lang}
end

-- Storage key of a video: its OpenSubtitles hash (size-based for files too
-- small to hash, which only happens with test clips).
function M.video_key(path)
    local hash, size = OpenSubtitles.moviehash(path)
    if hash then return hash end
    if size then return string.format("small-%d", size) end
    return nil
end

local function is_local(path)
    return path ~= nil and path:sub(1, 1) == "/"
end

-- Pure: storage key of a Plex video (server + item id, no network).
function M.plex_key(item)
    return ("plex-" .. tostring(item.machine) .. "-" .. tostring(item.rating_key)):gsub("[^%w%-]", "_")
end

-- Pure: what to search for a Plex video, from Plex's own metadata (more
-- reliable than parsing a file name).
function M.plex_info(item)
    if item.kind == "episode" then
        return {title = item.show or item.name or "", season = item.season, episode = item.episode}
    end
    return {title = item.name or "", year = item.year}
end

-- ctx: cfg, menu, toast. api_url: optional override (mock server in tests).
function M.new(ctx, data_dir, api_url)
    local self = setmetatable({}, M)
    self.ctx = ctx
    local c = ctx.cfg.opensubtitles
    self.client = OpenSubtitles.new({
        api_key = c.api_key,
        username = c.username, password = c.password, api_url = api_url,
    })
    self.languages = OpenSubtitles.languages(ctx.cfg.playback.subtitle_languages)
    self.dir = (data_dir and data_dir ~= "") and util.join(data_dir, "subtitles") or nil
    self.keys = {}  -- path -> key (hashing reads 128 KiB, do it once)
    self.hashes = {} -- Plex path -> OpenSubtitles hash (fetched over HTTP)
    return self
end

function M:plex_item(path)
    return self.ctx.plex and self.ctx.plex:item_for(path)
end

function M:available(path)
    return self.client:enabled() and self.dir ~= nil and (is_local(path) or self:plex_item(path) ~= nil)
end

-- Storage key: the file hash for local files, the item id for Plex videos.
function M:key(path)
    if self.keys[path] == nil then
        local item = self:plex_item(path)
        self.keys[path] = (item and M.plex_key(item)) or (is_local(path) and M.video_key(path)) or false
    end
    return self.keys[path] or nil
end

-- OpenSubtitles hash for the exact-match search. cb(hash or nil). Local
-- files: the storage key. Plex: first and last 64 KiB fetched from the
-- server (two range requests), only when the user searches.
function M:hash_for(path, cb)
    local item = self:plex_item(path)
    if not item then
        local key = self:key(path)
        return cb((key and #key == 16) and key or nil)
    end
    if self.hashes[path] then return cb(self.hashes[path]) end
    local size = tonumber(item.size)
    if not size or size < 2 * 65536 then return cb(nil) end
    local head = os.tmpname()
    local tail = os.tmpname()
    local pending, ok_all = 2, true
    local function done(ok)
        ok_all = ok_all and ok
        pending = pending - 1
        if pending > 0 then return end
        local h = ok_all and util.read_file(head)
        local t = ok_all and util.read_file(tail)
        os.remove(head)
        os.remove(tail)
        local hash = (h and t and #h == 65536 and #t == 65536) and OpenSubtitles.moviehash_from(size, h, t) or nil
        -- Not cached on failure: a later search retries.
        self.hashes[path] = hash
        cb(hash)
    end
    self.ctx.plex:fetch_range(path, 0, 65535, head, done)
    self.ctx.plex:fetch_range(path, size - 65536, size - 1, tail, done)
end

-- Downloaded subtitles of a video: list of {path, title, lang}.
function M:stored(path)
    if not self.dir or not (is_local(path) or self:plex_item(path)) then return {} end
    -- Nothing downloaded yet (the usual case): no hashing at all. Plex
    -- items and known keys cost no hashing, so they skip this check.
    if self.keys[path] == nil and not self:plex_item(path) then
        local top = utils.readdir(self.dir, "dirs")
        if not top or #top == 0 then return {} end
    end
    local key = self:key(path)
    if not key then return {} end
    local dir = util.join(self.dir, key)
    local names = utils.readdir(dir, "files") or {}
    table.sort(names)
    local out = {}
    for _, name in ipairs(names) do
        if name:match("%.srt$") then
            local f = M.parse_file_name(name)
            f.path = util.join(dir, name)
            out[#out + 1] = f
        end
    end
    return out
end

-- Called from the on_preloaded hook (tracks known, none selected yet), so
-- the language rules and a resumed subtitle choice include these files.
function M:load_stored(path)
    for _, f in ipairs(self:stored(path)) do
        mp.commandv("sub-add", f.path, "auto", f.title, f.lang or "")
    end
end

---------------------------------------------------------------------------
-- Search and download
---------------------------------------------------------------------------

-- Runs the hash search and the name search in parallel and merges them.
-- cb(results or nil, err).
function M:search(path, info, cb)
    self:hash_for(path, function(hash) self:search_with(hash, info, cb) end)
end

function M:search_with(hash, info, cb)
    local langs = table.concat(self.languages, ",")
    local requests = {}
    if hash then
        requests[#requests + 1] = {languages = langs, moviehash = hash}
    end
    if info.title ~= "" then
        local p = {languages = langs, query = info.title}
        if info.season then
            p.season_number, p.episode_number, p.type = info.season, info.episode, "episode"
        elseif info.year then
            p.year = info.year
        end
        requests[#requests + 1] = p
    end
    if #requests == 0 then
        cb({})
        return
    end
    local lists, first_err, pending = {}, nil, #requests
    for i, params in ipairs(requests) do
        self.client:search(params, function(results, err)
            lists[i] = results or {}
            first_err = first_err or err
            pending = pending - 1
            if pending > 0 then return end
            local merged = OpenSubtitles.rank(lists, self.languages)
            if #merged == 0 and first_err then cb(nil, first_err) else cb(merged) end
        end)
    end
end

local function describe(info, path)
    local what = info.title ~= "" and info.title or util.basename(path)
    if info.season then
        what = string.format("%s S%02dE%02d", what, info.season, info.episode)
    elseif info.year then
        what = what .. " (" .. info.year .. ")"
    end
    return util.utf8_truncate(what, 42)
end

-- Opens the results menu for the playing file.
function M:open(path)
    local menu = self.ctx.menu
    local item = self:plex_item(path)
    local info = item and M.plex_info(item) or OpenSubtitles.parse_release(path)
    local spec = {
        title = "Download subtitles", style = "side", close_action = "x",
        subtitle = describe(info, path),
        items = {{label = "Searching…", disabled = true}},
    }
    menu:open(spec)
    self:search(path, info, function(results, err)
        local items = {}
        if not results then
            items[1] = {label = "Search failed", disabled = true}
        elseif #results == 0 then
            items[1] = {label = "No subtitles found", disabled = true}
        else
            for i = 1, math.min(#results, MAX_RESULTS) do
                local r = results[i]
                items[#items + 1] = {
                    label = (media.language(r.language) or "?") .. " · " .. r.release,
                    value = OpenSubtitles.result_value(r),
                    action = function() self:download(path, r) end,
                }
            end
        end
        -- Only tell about a failure if the menu is still open.
        if menu:update(spec, {items = items}) and not results then self.ctx.toast(err) end
    end)
end

-- Selects `file` if it is already a track, otherwise adds and selects it.
local function select_file(file, title, lang)
    for _, t in ipairs(media.tracks("sub")) do
        if t["external-filename"] == file then
            mp.set_property_number("sid", t.id)
            mp.set_property_bool("sub-visibility", true)
            return
        end
    end
    mp.commandv("sub-add", file, "select", title, lang)
    mp.set_property_bool("sub-visibility", true)
end

function M:download(path, r)
    local toast = self.ctx.toast
    local key = self:key(path)
    if not key then
        toast("Can't read this video file")
        return
    end
    local dir = util.join(self.dir, key)
    util.mkdir_p(dir)
    local lang = M.safe_lang(r.language)
    local dest = util.join(dir, M.file_name(r.release, lang, r.file_id))
    local title = M.parse_file_name(util.basename(dest)).title
    local label = "Subtitles: " .. (media.language(lang) or lang)
    -- Same release downloaded before: don't spend quota again.
    if util.file_exists(dest) then
        select_file(dest, title, lang)
        toast(label)
        return
    end
    toast("Downloading subtitles…")
    self.client:download(r.file_id, dest, function(ok, res)
        if not ok then
            toast(res)
            return
        end
        -- The user may have moved on to another video meanwhile; the file
        -- is kept and loads next time this one plays.
        if mp.get_property("path") == path then
            select_file(dest, title, lang)
            self.ctx.menu:refresh()   -- a menu showing the subtitle track
        end
        if res.remaining then
            label = label .. string.format("  ·  %d downloads left today", res.remaining)
        end
        toast(label)
    end)
end

return M
