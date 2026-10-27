-- "Video info" panel of the library (v0.4.1, D50): container, size,
-- bitrate, video format with HDR type, audio and subtitle tracks, path.
-- Local files are read with ffprobe (in the background, only when asked);
-- Plex and Jellyfin videos with the item's metadata from the server.
-- The first row says where the video is (local folder, drive or server).

local utils = require "mp.utils"
local util = require "dvp.util"
local media = require "dvp.media"

local M = {}

---------------------------------------------------------------------------
-- Pure helpers (unit-tested)
---------------------------------------------------------------------------

-- "24000/1001" or 23.976 -> 23.976 (nil when unknown).
local function ratio(v)
    if type(v) == "number" then return v > 0 and v or nil end
    local a, b = tostring(v or ""):match("^(%d+%.?%d*)/(%d+%.?%d*)$")
    if a and tonumber(b) > 0 then
        local r = tonumber(a) / tonumber(b)
        return r > 0 and r or nil
    end
    local n = tonumber(v)
    return n and n > 0 and n or nil
end

function M.format_fps(fps)
    fps = ratio(fps)
    if not fps then return nil end
    local s = string.format("%.3f", fps):gsub("0+$", ""):gsub("%.$", "")
    return s .. " fps"
end

-- bits per second -> "24.5 Mb/s" / "640 kb/s".
function M.format_bitrate(bps)
    bps = tonumber(bps)
    if not bps or bps <= 0 then return nil end
    if bps >= 1e6 then return string.format("%.1f Mb/s", bps / 1e6) end
    return string.format("%d kb/s", math.floor(bps / 1e3 + 0.5))
end

function M.format_size(bytes)
    bytes = tonumber(bytes)
    if not bytes or bytes <= 0 then return nil end
    if bytes >= 1e9 then return string.format("%.2f GB", bytes / 1e9) end
    if bytes >= 1e6 then return string.format("%.0f MB", bytes / 1e6) end
    return string.format("%.0f KB", math.max(1, bytes / 1e3))
end

