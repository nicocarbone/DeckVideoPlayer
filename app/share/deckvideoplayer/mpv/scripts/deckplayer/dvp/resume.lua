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

function M:update(path, pos, duration, aid, sid)
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
    e.t = os.time()
    self.entries[path] = e
    self.dirty = true
end

function M:mark_watched(path)
    local e = self.entries[path] or {}
    e.pos, e.watched, e.t = nil, true, os.time()
    self.entries[path] = e
    self.dirty = true
end

function M:forget(path)
    if self.entries[path] then
        self.entries[path] = nil
        self.dirty = true
    end
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
