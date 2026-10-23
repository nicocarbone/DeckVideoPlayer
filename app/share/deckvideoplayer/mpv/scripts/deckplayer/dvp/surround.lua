-- Headphone surround: renders 5.1/7.1 audio binaurally for headphones with
-- FFmpeg's sofalizer filter and a measured dummy head (MIT KEMAR HRTF,
-- app/share/deckvideoplayer/hrtf).
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
-- +6 dB gives the same loudness as mpv's own stereo downmix (measured with
-- pink noise), so switching surround on or off doesn't change the volume.
M.GAIN = 6

-- Escapes a value for an FFmpeg filter option inside a filter graph: first
-- the option-value level (\ ' :), then the graph level (\ ' [ ] , ;).
function M.escape_lavfi(value)
    local level1 = value:gsub("[\\':]", "\\%0")
    return (level1:gsub("[\\'%[%],;]", "\\%0"))
end

-- The `af add` argument. mpv's %length% quoting passes the graph through
-- without interpreting any of its characters.
function M.filter_string(sofa_path, gain)
    local graph = string.format("sofalizer=sofa=%s:gain=%s:type=freq",
                                M.escape_lavfi(sofa_path), tostring(gain or M.GAIN))
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
    self.active = false
    self.channels = nil
    -- Channel count of the decoder output (before filters), so inserting the
    -- filter doesn't feed back into this observer.
    mp.observe_property("audio-params/channel-count", "number", function(_, n)
        self.channels = n
        self:update()
    end)
    return self
end

function M:wanted()
    return self.enabled and (self.channels or 0) > 2
end

function M:update()
    local want = self:wanted()
    if want == self.active then return end
    if want then
        if mp.commandv("af", "add", M.filter_string(self.sofa)) then
            self.active = true
            msg.info(string.format("headphone surround on (%d channels)", self.channels))
        else
            -- e.g. an mpv/FFmpeg build without libmysofa: stop offering it.
            msg.warn("headphone surround: the sofalizer filter is not available")
            self.available, self.enabled = false, false
        end
    else
        mp.commandv("af", "remove", "@" .. M.LABEL)
        self.active = false
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
