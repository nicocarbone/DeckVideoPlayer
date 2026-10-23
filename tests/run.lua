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
eq("mountinfo count", #points, 3)
eq("mountinfo escape", points[1], "/run/media/deck/SD Card")

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

-- media --------------------------------------------------------------------
eq("lang", media.language("spa"), "Spanish")
eq("lang unknown", media.language("xyz"), "XYZ")
eq("codec dts-hd", media.codec("dts", "DTS-HD MA"), "DTS-HD MA")
eq("track label", media.track_label({id = 1, lang = "eng", title = "Commentary"}), "English · Commentary")
eq("track detail", media.track_detail({type = "audio", codec = "truehd", ["demux-channel-count"] = 8, default = true}),
    "TrueHD · 7.1 · Default")
eq("res 4k", media.resolution_badge(3840, 1600), "4K")
eq("res 1080p scope", media.resolution_badge(1920, 800), "1080p")

print(string.format("%d checks, %d failures", count, failures))
mp.commandv("quit", failures == 0 and "0" or "1")
