-- TV speakers: a stereo downmix of 5.1/7.1 audio for TV (or other stereo)
-- speakers, with dialogue clearer than in the usual downmix (D75).
--
-- The usual downmix (PipeWire's, mpv's, ITU-R BS.775) keeps the front
-- channels at full level and adds the centre and surrounds at -3 dB. Here
-- the centre channel, where films put dialogue, comes in at full level, and
-- the other channels 3 dB below the usual downmix: dialogue 3 dB louder,
-- music and effects 3 dB quieter. A scene with every channel busy ends up
-- about as loud as before (pink noise: -0.6 dB), so switching it on doesn't
-- jump the volume.
--
-- Only audio with a centre channel is remixed; stereo, and layouts without
-- dialogue in a channel of its own, are left alone. mpv sends 5.1 to
-- PipeWire as 5.1 and the system downmixes it, so the app can't see whether
-- the output is stereo: the user switches this on, as with headphone
-- surround (the two are exclusive).

local msg = require "mp.msg"

local M = {}
M.__index = M

M.LABEL = "dvp-tvmix"
-- Gains into each stereo side, linear (D75, measured with pink noise).
M.FRONT = 0.7071      -- -3 dB (usual downmix: 0 dB)
M.CENTER = 1.0        -- 0 dB into each side (usual: -3 dB)
M.SURROUND = 0.5      -- -6 dB (usual: -3 dB)
M.LFE = 0.3536        -- -9 dB (PipeWire's: -6 dB; mpv's own drops it)
-- The sum can pass full scale in loud scenes: a limiter at -1 dBFS, as
-- after headphone surround.
M.LIMITER = "alimiter=limit=0.891:attack=5:release=50:level=0"

-- mpv's standard layouts with more than two channels
-- (`mpv --audio-channels=help`). Other layouts come as "fl-fr-…".
M.LAYOUTS = {
    ["2.1"] = "fl-fr-lfe", ["3.0"] = "fl-fr-fc", ["3.0(back)"] = "fl-fr-bc",
    ["4.0"] = "fl-fr-fc-bc", ["quad"] = "fl-fr-bl-br", ["quad(side)"] = "fl-fr-sl-sr",
    ["3.1"] = "fl-fr-fc-lfe", ["3.1(back)"] = "fl-fr-lfe-bc",
    ["5.0"] = "fl-fr-fc-bl-br", ["5.0(alsa)"] = "fl-fr-bl-br-fc", ["5.0(side)"] = "fl-fr-fc-sl-sr",
    ["4.1"] = "fl-fr-fc-lfe-bc", ["4.1(alsa)"] = "fl-fr-bl-br-lfe",
    ["5.1"] = "fl-fr-fc-lfe-bl-br", ["5.1(alsa)"] = "fl-fr-bl-br-fc-lfe",
    ["5.1(side)"] = "fl-fr-fc-lfe-sl-sr",
    ["6.0"] = "fl-fr-fc-bc-sl-sr", ["6.0(front)"] = "fl-fr-flc-frc-sl-sr",
    ["hexagonal"] = "fl-fr-fc-bl-br-bc",
    ["6.1"] = "fl-fr-fc-lfe-bc-sl-sr", ["6.1(back)"] = "fl-fr-fc-lfe-bl-br-bc",
    ["6.1(top)"] = "fl-fr-fc-lfe-bl-br-tc", ["6.1(front)"] = "fl-fr-lfe-flc-frc-sl-sr",
    ["7.0"] = "fl-fr-fc-bl-br-sl-sr", ["7.0(front)"] = "fl-fr-fc-flc-frc-sl-sr",
    ["7.0(rear)"] = "fl-fr-fc-bl-br-sdl-sdr",
    ["7.1"] = "fl-fr-fc-lfe-bl-br-sl-sr", ["7.1(alsa)"] = "fl-fr-bl-br-fc-lfe-sl-sr",
    ["7.1(wide)"] = "fl-fr-fc-lfe-bl-br-flc-frc", ["7.1(wide-side)"] = "fl-fr-fc-lfe-flc-frc-sl-sr",
    ["7.1(top)"] = "fl-fr-fc-lfe-bl-br-tfl-tfr", ["7.1(rear)"] = "fl-fr-fc-lfe-bl-br-sdl-sdr",
    ["octagonal"] = "fl-fr-fc-bl-br-bc-sl-sr",
    ["cube"] = "fl-fr-bl-br-tfl-tfr-tbl-tbr",
    ["hexadecagonal"] = "fl-fr-fc-bl-br-bc-sl-sr-tfc-tfl-tfr-tbl-tbc-tbr-wl-wr",
    ["22.2"] = "fl-fr-fc-lfe-bl-br-flc-frc-bc-sl-sr-tc-tfl-tfc-tfr-tbl-tbc-tbr-lfe2-tsl-tsr-bfc-bfl-bfr",
}

