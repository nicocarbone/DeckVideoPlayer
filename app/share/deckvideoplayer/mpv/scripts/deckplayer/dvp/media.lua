-- Human-readable descriptions of tracks, codecs and HDR state.

local M = {}

local LANGS = {
    en = "English", eng = "English",
    es = "Spanish", spa = "Spanish",
    fr = "French", fre = "French", fra = "French",
    de = "German", ger = "German", deu = "German",
    it = "Italian", ita = "Italian",
    pt = "Portuguese", por = "Portuguese",
    ja = "Japanese", jpn = "Japanese",
    ko = "Korean", kor = "Korean",
    zh = "Chinese", chi = "Chinese", zho = "Chinese",
    ru = "Russian", rus = "Russian",
    nl = "Dutch", dut = "Dutch", nld = "Dutch",
    sv = "Swedish", swe = "Swedish",
    no = "Norwegian", nor = "Norwegian", nb = "Norwegian", nob = "Norwegian",
    da = "Danish", dan = "Danish",
    fi = "Finnish", fin = "Finnish",
    pl = "Polish", pol = "Polish",
    cs = "Czech", cze = "Czech", ces = "Czech",
    hu = "Hungarian", hun = "Hungarian",
    el = "Greek", gre = "Greek", ell = "Greek",
    tr = "Turkish", tur = "Turkish",
    ar = "Arabic", ara = "Arabic",
    he = "Hebrew", heb = "Hebrew",
    hi = "Hindi", hin = "Hindi",
    th = "Thai", tha = "Thai",
    vi = "Vietnamese", vie = "Vietnamese",
    id = "Indonesian", ind = "Indonesian",
    uk = "Ukrainian", ukr = "Ukrainian",
    ro = "Romanian", rum = "Romanian", ron = "Romanian",
    ca = "Catalan", cat = "Catalan",
    eu = "Basque", baq = "Basque", eus = "Basque",
    gl = "Galician", glg = "Galician",
    und = "Unknown",
}

local CODECS = {
    truehd = "TrueHD", eac3 = "E-AC-3", ac3 = "AC-3", dts = "DTS", aac = "AAC",
    opus = "Opus", flac = "FLAC", mp3 = "MP3", vorbis = "Vorbis", alac = "ALAC",
    pcm_s16le = "PCM", pcm_s24le = "PCM", pcm_s32le = "PCM", pcm_bluray = "PCM",
    subrip = "SRT", ass = "ASS", ssa = "SSA", hdmv_pgs_subtitle = "PGS",
    dvd_subtitle = "VobSub", mov_text = "Text", webvtt = "WebVTT", dvb_subtitle = "DVB",
    hevc = "HEVC", h264 = "H.264", av1 = "AV1", vp9 = "VP9", vp8 = "VP8",
    mpeg2video = "MPEG-2", mpeg4 = "MPEG-4", vc1 = "VC-1", prores = "ProRes",
}

function M.language(code)
    if not code or code == "" then return nil end
    return LANGS[code:lower()] or code:upper()
end

function M.codec(name, profile)
    if not name then return "?" end
    if name == "dts" and profile and profile ~= "" then
        if profile:find("MA") then return "DTS-HD MA" end
        if profile:find("HRA") or profile:find("HD") then return "DTS-HD" end
        if profile:find("X") then return "DTS:X" end
    end
    return CODECS[name] or name:upper()
end

local function channels(n)
    if not n then return nil end
    if n == 1 then return "Mono" end
    if n == 2 then return "Stereo" end
    if n == 6 then return "5.1" end
    if n == 8 then return "7.1" end
    return n .. "ch"
end

-- "English · Commentary · AC-3 5.1"
function M.track_label(t)
    local parts = {}
    local lang = M.language(t.lang)
    if lang then parts[#parts + 1] = lang end
    if t.title and t.title ~= "" and t.title ~= lang then parts[#parts + 1] = t.title end
    if #parts == 0 then parts[1] = "Track " .. t.id end
    return table.concat(parts, " · ")
end

function M.track_detail(t)
    local parts = {M.codec(t.codec, t["codec-profile"])}
    if t.type == "audio" then
        parts[#parts + 1] = channels(t["demux-channel-count"])
    end
    if t.forced then parts[#parts + 1] = "Forced" end
    if t["hearing-impaired"] then parts[#parts + 1] = "SDH" end
    if t.default then parts[#parts + 1] = "Default" end
    if t.external then parts[#parts + 1] = "External" end
    return table.concat(parts, " · ")
end

function M.tracks(kind)
    local out = {}
    for _, t in ipairs(mp.get_property_native("track-list") or {}) do
        if t.type == kind then out[#out + 1] = t end
    end
    return out
end

function M.selected_track(kind)
    for _, t in ipairs(M.tracks(kind)) do
        if t.selected then return t end
    end
    return nil
end

-- Describes the HDR state of the current video:
-- source = "HDR10" | "HLG" | "Dolby Vision" | "SDR" | nil, output_hdr = bool
-- `video_track` may be passed (cached by the caller) to avoid re-reading
-- the whole track-list.
function M.hdr_state(video_track)
    local vp = mp.get_property_native("video-params") or {}
    local target = mp.get_property_native("video-target-params") or {}
    local vt = video_track or M.selected_track("video") or {}
    local source
    if vt["dolby-vision-profile"] then
        source = "Dolby Vision"
    elseif vp.gamma == "pq" then
        source = "HDR10"
    elseif vp.gamma == "hlg" then
        source = "HLG"
    elseif vp.gamma then
        source = "SDR"
    end
    local out_gamma = target.gamma or (target.params and target.params.gamma)
    local output_hdr = out_gamma == "pq" or out_gamma == "hlg"
    return source, output_hdr, vp, target
end

-- "4K" / "1080p" etc. from the video's pixel size.
function M.resolution_badge(w, h)
    if not w or not h then return nil end
    if w >= 3800 or h >= 2100 then return "4K" end
    if w >= 2500 or h >= 1400 then return "1440p" end
    if w >= 1900 or h >= 1000 then return "1080p" end
    if w >= 1200 or h >= 700 then return "720p" end
    return h .. "p"
end

return M
