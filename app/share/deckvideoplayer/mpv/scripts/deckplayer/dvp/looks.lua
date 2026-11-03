-- Looks for old SD video (D69), three settings of the Video menu:
--   look     "CRT": scanlines (a shader on the scaled video)
--   grain    film grain (a shader on the scaled video)
--   cleanup  compression clean-up: debanding (renderer) plus deblocking
--            and, when strong, light denoising (FFmpeg filters, CPU)
-- Remembered together per folder (local files, DLNA folders), per show
-- (Plex / Jellyfin episodes) or per video (other server videos). SDR
-- videos only: the shaders work on SDR light levels, and old SD video is
-- what needs them. Everything is file-local (mpv restores the options at
-- the next file), on top of the user's own mpv.conf shaders and filters.

local utils = require "mp.utils"
local msg = require "mp.msg"
local util = require "dvp.util"

local M = {}
M.__index = M

M.SETTINGS = {"look", "grain", "cleanup"}
M.ORDER = {
    look = {"off", "crt"},
    grain = {"off", "light", "medium", "strong"},
    cleanup = {"off", "light", "strong"},
}
M.LABELS = {
    look = {off = "Off", crt = "CRT"},
    grain = {off = "Off", light = "Light", medium = "Medium", strong = "Strong"},
    cleanup = {off = "Off", light = "Light", strong = "Strong"},
}
M.TITLES = {look = "Look", grain = "Grain", cleanup = "Clean-up"}

