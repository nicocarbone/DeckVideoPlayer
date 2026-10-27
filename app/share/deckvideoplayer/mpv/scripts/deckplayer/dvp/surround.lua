-- Headphone surround: renders 5.1/7.1 audio binaurally for headphones with
-- FFmpeg's sofalizer filter and a measured dummy head (MIT KEMAR HRTF,
-- diffuse-field equalized for headphones: app/share/deckvideoplayer/hrtf,
-- D48).
--
-- Stereo and mono sources are left untouched: the filter is only in the
-- chain while the decoded audio has more than two channels. mpv cannot tell
-- headphones from speakers, so the user switches it on (audio menu or
-- config.ini). See docs/DECISIONS.md D27.

local msg = require "mp.msg"
local util = require "dvp.util"

local M = {}
M.__index = M

M.LABEL = "dvp-surround"
-- Levels (D48, measured with pink noise against mpv's stereo downmix):
-- +12.5 dB gives 5.1 dialogue (centre channel) the same loudness as the
-- downmix, so switching surround on or off doesn't change the volume.
-- sofalizer lowers its output 3 dB per input channel, so other layouts get
-- 3 dB per channel more or less (7.1: +18.5 dB). The LFE channel, which
-- mpv's downmix drops, comes out level with the main channels' bass.
-- The gain is applied after sofalizer (which warns on every block that
-- goes past full scale), then a limiter at -1 dBFS keeps loud scenes with
-- every channel busy from clipping.
M.GAIN_51 = 12.5
M.LFE_GAIN = 3
M.LIMITER = "alimiter=limit=0.891:attack=5:release=50:level=0"

function M.gain(channels)
    return M.GAIN_51 + 3 * ((channels or 6) - 6)
end

-- Virtual speaker positions that differ from sofalizer's (D57). It puts
-- side channels at 90° (beside the ears), but in a 5.1 mix they are the
-- surrounds, which a 5.1 room has at 100-120° (ITU-R BS.775), behind the
-- listener. Most 5.1 tracks decode as "5.1(side)". 120°: with this HRTF
-- the rear cue (a 4-10 kHz dip) is weak at 110° and clear from 120-130°.
-- 7.1 keeps sofalizer's sides at 90° and backs at 150°, as in a 7.1 room.
-- Speakers are given by their index in the layout: sofalizer in FFmpeg 9
-- looks channel names up as indexes, so "SL 120" would be ignored.
M.SPEAKERS = {["5.1(side)"] = "4 120|5 240", ["5.1"] = "4 120|5 240"}

-- Escapes a value for an FFmpeg filter option inside a filter graph: first
-- the option-value level (\ ' :), then the graph level (\ ' [ ] , ;).
function M.escape_lavfi(value)
    local level1 = value:gsub("[\\':]", "\\%0")
    return (level1:gsub("[\\'%[%],;]", "\\%0"))
end

-- The `af add` argument. mpv's %length% quoting passes the graph through
-- without interpreting any of its characters. `layout`: mpv's channel
-- layout name ("5.1(side)"), for M.SPEAKERS.
function M.filter_string(sofa_path, channels, layout)
    local speakers = M.SPEAKERS[layout or ""]
    local graph = string.format("sofalizer=sofa=%s:gain=0:lfegain=%s:type=freq%s,volume=%sdB,%s",
                                M.escape_lavfi(sofa_path), tostring(M.LFE_GAIN),
                                speakers and (":speakers=" .. M.escape_lavfi(speakers)) or "",
                                tostring(M.gain(channels)), M.LIMITER)
    return string.format("@%s:lavfi=graph=%%%d%%%s", M.LABEL, #graph, graph)
end

-- cfg: parsed config; sofa_path: HRTF file (feature unavailable if missing).
function M.new(cfg, sofa_path)
    local self = setmetatable({}, M)
    local pb = cfg.playback
    self.sofa = sofa_path
    -- Compressed passthrough to a receiver can't be filtered (and a receiver
    -- means speakers anyway).
    self.passthrough = pb.audio_passthrough ~= "" and pb.audio_passthrough ~= "no"
    self.available = sofa_path ~= nil and util.file_exists(sofa_path) and not self.passthrough
    self.enabled = pb.headphone_surround and self.available
    self.active = false   -- "<channels> <layout>" the filter was added for, or false
    self.channels, self.layout = nil, nil
    -- Channel count and layout of the decoder output (before filters), so
    -- inserting the filter doesn't feed back into these observers.
    -- (One observer for both, so the filter isn't added before the layout
    -- is known and then replaced.)
    mp.observe_property("audio-params", "native", function(_, p)
        p = type(p) == "table" and p or {}
        self.channels, self.layout = tonumber(p["channel-count"]), p.channels
        self:update()
    end)
    return self
end

function M:wanted()
    return self.enabled and (self.channels or 0) > 2
end

function M:update()
    local want = self:wanted() and (self.channels .. " " .. tostring(self.layout))
    if want == self.active then return end
    -- A different layout needs a different gain or speakers: replace the filter.
    if self.active then
        mp.commandv("af", "remove", "@" .. M.LABEL)
        self.active = false
    end
    if want then
        if mp.commandv("af", "add", M.filter_string(self.sofa, self.channels, self.layout)) then
            self.active = want
            msg.info(string.format("headphone surround on (%d channels, %s)", self.channels,
                                   tostring(self.layout)))
        else
            -- e.g. an mpv/FFmpeg build without libmysofa: stop offering it.
            msg.warn("headphone surround: the sofalizer filter is not available")
            self.available, self.enabled = false, false
        end
    end
end

-- Returns the new state.
function M:toggle()
    if not self.available then return false end
    self.enabled = not self.enabled
    self:update()
    return self.enabled
end

return M
