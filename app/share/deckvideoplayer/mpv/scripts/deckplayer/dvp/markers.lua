-- Intro and credits markers (D47): where they are, and what "skip" does.
-- Pure functions; dvp/player.lua shows the prompt and acts on R2.
-- A marker is {kind = "intro" | "credits", start = s, stop = s, final = bool}.

local M = {}

-- Markers from a Plex metadata item fetched with includeMarkers=1
-- (times in ms). Plex detects intros (Plex Pass) and credits; "final" is
-- the closing credits. Other kinds (e.g. commercials) are ignored.
function M.from_plex(md)
    local out = {}
    for _, mk in ipairs((type(md) == "table" and md.Marker) or {}) do
        local kind = mk.type
        local start, stop = tonumber(mk.startTimeOffset), tonumber(mk.endTimeOffset)
        if (kind == "intro" or kind == "credits") and start and stop and stop - start >= 2000 then
            out[#out + 1] = {kind = kind, start = start / 1000, stop = stop / 1000, final = mk.final == true}
        end
    end
    table.sort(out, function(a, b) return a.start < b.start end)
    return out
end

-- Markers from Jellyfin's media segments (GET /MediaSegments/<id>; times
-- in ticks of 100 ns). Jellyfin stores segments that a plugin detected
-- (e.g. Intro Skipper); "Outro" is the closing credits. Recaps, previews
-- and commercials are ignored.
local SEGMENT_KINDS = {Intro = "intro", Outro = "credits"}
local TICKS = 1e7

function M.from_jellyfin(segments)
    local out = {}
    for _, sg in ipairs((type(segments) == "table" and segments.Items) or {}) do
        local kind = SEGMENT_KINDS[sg.Type]
        local start, stop = tonumber(sg.StartTicks), tonumber(sg.EndTicks)
        if kind and start and stop and (stop - start) / TICKS >= 2 then
            out[#out + 1] = {kind = kind, start = start / TICKS, stop = stop / TICKS, final = kind == "credits"}
        end
    end
    table.sort(out, function(a, b) return a.start < b.start end)
    return out
end

-- The marker playing at `pos` (s), or nil. The last second doesn't count:
-- skipping there would do nothing useful.
function M.at(list, pos)
    if not pos then return nil end
    for _, mk in ipairs(list or {}) do
        if pos >= mk.start and pos < mk.stop - 1 then return mk end
    end
    return nil
end

-- What R2 does on a marker: {label = prompt text, next = true to go to the
-- next playlist entry, target = seek position, done = toast}. Only the
-- closing credits lead to the next episode (credits in the middle of a
-- film may be followed by more of it). `episode`: wording for TV.
function M.action(mk, has_next, episode)
    if mk.kind == "intro" then
        return {label = "Skip intro", target = mk.stop, done = "Skipped intro"}
    end
    if mk.final and has_next then
        local label = episode and "Next episode" or "Next video"
        return {label = label, next = true, done = label}
    end
    return {label = "Skip credits", target = mk.stop, done = "Skipped credits"}
end

return M