local CRT_SHADER = "~~/shaders/dvp-crt.glsl"
local GRAIN_SHADER = "~~/shaders/dvp-grain.glsl"
-- Grain amounts (the shader's dvp_grain).
local GRAIN = {light = "0.025", medium = "0.045", strong = "0.075"}
-- Clean-up: libplacebo debanding passes, and the FFmpeg filters. fspp at a
-- fixed strength (mpv gives filters no quantizers, D69); hqdn3d at half
-- its default strength.
local CLEANUP = {
    light = {iterations = "1", graph = "fspp=qp=4"},
    strong = {iterations = "2", graph = "fspp=qp=8,hqdn3d=2:1.5:3:2.25"},
}
M.FILTER_LABEL = "dvp-cleanup"
-- Before the FFmpeg filters: a software-format frame. Hardware-decoded
-- frames (VA-API) are copied to memory for them (mpv's autoconvert);
-- without this the lavfi graph can't take them and mpv drops the filter.
-- Software-decoded SD video is yuv420p already (FFmpeg's filters are 8-bit).
M.FORMAT_LABEL = "dvp-cleanup-format"
local OUR_FILTERS = {[M.FILTER_LABEL] = true, [M.FORMAT_LABEL] = true}
local OUR_SHADERS = {[CRT_SHADER] = true, [GRAIN_SHADER] = true}

local function is_hdr(gamma) return gamma == "pq" or gamma == "hlg" end

-- Pure: where the choice for a video is kept. `item`: its media server
-- item (dvp/servers.lua), or nil for a local file. nil: not remembered.
function M.memory_key(path, item)
    if item then
        local base = tostring(item.backend or "server") .. ":" .. tostring(item.machine) .. ":"
        if item.kind == "episode" and item.show and item.show ~= "" then return base .. "show:" .. item.show end
        if item.parent and item.parent ~= "" then return base .. "folder:" .. tostring(item.parent) end
        if item.rating_key then return base .. "item:" .. tostring(item.rating_key) end
        return nil
    end
    if type(path) == "string" and path:sub(1, 1) == "/" then return "dir:" .. util.dirname(path) end
    return nil
end

-- Pure: the video's visible lines: its height, or the height of the
-- crop ("WxH+X+Y", Picture mode "Crop black bars").
function M.source_lines(h, crop)
    local ch = tonumber(tostring(crop or ""):match("^%d+x(%d+)"))
    if ch and ch > 0 then return ch end
    return tonumber(h)
end

-- Pure: whether a video is SD (Clean-up only runs for SD: its filters run
-- on one CPU core, about a quarter of a desktop core for a deinterlaced
-- 576i DVD, so HD would not keep up on a Deck; D69).
function M.is_sd(w, h)
    w, h = tonumber(w), tonumber(h)
    return w ~= nil and h ~= nil and w <= 1024 and h <= 576
end

-- Pure: the choice that applies: all off for HDR, no clean-up for HD.
function M.effective(choice, sdr, sd)
    if not sdr then return {} end
    local out = {}
    for k, v in pairs(choice or {}) do out[k] = v end
    if not sd then out.cleanup = nil end
    return out
end

-- Pure: a choice ({look, grain, cleanup}) from a looks.json value: a table
-- (v2) or a look name (v1). Unknown values (looks of test builds that
-- didn't ship) become "off". nil when everything is off.
function M.normalize(value)
    if type(value) == "string" then value = {look = value} end
    if type(value) ~= "table" then return nil end
    local out, any = {}, false
    for _, s in ipairs(M.SETTINGS) do
        local v = value[s]
        if type(v) == "string" and v ~= "off" and M.LABELS[s][v] then out[s] = v; any = true end
    end
    return any and out or nil
end

-- Pure: the file-local option values for `choice` (a table, missing
-- settings off), on top of `base` (the options at the start of the file:
-- {shaders = list, opts = map, vf = list, deband = "yes"/"no",
-- iterations = string}). `lines`: the video's visible lines (CRT).
function M.option_values(choice, base, lines)
    choice = choice or {}
    -- (opts marked as a map for mpv: an empty Lua table would be a list.)
    local shaders, opts = {}, setmetatable({}, {type = "MAP"})
    for _, s in ipairs(base.shaders or {}) do
        if not OUR_SHADERS[s] then shaders[#shaders + 1] = s end
    end
    for k, v in pairs(base.opts or {}) do opts[k] = v end
    local vf = {}
    for _, f in ipairs(base.vf or {}) do
        if not OUR_FILTERS[f.label] then vf[#vf + 1] = f end
    end
    local out = {deband = base.deband, ["deband-iterations"] = base.iterations}
    -- Grain first: the CRT draws its lines over the grainy picture, as a
    -- television showed a grainy film.
    if GRAIN[choice.grain] then
        shaders[#shaders + 1] = GRAIN_SHADER
        opts.dvp_grain = GRAIN[choice.grain]
    end
    if choice.look == "crt" then
        shaders[#shaders + 1] = CRT_SHADER
        if lines then opts.dvp_src_h = tostring(math.floor(lines)) end
    end
    local clean = CLEANUP[choice.cleanup]
    if clean then
        out.deband, out["deband-iterations"] = "yes", clean.iterations
        vf[#vf + 1] = {name = "format", label = M.FORMAT_LABEL, enabled = true, params = {fmt = "yuv420p"}}
        vf[#vf + 1] = {name = "lavfi", label = M.FILTER_LABEL, enabled = true, params = {graph = clean.graph}}
    end
    out["glsl-shaders"], out["glsl-shader-opts"], out.vf = shaders, opts, vf
    return out
end

-- Pure: a stable text for an option value (sorted keys), to compare
-- values without setting unchanged options again.
function M.serialize(v)
    if type(v) ~= "table" then return tostring(v) end
    local keys = {}
    for k in pairs(v) do keys[#keys + 1] = tostring(k) end
    table.sort(keys)
    local parts = {}
    for _, k in ipairs(keys) do
        local val = v[k]
        if val == nil then val = v[tonumber(k)] end
        parts[#parts + 1] = k .. "=" .. M.serialize(val)
    end
    return "{" .. table.concat(parts, ",") .. "}"
end

-- Pure: the choice's active settings, for the info panel ("CRT",
-- "Grain: light", "Clean-up: strong"); empty when all off.
function M.describe(choice)
    local parts = {}
    for _, s in ipairs(M.SETTINGS) do
        local v = (choice or {})[s]
        if v and v ~= "off" and M.LABELS[s][v] then
            if s == "look" then parts[#parts + 1] = M.LABELS.look[v]
            else parts[#parts + 1] = M.TITLES[s] .. ": " .. M.LABELS[s][v]:lower() end
        end
    end
    return parts
end

-- Set `on_change` (a function) to be told when the playing video turns
-- out SDR/HDR or SD/HD (which rows the Video menu offers, what the info
-- panel shows).
function M.new(data_dir)
    local self = setmetatable({}, M)
    self.file = (data_dir and data_dir ~= "") and util.join(data_dir, "looks.json") or nil
    self.saved = {}
    local text = self.file and util.read_file(self.file)
    local data = text and utils.parse_json(text)
    if type(data) == "table" and type(data.looks) == "table" then
        for k, v in pairs(data.looks) do
            if type(k) == "string" then self.saved[k] = M.normalize(v) end
        end
    end
    self.current = {}
    mp.observe_property("video-params", "native", function(_, p) self:video_changed(p) end)
    -- Crop black bars changes the visible lines.
    mp.observe_property("video-crop", "string", function()
        self:video_changed(mp.get_property_native("video-params"))
    end)
    -- Between files nothing applies (mpv restores the file-local values).
    mp.register_event("end-file", function() self.base = nil end)
    return self
end

function M:save()
    if not self.file then return end
    local ok, err = util.write_file_atomic(self.file, utils.format_json({version = 2, looks = self.saved}))
    if not ok then msg.warn("looks: could not save: " .. tostring(err)) end
end

-- A new file: its remembered choice (applied once the video is known to
-- be SDR). The options before any look are read now (mpv has restored the
-- previous file's file-local values).
function M:start(key)
    self.key = key
    local saved = key and self.saved[key] or {}
    self.current = {}
    for _, s in ipairs(M.SETTINGS) do self.current[s] = saved[s] or "off" end
    self.sdr, self.sd, self.lines = nil, nil, nil
    self.base = {
        shaders = mp.get_property_native("glsl-shaders") or {},
        opts = mp.get_property_native("glsl-shader-opts") or {},
        vf = mp.get_property_native("vf") or {},
        deband = mp.get_property("deband"),
        iterations = mp.get_property("deband-iterations"),
    }
    -- What mpv has now: only options that differ from it get set.
    self.applied = {}
    for name, value in pairs(M.option_values({}, self.base, nil)) do
        self.applied[name] = M.serialize(value)
    end
    -- In case the video is already known.
    self:video_changed(mp.get_property_native("video-params"))
end

function M:video_changed(p)
    if not self.base or type(p) ~= "table" or not p.gamma then return end
    local sdr, sd = not is_hdr(p.gamma), M.is_sd(p.w, p.h)
    local changed = sdr ~= self.sdr or sd ~= self.sd
    self.sdr, self.sd = sdr, sd
    self.lines = M.source_lines(p.h, mp.get_property("video-crop"))
    self:apply()
    if changed and self.on_change then self.on_change() end
end

-- Whether looks can be chosen for the playing video (nil: not known yet).
function M:available()
    return self.sdr
end

-- Whether Clean-up can be chosen (SDR and SD).
function M:cleanup_available()
    return self.sdr and self.sd
end

-- Sets the options whose values changed (a changed filter list restarts
-- the filters; a changed shader list recompiles shaders).
function M:apply()
    if not self.base then return end
    local values = M.option_values(M.effective(self.current, self.sdr, self.sd), self.base, self.lines)
    for _, name in ipairs({"deband", "deband-iterations", "vf", "glsl-shaders", "glsl-shader-opts"}) do
        local value = values[name]
        local key = M.serialize(value)
        if value ~= nil and key ~= self.applied[name] then
            local ok, err
            if type(value) == "table" then ok, err = mp.set_property_native("file-local-options/" .. name, value)
            else ok, err = mp.set_property("file-local-options/" .. name, value) end
            if not ok then msg.warn("looks: " .. name .. ": " .. tostring(err)) end
            self.applied[name] = key
        end
    end
end

-- The user's choice for `setting` (Video menu): applied and remembered.
function M:set(setting, value)
    if not (M.LABELS[setting] and M.LABELS[setting][value]) then return end
    self.current[setting] = value
    self:apply()
    if self.key then
        self.saved[self.key] = M.normalize(self.current)
        self:save()
    end
end

-- The choice on screen (all off for an HDR video, no clean-up for HD).
function M:shown()
    return M.effective(self.current, self.sdr, self.sd)
end

return M