-- Each speaker: which side it goes to ("l", "r", or "c" for both at -3 dB
-- each, except the dialogue centre) and its gain.
local SPEAKERS = {
    fl = {"l", "FRONT"}, fr = {"r", "FRONT"}, flc = {"l", "FRONT"}, frc = {"r", "FRONT"},
    wl = {"l", "FRONT"}, wr = {"r", "FRONT"}, dl = {"l", "FRONT"}, dr = {"r", "FRONT"},
    tfl = {"l", "FRONT"}, tfr = {"r", "FRONT"}, bfl = {"l", "FRONT"}, bfr = {"r", "FRONT"},
    tc = {"c", "FRONT"}, tfc = {"c", "FRONT"}, bfc = {"c", "FRONT"},
    fc = {"both", "CENTER"},
    -- A second LFE is left out: `pan` reads channel names as letters only,
    -- so "LFE2" is a syntax error that rejects the whole graph (ISSUES.md
    -- XI 1.1); it carries the same bass as the first.
    lfe = {"both", "LFE"}, lfe2 = {"none", "LFE"},
    bl = {"l", "SURROUND"}, br = {"r", "SURROUND"}, sl = {"l", "SURROUND"}, sr = {"r", "SURROUND"},
    sdl = {"l", "SURROUND"}, sdr = {"r", "SURROUND"}, tbl = {"l", "SURROUND"}, tbr = {"r", "SURROUND"},
    tsl = {"l", "SURROUND"}, tsr = {"r", "SURROUND"},
    bc = {"c", "SURROUND"}, tbc = {"c", "SURROUND"},
}

-- Speaker names of an mpv layout ("5.1(side)" or "fl-fr-fc-…"), or nil if
-- any speaker is unknown ("na", "unknown6").
function M.speakers(layout)
    if type(layout) ~= "string" then return nil end
    local spec = M.LAYOUTS[layout] or layout
    local list = {}
    for name in spec:gmatch("[^-]+") do
        if not SPEAKERS[name] then return nil end
        list[#list + 1] = name
    end
    return list
end

local function num(x)
    return (string.format("%.4f", x):gsub("0+$", ""):gsub("%.$", ""))
end

-- The `pan` filter for a layout, or nil when it isn't remixed (no centre
-- channel, stereo, unknown speakers).
function M.graph(layout)
    local list = M.speakers(layout)
    if not list or #list <= 2 then return nil end
    local left, right, centre = {}, {}, false
    for _, name in ipairs(list) do
        local side, gain = SPEAKERS[name][1], M[SPEAKERS[name][2]]
        if name == "fc" then centre = true end
        if side == "c" then gain = gain * math.sqrt(0.5) end
        if side ~= "none" then
            local term = num(gain) .. "*" .. name:upper()
            if side ~= "r" then left[#left + 1] = term end
            if side ~= "l" then right[#right + 1] = term end
        end
    end
    if not centre then return nil end
    return "pan=stereo|FL=" .. table.concat(left, "+") .. "|FR=" .. table.concat(right, "+")
           .. "," .. M.LIMITER
end

-- The `af add` argument (mpv's %length% quoting passes the graph through as is).
function M.filter_string(graph)
    return string.format("@%s:lavfi=graph=%%%d%%%s", M.LABEL, #graph, graph)
end

function M.new(cfg)
    local self = setmetatable({}, M)
    local pb = cfg.playback
    -- Compressed passthrough to a receiver can't be filtered.
    self.available = not (pb.audio_passthrough ~= "" and pb.audio_passthrough ~= "no")
    self.enabled = pb.tv_speakers and self.available
    self.active = false   -- the layout the filter was added for, or false
    self.layout = nil
    self.failed = {}      -- layouts FFmpeg refused this session
    self.worked = false   -- the filter was added at least once
    -- The decoder's layout (before filters), as in dvp/surround.lua.
    mp.observe_property("audio-params", "native", function(_, p)
        p = type(p) == "table" and p or {}
        self.layout = p.channels
        self:update()
    end)
    return self
end

function M:update()
    local graph = self.enabled and not self.failed[self.layout or ""] and M.graph(self.layout)
    local want = graph and self.layout or false
    if want == self.active then return end
    if self.active then
        mp.commandv("af", "remove", "@" .. M.LABEL)
        self.active = false
    end
    if want then
        if mp.commandv("af", "add", M.filter_string(graph)) then
            self.active, self.worked = want, true
            msg.info("TV speaker mix on (" .. tostring(self.layout) .. ")")
        elseif not self.worked and #(M.speakers(self.layout) or {}) <= 8 then
            -- Failing on an ordinary layout before ever working: the
            -- filters are missing from this build; stop offering it.
            msg.warn("TV speaker mix: the pan/alimiter filters are not available")
            self.available, self.enabled = false, false
        else
            -- Only this layout: it plays with the usual downmix, and the
            -- option stays on for other tracks (ISSUES.md XI 1.1).
            msg.warn("TV speaker mix: can't remix " .. tostring(self.layout) .. "; left as it is")
            self.failed[self.layout] = true
        end
    end
end

-- mpv disabled the filter after `af add` had succeeded: FFmpeg refused this
-- layout only when configuring it (sofalizer has no speaker positions for
-- 22.2). Audio plays on with the usual downmix; the layout is remembered and
-- the filter removed, so the info panel stops claiming it (D78).
function M:filter_failed()
    if not self.active then return end
    msg.warn("TV speaker mix: can't process " .. tostring(self.active) .. "; left as it is")
    self.failed[self.active] = true
    mp.commandv("af", "remove", "@" .. M.LABEL)
    self.active = false
end

-- Returns the new state.
function M:set(on)
    self.enabled = on and self.available or false
    self:update()
    return self.enabled
end

function M:toggle()
    return self:set(not self.enabled)
end

return M
