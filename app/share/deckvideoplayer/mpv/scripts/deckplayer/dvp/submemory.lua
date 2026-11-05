-- Subtitle settings remembered between plays (D72): what the user chose in
-- the menus, never what mpv selected by itself.
--   track, size, position, brightness: per movie, or per season for
--     episodes (the next episode starts with the same choice)
--   delay: per video (it depends on the video and the subtitle file)
-- A choice made while no remembered value applies also carries on to the
-- following videos of the session, for size, position and brightness.

local util = require "dvp.util"
local media = require "dvp.media"
local Memory = require "dvp.memory"

local M = {}
M.__index = M

-- The adjustable settings. `prop`: the mpv property (brightness sets two,
-- see set_brightness). `per_video`: kept per video, not per season.
M.FIELDS = {
    scale = {prop = "sub-scale", min = 0.5, max = 2.5, digits = 2},
    pos = {prop = "sub-pos", min = 50, max = 150, digits = 0},
    brightness = {min = 0.3, max = 1, digits = 1},
    delay = {prop = "sub-delay", min = -3600, max = 3600, digits = 3, per_video = true},
}

-- Pure: `value` as stored and applied: a number in range, without floating
-- point residue from repeated steps. nil when it isn't a usable number.
function M.clean(field, value)
    local f = M.FIELDS[field]
    value = tonumber(value)
    if not f or not value or value ~= value then return nil end
    local scale = 10 ^ f.digits
    return math.floor(util.clamp(value, f.min, f.max) * scale + 0.5) / scale
end

-- Pure: what identifies a subtitle track in this video and its season's
-- other videos, where track ids differ. nil track: subtitles off.
function M.track_spec(t)
    if not t then return {off = true} end
    return {lang = t.lang, title = t.title, codec = t.codec, id = t.id,
            forced = t.forced or nil, hi = t["hearing-impaired"] or nil, external = t.external or nil}
end

-- Pure: how two language tags compare. 2: the same language ("es", "spa"),
-- or neither says. 1: variants of one ("es-419", "spa"). 0: different.
local function language_match(a, b)
    local la, lb = media.language(a), media.language(b)
    if la == lb then return 2 end
    if not la or not lb then return 0 end
    local function primary(code) return media.language(tostring(code):match("^%a+")) end
    return primary(a) == primary(b) and 1 or 0
end

-- Pure: the id of the track in `tracks` (mpv's track-list) closest to
-- `spec`, or nil if none has its language and forced flag: then mpv's own
-- selection applies, rather than subtitles nobody asked for.
function M.match_track(tracks, spec)
    if type(spec) ~= "table" then return nil end
    local best, best_score
    for _, t in ipairs(tracks or {}) do
        local language = t.type == "sub" and language_match(t.lang, spec.lang) or 0
        if language > 0 and (t.forced or false) == (spec.forced or false) then
            local score = (language == 2 and 16 or 0)
                + (t.title == spec.title and 8 or 0)
                + ((t["hearing-impaired"] or false) == (spec.hi or false) and 4 or 0)
                + ((t.external or false) == (spec.external or false) and 2 or 0)
                + (t.codec == spec.codec and 1 or 0)
                + (t.id == spec.id and 0.5 or 0)
            if not best_score or score > best_score then best, best_score = t.id, score end
        end
    end
    return best
end

-- Pure: a stored track_spec with only values of the right type (the file
-- may be damaged, and match_track trusts these), or nil.
local function normalize_track(spec)
    if type(spec) ~= "table" then return nil end
    if spec.off == true then return {off = true} end
    local out = {id = tonumber(spec.id)}
    for _, k in ipairs({"lang", "title", "codec"}) do
        if type(spec[k]) == "string" then out[k] = spec[k] end
    end
    for _, k in ipairs({"forced", "hi", "external"}) do
        if spec[k] == true then out[k] = true end
    end
    return out
end

-- Pure: a stored entry with only usable values, or nil if nothing is left.
function M.normalize(entry)
    if type(entry) ~= "table" then return nil end
    local out, any = {t = tonumber(entry.t) or 0}, false
    for field in pairs(M.FIELDS) do
        out[field] = M.clean(field, entry[field])
        any = any or out[field] ~= nil
    end
    out.track = normalize_track(entry.track)
    any = any or out.track ~= nil
    return any and out or nil
end

-- nil `data_dir`: nothing is read or written.
function M.new(data_dir)
    local self = setmetatable({session = {}}, M)
    self.memory = Memory.new(data_dir, "subtitle-settings.json", M.normalize)
    -- Without a choice: the user's mpv.conf.
    self.base = {
        scale = mp.get_property_number("sub-scale", 1),
        pos = mp.get_property_number("sub-pos", 100),
        brightness = 1,
        delay = 0,
    }
    return self
end

function M:brightness()
    return self.level or 1
end

-- Subtitle brightness (D58): applies `level` (not touching mpv's options
-- until a level other than full is first asked for).
function M:set_brightness(level)
    if level == 1 and not self.level then return end
    -- The configured peak (mpv.conf), read before the first change.
    self.peak = self.peak or tonumber(mp.get_property("image-subs-hdr-peak")) or 203
    self.level = level
    local color, peak = media.sub_brightness(level, self.peak)
    mp.set_property("sub-color", color)
    mp.set_property_number("image-subs-hdr-peak", peak)
end

-- Applies a value of `field` to mpv.
function M:apply(field, value)
    if field == "brightness" then
        self:set_brightness(value)
    else
        mp.set_property_number(M.FIELDS[field].prop, value)
    end
end

-- A new file (on_load): applies what is remembered. The delay is
-- file-local, like the default main.lua has just set; the others are
-- simply set for every file, so nothing leaks into the next one.
function M:start(path, item)
    self.video, self.scope = Memory.keys(path, item)
    local shared = self.memory:get(self.scope) or {}
    for _, field in ipairs({"scale", "pos", "brightness"}) do
        self:apply(field, shared[field] or self.session[field] or self.base[field])
    end
    local own = self.memory:get(self.video)
    if own and own.delay then mp.set_property_number("file-local-options/sub-delay", own.delay) end
end

-- After the external subtitles are added, before mpv selects tracks
-- (on_preloaded). Overrides the per-file track id of resume.json.
function M:apply_track()
    local e = self.memory:get(self.scope)
    local spec = e and e.track
    if not spec then return end
    if spec.off then
        mp.set_property("file-local-options/sid", "no")
        return
    end
    local id = M.match_track(mp.get_property_native("track-list"), spec)
    if id then mp.set_property("file-local-options/sid", tostring(id)) end
end

-- The user chose a subtitle track, or none, in a menu.
function M:remember_track()
    self.memory:set(self.scope, "track", M.track_spec(media.selected_track("sub")))
end

-- The user changed `field` in the menu: applied and remembered.
function M:set(field, value)
    value = M.clean(field, value)
    if not value then return end
    local per_video = M.FIELDS[field].per_video
    self:apply(field, value)
    if not per_video then self.session[field] = value end
    if value == M.clean(field, self.base[field]) then value = nil end
    self.memory:set(per_video and self.video or self.scope, field, value)
end

function M:forget(path)
    self.memory:forget(path)
end

return M
