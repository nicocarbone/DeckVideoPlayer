-- Video menu choices remembered per movie or per season (D73): Picture and
-- the HDR choices (dvp/hdr.lua). Only what the user chose in the menu.
-- Looks (dvp/looks.lua) and Decoding (resume.json) have their own memory.
-- Also an online video's Quality, per list (D89).

local Memory = require "dvp.memory"
local Hdr = require "dvp.hdr"
local config = require "dvp.config"

local M = {}
M.__index = M

M.PICTURE_MODES = {fit = true, fill = true, stretch = true}

-- Pure: a stored Picture choice: a mode, or Crop black bars as the found
-- rectangle and the size of the video it was found in. nil if unusable.
function M.normalize_picture(p)
    if type(p) == "string" then return M.PICTURE_MODES[p] and p or nil end
    if type(p) ~= "table" or type(p.crop) ~= "string" then return nil end
    if not p.crop:match("^%d+x%d+%+%d+%+%d+$") then return nil end
    local w, h = tonumber(p.w), tonumber(p.h)
    if not w or not h then return nil end
    return {crop = p.crop, w = w, h = h}
end

-- Pure: a stored entry with only usable values, or nil if nothing is left.
function M.normalize(entry)
    if type(entry) ~= "table" then return nil end
    local out = {t = tonumber(entry.t) or 0}
    if type(entry.enabled) == "boolean" then out.enabled = entry.enabled end
    for _, m in ipairs(Hdr.MAPPINGS) do
        if entry.mapping == m then out.mapping = m end
    end
    if tonumber(entry.peak) then out.peak = Hdr.clamp_peak(entry.peak) end
    for _, level in ipairs(Hdr.ITM_LEVELS) do
        if entry.itm == level then out.itm = level end
    end
    out.picture = M.normalize_picture(entry.picture)
    for _, q in ipairs(config.STREAM_QUALITIES) do
        if entry.quality == q then out.quality = q end
    end
    for k in pairs(out) do
        if k ~= "t" then return out end
    end
    return nil
end

-- Pure: the rectangle to crop a video of size w x h to, if `picture` is a
-- crop found in a video of that size. A season's other videos usually have
-- the same bars; another size means another master, where it would be wrong.
function M.crop_for(picture, w, h)
    if type(picture) == "table" and picture.w == w and picture.h == h then return picture.crop end
    return nil
end

function M.new(data_dir)
    return setmetatable({memory = Memory.new(data_dir, "video-settings.json", M.normalize)}, M)
end

-- A new file (on_load): its remembered choices, or nil.
function M:start(path, item)
    local _, scope = Memory.keys(path, item)
    self.scope = scope
    return self.memory:get(scope)
end

function M:set(field, value)
    self.memory:set(self.scope, field, value)
end

-- An online video's Quality chosen in the menu (D89), kept for the list
-- it plays from: "auto" or a height, nil when none was chosen.
function M:quality(item)
    local e = self.memory:get(Memory.list_key(item))
    return e and e.quality or nil
end

-- Pure: what to keep for a Quality chosen in the menu: nothing when it is
-- config.ini's stream_quality (the list follows config.ini again).
function M.quality_to_keep(choice, configured)
    if choice == (configured or "auto") then return nil end
    return choice
end

function M:set_quality(item, value)
    self.memory:set(Memory.list_key(item), "quality", value)
end

function M:forget(path)
    self.memory:forget(path)
end

return M