-- HDR type: {dv_profile = 8, transfer = "smpte2084", hdr10plus = true}
-- -> "Dolby Vision 8 · HDR10+". Profile 5 has no HDR10 base layer.
function M.hdr_label(h)
    local parts = {}
    local dv = tonumber(h.dv_profile)
    if dv then parts[#parts + 1] = "Dolby Vision " .. dv end
    if h.transfer == "smpte2084" and dv ~= 5 then
        parts[#parts + 1] = h.hdr10plus and "HDR10+" or "HDR10"
    elseif h.transfer == "arib-std-b67" then
        parts[#parts + 1] = "HLG"
    end
    if #parts == 0 then return "SDR" end
    return table.concat(parts, " · ")
end

local PRIMARIES = {bt2020 = "BT.2020", bt709 = "BT.709", smpte170m = "BT.601", bt470bg = "BT.601",
                   ["smpte432"] = "Display P3", ["smpte431"] = "DCI-P3"}

local function channels_label(layout, n)
    if type(layout) == "string" and layout ~= "" then
        layout = layout:gsub("%(.*%)$", "")
        if layout == "mono" then return "Mono" end
        if layout == "stereo" then return "Stereo" end
        if layout:match("^%d") then return layout end
    end
    n = tonumber(n)
    if not n then return nil end
    if n == 1 then return "Mono" end
    if n == 2 then return "Stereo" end
    if n == 6 then return "5.1" end
    if n == 8 then return "7.1" end
    return n .. " ch"
end

local function add(rows, label, value)
    if value and value ~= "" then rows[#rows + 1] = {label = label, value = value} end
end

-- "a · b" of the given parts, skipping nil/false/"" (anywhere).
local function join(...)
    local out = {}
    for i = 1, select("#", ...) do
        local p = select(i, ...)
        if p and p ~= "" then out[#out + 1] = p end
    end
    return table.concat(out, " · ")
end

-- One audio track: "TrueHD Atmos 7.1 · Commentary · Default".
local function audio_row(i, t)
    local lang = media.language(t.lang)
    local codec = media.codec(t.codec, t.profile)
    -- ffprobe: "Dolby TrueHD + Dolby Atmos"; Plex: "dolby digital plus + dolby atmos".
    if (tostring(t.profile or "") .. " " .. tostring(t.display or "")):lower():find("atmos") then
        codec = codec .. " Atmos"
    end
    local title = (t.title and t.title ~= lang) and t.title or nil
    return {label = lang or title or ("Track " .. i),
            value = join(codec, channels_label(t.layout, t.channels), lang and title,
                         t.default and "Default")}
end

local function sub_row(i, t)
    local lang = media.language(t.lang)
    local title = (t.title and t.title ~= lang) and t.title or nil
    return {label = lang or title or ("Track " .. i),
            value = join(t.external and "External" or media.codec(t.codec), lang and title,
                         t.forced and "Forced", t.sdh and "SDH", t.default and "Default")}
end

-- Sections from a normalized description:
-- {file = {source, name, folder, size, duration, container, bitrate},
--  video = {codec, profile, width, height, fps, bit_depth, primaries,
--           transfer, dv_profile, hdr10plus, bitrate, mastering, maxcll, maxfall} or nil,
--  audio = {{lang, title, codec, profile, layout, channels, default, display}},
--  subs = {{lang, title, codec, forced, sdh, default, external}}}
function M.sections(d)
    local out = {}
    local f = d.file or {}
    local rows = {}
    add(rows, "Source", f.source)
    add(rows, "Name", f.name)
    add(rows, "Folder", f.folder)
    add(rows, "Size", M.format_size(f.size))
    add(rows, "Duration", f.duration and f.duration > 0 and util.format_time(f.duration))
    add(rows, "Container", f.container)
    add(rows, "Bitrate", M.format_bitrate(f.bitrate))
    out[#out + 1] = {title = "File", rows = rows}
    local v = d.video
    if v then
        rows = {}
        local codec = media.codec(v.codec)
        if v.profile and v.profile ~= "" then codec = codec .. " " .. v.profile end
        add(rows, "Codec", codec)
        if v.width and v.height then
            local badge = media.resolution_badge(v.width, v.height)
            add(rows, "Resolution", string.format("%d × %d", v.width, v.height)
                .. (badge and badge ~= v.height .. "p" and (" (" .. badge .. ")") or ""))
        end
        add(rows, "Frame rate", M.format_fps(v.fps))
        add(rows, "Bit depth", tonumber(v.bit_depth) and (v.bit_depth .. "-bit"))
        add(rows, "HDR", M.hdr_label(v))
        add(rows, "Colors", PRIMARIES[v.primaries or ""])
        add(rows, "Mastering peak", tonumber(v.mastering) and string.format("%d nits", math.floor(v.mastering)))
        if tonumber(v.maxcll) and v.maxcll > 0 then
            add(rows, "MaxCLL / MaxFALL", string.format("%d / %d nits", math.floor(v.maxcll),
                                                     math.floor(tonumber(v.maxfall) or 0)))
        end
        add(rows, "Video bitrate", M.format_bitrate(v.bitrate))
        out[#out + 1] = {title = "Video", rows = rows}
    end
    if d.audio and #d.audio > 0 then
        rows = {}
        for i, t in ipairs(d.audio) do rows[#rows + 1] = audio_row(i, t) end
        out[#out + 1] = {title = #rows == 1 and "Audio" or ("Audio (" .. #rows .. " tracks)"), rows = rows}
    end
    if d.subs and #d.subs > 0 then
        rows = {}
        for i, t in ipairs(d.subs) do rows[#rows + 1] = sub_row(i, t) end
        out[#out + 1] = {title = "Subtitles (" .. #rows .. ")", rows = rows}
    end
    return out
end

-- Menu items (dvp/menu.lua) of the sections: a header, then label/value rows.
function M.items(sections)
    local items = {}
    for _, s in ipairs(sections) do
        items[#items + 1] = {label = s.title, header = true}
        for _, r in ipairs(s.rows) do items[#items + 1] = {label = r.label, value = r.value} end
    end
    return items
end

local function tag(t, name)
    local tags = type(t.tags) == "table" and t.tags or {}
    return tags[name] or tags[name:upper()] or tags[name:lower()]
end

local function nits(v)
    local r = ratio(v)
    return r and math.floor(r + 0.5) or nil
end

-- Pure: an ffprobe colour field, nil when "unknown"/missing.
local function known(v)
    if v == nil or v == "" or v == "unknown" or v == "unspecified" then return nil end
    return v
end

-- Normalized description of a local file from ffprobe's JSON
-- (-show_format -show_streams), plus `frame` (-show_frames of the first
-- video frame; optional): HDR10+ and brightness metadata are only there,
-- and FFmpeg 9 often leaves the stream's transfer/primaries "unknown"
-- until a frame is decoded.
function M.from_ffprobe(probe, frame, path)
    local fmt = type(probe.format) == "table" and probe.format or {}
    local name = util.basename(path or fmt.filename or "")
    local ext = util.extension(name)
    local d = {file = {
        name = name, folder = path and util.dirname(path),
        size = tonumber(fmt.size), duration = tonumber(fmt.duration),
        container = (ext and ext ~= "") and ext:upper() or fmt.format_long_name,
        bitrate = tonumber(fmt.bit_rate),
    }, audio = {}, subs = {}}
    for _, s in ipairs(type(probe.streams) == "table" and probe.streams or {}) do
        local disp = type(s.disposition) == "table" and s.disposition or {}
        if s.codec_type == "video" and not d.video and disp.attached_pic ~= 1 then
            local depth = tostring(s.pix_fmt or ""):match("p(%d%d)[lb]e$")
            local v = {codec = s.codec_name, profile = s.profile, width = s.width, height = s.height,
                       fps = s.avg_frame_rate ~= "0/0" and s.avg_frame_rate or s.r_frame_rate,
                       bit_depth = tonumber(depth) or tonumber(s.bits_per_raw_sample)
                           or (s.pix_fmt and 8 or nil),
                       primaries = known(s.color_primaries), transfer = known(s.color_transfer),
                       bitrate = tonumber(s.bit_rate) or tonumber(tag(s, "BPS"))}
            local side = {}
            for _, x in ipairs(type(s.side_data_list) == "table" and s.side_data_list or {}) do side[#side + 1] = x end
            local f1 = type(frame) == "table" and type(frame.frames) == "table" and frame.frames[1]
            if type(f1) == "table" then
                v.primaries = v.primaries or known(f1.color_primaries)
                v.transfer = v.transfer or known(f1.color_transfer)
            end
            for _, x in ipairs(f1 and type(f1.side_data_list) == "table" and f1.side_data_list or {}) do
                side[#side + 1] = x
            end
            for _, x in ipairs(side) do
                local kind = tostring(x.side_data_type or "")
                if kind:find("DOVI configuration") then v.dv_profile = x.dv_profile end
                if kind:find("SMPTE2094%-40") or kind:find("HDR10%+") then v.hdr10plus = true end
                if kind:find("Mastering display") then v.mastering = nits(x.max_luminance) end
                if kind:find("Content light level") then v.maxcll, v.maxfall = x.max_content, x.max_average end
            end
            d.video = v
        elseif s.codec_type == "audio" then
            d.audio[#d.audio + 1] = {lang = tag(s, "language"), title = tag(s, "title"), codec = s.codec_name,
                                     profile = s.profile, layout = s.channel_layout, channels = s.channels,
                                     default = disp.default == 1}
        elseif s.codec_type == "subtitle" then
            d.subs[#d.subs + 1] = {lang = tag(s, "language"), title = tag(s, "title"), codec = s.codec_name,
                                   forced = disp.forced == 1, sdh = disp.hearing_impaired == 1,
                                   default = disp.default == 1}
        end
    end
    return d
end

-- "Plex · Home · local network": a media server's Source row. `connection`:
-- "local" / "remote" (how the app reached it), or nil.
function M.server_source(service, server_name, connection)
    local how = connection == "local" and "local network" or connection == "remote" and "remote" or nil
    return join(service, server_name, how)
end

-- Normalized description of a Plex item from its full metadata
-- (GET /library/metadata/<id>). `source`: see server_source.
function M.from_plex(md, source)
    local m = type(md.Media) == "table" and md.Media[1] or {}
    local part = type(m.Part) == "table" and m.Part[1] or {}
    local file = type(part.file) == "string" and part.file or nil
    local d = {file = {
        source = source, name = file and util.basename(file) or md.title,
        folder = file and util.dirname(file),
        size = tonumber(part.size), duration = tonumber(md.duration or m.duration) and (md.duration or m.duration) / 1000,
        container = m.container and tostring(m.container):upper(),
        bitrate = tonumber(m.bitrate) and m.bitrate * 1000,
    }, audio = {}, subs = {}}
    for _, s in ipairs(type(part.Stream) == "table" and part.Stream or {}) do
        local st = tonumber(s.streamType)
        if st == 1 and not d.video then
            local display = tostring(s.displayTitle or "") .. " " .. tostring(s.extendedDisplayTitle or "")
            d.video = {codec = s.codec, profile = s.profile and (tostring(s.profile):gsub("^%l", string.upper)),
                       width = tonumber(s.width) or tonumber(m.width), height = tonumber(s.height) or tonumber(m.height),
                       fps = tonumber(s.frameRate), bit_depth = tonumber(s.bitDepth),
                       primaries = s.colorPrimaries and tostring(s.colorPrimaries):lower(),
                       transfer = s.colorTrc and tostring(s.colorTrc):lower(),
                       dv_profile = (s.DOVIPresent == true or s.DOVIPresent == 1 or s.DOVIPresent == "1")
                           and s.DOVIProfile or nil,
                       hdr10plus = display:find("HDR10%+") ~= nil,
                       bitrate = tonumber(s.bitrate) and s.bitrate * 1000}
        elseif st == 2 then
            -- Plex calls DTS by its FFmpeg name "dca".
            local codec = s.codec == "dca" and "dts" or s.codec
            d.audio[#d.audio + 1] = {lang = s.languageTag or s.languageCode, title = s.title, codec = codec,
                                     profile = s.profile and tostring(s.profile):upper(),
                                     layout = s.audioChannelLayout, channels = s.channels,
                                     default = s.default == true or s.default == 1,
                                     display = s.extendedDisplayTitle or s.displayTitle}
        elseif st == 3 then
            d.subs[#d.subs + 1] = {lang = s.languageTag or s.languageCode, title = s.title, codec = s.codec,
                                   forced = s.forced == true or s.forced == 1,
                                   sdh = s.hearingImpaired == true or s.hearingImpaired == 1,
                                   default = s.default == true or s.default == 1,
                                   external = s.key ~= nil}
        end
    end
    return d
end

-- Normalized description of a Jellyfin item from its full metadata
-- (GET /Items/<id>: MediaSources with MediaStreams). `source`: see server_source.
function M.from_jellyfin(it, source)
    local ms = type(it.MediaSources) == "table" and it.MediaSources[1] or {}
    local path = type(ms.Path) == "string" and ms.Path or (type(it.Path) == "string" and it.Path) or nil
    local ticks = tonumber(ms.RunTimeTicks or it.RunTimeTicks)
    local d = {file = {
        source = source, name = path and util.basename(path) or it.Name,
        folder = path and util.dirname(path),
        size = tonumber(ms.Size), duration = ticks and ticks / 1e7,
        container = ms.Container and tostring(ms.Container):upper(),
        bitrate = tonumber(ms.Bitrate),
    }, audio = {}, subs = {}}
    for _, s in ipairs(type(ms.MediaStreams) == "table" and ms.MediaStreams or {}) do
        if s.Type == "Video" and not d.video then
            local range = tostring(s.VideoRangeType or "")
            d.video = {codec = s.Codec and tostring(s.Codec):lower(),
                       profile = s.Profile and (tostring(s.Profile):gsub("^%l", string.upper)),
                       width = tonumber(s.Width), height = tonumber(s.Height),
                       fps = tonumber(s.RealFrameRate) or tonumber(s.AverageFrameRate),
                       bit_depth = tonumber(s.BitDepth),
                       primaries = s.ColorPrimaries and tostring(s.ColorPrimaries):lower(),
                       -- Without a transfer from the server's probe, the
                       -- range type ("HDR10", "DOVIWithHLG"…) still says it.
                       transfer = s.ColorTransfer and tostring(s.ColorTransfer):lower()
                           or (range:find("HDR10") and "smpte2084")
                           or (range:find("HLG") and "arib-std-b67") or nil,
                       dv_profile = tonumber(s.DvProfile),
                       hdr10plus = range:find("HDR10Plus") ~= nil,
                       bitrate = tonumber(s.BitRate)}
        elseif s.Type == "Audio" then
            d.audio[#d.audio + 1] = {lang = s.Language, title = s.Title, codec = s.Codec and tostring(s.Codec):lower(),
                                     profile = s.Profile, layout = s.ChannelLayout, channels = s.Channels,
                                     default = s.IsDefault == true, display = s.DisplayTitle}
        elseif s.Type == "Subtitle" then
            d.subs[#d.subs + 1] = {lang = s.Language, title = s.Title, codec = s.Codec and tostring(s.Codec):lower(),
                                   forced = s.IsForced == true, sdh = s.IsHearingImpaired == true,
                                   default = s.IsDefault == true, external = s.IsExternal == true}
        end
    end
    return d
end

---------------------------------------------------------------------------
-- Reading (ffprobe / Plex / Jellyfin) and the panel
---------------------------------------------------------------------------

local function ffprobe(args, cb)
    local cmd = {"ffprobe", "-v", "error", "-print_format", "json"}
    for _, a in ipairs(args) do cmd[#cmd + 1] = a end
    mp.command_native_async({name = "subprocess", args = cmd, capture_stdout = true,
                             capture_stderr = true, playback_only = false}, function(ok, r)
        local data = ok and r and r.status == 0 and utils.parse_json(r.stdout or "")
        cb(type(data) == "table" and data or nil, r and r.stderr)
    end)
end

-- cb(description or nil, err). Two quick runs: streams and container, then
-- the first video frame (one frame decoded: colours, HDR10+, brightness).
function M.probe_local(path, cb)
    -- Paths in the library are absolute, so never taken for an option.
    if path:sub(1, 1) ~= "/" then return cb(nil, "not a local file") end
    ffprobe({"-show_format", "-show_streams", path}, function(probe, err)
        if not probe then return cb(nil, (err and err ~= "") and util.trim(err) or "Can't read this file") end
        local video
        for _, s in ipairs(probe.streams or {}) do
            if s.codec_type == "video" and not (s.disposition and s.disposition.attached_pic == 1) then
                video = s.index
                break
            end
        end
        if not video then return cb(M.from_ffprobe(probe, nil, path)) end
        ffprobe({"-select_streams", tostring(video), "-read_intervals", "%+#1", "-show_frames", path}, function(frame)
            cb(M.from_ffprobe(probe, frame, path))
        end)
    end)
end

-- Opens the panel for a library entry: a local file, or a media server
-- item (an entry with `server` or `server_recent`, dvp/servers.lua).
-- `source`: the Source row of a local file (library.source_label).
function M.open(ctx, entry, source)
    local spec = {title = "Video info", subtitle = entry.label, style = "side", wide = true,
                  items = {{label = "Reading…", disabled = true}}}
    ctx.menu:open(spec)
    local function show(d, err)
        -- The cursor (it only serves to scroll long values) starts on the
        -- first row under the "File" header.
        ctx.menu:update(spec, {items = d and M.items(M.sections(d))
                                    or {{label = err or "Not available", disabled = true}}})
    end
    local ref = entry.server or entry.server_recent
    local backend = ctx.servers:for_ref(ref)
    if backend then
        backend:video_info(ref, show)
    else
        M.probe_local(entry.path, function(d, err)
            if d then d.file.source = source end
            show(d, err)
        end)
    end
end

return M
