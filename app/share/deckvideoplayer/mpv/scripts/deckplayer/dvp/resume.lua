-- Per-file playback state: resume position, chosen tracks and "watched" flag.
-- Stored as one small JSON file in the data directory.

local utils = require "mp.utils"
local util = require "dvp.util"

local M = {}
M.__index = M

local MAX_ENTRIES = 1000
M.MIN_POSITION = 30       -- don't offer resume for the first 30 s
M.END_MARGIN_MIN = 60     -- closer than this to the end counts as finished...
M.END_MARGIN_FRAC = 0.05  -- ...or within the last 5%

function M.new(data_dir)
    local self = setmetatable({entries = {}, dirty = false}, M)
    self.file = data_dir and data_dir ~= "" and util.join(data_dir, "resume.json") or nil
    if self.file then
        local text = util.read_file(self.file)
        local data = text and utils.parse_json(text)
        if type(data) == "table" and type(data.entries) == "table" then
            self.entries = data.entries
        end
    end
    return self
end

function M:get(path)
    return self.entries[path]
end

-- Resume position worth offering, or nil.
function M:position(path)
    local e = self.entries[path]
    if e and e.pos and e.pos >= M.MIN_POSITION then return e.pos end
    return nil
end

function M:is_watched(path)
    local e = self.entries[path]
    return e ~= nil and e.watched == true
end

-- Is `pos` close enough to the end to count as finished?
function M.is_finished(pos, duration)
    if not duration or duration <= 0 then return false end
    local margin = math.max(M.END_MARGIN_MIN, duration * M.END_MARGIN_FRAC)
    margin = math.min(margin, duration * 0.25) -- short clips
    return pos >= duration - margin
end

-- `title` (optional): name to show in "Recently played" (Plex videos,
-- whose key is no file name).
function M:update(path, pos, duration, aid, sid, title)
    if not path or not pos then return end
    local e = self.entries[path] or {}
    if M.is_finished(pos, duration) then
        e.pos = nil
        e.watched = true
    elseif pos >= M.MIN_POSITION then
        e.pos = math.floor(pos)
    else
        e.pos = nil
    end
    e.duration = duration and math.floor(duration) or e.duration
    e.aid, e.sid = aid, sid
    if title then e.title = title end
    e.t = os.time()
    e.played = e.t
    self.entries[path] = e
    self.dirty = true
end

-- Progress learnt elsewhere (a Plex server: `state` = {pos, duration,
-- watched}) for an entry that exists, keeping its play timestamps.
function M:sync(path, state)
    local e = self.entries[path]
    if not e or not state then return end
    local pos = state.pos and state.pos >= M.MIN_POSITION and math.floor(state.pos) or nil
    if e.pos == pos and e.watched == (state.watched or nil) then return end
    e.pos, e.watched = pos, state.watched or nil
    e.duration = state.duration and math.floor(state.duration) or e.duration
    self.dirty = true
end

-- Marking doesn't count as playing: a file never played stays out of
-- "Recently played" (played = false; nil means an entry from before v0.3.1,
-- dated by `t`).
function M:mark_watched(path)
    local e = self.entries[path] or {}
    -- Before v0.3.1 `t` was also the play time; keep it as such.
    if e.played == nil then e.played = e.duration and e.t or false end
    e.pos, e.watched, e.t = nil, true, os.time()
    self.entries[path] = e
    self.dirty = true
end

-- Clears the position and watched mark. A played file stays in "Recently
-- played" (its timestamps are kept); anything else is dropped.
function M:mark_unwatched(path)
    local e = self.entries[path]
    if not e then return end
    if e.played == nil then e.played = e.t end   -- entry from before v0.3.1
    if e.played then
        e.pos, e.watched = nil, nil
    else
        self.entries[path] = nil
    end
    self.dirty = true
end

-- Hides `path` from "Recently played", keeping its position and marks.
function M:hide_recent(path)
    local e = self.entries[path]
    if e and e.played ~= false then
        e.played = false
        self.dirty = true
    end
end

-- Decoding chosen in the Video menu (D62): "software", "hardware" or nil
-- (config.ini's hwdec). Only for an existing entry: update() creates it.
function M:set_decoder(path, decoder)
    local e = self.entries[path]
    if not e or e.decoder == decoder then return end
    e.decoder = decoder
    self.dirty = true
end

-- Forgets everything about `path` (the file was deleted).
function M:forget(path)
    if self.entries[path] then
        self.entries[path] = nil
        self.dirty = true
    end
end

-- Up to `n` most recently played paths, newest first. `exists(path)`
-- filters out files that are gone or on a drive that isn't mounted; it is
-- called on the newest entries only, until `n` are found.
function M:recent(n, exists)
    if not n or n <= 0 then return {} end
    local list = {}
    for path, e in pairs(self.entries) do
        local t = e.played
        if t == nil then t = e.t end
        if t then list[#list + 1] = {path = path, t = t} end
    end
    table.sort(list, function(a, b)
        if a.t ~= b.t then return a.t > b.t end
        return a.path < b.path
    end)
    local out = {}
    for _, item in ipairs(list) do
        if not exists or exists(item.path) then
            out[#out + 1] = item.path
            if #out >= n then break end
        end
    end
    return out
end

local function prune(entries)
    local list = {}
    for path, e in pairs(entries) do list[#list + 1] = {path = path, t = e.t or 0} end
    if #list <= MAX_ENTRIES then return end
    table.sort(list, function(a, b) return a.t > b.t end)
    for i = MAX_ENTRIES + 1, #list do entries[list[i].path] = nil end
end

function M:flush()
    if not self.dirty or not self.file then return end
    prune(self.entries)
    local json = utils.format_json({version = 1, entries = self.entries})
    if json then
        util.write_file_atomic(self.file, json)
        self.dirty = false
    end
end

return M
