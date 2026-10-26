-- Night mode: narrows the dynamic range so dialogue stays audible at low
-- volume and explosions don't wake the house (D46). A compressor lifts
-- quiet passages relative to loud ones, and a limiter catches peaks. It
-- works on any channel layout, so 5.1 to a TV or receiver (LPCM) keeps its
-- channels; it is first in the chain, before headphone surround.

local msg = require "mp.msg"

local M = {}
M.__index = M

M.LABEL = "dvp-night"

-- Threshold -30 dBFS, ratio 4:1, +5 dB make-up, limiter at -1 dBFS. The
-- detector follows the loudest channel (link=maximum): with the default
-- average, dialogue alone in the centre of a 5.1 track would be measured
-- 15 dB too low and hardly compressed. One gain for all channels keeps the
-- surround balance.
-- Measured with pink noise (docs/DECISIONS.md D46): quiet passages come out
-- 5 dB louder, loud ones up to 8 dB quieter (a 25 dB gap becomes 12 dB),
-- and loud passages never end up louder than without night mode, so
-- switching it on doesn't jump the volume.
M.GRAPH = "acompressor=threshold=0.0316:ratio=4:attack=10:release=300:knee=4:makeup=1.78:link=maximum,"
       .. "alimiter=limit=0.891:attack=5:release=100:level=0"

function M.filter_string(graph)
    graph = graph or M.GRAPH
    return string.format("@%s:lavfi=graph=%%%d%%%s", M.LABEL, #graph, graph)
end

function M.new(cfg)
    local self = setmetatable({}, M)
    local pb = cfg.playback
    -- Compressed passthrough to a receiver can't be filtered.
    self.available = not (pb.audio_passthrough ~= "" and pb.audio_passthrough ~= "no")
    self.enabled = pb.night_mode and self.available
    self.active = false
    self.audio = false
    -- The filter is added once audio is open: only then does mpv build it,
    -- so a missing filter is reported here instead of muting the file.
    mp.observe_property("audio-params/channel-count", "number", function(_, n)
        if n then
            self.audio = true
            self:update()
        end
    end)
    return self
end

-- The filter stays in mpv's chain across files, so it is added once.
function M:update()
    local want = self.enabled and (self.active or self.audio)
    if want == self.active then return end
    if want then
        -- "pre": compress the source channels, before surround or downmix.
        if mp.commandv("af", "pre", M.filter_string()) then
            self.active = true
            msg.info("night mode on")
        else
            msg.warn("night mode: the acompressor/alimiter filters are not available")
            self.available, self.enabled = false, false
        end
    else
        mp.commandv("af", "remove", "@" .. M.LABEL)
        self.active = false
    end
end

function M:set(on)
    self.enabled = on and self.available
    self:update()
    return self.enabled
end

function M:toggle()
    return self:set(not self.enabled)
end

return M
