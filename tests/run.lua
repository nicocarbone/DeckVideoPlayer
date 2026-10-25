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
local graph = "sofalizer=sofa=/x/h.sofa:gain=6:type=freq"
eq("surround filter", fstr, "@dvp-surround:lavfi=graph=%" .. #graph .. "%" .. graph)

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
local ks = KeepAwake.parse_status("request: portal not supported, screensaver accepted\n")
eq("awake status", ks.request, "portal not supported, screensaver accepted")
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

print(string.format("%d checks, %d failures", count, failures))
mp.commandv("quit", failures == 0 and "0" or "1")
