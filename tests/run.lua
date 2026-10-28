-- Unit tests for the pure-logic modules. Runs inside mpv's Lua so the
-- mp.* API is available:
--
--   tests/run.sh
--
-- Exits mpv with status 0 on success, 1 on failure.

local here = mp.get_script_directory and mp.get_script_directory()
    or debug.getinfo(1, "S").source:match("@(.*)/[^/]*$")
local root = here .. "/../app/share/deckvideoplayer/mpv/scripts/deckplayer"
package.path = root .. "/?.lua;" .. package.path

local util = require "dvp.util"
local config = require "dvp.config"
local display = require "dvp.display"
local library = require "dvp.library"
local Resume = require "dvp.resume"
local media = require "dvp.media"
local Surround = require "dvp.surround"
local OS = require "dvp.opensubtitles"
local SubDL = require "dvp.subdownload"

local failures, count = 0, 0

local function check(name, cond, detail)
    count = count + 1
    if not cond then
        failures = failures + 1
        print("FAIL " .. name .. (detail and (": " .. detail) or ""))
    end
end

local function eq(name, got, want)
    check(name, got == want, string.format("got %s, want %s", tostring(got), tostring(want)))
end

-- Every module parses, also those the tests below don't load (browser,
-- player, main…): a syntax error there would only show when the app starts.
do
    local utils = require "mp.utils"
    local files = {root .. "/main.lua"}
    for _, name in ipairs(utils.readdir(root .. "/dvp", "files") or {}) do
        if name:match("%.lua$") then files[#files + 1] = root .. "/dvp/" .. name end
    end
    for _, f in ipairs(files) do
        local ok, err = loadfile(f)
        check("parses " .. f:match("[^/]+/[^/]+$"), ok ~= nil, err)
    end
    check("modules found", #files > 20)
    -- No accidental globals (a typo or a local declared after its use reads
    -- a global nil): checked in the bytecode where LuaJIT's jit.bc exists
    -- (the Flatpak's mpv); skipped elsewhere.
    local has_bc, bc = pcall(require, "jit.bc")
    if has_bc then
        local allowed = {}
        for n in ([[mp require string table math os io tostring tonumber type pairs ipairs select pcall error
            setmetatable getmetatable print collectgarbage next unpack rawget rawset rawequal debug package
            jit assert xpcall bit load loadfile loadstring _G _VERSION testing]]):gmatch("%S+") do
            allowed[n] = true
        end
        for _, f in ipairs(files) do
            local fn = loadfile(f)
            if fn then
                local out, bad = {}, {}
                bc.dump(fn, {write = function(_, t) out[#out + 1] = t end, flush = function() end}, true)
                for op, name in table.concat(out):gmatch("(G[GS]ET)%s+%d+%s+%d+%s*;%s*\"([^\"]+)\"") do
                    if op ~= "GGET" or not allowed[name] then bad[#bad + 1] = op .. " " .. name end
                end
                check("no stray globals in " .. f:match("[^/]+$"), #bad == 0, table.concat(bad, ", "))
            end
        end
    end
end

-- util ------------------------------------------------------------------
eq("format_time short", util.format_time(65), "1:05")
eq("format_time hours", util.format_time(3725), "1:02:05")
eq("format_time forced", util.format_time(65, true), "0:01:05")
eq("format_time nil", util.format_time(nil), "0:00")
check("natural order", util.natural_key("Episode 2") < util.natural_key("Episode 10"))
check("natural case", util.natural_key("apple") < util.natural_key("Banana"))
eq("utf8_len", util.utf8_len("Españolá"), 8)
eq("utf8_truncate", util.utf8_truncate("Mañana es otro día", 7), "Mañana…")
eq("utf8_truncate fits", util.utf8_truncate("corto", 10), "corto")
eq("extension", util.extension("Movie.Name.MKV"), "mkv")
eq("strip_extension", util.strip_extension("a.b.mkv"), "a.b")
eq("basename", util.basename("/a/b/c/"), "c")
eq("dirname", util.dirname("/a/b/c"), "/a/b")
eq("ass_escape", util.ass_escape("{x}\\n"), "\\{x}\\\239\187\191n")
eq("expand_path", util.expand_path("~/Videos/"), (os.getenv("HOME") or "") .. "/Videos")
local parts = util.split("a; b ;;c", ";")
eq("split count", #parts, 3)
eq("split item", parts[2], "b")

-- config ------------------------------------------------------------------
local cfg, warnings = config.from_text([[
# comment
[library]
folder = ~/Videos
folder = /run/media/deck/SD/Movies ; /mnt/nas
removable_media = no

[playback]
seek_short = 5
subtitles = ALWAYS
resume = maybe
bogus = 1

[display]
refresh_prefer = high
]])
eq("folders", #cfg.library.folder, 3)
eq("folder 3", cfg.library.folder[3], "/mnt/nas")
eq("bool", cfg.library.removable_media, false)
eq("number", cfg.playback.seek_short, 5)
eq("enum case-insensitive", cfg.playback.subtitles, "always")
eq("invalid bool falls back", cfg.playback.resume, true)
eq("enum", cfg.display.refresh_prefer, "high")
eq("default kept", cfg.playback.seek_long, 60)
eq("warnings", #warnings, 2)
local dcfg = config.from_text("")
eq("default folder", dcfg.library.folder[1], "~/Videos")

-- display -----------------------------------------------------------------
local oled = display.parse_rates("45,47,48,49,50,51,53,55,56,59,60,62,64,65,66,68,72,73,76,77,78,80,81,82,84,85,86,87,88,90")
eq("23.976 low", display.choose_rate(24000 / 1001, oled, "low"), 48)
eq("23.976 high", display.choose_rate(24000 / 1001, oled, "high"), 72)
eq("24 low", display.choose_rate(24, oled, "low"), 48)
eq("25 low", display.choose_rate(25, oled, "low"), 50)
eq("25 high (no 75 on OLED)", display.choose_rate(25, oled, "high"), 50)
eq("29.97 high", display.choose_rate(30000 / 1001, oled, "high"), 90)
eq("50 fps", display.choose_rate(50, oled, "low"), 50)
eq("59.94 fps", display.choose_rate(60000 / 1001, oled, "low"), 60)
eq("unmatched", display.choose_rate(23.5, display.parse_rates("40-44"), "low"), nil)
local lcd = display.parse_rates("40-60")
eq("lcd range size", #lcd, 21)
eq("lcd 24", display.choose_rate(24, lcd, "low"), 48)
eq("lcd 30", display.choose_rate(30, lcd, "low"), 60)
eq("no fps", display.choose_rate(nil, lcd, "low"), nil)
local hi = display.parse_helper_info("connector=eDP-1 internal=1 only_refresh=1 rates=45,47,48,90\n")
eq("helper connector", hi.connector, "eDP-1")
check("helper internal", hi.internal)
eq("helper rates", #hi.rates, 4)
eq("helper rate pick", display.choose_rate(24, hi.rates, "low"), 48)
local hx = display.parse_helper_info("connector=HDMI-A-1 internal=0 only_refresh=1 rates=")
check("helper external", not hx.internal)
eq("helper no rates", #hx.rates, 0)

-- library ------------------------------------------------------------------
eq("display_name clean", library.display_name("The.Movie.2019.1080p.mkv", false, true), "The Movie 2019 1080p")
eq("display_name spaces kept", library.display_name("My Movie (2019).mkv", false, true), "My Movie (2019)")
eq("display_name raw", library.display_name("A_B.mkv", false, false), "A_B")
eq("display_name dir", library.display_name("Season.1", true, true), "Season 1")
local mi = table.concat({
    "22 1 0:21 / /proc rw - proc proc rw",
    "120 30 179:1 / /run/media/deck/SD\\040Card rw - ext4 /dev/mmcblk0p1 rw",
    "121 30 8:1 / /run/media/deck rw - tmpfs tmpfs rw",
    "122 30 8:2 / /media/usb rw - vfat /dev/sdb1 rw",
}, "\n")
local points = library.parse_mountinfo(mi)
eq("mountinfo count (tmpfs skipped)", #points, 2)
eq("mountinfo escape", points[1].path, "/run/media/deck/SD Card")
eq("mountinfo source", points[1].source, "/dev/mmcblk0p1")
local function rinfo(path, source)
    local kind, name = library.removable_info(path, source)
    return kind .. "|" .. name
end
eq("sd uuid", rinfo("/run/media/deck/9f3b6c2e-1d4a-4b7e-8c21-5a6e7f8091ab", "/dev/mmcblk0p1"), "sdcard|SD Card")
eq("sd serial", rinfo("/run/media/deck/1A2B-3C4D", "/dev/mmcblk0p1"), "sdcard|SD Card")
eq("sd kernel name", rinfo("/run/media/mmcblk0p1", "/dev/mmcblk0p1"), "sdcard|SD Card")
eq("sd labelled", rinfo("/run/media/deck/Movies", "/dev/mmcblk0p1"), "sdcard|SD Card (Movies)")
eq("usb labelled", rinfo("/run/media/deck/KINGSTON", "/dev/sdb1"), "usb|KINGSTON")
eq("usb unlabelled", rinfo("/run/media/deck/0123-4567", "/dev/sda1"), "usb|USB drive")
eq("other", rinfo("/media/nas", "server:/export"), "removable|nas")

-- resume -------------------------------------------------------------------
check("finished near end", Resume.is_finished(3550, 3600))
check("not finished", not Resume.is_finished(3000, 3600))
check("short clip finished", Resume.is_finished(38, 40))
check("short clip not finished", not Resume.is_finished(20, 40))
local r = Resume.new(nil)
r:update("/x.mkv", 100, 3600, "2", "no")
eq("resume position", r:position("/x.mkv"), 100)
r:update("/x.mkv", 10, 3600, "2", "no")
eq("too early", r:position("/x.mkv"), nil)
r:update("/x.mkv", 3590, 3600, "2", "no")
check("watched", r:is_watched("/x.mkv"))
eq("watched has no position", r:position("/x.mkv"), nil)

-- recently played: newest first, gone files skipped, marking isn't playing
local rr = Resume.new(nil)
rr.entries = {
    ["/old.mkv"] = {t = 100, pos = 50},            -- entry from before v0.3.1
    ["/a.mkv"] = {t = 300, played = 300},
    ["/b.mkv"] = {t = 200, played = 200},
    ["/gone.mkv"] = {t = 400, played = 400},
    ["/hidden.mkv"] = {t = 500, played = false},
}
local exists = function(p) return p ~= "/gone.mkv" end
eq("recent order", table.concat(rr:recent(5, exists), " "), "/a.mkv /b.mkv /old.mkv")
eq("recent limit", table.concat(rr:recent(2, exists), " "), "/a.mkv /b.mkv")
eq("recent off", #rr:recent(0, exists), 0)
rr:mark_watched("/new.mkv")
check("marked not recent", rr.entries["/new.mkv"].played == false)
rr:hide_recent("/a.mkv")
eq("hidden keeps position", rr.entries["/a.mkv"].t, 300)
eq("hide recent", table.concat(rr:recent(5, exists), " "), "/b.mkv /old.mkv")
rr:update("/a.mkv", 100, 3600)
eq("played again is recent", rr:recent(1, exists)[1], "/a.mkv")
rr:mark_unwatched("/a.mkv")
check("unwatched stays recent", rr:recent(1, exists)[1] == "/a.mkv" and not rr:position("/a.mkv"))
rr:mark_unwatched("/new.mkv")
eq("unwatched never played dropped", rr.entries["/new.mkv"], nil)
-- entries from before v0.3.1 (no `played`): marking keeps their place
local legacy = Resume.new(nil)
legacy.entries = {["/l.mkv"] = {t = 100, pos = 50, duration = 3600}, ["/n.mkv"] = {t = 200, played = 200}}
legacy:mark_watched("/l.mkv")
eq("legacy watched keeps place", table.concat(legacy:recent(5), " "), "/n.mkv /l.mkv")
legacy.entries["/m.mkv"] = {t = 50, pos = 60, duration = 3600}
legacy:mark_unwatched("/m.mkv")
check("legacy unwatched stays recent", legacy.entries["/m.mkv"] ~= nil and legacy.entries["/m.mkv"].played == 50)

-- media --------------------------------------------------------------------
eq("lang", media.language("spa"), "Spanish")
eq("lang unknown", media.language("xyz"), "XYZ")
eq("lang und", media.language("und"), nil)
eq("label und uses title", media.track_label({id = 1, lang = "und", title = "Stereo mix"}), "Stereo mix")
eq("label und no title", media.track_label({id = 3, lang = "und"}), "Track 3")
eq("codec dts-hd", media.codec("dts", "DTS-HD MA"), "DTS-HD MA")
eq("track label", media.track_label({id = 1, lang = "eng", title = "Commentary"}), "English · Commentary")
eq("track detail", media.track_detail({type = "audio", codec = "truehd", ["demux-channel-count"] = 8, default = true}),
    "TrueHD · 7.1 · Default")
eq("res 4k", media.resolution_badge(3840, 1600), "4K")
eq("res 1080p scope", media.resolution_badge(1920, 800), "1080p")

eq("external sub detail", media.track_detail({type = "sub", codec = "subrip", external = true, forced = true}),
    "External · Forced")
eq("lang pt-br", media.language("pt-br"), "Portuguese (Brazil)")

local sbc, sbp = media.sub_brightness(1, 203)
eq("sub brightness full", sbc .. " " .. sbp, "#FFFFFF 203")
sbc, sbp = media.sub_brightness(0.5, 203)
eq("sub brightness half", sbc .. " " .. sbp, "#808080 44")
eq("sub brightness floor", select(2, media.sub_brightness(0.3, 20)), 10)

-- surround -----------------------------------------------------------------
eq("lavfi escape", Surround.escape_lavfi("/a b:c,[d]'e\\f"), "/a b\\\\:c\\,\\[d\\]\\\\\\'e\\\\\\\\f")
local fstr = Surround.filter_string("/x/h.sofa", 6)
local graph = "sofalizer=sofa=/x/h.sofa:gain=0:lfegain=3:type=freq,volume=12.5dB,"
    .. "alimiter=limit=0.891:attack=5:release=50:level=0"
eq("surround filter", fstr, "@dvp-surround:lavfi=graph=%" .. #graph .. "%" .. graph)
-- 5.1 surrounds at 120° (D57), by layout index; 7.1 keeps sofalizer's positions
local g51 = Surround.filter_string("/x/h.sofa", 6, "5.1(side)")
eq("surround 5.1 speakers", g51:find(":type=freq:speakers=4 120|5 240,volume=12.5dB,", 1, true) ~= nil, true)
eq("surround 5.1 back speakers", Surround.filter_string("/x/h.sofa", 6, "5.1"):find("speakers=4 120|5 240", 1, true) ~= nil, true)
eq("surround 7.1 default speakers", Surround.filter_string("/x/h.sofa", 8, "7.1"):find("speakers", 1, true), nil)
-- sofalizer takes 3 dB per input channel: same dialogue level for any layout
eq("surround gain 7.1", Surround.gain(8), 18.5)
eq("surround gain 4.0", Surround.gain(4), 6.5)

-- intro / credits markers (D47) --------------------------------------------------
local Markers = require "dvp.markers"
local mks = Markers.from_plex({Marker = {
    {type = "credits", startTimeOffset = 2580000, endTimeOffset = 2645000, final = true},
    {type = "intro", startTimeOffset = 499000, endTimeOffset = 559000},
    {type = "commercial", startTimeOffset = 1000000, endTimeOffset = 1060000},
    {type = "intro", startTimeOffset = 10000, endTimeOffset = 10500},   -- too short
}})
eq("markers kept", #mks, 2)
eq("markers sorted", mks[1].kind .. " " .. mks[2].kind, "intro credits")
eq("marker seconds", mks[1].start .. "-" .. mks[1].stop, "499-559")
eq("no markers", #Markers.from_plex({}), 0)
eq("at intro", Markers.at(mks, 500), mks[1])
eq("before intro", Markers.at(mks, 498.9), nil)
eq("intro last second", Markers.at(mks, 558.5), nil)
eq("at credits", Markers.at(mks, 2600), mks[2])
eq("skip intro", Markers.action(mks[1], true, true).target, 559)
eq("next episode", Markers.action(mks[2], true, true).label, "Next episode")
eq("next video", Markers.action(mks[2], true, false).label, "Next video")
eq("credits at the end", Markers.action(mks[2], false, true).label, "Skip credits")
eq("mid-film credits", Markers.action({kind = "credits", start = 10, stop = 20, final = false}, true, true).label,
    "Skip credits")

-- night mode (D46) ---------------------------------------------------------------
local NightMode = require "dvp.nightmode"
eq("night filter", NightMode.filter_string("acompressor"), "@dvp-night:lavfi=graph=%11%acompressor")
check("night graph", NightMode.GRAPH:match("^acompressor=.*,alimiter=.*level=0$") ~= nil)
-- the detector follows the loudest channel, or centre-only dialogue in 5.1
-- would be measured 15 dB low (ISSUES.md Part VI 1.1)
check("night link max", NightMode.GRAPH:match("acompressor=[^,]*link=maximum") ~= nil)

-- opensubtitles ---------------------------------------------------------------
local function bytes(n, f)
    local t = {}
    for i = 0, n - 1 do t[#t + 1] = string.char(f(i)) end
    return table.concat(t)
end
local head = bytes(65536, function(i) return (i * 7 + 3) % 256 end)
local tail = bytes(65536, function(i) return (i * 13 + 5) % 256 end)
-- Expected values computed with the reference Python implementation.
eq("moviehash >4GiB", OS.moviehash_from(5000000123, head, tail), "20a01fa149a5f27b")
local ff = string.rep("\255", 65536)
eq("moviehash wraps", OS.moviehash_from(200000, ff, ff), "000000000002cd40")

local function release(path)
    local r = OS.parse_release(path)
    return string.format("%s|%s|%s|%s", r.title, tostring(r.year), tostring(r.season), tostring(r.episode))
end
eq("release movie", release("/v/The.Test.Movie.2024.1080p.BluRay.x264.mkv"), "The Test Movie|2024|nil|nil")
eq("release parens", release("/v/A Long Film (2023).mkv"), "A Long Film|2023|nil|nil")
eq("release year title", release("/v/2001.A.Space.Odyssey.1968.mkv"), "2001 A Space Odyssey|1968|nil|nil")
eq("release no year", release("/v/Charlotte's Web.mkv"), "Charlotte's Web|nil|nil|nil")
eq("release junk", release("/v/Movie.Name.WEB-DL.mkv"), "Movie Name|nil|nil|nil")
eq("release episode", release("/v/Show.Name.S02E05.720p.mkv"), "Show Name|nil|2|5")
eq("release 1x02", release("/v/Show Name - 1x02 - Pilot.mkv"), "Show Name|nil|1|2")
eq("release folder", release("/v/Series/Great Show (2019)/Season 1/S01E03.mkv"), "Great Show|nil|1|3")
eq("release group tag", release("/v/[Group] Anime Title - S01E12.mkv"), "Anime Title|nil|1|12")

eq("languages map", table.concat(OS.languages("spa, eng,pob"), ","), "es,en,pt-br")
eq("languages default", table.concat(OS.languages(""), ","), "en")
eq("languages dedupe", table.concat(OS.languages("en,eng,xx-yy"), ","), "en,xx-yy")
eq("query string", OS.query_string({query = "Show Name & Co", languages = "en,es", season_number = 2}),
    "languages=en%2Ces&query=show+name+%26+co&season_number=2")
eq("curl quote", OS.curl_quote('a"b\\c\nd'), '"a\\"b\\\\c\\nd"')

local parsed = OS.parse_results({data = {
    {attributes = {language = "EN", release = "Rel.A", download_count = 1500, moviehash_match = true,
                   files = {{file_id = 1, file_name = "a.srt"}}}},
    {attributes = {language = "es", release = "", download_count = 10, hearing_impaired = true,
                   files = {{file_id = 2, file_name = "b.srt"}}}},
    {attributes = {language = "en", release = "Rel.C", download_count = 90000, files = {}}},
    {attributes = {language = "en", release = "Rel.D", download_count = 90000, ai_translated = true,
                   files = {{file_id = 4}}}},
    {attributes = {language = "en", release = "Rel.E", download_count = 5,
                   files = {{file_id = 5}}}},
}})
eq("results parsed", #parsed, 4)
eq("results release fallback", parsed[2].release, "b.srt")
local ranked = OS.rank({parsed, {parsed[1]}}, {"es", "en"})
eq("rank dedupe", #ranked, 4)
eq("rank language first", ranked[1].file_id, 2)
eq("rank exact match", ranked[2].file_id, 1)
eq("rank human before machine", ranked[3].file_id, 5)
eq("result value exact", OS.result_value(parsed[1]), "Exact")
eq("result value sdh", OS.result_value(parsed[2]), "SDH")
eq("result value count", OS.result_value({downloads = 1500}), "1.5k ↓")
eq("result value round count", OS.result_value({downloads = 2000}), "2k ↓")
eq("error quota", OS.error_message(406, {reset_time = "5 hours"}), "Daily download limit reached (resets in 5 hours)")
eq("error login", OS.error_message(401, nil, "login"), "OpenSubtitles login failed: check username and password")
eq("error network", OS.error_message(nil, "No internet connection"), "No internet connection")

eq("sub file name", SubDL.file_name("Rel/Name: Cut?.srt", "pt-br", 123), "Rel Name Cut #123.pt-br.srt")
eq("sub file name empty", SubDL.file_name("", "en", 7), "Subtitles #7.en.srt")
eq("sub file name no id", SubDL.file_name("A", "en"), "A.en.srt")
local pid = SubDL.parse_file_name("The.Movie.2024 #9876.en.srt")
check("parse sub file id", pid.title == "The.Movie.2024" and pid.file_id == "9876" and pid.lang == "en",
    tostring(pid.title) .. "|" .. tostring(pid.file_id))
local pf = SubDL.parse_file_name("The.Movie.2024.WEB.en.srt")
eq("parse sub file title", pf.title, "The.Movie.2024.WEB")
eq("parse sub file lang", pf.lang, "en")
eq("parse sub file lang region", SubDL.parse_file_name("X.pt-br.srt").lang, "pt-br")

-- ui text measuring -----------------------------------------------------------
local ui = require "dvp.ui"
check("width wide > narrow", ui.text_width("WWWW", 20) > 2 * ui.text_width("iiii", 20))
check("width bold wider", ui.text_width("Movie", 20, true) > ui.text_width("Movie", 20))
-- Calibrated on a real render: this 96-char string is ~955 units at size 23.
local measured = "English · The.Movie.Title.2024.1080p.BluRay.x264.DTS-HD.MA.5.1-SOMEGROUP.Extra.Long.Release.Name"
local est = ui.text_width(measured, 23)
check("width calibration", est > 900 and est < 1010, tostring(est))
eq("fit keeps short", ui.fit_text("Short", 20, 500), "Short")
local w1x = ui.text_width("1x", 23)
eq("fit exact width", ui.fit_text("1x", 23, (w1x + 44) - 44), "1x")
local fitted = ui.fit_text(measured, 23, 300)
check("fit ends with ellipsis", fitted:sub(-3) == "…", fitted)
check("fit within width", ui.text_width(fitted, 23) <= 300, tostring(ui.text_width(fitted, 23)))
check("fit capitals shorter", util.utf8_len(ui.fit_text(string.rep("W", 60), 20, 200))
    < util.utf8_len(ui.fit_text(string.rep("i", 60), 20, 200)))
eq("marquee rests first", ui.marquee_offset(0.5, 100), 0)
check("marquee scrolls", ui.marquee_offset(2.0, 100) > 0)
eq("marquee stops at end", ui.marquee_offset(1.2 + 100 / 45 + 0.5, 100), 100)
eq("marquee finishes", ui.marquee_offset(1000, 100), nil)

-- http ------------------------------------------------------------------------
local http = require "dvp.http"
local cfgtext = http.curl_config({url = "https://x/y?a=1", headers = {["X-Token"] = 'se"cret'},
                                  method = "POST", timeout = 7})
check("curl url", cfgtext:find('url = "https://x/y?a=1"', 1, true) ~= nil, cfgtext)
check("curl header quoted", cfgtext:find('header = "X-Token: se\\"cret"', 1, true) ~= nil, cfgtext)
check("curl method", cfgtext:find('request = "POST"', 1, true) ~= nil)
check("curl timeout", cfgtext:find("max-time = 7", 1, true) ~= nil)
check("curl no redirects by default", http.curl_config({url = "u"}):find("location", 1, true) == nil)
check("curl follow on request", http.curl_config({url = "u", follow = true}):find("location", 1, true) ~= nil)
check("curl http(s) only", cfgtext:find('proto = "=http,https"', 1, true) ~= nil)
check("curl https-only redirects", cfgtext:find('proto-redir = "=https"', 1, true) ~= nil)
check("curl max size", http.curl_config({url = "u", max_size = 99}):find("max-filesize = 99", 1, true) ~= nil)
local code, body = http.parse_result({status = 0, stdout = '{"a":1}\n200'})
check("http parse json", code == 200 and type(body) == "table" and body.a == 1)
code, body = http.parse_result({status = 7, stderr = "x"})
check("http parse failure", code == nil and body == "Cannot connect to the server", tostring(body))
eq("http query", http.query_string({b = "x y", a = "Z"}), "a=Z&b=x+y")

-- library sort ------------------------------------------------------------------
local ents = library.sort_entries({
    {label = "E10 · Ten", is_dir = false, mtime = 1}, {label = "E2 · Two", is_dir = false, mtime = 3},
    {label = "Season 1", is_dir = true}, {label = "Abyss", name = "Abyss", sort_name = nil, is_dir = false, mtime = 2},
}, "name")
eq("sort dirs first", ents[1].label, "Season 1")
eq("sort natural", ents[2].label .. "|" .. ents[3].label .. "|" .. ents[4].label, "Abyss|E2 · Two|E10 · Ten")
library.sort_entries(ents, "date")
eq("sort by date", ents[2].label, "E2 · Two")

-- plex ------------------------------------------------------------------------
local Plex = require "dvp.plex"
local servers = Plex.parse_resources({
    {name = "Home", clientIdentifier = "m1", provides = "server", owned = true, accessToken = "st",
     connections = {
        {uri = "https://172-17-0-1.x.plex.direct:32400", address = "172.17.0.1", port = 32400, ["local"] = true},
        {uri = "https://10-0-0-20.x.plex.direct:32400", address = "10.0.0.20", port = 32400, ["local"] = true},
        {uri = "https://1-2-3-4.x.plex.direct:21723", address = "1.2.3.4", port = 21723, ["local"] = false},
        {uri = "https://9-9-9-9.x.plex.direct:8443", address = "9.9.9.9", port = 8443, ["local"] = false, relay = true},
     }},
    {name = "Phone", clientIdentifier = "p", provides = "player"},
}, "acct")
eq("plex servers", #servers, 1)
eq("plex server token", servers[1].token, "st")
local cands = Plex.server_candidates(servers[1])
eq("plex candidates: https only, no relay", #cands, 3)
eq("plex LAN https first", cands[1].url, "https://10-0-0-20.x.plex.direct:32400")
eq("plex docker after LAN", cands[2].url, "https://172-17-0-1.x.plex.direct:32400")
eq("plex remote last", cands[3].kind, "remote")
local icands = Plex.server_candidates(servers[1], true)
eq("plex insecure opt-in adds http", #icands, 5)
eq("plex insecure http after its https", icands[2].url, "http://10.0.0.20:32400")
local odd = Plex.server_candidates({connections = {
    {uri = "https://srv@evil.example:32400", ["local"] = true},
    {uri = "https://srv.example:32400/path?x=", ["local"] = false},
    {uri = "https://ok.example:32400/", ["local"] = false},
    {uri = "https://10-0-0-9.x.plex.direct:32400", address = "10.0.0.9/x", port = "abc", ["local"] = true},
}}, true)
eq("plex odd connections: only bare https origins", #odd, 2)
eq("plex bad address/port skipped", odd[1].url, "https://10-0-0-9.x.plex.direct:32400")
eq("plex trailing slash trimmed", odd[2].url, "https://ok.example:32400")
check("plex safe key", Plex.safe_key("/library/parts/1/22/file.mkv") and Plex.safe_key("/library/metadata/7/children"))
check("plex key with @ rejected", not Plex.safe_key("@evil.example/x") and not Plex.safe_key("/x@evil.example"))
check("plex key // rejected", not Plex.safe_key("//evil.example/x"))
check("plex key scheme rejected", not Plex.safe_key("https://evil/x") and not Plex.safe_key("/a b") and not Plex.safe_key(nil))
eq("plex rank docker", Plex.local_rank("172.20.0.1"), 3)
eq("plex rank lan", Plex.local_rank("10.0.0.5"), 1)
eq("plex pick undecided", Plex.pick_candidate({[2] = true}, 3), nil)
eq("plex pick first ok", Plex.pick_candidate({false, true}, 3), 2)
eq("plex pick none", Plex.pick_candidate({false, false}, 2), false)
eq("plex label movie", Plex.item_label({type = "movie", title = "Alien", year = 1979}), "Alien (1979)")
eq("plex label episode", Plex.item_label({type = "episode", index = 2, title = "Two"}, "items"), "E02 · Two")
eq("plex label ondeck", Plex.item_label({type = "episode", index = 2, parentIndex = 1, title = "Two",
    grandparentTitle = "Show"}, "ondeck"), "Show · S01E02 · Two")
local st = Plex.item_state({duration = 600000, viewOffset = 120000, viewCount = 1})
check("plex state progress", st.pos == 120 and st.duration == 600 and not st.watched)
check("plex state watched", Plex.item_state({viewCount = 2}).watched == true)
st = Plex.item_state({duration = 600000, viewOffset = 15000, viewCount = 1})
check("plex state: short offset on a watched item", st.watched and not st.pos)
st = Plex.item_state({duration = 600000, viewOffset = 15000})
check("plex state: short offset ignored", not st.watched and not st.pos)
st = Plex.item_state({duration = 6000000, viewOffset = 5900000})
check("plex state: near the end is watched", st.watched and not st.pos)
local pents = Plex.entries_from({
    Directory = {{key = "3", type = "movie", title = "Movies"}, {key = "9", type = "artist", title = "Music"}},
    Metadata = {
        {type = "movie", title = "Alien", year = 1979, ratingKey = "7", key = "/library/metadata/7",
         titleSort = "Alien", addedAt = 5, duration = 1000, Media = {{Part = {{key = "/library/parts/1/file.mkv"}}}}},
        {type = "show", title = "One", key = "/library/metadata/8/children", childCount = 1},
        {type = "show", title = "Many", key = "/library/metadata/9/children", childCount = 3,
         leafCount = 4, viewedLeafCount = 4},
    },
}, "https://srv", "m1", "items")
eq("plex entries (music skipped)", #pents, 4)
local evil = Plex.entries_from({Metadata = {
    {type = "movie", title = "X", key = "/library/metadata/1", Media = {{Part = {{key = "@evil.example/f.mkv"}}}}},
    {type = "show", title = "Y", key = "//evil.example/children"},
}}, "https://srv", "m1", "items")
eq("plex entries with unsafe keys dropped", #evil, 0)
eq("plex section path", pents[1].path, "plex://m1/library/sections/3/all")
eq("plex movie url", pents[2].path, "https://srv/library/parts/1/file.mkv")
eq("plex movie title", pents[2].server.title, "Alien (1979)")
eq("plex one-season show", pents[3].server.key, "/library/metadata/8/allLeaves")
eq("plex one-season show lists episodes", pents[3].server.kind, "episodes")
eq("plex show lists seasons", pents[4].server.kind, "seasons")
eq("plex season lists episodes", Plex.entries_from({Metadata = {
    {type = "season", title = "Book Two", index = 2, key = "/library/metadata/10/children"}}},
    "https://srv", "m1", "seasons")[1].server.kind, "episodes")
check("plex watched show", pents[4].state and pents[4].state.watched)
local subs = Plex.external_subtitles({Media = {{Part = {{Stream = {
    {streamType = 3, codec = "srt", key = "/library/streams/5", languageTag = "en", displayTitle = "English"},
    {streamType = 3, codec = "vobsub"}, {streamType = 2, key = "/x"},
}}}}}}, "https://srv")
eq("plex external subs", #subs, 1)
eq("plex sub url", subs[1].url, "https://srv/library/streams/5")

-- about -----------------------------------------------------------------------
local About = require "dvp.about"
local bi = About.parse_build_info("date=2026-10-23\ncommit=1a2b3c4-modified\n")
eq("build info date", bi.date, "2026-10-23")
eq("build text", About.build_text(bi), "2026-10-23 · 1a2b3c4-modified")
eq("build text no commit", About.build_text(About.parse_build_info("date=2026-10-23\ncommit=\n")), "2026-10-23")
eq("build text dev", About.build_text(About.parse_build_info(nil)), "development build")

eq("plex sub key", SubDL.server_key({machine = "ab12", rating_key = "77"}), "plex-ab12-77")
local pinfo = SubDL.server_info({kind = "episode", show = "Sherlock", name = "The Blind Banker", season = 1, episode = 2})
check("plex sub info episode", pinfo.title == "Sherlock" and pinfo.season == 1 and pinfo.episode == 2)
pinfo = SubDL.server_info({kind = "movie", name = "Some Film", year = 1995})
check("plex sub info movie", pinfo.title == "Some Film" and pinfo.year == 1995 and not pinfo.season)
eq("safe lang", SubDL.safe_lang("pt-br"), "pt-br")
eq("unsafe lang", SubDL.safe_lang("../../x"), "und")
eq("empty lang", SubDL.safe_lang(""), "und")
check("os base url ok", OS.valid_base_url("vip-api.opensubtitles.com") and OS.valid_base_url("api.opensubtitles.com"))
check("os base url rejected", not OS.valid_base_url("evil.example") and not OS.valid_base_url("opensubtitles.com.evil.example")
    and not OS.valid_base_url("x/@evil"))
check("os link https", OS.valid_link("https://cdn.example/f.srt", OS.API_URL))
check("os link rejected", not OS.valid_link("file:///etc/passwd", OS.API_URL)
    and not OS.valid_link("http://cdn.example/f.srt", OS.API_URL) and not OS.valid_link(nil, OS.API_URL))
check("os link mock origin", OS.valid_link("http://127.0.0.1:8080/files/x.srt", "http://127.0.0.1:8080/api/v1")
    and not OS.valid_link("http://127.0.0.1:80800/x", "http://127.0.0.1:8080/api/v1"))
eq("plex auth url", Plex.auth_url("cid", "abc"),
    "https://app.plex.tv/auth#?clientID=cid&code=abc&context%5Bdevice%5D%5Bproduct%5D=Deck%20Video%20Player")
local qrencode = require "dvp.qrencode"
local qok, qm = qrencode.qrcode(Plex.auth_url(string.rep("a", 32), string.rep("b", 25)))
check("qr encodes sign-in url", qok and #qm == 45, tostring(qok and #qm))

-- black bar detection ----------------------------------------------------------
-- keep awake (D43) -------------------------------------------------------------
local KeepAwake = require "dvp.keepawake"
eq("awake args", table.concat(KeepAwake.args("/s"), " "), "dvp-keep-awake --status /s")
local ks = KeepAwake.parse_status("request: screensaver accepted, portal not supported\n")
eq("awake status", ks.request, "screensaver accepted, portal not supported")
eq("awake status empty", next(KeepAwake.parse_status(nil)), nil)

local cropdetect = require "dvp.cropdetect"
-- A frame w x h with a picture at (px, py, pw, ph); `value` = its brightness.
local function frame(px, py, pw, ph, value)
    return function(x, y)
        if x >= px and x < px + pw and y >= py and y < py + ph then return value end
        return 8
    end
end
local function box(b) return b and string.format("%dx%d+%d+%d", b.w, b.h, b.x, b.y) end
eq("pillarbox 4:3 in 16:9", box(cropdetect.bounds(frame(240, 0, 1440, 1080, 200), 1920, 1080)), "1440x1080+240+0")
eq("letterbox 2.39 in 16:9", box(cropdetect.bounds(frame(0, 138, 1920, 804, 200), 1920, 1080)), "1920x804+0+138")
eq("odd bar rounded down", box(cropdetect.bounds(frame(0, 141, 1920, 798, 200), 1920, 1080)), "1920x800+0+140")
eq("no bars", cropdetect.bounds(frame(0, 0, 1920, 1080, 200), 1920, 1080), nil)
eq("thin edge ignored", cropdetect.bounds(frame(4, 0, 1912, 1080, 200), 1920, 1080), nil)
eq("dark frame", cropdetect.bounds(frame(0, 0, 1920, 1080, 20), 1920, 1080), nil)
eq("small bright spot", cropdetect.bounds(frame(900, 500, 100, 60, 200), 1920, 1080), nil)
eq("dark sky at the top only", cropdetect.bounds(frame(0, 260, 1920, 820, 200), 1920, 1080), nil)
-- letterboxed film whose left side is in shadow: only the bars go
eq("letterbox with dark left side", box(cropdetect.bounds(frame(360, 138, 1560, 804, 200), 1920, 1080)),
    "1920x804+0+138")
eq("uneven bars use the thinner", box(cropdetect.bounds(frame(0, 136, 1920, 806, 200), 1920, 1080)),
    "1920x808+0+136")
local raw = {}
for y = 0, 9 do for x = 0, 15 do
    raw[#raw + 1] = (x >= 2 and x < 14) and "\200\200\200\0" or "\0\0\0\0"
end end
cropdetect.SAMPLES = 16
eq("from screenshot", box(cropdetect.from_screenshot({w = 16, h = 10, stride = 64, data = table.concat(raw)})),
    "12x10+2+0")
cropdetect.SAMPLES = 64

-- menu ------------------------------------------------------------------------
local Menu = require "dvp.menu"
local lw, vw = Menu.split_row(400, 100, 80, 0, 16)
check("split both fit", lw == 100 and vw == 80)
lw, vw = Menu.split_row(400, 120, 900, 0, 16)
check("split long value keeps label", lw == 120 and vw == 400 - 16 - 120, lw .. "/" .. vw)
lw, vw = Menu.split_row(400, 600, 600, 44, 16)
check("split both long", lw == 180 and vw == 204, lw .. "/" .. vw)
lw, vw = Menu.split_row(400, 700, 0, 0, 16)
check("split no value", lw == 400 and vw == 0)
local m = Menu.new()
local spec = {title = "T", items = {{label = "Searching…", disabled = true}}}
m:open(spec)
check("menu update open", m:update(spec, {items = {{label = "a"}, {label = "b"}}}))
eq("menu update items", #spec.items, 2)
m:close_all()
check("menu update closed", not m:update(spec, {items = {}}))
-- Section headers are skipped by the cursor (also when wrapping).
spec = {title = "T", style = "side", items = {{label = "A", header = true}, {label = "a"},
                                              {label = "B", header = true}, {label = "b"}}}
m:open(spec)
m:update(spec, {items = spec.items})
eq("menu header skipped", spec.selected, 2)
m:handle("down")
eq("menu header skipped down", spec.selected, 4)
m:handle("down")
eq("menu header skipped wrap", spec.selected, 2)
m:close_all()

-- video info (D50) -----------------------------------------------------------
local VI = require "dvp.videoinfo"
eq("fps ntsc", VI.format_fps("24000/1001"), "23.976 fps")
eq("fps whole", VI.format_fps("24/1"), "24 fps")
eq("fps number", VI.format_fps(59.94), "59.94 fps")
eq("fps unknown", VI.format_fps("0/0"), nil)
eq("bitrate mb", VI.format_bitrate(24500000), "24.5 Mb/s")
eq("bitrate kb", VI.format_bitrate(640000), "640 kb/s")
eq("size gb", VI.format_size(15234000000), "15.23 GB")
eq("size mb", VI.format_size(734000000), "734 MB")
eq("hdr10", VI.hdr_label({transfer = "smpte2084"}), "HDR10")
eq("hdr10+", VI.hdr_label({transfer = "smpte2084", hdr10plus = true}), "HDR10+")
eq("dv8 hdr10", VI.hdr_label({transfer = "smpte2084", dv_profile = 8}), "Dolby Vision 8 · HDR10")
eq("dv5 only", VI.hdr_label({transfer = "smpte2084", dv_profile = 5}), "Dolby Vision 5")
eq("hlg", VI.hdr_label({transfer = "arib-std-b67"}), "HLG")
eq("sdr", VI.hdr_label({transfer = "bt709"}), "SDR")
local probe = {
    format = {filename = "/v/Film.mkv", format_long_name = "Matroska / WebM", size = "15234000000",
              duration = "7260.0", bit_rate = "16800000"},
    streams = {
        {codec_type = "video", codec_name = "hevc", profile = "Main 10", width = 3840, height = 2160,
         pix_fmt = "yuv420p10le", avg_frame_rate = "24000/1001", color_transfer = "smpte2084",
         color_primaries = "bt2020", tags = {BPS = "15000000"},
         side_data_list = {{side_data_type = "DOVI configuration record", dv_profile = 8}}},
        {codec_type = "audio", codec_name = "truehd", profile = "Dolby TrueHD + Dolby Atmos",
         channel_layout = "7.1", channels = 8, tags = {language = "eng"}, disposition = {default = 1}},
        {codec_type = "audio", codec_name = "ac3", channel_layout = "stereo", channels = 2,
         tags = {language = "eng", title = "Commentary"}, disposition = {default = 0}},
        {codec_type = "subtitle", codec_name = "hdmv_pgs_subtitle", tags = {language = "spa"},
         disposition = {forced = 1}},
        {codec_type = "video", codec_name = "mjpeg", disposition = {attached_pic = 1}},
    },
}
local frame = {frames = {{side_data_list = {
    {side_data_type = "HDR Dynamic Metadata SMPTE2094-40 (HDR10+)"},
    {side_data_type = "Mastering display metadata", max_luminance = "10000000/10000"},
    {side_data_type = "Content light level metadata", max_content = 1000, max_average = 400}}}}}
local function rows_of(sections)
    local out = {}
    for _, sec in ipairs(sections) do
        for _, r in ipairs(sec.rows) do out[sec.title .. "/" .. r.label] = r.value end
    end
    return out
end
local lr = rows_of(VI.sections(VI.from_ffprobe(probe, frame, "/v/Film.mkv")))
eq("local name", lr["File/Name"], "Film.mkv")
eq("local folder", lr["File/Folder"], "/v")
eq("local container", lr["File/Container"], "MKV")
eq("local duration", lr["File/Duration"], "2:01:00")
eq("local bitrate", lr["File/Bitrate"], "16.8 Mb/s")
eq("local codec", lr["Video/Codec"], "HEVC Main 10")
eq("local resolution", lr["Video/Resolution"], "3840 × 2160 (4K)")
eq("local depth", lr["Video/Bit depth"], "10-bit")
eq("local hdr", lr["Video/HDR"], "Dolby Vision 8 · HDR10+")
eq("local mastering", lr["Video/Mastering peak"], "1000 nits")
eq("local maxcll", lr["Video/MaxCLL / MaxFALL"], "1000 / 400 nits")
eq("local video bitrate", lr["Video/Video bitrate"], "15.0 Mb/s")
eq("local atmos", lr["Audio (2 tracks)/English"], "AC-3 · Stereo · Commentary")
local secs = VI.sections(VI.from_ffprobe(probe, nil, "/v/Film.mkv"))
eq("local audio 1", secs[3].rows[1].value, "TrueHD Atmos · 7.1 · Default")
eq("local sub", secs[4].rows[1].label .. ": " .. secs[4].rows[1].value, "Spanish: PGS · Forced")
eq("local no frame hdr", rows_of(secs)["Video/HDR"], "Dolby Vision 8 · HDR10")
-- FFmpeg 9: stream colours "unknown" until a frame is decoded.
local p9 = {format = {}, streams = {{codec_type = "video", codec_name = "hevc", color_transfer = "unknown",
                                       width = 1920, height = 1080}}}
local f9 = {frames = {{color_transfer = "smpte2084", color_primaries = "bt2020"}}}
local r9 = rows_of(VI.sections(VI.from_ffprobe(p9, f9, "/v/a.mkv")))
eq("frame colours", r9["Video/HDR"] .. " " .. r9["Video/Colors"], "HDR10 BT.2020")
eq("unknown transfer", rows_of(VI.sections(VI.from_ffprobe(p9, nil, "/v/a.mkv")))["Video/HDR"], "SDR")
eq("menu items", VI.items(secs)[1].header, true)
local md = {title = "Film", duration = 7260000, Media = {{container = "mkv", bitrate = 16800,
    width = 3840, height = 2160, Part = {{file = "/data/movies/Film/Film.mkv", size = 15234000000, Stream = {
        {streamType = 1, codec = "hevc", profile = "main 10", bitDepth = 10, frameRate = 23.976,
         colorTrc = "smpte2084", colorPrimaries = "bt2020", DOVIPresent = true, DOVIProfile = 8,
         width = 3840, height = 2160, bitrate = 15000},
        {streamType = 2, codec = "dca", profile = "ma", channels = 6, audioChannelLayout = "5.1(side)",
         languageTag = "en", default = true},
        {streamType = 3, codec = "srt", languageTag = "es", key = "/library/streams/9"},
    }}}}}}
local pr = rows_of(VI.sections(VI.from_plex(md, VI.server_source("Plex", "Home server", "local"))))
eq("plex source", pr["File/Source"], "Plex · Home server · local network")
eq("source first", VI.sections(VI.from_plex(md, "Plex"))[1].rows[1].label, "Source")
eq("server source remote", VI.server_source("Jellyfin", "Home", "remote"), "Jellyfin · Home · remote")
eq("server source unknown", VI.server_source("Plex", "Home", nil), "Plex · Home")
eq("plex folder", pr["File/Folder"], "/data/movies/Film")
eq("plex codec", pr["Video/Codec"], "HEVC Main 10")
eq("plex hdr", pr["Video/HDR"], "Dolby Vision 8 · HDR10")
eq("plex fps", pr["Video/Frame rate"], "23.976 fps")
eq("plex bitrate", pr["File/Bitrate"], "16.8 Mb/s")
eq("plex audio", pr["Audio/English"], "DTS-HD MA · 5.1 · Default")
eq("plex sub external", pr["Subtitles (1)/Spanish"], "External")
local atm = VI.from_plex({Media = {{Part = {{Stream = {{streamType = 2, codec = "eac3", channels = 6,
    profile = "dolby digital plus + dolby atmos", languageTag = "en"}}}}}}})
eq("plex atmos", VI.sections(atm)[2].rows[1].value, "E-AC-3 Atmos · 5.1")
local upper = VI.from_plex({Media = {{Part = {{Stream = {{streamType = 1, codec = "hevc",
    colorTrc = "SMPTE2084", colorPrimaries = "BT2020"}}}}}}})
eq("plex colour case", upper.video.transfer .. " " .. upper.video.primaries, "smpte2084 bt2020")

-- Plex in "Recently played" (D50) ---------------------------------------------
eq("recent key", Plex.recent_key({machine = "abc123", key = "/library/metadata/42"}), "plex://abc123/library/metadata/42")
eq("recent key unsafe", Plex.recent_key({machine = "abc", key = "//evil"}), nil)
local rm, rk = Plex.parse_recent_key("plex://abc123/library/metadata/42")
check("parse recent key", rm == "abc123" and rk == "/library/metadata/42")
eq("parse not plex", Plex.parse_recent_key("/videos/a.mkv"), nil)
eq("parse other plex", Plex.parse_recent_key("plex://abc/library/sections/1/all"), nil)
local pres = Resume.new(nil)
pres:update("plex://abc/library/metadata/42", 300, 3600, nil, nil, "Show · S01E02 · Title")
eq("plex recent title", pres:get("plex://abc/library/metadata/42").title, "Show · S01E02 · Title")
eq("plex recent listed", pres:recent(5)[1], "plex://abc/library/metadata/42")
local played = pres:get("plex://abc/library/metadata/42").played
pres:sync("plex://abc/library/metadata/42", {pos = 1200, duration = 3600})
eq("sync pos", pres:get("plex://abc/library/metadata/42").pos, 1200)
pres:sync("plex://abc/library/metadata/42", {watched = true, duration = 3600})
local se = pres:get("plex://abc/library/metadata/42")
check("sync watched", se.watched == true and se.pos == nil and se.played == played)
pres:sync("plex://abc/library/metadata/99", {pos = 1200})
eq("sync unknown entry", pres:get("plex://abc/library/metadata/99"), nil)

-- HDR choices (D52) ----------------------------------------------------------------
local Hdr = require "dvp.hdr"
local hd = {["target-colorspace-hint"] = "yes", ["target-colorspace-hint-mode"] = "target",
            ["target-peak"] = "auto", ["target-trc"] = "auto", ["target-prim"] = "auto",
            ["inverse-tone-mapping"] = "no", ["hdr-compute-peak"] = "no"}
local function hs(t)
    local s = {enabled = true, mapping = "static", peak = 1000, itm = 0}
    for k, v in pairs(t) do s[k] = v end
    return s
end
local o = Hdr.options(hs{gamma = "pq", itm = 400}, hd)
check("hdr static = defaults", o["target-peak"] == "auto" and o["target-colorspace-hint-mode"] == "target"
    and o["inverse-tone-mapping"] == "no" and o["target-colorspace-hint"] == "yes")
eq("hdr dynamic", Hdr.options(hs{gamma = "pq", mapping = "dynamic", dynamic = true}, hd)["target-colorspace-hint-mode"],
   "source-dynamic")
-- Plain HDR10 has no per-scene metadata: "dynamic" works as "static".
eq("hdr10 dynamic = static", Hdr.options(hs{gamma = "pq", mapping = "dynamic"}, hd)["target-colorspace-hint-mode"],
   "target")
eq("hdr10 dynamic shown", Hdr.shown_mapping(hs{mapping = "dynamic"}), "static")
eq("dv dynamic shown", Hdr.shown_mapping(hs{mapping = "dynamic", dynamic = true}), "dynamic")
eq("choices hdr10", table.concat(Hdr.mapping_choices(false), ","), "static,app")
eq("choices dv", table.concat(Hdr.mapping_choices(true), ","), "static,dynamic,app")
eq("hdr10 steps over dynamic", Hdr.step(Hdr.mapping_choices(false), "static", 1), "app")
check("scene metadata", Hdr.has_scene_metadata({["max-pq-y"] = 0.5})
    and Hdr.has_scene_metadata({["scene-max-r"] = 140})
    and Hdr.has_scene_metadata({}, {["dolby-vision-profile"] = 8})
    and not Hdr.has_scene_metadata({["max-luma"] = 1000, ["max-cll"] = 1000}, {codec = "hevc"})
    and not Hdr.has_scene_metadata(nil, nil))
o = Hdr.options(hs{gamma = "hlg", mapping = "app", peak = 800}, hd)
check("hdr app", o["target-peak"] == "800" and o["hdr-compute-peak"] == "yes")
o = Hdr.options(hs{gamma = "bt.1886", mapping = "app", peak = 800, itm = 400}, hd)
check("sdr to hdr", o["inverse-tone-mapping"] == "yes" and o["target-trc"] == "pq" and o["target-peak"] == "400")
check("sdr to hdr off", Hdr.options(hs{gamma = "bt.1886", mapping = "app"}, hd)["target-peak"] == "auto")
check("unknown gamma", Hdr.options(hs{mapping = "app", itm = 400}, hd)["target-peak"] == "auto")
o = Hdr.options(hs{gamma = "pq", enabled = false, mapping = "app", itm = 400}, hd)
check("hdr off", o["target-colorspace-hint"] == "no" and o["target-peak"] == "auto")
eq("hdr off before a file", Hdr.options(hs{enabled = false}, hd)["target-colorspace-hint"], "no")
-- A screen known not to be in HDR mode drops app mapping and SDR to HDR.
check("no hdr screen: app", Hdr.options(hs{gamma = "pq", mapping = "app", screen = false}, hd)["target-peak"] == "auto")
check("no hdr screen: itm", Hdr.options(hs{gamma = "bt.1886", itm = 600, screen = false}, hd)["inverse-tone-mapping"] == "no")
eq("no hdr screen: dynamic dropped",
   Hdr.options(hs{gamma = "pq", mapping = "dynamic", dynamic = true, screen = false}, hd)["target-colorspace-hint-mode"],
   "target")
eq("no hdr screen: nothing effective",
   Hdr.effective(hs{gamma = "pq", mapping = "dynamic", dynamic = true, screen = false}), nil)
check("defaults untouched", hd["target-peak"] == "auto")
check("expects hdr", Hdr.expects_hdr(hs{gamma = "pq"}) and Hdr.expects_hdr(hs{gamma = "bt.1886", itm = 300})
    and not Hdr.expects_hdr(hs{gamma = "bt.1886"}) and not Hdr.expects_hdr(hs{gamma = "pq", enabled = false})
    and not Hdr.expects_hdr(hs{}))
eq("effective static", Hdr.effective(hs{gamma = "pq"}), nil)
eq("effective itm", Hdr.effective(hs{gamma = "bt.1886", itm = 300}).itm, 300)
eq("step clamps", Hdr.step(Hdr.MAPPINGS, "app", 1), "app")
eq("step back", Hdr.step(Hdr.ITM_LEVELS, 300, -1), 0)
eq("peak clamp high", Hdr.clamp_peak(5000), 2000)
eq("peak round", Hdr.clamp_peak(640), 600)
eq("peak bad", Hdr.clamp_peak("x"), 1000)
eq("itm off", Hdr.parse_itm("off"), 0)
eq("itm nits", Hdr.parse_itm("600"), 600)
local hcfg = config.from_text("[display]\nhdr_mapping = Dynamic\nhdr_peak = 800\nsdr_to_hdr = 400\n")
check("hdr config", hcfg.display.hdr_mapping == "dynamic" and hcfg.display.hdr_peak == 800
    and hcfg.display.sdr_to_hdr == "400")
check("hdr config defaults", config.defaults().display.hdr_mapping == "static"
    and config.defaults().display.sdr_to_hdr == "off")

-- Jellyfin (D55) ---------------------------------------------------------------
-- Made-up ids and names (never the owner's server).
local JF = require "dvp.jellyfin"
local SID = "0123456789abcdef0123456789abcdef"
local IID = "fedcba9876543210fedcba9876543210"
check("jf safe id", JF.safe_id(SID) and JF.safe_id("01234567-89ab-cdef-0123-456789abcdef")
    and not JF.safe_id("../x") and not JF.safe_id("abc") and not JF.safe_id(nil))
check("jf private hosts", JF.private_host("192.168.1.20") and JF.private_host("10.0.0.5")
    and JF.private_host("172.20.1.1") and JF.private_host("127.0.0.1") and JF.private_host("nas.local")
    and JF.private_host("jellyfin") and not JF.private_host("172.32.0.1")
    and not JF.private_host("8.8.8.8") and not JF.private_host("jellyfin.example.com"))
eq("jf url lan http", JF.normalize_url(" http://192.168.1.20:8096/ "), "http://192.168.1.20:8096")
eq("jf url https prefix", JF.normalize_url("https://Media.Example.com/jellyfin"), "https://media.example.com/jellyfin")
eq("jf url public http refused", select(2, JF.normalize_url("http://media.example.com")),
   "Use https for a server outside your home network")
eq("jf url userinfo refused", JF.normalize_url("http://evil@192.168.1.2:8096"), nil)
eq("jf url bad port", JF.normalize_url("http://192.168.1.2:99999"), nil)
eq("jf url path tricks", JF.normalize_url("http://192.168.1.2:8096/../x"), nil)
eq("jf url no slash prefix", JF.normalize_url("http://192.168.1.2:8096x"), nil)
eq("jf auth header", JF.auth_header("Deck", "dev1", "tok"),
   'MediaBrowser Client="Deck Video Player", Device="Deck", DeviceId="dev1", Version="'
   .. require("dvp.version") .. '", Token="tok"')
local disc = JF.parse_discovery('{"Address":"http://192.168.1.20:8096","Id":"' .. SID .. '","Name":"Home"}\n'
    .. '{"Address":"http://192.168.1.20:8096","Id":"' .. SID .. '","Name":"Home"}\n'
    .. '{"Address":"http://8.8.8.8:8096","Id":"' .. IID .. '","Name":"Far"}\nnot json\n')
check("jf discovery", #disc == 1 and disc[1].name == "Home" and disc[1].url == "http://192.168.1.20:8096")
-- Same id from another address: both kept (discover() probes which is real)
local disc2 = JF.parse_discovery('{"Address":"http://192.168.1.66:8096","Id":"' .. SID .. '","Name":"Fake"}\n'
    .. '{"Address":"http://192.168.1.20:8096","Id":"' .. SID .. '","Name":"Home"}\n')
check("jf discovery same id", #disc2 == 2 and disc2[2].url == "http://192.168.1.20:8096")
local flood = {}
for n = 1, 40 do flood[n] = '{"Address":"http://10.0.0.' .. n .. ':8096","Id":"' .. SID .. '","Name":"x"}' end
eq("jf discovery cap", #JF.parse_discovery(table.concat(flood, "\n")), JF.MAX_ANSWERS)
local st = JF.item_state({RunTimeTicks = 36000 * 1e7, UserData = {PlaybackPositionTicks = 600 * 1e7}})
check("jf state pos", st.pos == 600 and st.duration == 36000 and not st.watched)
st = JF.item_state({RunTimeTicks = 3600 * 1e7, UserData = {PlaybackPositionTicks = 3590 * 1e7}})
check("jf state finished", st.watched == true and st.pos == nil)
check("jf state played", JF.item_state({UserData = {Played = true}}).watched == true)
check("jf state short pos", JF.item_state({RunTimeTicks = 3600e7, UserData = {PlaybackPositionTicks = 10e7}}).pos == nil)
eq("jf date key", JF.date_key("2024-05-01T12:34:56.0000000Z"), 20240501123456)
local ep = {Type = "Episode", Name = "Pilot", IndexNumber = 1, ParentIndexNumber = 2, SeriesName = "Show"}
eq("jf episode label", JF.item_label(ep, "episodes"), "E01 · Pilot")
eq("jf episode label ondeck", JF.item_label(ep, "nextup"), "Show · S02E01 · Pilot")
eq("jf movie label", JF.item_label({Type = "Movie", Name = "Film", ProductionYear = 1999}, "items"), "Film (1999)")
local SER, SEA = "11111111111111111111111111111111", "22222222222222222222222222222222"
local jents = JF.entries_from({
    {Id = "33333333333333333333333333333333", Type = "CollectionFolder", IsFolder = true, CollectionType = "movies", Name = "Movies"},
    {Id = "44444444444444444444444444444444", Type = "CollectionFolder", IsFolder = true, CollectionType = "music", Name = "Music"},
    {Id = SER, Type = "Series", IsFolder = true, Name = "Show", ChildCount = 3},
    {Id = "55555555555555555555555555555555", Type = "Series", IsFolder = true, Name = "Mini", ChildCount = 1},
    {Id = SEA, Type = "Season", IsFolder = true, Name = "Season 1", SeriesId = SER, UserData = {Played = true}},
    {Id = IID, Type = "Movie", MediaType = "Video", Name = "Film", ProductionYear = 1999, SortName = "film",
     RunTimeTicks = 6000e7, DateCreated = "2024-05-01T12:00:00Z", UserData = {PlaybackPositionTicks = 0}},
    {Id = "bad", Type = "Movie", MediaType = "Video", Name = "No id"},
    "junk",
}, "http://192.168.1.20:8096", SID, "items")
eq("jf entries count", #jents, 5)
check("jf library", jents[1].is_dir and jents[1].server.kind == "items" and jents[1].server.backend == "jellyfin")
eq("jf series seasons", jents[2].server.kind, "seasons")
eq("jf one-season series", jents[3].server.kind, "series_episodes")
check("jf season", jents[4].server.kind == "episodes" and jents[4].server.series == SER and jents[4].state.watched)
local jm = jents[5]
check("jf movie", not jm.is_dir and jm.path == "http://192.168.1.20:8096/Videos/" .. IID .. "/stream?static=true"
    and jm.server.key == IID and jm.server.rating_key == IID and jm.server.duration == 6000000
    and jm.server.title == "Film (1999)" and jm.mtime == 20240501120000 and jm.name == "film")
eq("jf listing root", JF.listing_path({kind = "root"}, "U"), "/UserViews?userId=U")
eq("jf listing episodes", JF.listing_path({kind = "episodes", key = SEA, series = SER}, "U"),
   "/Shows/" .. SER .. "/Episodes?userId=U&SeasonId=" .. SEA .. "&Fields=DateCreated,SortName,ChildCount&EnableImages=false")
check("jf listing nextup", JF.listing_path({kind = "nextup"}, "U"):find("EnableResumable=false", 1, true) ~= nil)
local jsubs = JF.external_subtitles({Id = IID, MediaSources = {{Id = SID, MediaStreams = {
    {Type = "Subtitle", IsExternal = true, Codec = "subrip", Index = 3, Language = "spa"},
    {Type = "Subtitle", IsExternal = true, Codec = "PGSSUB", Index = 4},
    {Type = "Subtitle", IsExternal = false, Codec = "ass", Index = 5},
}}}}, "http://h:8096")
check("jf external subs", #jsubs == 1 and jsubs[1].url == "http://h:8096/Videos/" .. IID .. "/" .. SID
    .. "/Subtitles/3/Stream.srt" and jsubs[1].lang == "spa")
local rk = JF.recent_key({machine = SID, key = IID})
eq("jf recent key", rk, "jellyfin://" .. SID .. "/" .. IID)
local rs, ri = JF.parse_recent_key(rk)
check("jf parse recent", rs == SID and ri == IID)
eq("jf parse plex key", JF.parse_recent_key("plex://abc/library/metadata/42"), nil)
eq("jf recent ref", JF.recent_ref(SID, IID).backend, "jellyfin")
local jmk = Markers.from_jellyfin({Items = {
    {Type = "Outro", StartTicks = 2500e7, EndTicks = 2600e7},
    {Type = "Intro", StartTicks = 60e7, EndTicks = 150e7},
    {Type = "Recap", StartTicks = 0, EndTicks = 50e7},
    {Type = "Intro", StartTicks = 10e7, EndTicks = 11e7},
}})
check("jf markers", #jmk == 2 and jmk[1].kind == "intro" and jmk[1].start == 60 and jmk[1].stop == 150
    and jmk[2].kind == "credits" and jmk[2].final == true)
eq("jf no markers", #Markers.from_jellyfin(nil), 0)
local jvi = VI.from_jellyfin({Name = "Film", MediaSources = {{Path = "/media/Movies/Film/Film.mkv", Size = 15234000000,
    Container = "mkv", Bitrate = 16800000, RunTimeTicks = 7260e7, MediaStreams = {
        {Type = "Video", Codec = "hevc", Profile = "Main 10", Width = 3840, Height = 2160, RealFrameRate = 23.976,
         BitDepth = 10, ColorTransfer = "smpte2084", ColorPrimaries = "bt2020", DvProfile = 8,
         VideoRangeType = "DOVIWithHDR10Plus"},
        {Type = "Audio", Codec = "eac3", Profile = "Dolby Digital Plus + Dolby Atmos", ChannelLayout = "5.1",
         Language = "eng", IsDefault = true},
        {Type = "Subtitle", Codec = "PGSSUB", Language = "spa", IsForced = true},
    }}}}, "Jellyfin · Home")
local jr = rows_of(VI.sections(jvi))
eq("jf vi hdr", jr["Video/HDR"], "Dolby Vision 8 · HDR10+")
eq("jf vi folder", jr["File/Folder"], "/media/Movies/Film")
eq("jf vi source", jr["File/Source"], "Jellyfin · Home")
local function jf_hdr(range, dv)
    local d = VI.from_jellyfin({MediaSources = {{MediaStreams = {{Type = "Video", Codec = "hevc",
        VideoRangeType = range, DvProfile = dv}}}}})
    return rows_of(VI.sections(d))["Video/HDR"]
end
eq("jf range hdr10", jf_hdr("HDR10"), "HDR10")
eq("jf range hdr10+", jf_hdr("HDR10Plus"), "HDR10+")
eq("jf range hlg", jf_hdr("HLG"), "HLG")
eq("jf range dv hdr10", jf_hdr("DOVIWithHDR10", 8), "Dolby Vision 8 · HDR10")
eq("jf range sdr", jf_hdr("SDR"), "SDR")
eq("jf vi audio", jr["Audio/English"], "E-AC-3 Atmos · 5.1 · Default")
eq("jf vi sub", jr["Subtitles (1)/Spanish"], "PGS · Forced")

-- Where a local file is (Recently played tags, Video info Source row)
local srcs = {{name = "Videos", path = "/home/deck/Videos", kind = "folder"},
              {name = "Movies", path = "/home/deck/Videos/Movies", kind = "folder"},
              {name = "SD Card", path = "/run/media/deck/abcd-1234", kind = "sdcard"},
              {name = "Stick", path = "/run/media/deck/Stick", kind = "usb"},
              {name = "USB drive", path = "/run/media/deck/0a1b2c3d", kind = "usb"},
              {name = "Home", path = "plex://m1/", kind = "plex"}}
eq("source longest", library.source_for(srcs, "/home/deck/Videos/Movies/a.mkv").name, "Movies")
eq("source folder", library.source_for(srcs, "/home/deck/Videos/b.mkv").name, "Videos")
eq("source not prefix", library.source_for(srcs, "/home/deck/VideosOld/c.mkv"), nil)
eq("source none", library.source_tag(library.source_for(srcs, "/tmp/x.mkv")), "Local")
eq("source sd tag", library.source_tag(library.source_for(srcs, "/run/media/deck/abcd-1234/x.mkv")), "SD Card")
eq("source usb tag", library.source_tag(srcs[4]), "USB")
eq("source folder tag", library.source_tag(srcs[1]), "Local")
eq("source label folder", library.source_label(srcs[2]), "Local · Movies")
eq("source label sd", library.source_label(srcs[3]), "SD Card")
eq("source label usb", library.source_label(srcs[4]), "USB drive · Stick")
eq("source label usb plain", library.source_label(srcs[5]), "USB drive")
eq("source label none", library.source_label(nil), "Local")
eq("jf sub key", SubDL.server_key({backend = "jellyfin", machine = SID, rating_key = IID}),
   "jellyfin-" .. SID .. "-" .. IID)
eq("jf config servers", #config.from_text("[jellyfin]\nserver = http://192.168.1.20:8096\nserver = https://x.example\n").jellyfin.server, 2)

-- Media server router (D55)
local Servers = require "dvp.servers"
local fake = function(id, name)
    local b = {ID = id, NAME = name, items = {}}
    function b:sources() return {{name = name, kind = id}} end
    function b:item_for(path) return self.items[path] end
    function b:signed_in() return true end
    function b:server(m) return m == "srv" and {} or nil end
    b.parse_recent_key = function(path) return path:match("^" .. id .. "://(%w+)/(%w+)$") end
    b.recent_key = function(item) return id .. "://" .. item.machine .. "/" .. item.key end
    return b
end
local fp, fj = fake("plex", "Plex"), fake("jellyfin", "Jellyfin")
fj.items["http://x/v"] = {backend = "jellyfin", machine = "srv", key = "k1"}
local router = Servers.new({fp, fj})
eq("router sources", #router:sources(), 2)
local ri_item, ri_backend = router:item_for("http://x/v")
check("router item", ri_item ~= nil and ri_backend == fj)
eq("router local file", router:item_for("/videos/a.mkv"), nil)
eq("router recent key", router:recent_key(ri_item), "jellyfin://srv/k1")
local rb, rid, rkey = router:parse_recent_key("jellyfin://srv/k1")
check("router parse recent", rb == fj and rid == "srv" and rkey == "k1")
check("router recent available", router:recent_available("jellyfin://srv/k1") == true
    and router:recent_available("jellyfin://gone/k1") == false and router:recent_available("/v/a.mkv") == nil)
eq("router get", router:get("plex"), fp)
eq("router for_ref", router:for_ref({backend = "jellyfin"}), fj)

-- Downloads and deleting (D60) -------------------------------------------
local DL = require "dvp.downloads"
eq("dl clean_name", DL.clean_name(' a/b:c*?"<>| d '), "a b c d")
eq("dl clean_name dots", DL.clean_name(".."), nil)
eq("dl clean_name hidden", DL.clean_name("  .hidden. "), "hidden")
eq("dl clean_name control", DL.clean_name("a\nb\0c"), "a b c")
local long = DL.clean_name(string.rep("ñ", 100))
check("dl clean_name bytes", #long <= 120 and #long % 2 == 0 and util.utf8_len(long) == #long / 2)
eq("dl safe_ext path", DL.safe_ext("/media/Films/Film.MKV"), "mkv")
eq("dl safe_ext container", DL.safe_ext("mp4"), "mp4")
eq("dl safe_ext odd", DL.safe_ext("/x/film.weird+ext"), "mkv")
eq("dl safe_ext none", DL.safe_ext(nil), "mkv")
eq("dl movie path", DL.relative_path({kind = "movie", name = "Film: Part 1", year = 2001}, "mkv"),
   "Film Part 1 (2001).mkv")
eq("dl movie no name", DL.relative_path({kind = "movie", title = "T"}, "mp4"), "T.mp4")
eq("dl episode path", DL.relative_path({kind = "episode", show = "Show/X", name = "Pilot", season = 1, episode = 2},
   "mkv"), "Show X/Season 01/Show X - S01E02 - Pilot.mkv")
eq("dl special", DL.relative_path({kind = "episode", show = "S", season = 0, episode = 3}, "mkv"),
   "S/Specials/S - S00E03.mkv")
eq("dl no season", DL.relative_path({kind = "episode", show = "S", name = "N"}, "mkv"), "S/S - N.mkv")
eq("dl dotdot show", DL.relative_path({kind = "episode", name = "N", show = ".."}, "mkv"),
   "Unknown show/Unknown show - N.mkv")
local sp = DL.subtitle_paths("/d/Film (2001).mkv", {
    {url = "u1", lang = "en", ext = "srt"}, {url = "u2", lang = "en", ext = "srt"},
    {url = "u3", lang = "../x", ext = "srt"}, {url = "u4", lang = "es", ext = "sup"}, {url = "u5", ext = "ass"}})
eq("dl subs count", #sp, 4)
eq("dl subs first", sp[1].path, "/d/Film (2001).en.srt")
eq("dl subs second", sp[2].path, "/d/Film (2001).2.en.srt")
eq("dl subs bad lang", sp[3].path, "/d/Film (2001).und.srt")
eq("dl subs no lang", sp[4].path, "/d/Film (2001).und.ass")
local spf = DL.subtitle_paths("/d/F.mkv", {{url = "u", lang = "en", ext = "srt"}, {file = "/s/x.srt", lang = "en", ext = "srt"}})
check("dl subs copy", spf[2].file == "/s/x.srt" and spf[2].path == "/d/F.2.en.srt" and spf[2].url == nil)
do
    local c = config.defaults()
    c.library.download_folder = "Downloaded"
    eq("download folder relative", library.download_folder(c), nil)
    c.library.download_folder = ""
    eq("download folder off", library.download_folder(c), nil)
    c.library.download_folder = "/x/Downloaded/"
    eq("download folder abs", library.download_folder(c), "/x/Downloaded")
end
eq("dl job id", DL.job_id({backend = "plex", machine = "m", key = "/library/metadata/1"}), "plex:m:/library/metadata/1")
eq("dl outcome ok", DL.outcome(200, 0), "done")
eq("dl outcome partial ok", DL.outcome(206, 0), "done")
eq("dl outcome complete", DL.outcome(416, 22), "done")
eq("dl outcome no ranges", DL.outcome(200, 33), "restart")
eq("dl outcome refused", DL.outcome(403, 22), "fail")
eq("dl outcome gone", DL.outcome(404, 22), "fail")
eq("dl outcome disk", DL.outcome(nil, 23), "fail")
eq("dl outcome 500", DL.outcome(503, 22), "retry")
eq("dl outcome net", DL.outcome(nil, 7), "retry")
eq("dl outcome stall", DL.outcome(206, 28), "retry")
eq("dl outcome redirect", DL.outcome(302, 0), "fail")
check("dl space ok", DL.enough_space(DL.SPACE_MARGIN + 100, 150, 50))
check("dl space short", not DL.enough_space(DL.SPACE_MARGIN + 99, 150, 50))
eq("dl status pct", DL.status_text({status = "downloading", size = 200}, 50, 2e6), "25% · 2 MB/s")
eq("dl status start", DL.status_text({status = "downloading", size = 200}, 0), "Starting…")
eq("dl status paused", DL.status_text({status = "paused", error = "x"}), "Stopped: x")
eq("dl status done", DL.status_text({status = "done", size = 1.5e9}), "1.5 GB")

-- curl options for long downloads
local dlcfg = http.curl_config({url = "u", timeout = 0, resume = true, fail = true, output = "/f.part"})
check("curl dl no max-time", dlcfg:find("max-time", 1, true) == nil)
check("curl dl stall limit", dlcfg:find("speed-time = 60", 1, true) ~= nil and dlcfg:find("speed-limit", 1, true) ~= nil)
check("curl dl resume fail", dlcfg:find('continue-at = "-"', 1, true) ~= nil and dlcfg:find("\nfail\n", 1, true) ~= nil)
check("curl default max-time", http.curl_config({url = "u"}):find("max-time = 25", 1, true) ~= nil)
check("curl default no resume", http.curl_config({url = "u"}):find("continue-at", 1, true) == nil)

-- Server side: what gets downloaded, and only when allowed
check("plex dl allowed owned", Plex.download_allowed({}, true))
check("plex dl allowed shared", Plex.download_allowed({allowSync = true}, false)
    and Plex.download_allowed({allowSync = "1"}, false))
check("plex dl refused shared", not Plex.download_allowed({allowSync = false}, false)
    and not Plex.download_allowed({}, false))
local pdl = Plex.download_parts({Media = {{Part = {{key = "/library/parts/5/1/file.mkv", size = 1234,
    file = "/srv/Film.mkv", Stream = {{streamType = 3, codec = "srt", key = "/library/streams/9", languageTag = "en"},
    {streamType = 3, codec = "pgs", key = "/library/streams/8"}, {streamType = 2, key = "/x"}}}}}}}, "https://s")
eq("plex dl url", pdl and pdl.url, "https://s/library/parts/5/1/file.mkv?download=1")
eq("plex dl size", pdl and pdl.size, 1234)
eq("plex dl subs", pdl and #pdl.subs, 1)
eq("plex dl sub url", pdl and pdl.subs[1].url, "https://s/library/streams/9")
eq("plex dl bad key", Plex.download_parts({Media = {{Part = {{key = "//evil/x"}}}}}, "https://s"), nil)
local jid, jms = string.rep("a", 32), string.rep("b", 32)
local jdl = JF.download_parts({Id = jid, CanDownload = true, MediaSources = {{Id = jms, Size = 99, Path = "/m/F.mp4",
    MediaStreams = {{Type = "Subtitle", IsExternal = true, Codec = "subrip", Index = 3, Language = "spa"}}}}}, "http://j")
eq("jf dl url", jdl and jdl.url, "http://j/Items/" .. jid .. "/Download")
eq("jf dl ext", jdl and DL.safe_ext(jdl.file), "mp4")
eq("jf dl sub ext", jdl and jdl.subs[1] and jdl.subs[1].ext, "srt")
local jno, jwhy = JF.download_parts({Id = jid, CanDownload = false}, "http://j")
check("jf dl refused", jno == nil and jwhy ~= nil)

-- Media servers are never asked to delete anything. The one DELETE
-- request clears a watched mark (Jellyfin's /UserPlayedItems).
do
    for _, name in ipairs({"plex.lua", "jellyfin.lua", "http.lua", "servers.lua", "downloads.lua", "library.lua",
                           "browser.lua"}) do
        local src = util.read_file(root .. "/dvp/" .. name) or ""
        local n, ok = 0, true
        for line in src:gmatch("[^\n]+") do
            if line:find('"DELETE"', 1, true) then
                n = n + 1
                ok = ok and name == "jellyfin.lua" and line:find('watched and "POST" or "DELETE"', 1, true) ~= nil
            end
        end
        check("no DELETE requests in " .. name, ok and n <= 1)
    end
    local jsrc = util.read_file(root .. "/dvp/jellyfin.lua") or ""
    local at = jsrc:find('watched and "POST" or "DELETE"', 1, true)
    check("jellyfin DELETE only for watched marks", at ~= nil
        and jsrc:sub(math.max(1, at - 300), at):find("/UserPlayedItems/", 1, true) ~= nil)
end

-- Queue: one at a time, stop/resume/cancel, stale answers ignored
do
    local pending = {}
    local fake = {ID = "plex", NAME = "Plex"}
    function fake:download_info(item, cb) pending[#pending + 1] = {item = item, cb = cb} end
    function fake:signed_in() return true end
    function fake:server(m) return m == "m" and {} or nil end
    function fake:sources() return {} end
    local q = DL.new({cfg = config.defaults(), servers = Servers.new({fake})}, nil)
    local a = {backend = "plex", machine = "m", key = "/library/metadata/1", kind = "movie", name = "A"}
    local b = {backend = "plex", machine = "m", key = "/library/metadata/2", kind = "movie", name = "B"}
    eq("queue add", q:add({a, b}), 2)
    eq("queue add again", q:add({a}), 0)
    eq("queue tag running", q:tag(a), "Downloading")
    eq("queue tag waiting", q:tag(b), "Waiting to download")
    eq("queue one request", #pending, 1)
    q:pause(q:find(a))
    eq("queue stopped", q:tag(a), "Download stopped")
    eq("queue next starts", q:tag(b), "Downloading")
    q:cancel(q:find(b))
    eq("queue cancel", q:find(b), nil)
    pending[1].cb(nil, "late")   -- answer for the stopped download: ignored
    eq("queue stale answer", q:find(a).status, "paused")
    q:resume(q:find(a))
    eq("queue resumed", q:tag(a), "Downloading")
    local act, other, done = q:counts()
    check("queue counts", act == 1 and other == 0 and done == 0)
    check("queue other backend", not q:can_download({backend = "jellyfin", machine = "m", key = "x"}))
    local off = config.defaults()
    off.library.download_folder = ""
    check("queue no folder", not DL.new({cfg = off, servers = Servers.new({fake})}, nil):can_download(a))
    q:shutdown()
    eq("queue shutdown", q:find(a).status, "paused")
end

-- Deleting: only video files of this device
do
    local lcfg = config.defaults()
    local mounts = library.parse_mounts(table.concat({
        "22 1 0:21 / / rw - ext4 /dev/nvme0n1p8 rw",
        "30 22 179:1 / /run/media/deck/SD\\040Card rw - exfat /dev/mmcblk0p1 rw",
        "31 22 0:50 / /home/deck/Videos/NAS rw - cifs //nas/share rw",
        "32 22 0:51 / /mnt/ssh rw - fuse.sshfs u@h: rw",
    }, "\n"))
    eq("mounts parsed", #mounts, 4)
    eq("mount unescaped", mounts[2].path, "/run/media/deck/SD Card")
    eq("mount_for", library.mount_for(mounts, "/home/deck/Videos/NAS/a.mkv").fstype, "cifs")
    eq("mount_for root", library.mount_for(mounts, "/home/deck/Videos/a.mkv").fstype, "ext4")
    check("network fs", library.is_network_fs("cifs") and library.is_network_fs("fuse.sshfs")
        and not library.is_network_fs("exfat") and not library.is_network_fs("fuseblk"))
    local srcs = {{path = "/home/deck/Videos", kind = "folder"}, {path = "/run/media/deck/SD Card", kind = "sdcard"},
                  {path = "plex://m/", kind = "plex"}, {path = "/mnt/ssh", kind = "folder"}}
    eq("delete ok", library.delete_refusal("/home/deck/Videos/a.mkv", srcs, mounts, lcfg), nil)
    eq("delete sd ok", library.delete_refusal("/run/media/deck/SD Card/M/b.mp4", srcs, mounts, lcfg), nil)
    check("delete url", library.delete_refusal("https://s/library/parts/1/file.mkv", srcs, mounts, lcfg) ~= nil)
    check("delete plex key", library.delete_refusal("plex://m/library/metadata/1", srcs, mounts, lcfg) ~= nil)
    check("delete outside", library.delete_refusal("/home/deck/.ssh/id.mkv", srcs, mounts, lcfg) ~= nil)
    check("delete source itself", library.delete_refusal("/home/deck/Videos", srcs, mounts, lcfg) ~= nil)
    check("delete dotdot", library.delete_refusal("/home/deck/Videos/../x.mkv", srcs, mounts, lcfg) ~= nil)
    check("delete relative", library.delete_refusal("Videos/a.mkv", srcs, mounts, lcfg) ~= nil)
    check("delete not video", library.delete_refusal("/home/deck/Videos/notes.txt", srcs, mounts, lcfg) ~= nil)
    check("delete network share", library.delete_refusal("/home/deck/Videos/NAS/a.mkv", srcs, mounts, lcfg) ~= nil)
    check("delete sshfs", library.delete_refusal("/mnt/ssh/a.mkv", srcs, mounts, lcfg) ~= nil)
    local side = library.sidecar_subtitles("Film.mkv", {"Film.mkv", "Film.srt", "Film.en.srt", "Film.Extended.mkv",
        "Film.Extended.en.srt", "Other.srt", "Film.nfo", "Filmography.srt"})
    eq("sidecars", table.concat(side, ","), "Film.en.srt,Film.srt")
    check("is_video", library.is_video("a.MKV", lcfg) and not library.is_video("a.srt", lcfg))
end

-- Deleting for real, in a temporary download folder: the video, its
-- subtitles, then the season and show folders it leaves empty.
do
    local tmp = os.tmpname()
    os.remove(tmp)
    local dl = tmp .. "/Downloaded"
    local season = dl .. "/Show/Season 01"
    util.mkdir_p(season)
    local function touch(p) local f = io.open(p, "w") f:write("x") f:close() end
    touch(season .. "/Show - S01E01.mkv")
    touch(season .. "/Show - S01E01.en.srt")
    touch(dl .. "/Film.mkv")
    eq("readdir skips dots", #util.readdir(dl, "all"), 2)
    local dcfg = config.defaults()
    dcfg.library.download_folder = dl
    dcfg.library.folder = {}
    dcfg.library.removable_media = false
    local srcs = library.sources(dcfg)
    eq("download folder source", #srcs, 1)
    local ok, err = library.delete_video(season .. "/Show - S01E01.mkv", srcs, dcfg)
    check("delete episode", ok, err)
    check("season and show folders gone", not util.is_dir(dl .. "/Show"))
    check("subtitle gone", not util.file_exists(season .. "/Show - S01E01.en.srt"))
    check("download folder kept", util.is_dir(dl))
    check("delete film", library.delete_video(dl .. "/Film.mkv", srcs, dcfg))
    eq("empty download folder hidden", #library.sources(dcfg), 0)
    os.remove(dl)
    os.remove(tmp)
end

-- Folder listings in a subprocess (v0.7 work)
do
    local lcfg = config.defaults()
    local rec = function(t, m, sz, n) return t .. "\t" .. m .. "\t" .. sz .. "\t" .. n .. "\0" end
    local out = rec("d", "1700000000.5", "4096", "Season 1") .. rec("f", "1700000001.25", "1234", "Film.mkv")
        .. rec("f", "1", "10", "notes.txt") .. rec("d", "1", "4096", ".hidden") .. rec("l", "1", "9", "broken.mkv")
        .. rec("f", "2", "20", "Tab\tand\nnewline.mp4") .. "garbage-without-nul"
    local entries = library.parse_listing(out, "/v", lcfg, "name")
    eq("listing: dirs, videos only, no hidden", #entries, 3)
    eq("listing: folder first", entries[1].name, "Season 1")
    check("listing: folder flag", entries[1].is_dir and entries[1].path == "/v/Season 1")
    eq("listing: mtime floored", entries[1].mtime, 1700000000)
    local film
    for _, e in ipairs(entries) do if e.name == "Film.mkv" then film = e end end
    check("listing: file with size", film and film.size == 1234 and not film.is_dir)
    local odd
    for _, e in ipairs(entries) do if e.name:find("newline") then odd = e end end
    check("listing: tab and newline in a name", odd ~= nil and odd.name == "Tab\tand\nnewline.mp4")
    eq("listing: empty output", #library.parse_listing("", "/v", lcfg, "name"), 0)
    eq("listing error: none on success", library.listing_error({status = 0, stdout = ""}), nil)
    eq("listing error: partial output wins", library.listing_error({status = 1, stdout = out, stderr = "x"}), nil)
    eq("listing error: find's reason", library.listing_error({status = 1, stdout = "",
        stderr = "find: '/mnt/x': Permission denied\n"}), "Permission denied")
    check("listing error: no result", library.listing_error(nil) ~= nil)
    eq("list args: absolute path kept", library.list_args("/a b")[3], "/a b")

    local mounts = library.parse_mounts(table.concat({
        "22 1 0:21 / / rw - ext4 /dev/nvme0n1p8 rw",
        "40 22 0:40 / /mnt/nas rw - autofs systemd-1 rw",
        "41 40 0:41 / /mnt/nas rw - cifs //nas/share rw",
        "50 22 0:50 / /home/deck/net rw - nfs4 nas:/export rw",
        "60 22 179:1 / /run/media/deck/SD rw - ext4 /dev/mmcblk0p1 rw",
    }, "\n"))
    check("slow: cifs share", library.is_slow_path(mounts, "/mnt/nas/Movies/a.mkv"))
    check("slow: automount point", library.is_slow_path(mounts, "/mnt/nas"))
    check("slow: nfs", library.is_slow_path(mounts, "/home/deck/net/x"))
    check("not slow: SD card", not library.is_slow_path(mounts, "/run/media/deck/SD/a.mkv"))
    check("not slow: internal", not library.is_slow_path(mounts, "/home/deck/Videos/a.mkv"))
    eq("network tag", library.source_tag({kind = "network", name = "Movies"}), "Network")
    eq("network label", library.source_label({kind = "network", name = "Movies"}), "Network · Movies")
    local pts = library.parse_mountinfo("70 22 0:70 / /media/nas rw - cifs //nas/share rw")
    eq("removable list keeps fstype", pts[1] and pts[1].fstype, "cifs")

    -- The same real folder, listed here and through find(1).
    local tmp = os.tmpname()
    os.remove(tmp)
    util.mkdir_p(tmp .. "/Sub")
    local function touch(p) local f = io.open(p, "w") f:write("x") f:close() end
    touch(tmp .. "/b.mkv")
    touch(tmp .. "/A.mp4")
    touch(tmp .. "/skip.txt")
    touch(tmp .. "/.hidden.mkv")
    local utils = require "mp.utils"
    local res = utils.subprocess({args = library.list_args(tmp), cancellable = false})
    local via_find = library.parse_listing(res.stdout, tmp, lcfg, "name")
    local direct = library.list(tmp, lcfg, "name")
    local function names(list) local o = {} for _, e in ipairs(list) do o[#o + 1] = e.name end return table.concat(o, "|") end
    eq("find listing = direct listing", names(via_find), names(direct))
    eq("find listing contents", names(via_find), "Sub|A.mp4|b.mkv")
    check("find listing sizes", via_find[2].size == 1 and via_find[2].mtime == direct[2].mtime)
    for _, f in ipairs({"b.mkv", "A.mp4", "skip.txt", ".hidden.mkv"}) do os.remove(tmp .. "/" .. f) end
    os.remove(tmp .. "/Sub")
    os.remove(tmp)
end

-- Video menu decoding choice (D62)
do
    local Player = require "dvp.player"
    eq("software decoding", Player.hwdec_choice(true, config.HWDEC_AUTO), "no")
    eq("hardware = configured", Player.hwdec_choice(false, "vaapi-copy"), "vaapi-copy")
    eq("hardware when config says no", Player.hwdec_choice(false, "no"), config.HWDEC_AUTO)
    eq("hardware without a value", Player.hwdec_choice(false, nil), config.HWDEC_AUTO)
    local samples = {{t = 0, count = 0}, {t = 3, count = 6}, {t = 6, count = 12}}
    check("drops below the threshold", not Player.sustained_drops(samples, 6, 10, 15))
    samples[#samples + 1] = {t = 8, count = 16}
    check("steady drops", Player.sustained_drops(samples, 8, 10, 15))
    -- A burst long ago doesn't count: old samples are dropped.
    local old_burst = {{t = 0, count = 0}, {t = 1, count = 20}, {t = 30, count = 22}}
    check("old burst ignored", not Player.sustained_drops(old_burst, 30, 10, 15))
    eq("old samples removed (baseline kept)", #old_burst, 2)
    check("no samples", not Player.sustained_drops({}, 5, 10, 15))
    eq("remember software", Player.remembered_decoder(true, config.HWDEC_AUTO), "software")
    eq("hardware is the default", Player.remembered_decoder(false, config.HWDEC_AUTO), nil)
    eq("remember hardware when config says no", Player.remembered_decoder(false, "no"), "hardware")
    eq("software is the default with hwdec = no", Player.remembered_decoder(true, "no"), nil)
    local r = Resume.new(nil)
    r:set_decoder("/v/a.mkv", "software")
    eq("no entry, nothing stored", r:get("/v/a.mkv"), nil)
    r:update("/v/a.mkv", 100, 1000, "1", "no")
    r:set_decoder("/v/a.mkv", "software")
    eq("decoder stored", r:get("/v/a.mkv").decoder, "software")
    r:update("/v/a.mkv", 200, 1000, "1", "no")
    eq("decoder kept by update", r:get("/v/a.mkv").decoder, "software")
    r:set_decoder("/v/a.mkv", nil)
    eq("back to default clears it", r:get("/v/a.mkv").decoder, nil)
end

print(string.format("%d checks, %d failures", count, failures))
mp.commandv("quit", failures == 0 and "0" or "1")
