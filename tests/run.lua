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

-- surround -----------------------------------------------------------------
eq("lavfi escape", Surround.escape_lavfi("/a b:c,[d]'e\\f"), "/a b\\\\:c\\,\\[d\\]\\\\\\'e\\\\\\\\f")
local fstr = Surround.filter_string("/x/h.sofa", 6)
local graph = "sofalizer=sofa=/x/h.sofa:gain=0:lfegain=3:type=freq,volume=12.5dB,"
    .. "alimiter=limit=0.891:attack=5:release=50:level=0"
eq("surround filter", fstr, "@dvp-surround:lavfi=graph=%" .. #graph .. "%" .. graph)
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
eq("plex movie title", pents[2].plex.title, "Alien (1979)")
eq("plex one-season show", pents[3].plex.key, "/library/metadata/8/allLeaves")
eq("plex one-season show lists episodes", pents[3].plex.kind, "episodes")
eq("plex show lists seasons", pents[4].plex.kind, "seasons")
eq("plex season lists episodes", Plex.entries_from({Metadata = {
    {type = "season", title = "Book Two", index = 2, key = "/library/metadata/10/children"}}},
    "https://srv", "m1", "seasons")[1].plex.kind, "episodes")
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

eq("plex sub key", SubDL.plex_key({machine = "ab12", rating_key = "77"}), "plex-ab12-77")
local pinfo = SubDL.plex_info({kind = "episode", show = "Sherlock", name = "The Blind Banker", season = 1, episode = 2})
check("plex sub info episode", pinfo.title == "Sherlock" and pinfo.season == 1 and pinfo.episode == 2)
pinfo = SubDL.plex_info({kind = "movie", name = "Some Film", year = 1995})
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
local pr = rows_of(VI.sections(VI.from_plex(md, "Home server")))
eq("plex server", pr["File/Server"], "Home server")
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
eq("hdr dynamic", Hdr.options(hs{gamma = "pq", mapping = "dynamic"}, hd)["target-colorspace-hint-mode"],
   "source-dynamic")
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
   Hdr.options(hs{gamma = "pq", mapping = "dynamic", screen = false}, hd)["target-colorspace-hint-mode"], "target")
eq("no hdr screen: nothing effective", Hdr.effective(hs{gamma = "pq", mapping = "dynamic", screen = false}), nil)
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

print(string.format("%d checks, %d failures", count, failures))
mp.commandv("quit", failures == 0 and "0" or "1")
