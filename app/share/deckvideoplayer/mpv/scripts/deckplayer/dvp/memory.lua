-- Choices remembered per movie or per season (D72, D73): the storage and
-- the keys shared by dvp/submemory.lua and dvp/videomemory.lua. A store
-- without a data folder keeps its choices until the app closes
-- ([playback] remember_settings = no, tests).

local utils = require "mp.utils"
local msg = require "mp.msg"
local util = require "dvp.util"
local OpenSubtitles = require "dvp.opensubtitles"

local M = {}
M.__index = M

local MAX_ENTRIES = 1000

-- Pure: where a video's settings are kept: its own key, and the key shared
-- by its season (the same one for a movie). `item`: its media server item
-- (dvp/servers.lua), or nil for a local file. nil, nil: not remembered.
function M.keys(path, item)
    if item then
        local base = tostring(item.backend or "server") .. ":" .. tostring(item.machine) .. ":"
        local id = item.rating_key or item.key
        local video = id and (base .. "item:" .. tostring(id)) or nil
        if item.kind == "episode" and item.show and item.show ~= "" then
            return video, base .. "show:" .. item.show .. ":season:" .. tostring(item.season or "")
        end
        -- DLNA has no notion of episodes: only the title tells.
        if item.parent and item.parent ~= "" then
            local season = OpenSubtitles.parse_name(tostring(item.name or item.title or "")).season
            if season then return video, base .. "folder:" .. tostring(item.parent) .. ":season:" .. season end
        end
        return video, video
    end
    if type(path) ~= "string" or path:sub(1, 1) ~= "/" then return nil, nil end
    local video = "file:" .. path
    local dir = util.dirname(path)
    local season = OpenSubtitles.parse_name(util.strip_extension(util.basename(path))).season
    if season then return video, "dir:" .. dir .. ":season:" .. season end
    if OpenSubtitles.is_season_dir(util.basename(dir)) then return video, "dir:" .. dir end
    return video, video
end

local function prune(entries)
    local list = {}
    for key, e in pairs(entries) do list[#list + 1] = {key = key, t = e.t or 0} end
    if #list <= MAX_ENTRIES then return end
    table.sort(list, function(a, b)
        if a.t ~= b.t then return a.t > b.t end
        return a.key < b.key
    end)
    for i = MAX_ENTRIES + 1, #list do entries[list[i].key] = nil end
end

-- `name`: the file in `data_dir`. `normalize(entry)`: the entry with only
-- usable values, or nil when nothing is left (the file may be damaged).
function M.new(data_dir, name, normalize)
    local self = setmetatable({entries = {}, normalize = normalize, name = name}, M)
    self.file = (data_dir and data_dir ~= "") and util.join(data_dir, name) or nil
    local text = self.file and util.read_file(self.file)
    local data = text and utils.parse_json(text)
    if type(data) == "table" and type(data.entries) == "table" then
        for key, e in pairs(data.entries) do
            if type(key) == "string" then self.entries[key] = normalize(e) end
        end
    end
    return self
end

function M:get(key)
    return key and self.entries[key] or nil
end

function M:save()
    if not self.file then return end
    prune(self.entries)
    local ok, err = util.write_file_atomic(self.file, utils.format_json({version = 1, entries = self.entries}))
    if not ok then msg.warn(self.name .. ": could not save: " .. tostring(err)) end
end

-- Stores a value (nil removes it), dropping an entry left empty.
function M:set(key, field, value)
    if not key then return end
    local e = self.entries[key] or {}
    e[field], e.t = value, os.time()
    self.entries[key] = self.normalize(e)
    self:save()
end

-- A deleted file: its own entry goes, its season's stays.
function M:forget(path)
    local key = M.keys(path)
    if key and self.entries[key] then
        self.entries[key] = nil
        self:save()
    end
end

return M
