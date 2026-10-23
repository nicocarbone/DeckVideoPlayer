-- "About" panel, opened from the library menu and the playback menu:
-- version and build, project link, licence, details useful in bug reports,
-- credits and the trademark notice. See docs/DECISIONS.md D34.

local util = require "dvp.util"
local version = require "dvp.version"

local M = {}

M.REPO = "github.com/nicocarbone/DeckVideoPlayer"
M.LICENSE = "GPL-2.0-or-later"
M.DEVELOPER = "nicocarbone"
M.COPYRIGHT = "© 2026 nicocarbone"
M.STATUS = "Beta · tested on Steam Deck OLED"
M.TIP = "ko-fi.com/nicocarbone"
M.SPONSOR = "github.com/sponsors/nicocarbone"

-- Pure: parses the build-info file written by scripts/build-info.sh.
function M.parse_build_info(text)
    local info = {}
    for key, value in (text or ""):gmatch("([%w_]+)=([^\n]*)") do
        info[key] = util.trim(value)
    end
    return info
end

-- Pure: "2026-10-23 · 1a2b3c4", "2026-10-23" or "development build".
function M.build_text(info)
    if not info.date or info.date == "" then return "development build" end
    if info.commit and info.commit ~= "" then return info.date .. " · " .. info.commit end
    return info.date
end

local DEVICES = {["deck-oled"] = "Steam Deck OLED", ["deck-lcd"] = "Steam Deck LCD", tv = "TV / desktop"}

local function short_path(p)
    local home = os.getenv("HOME")
    if p and home and home ~= "" and p:sub(1, #home + 1) == home .. "/" then
        return "~" .. p:sub(#home + 1)
    end
    return p or "?"
end

local function runtime()
    local mpv = (mp.get_property("mpv-version") or "mpv"):gsub("^mpv v?", "")
    local parts = {"mpv " .. mpv}
    local ff = mp.get_property("ffmpeg-version")
    if ff then parts[#parts + 1] = "FFmpeg " .. ff end
    local lua = (type(jit) == "table" and jit.version) or _VERSION
    parts[#parts + 1] = lua
    return table.concat(parts, " · ")
end

-- ctx: cfg, display, app_dir, data_dir
function M.items(ctx)
    local info = M.parse_build_info(ctx.app_dir and util.read_file(ctx.app_dir .. "/build-info"))
    local function row(label, value) return {label = label, value = value} end
    local function header(label) return {label = label, header = true} end
    return {
        row("Version", version),
        row("Status", M.STATUS),
        row("Build", M.build_text(info)),
        row("Developer", M.DEVELOPER),
        row("Source code", M.REPO),
        row("License", M.LICENSE),
        {label = M.COPYRIGHT},
        {label = "Free software, provided without any warranty"},
        header("Support the project"),
        row("Tip (card/PayPal)", M.TIP),
        row("GitHub Sponsors", M.SPONSOR),
        header("System"),
        row("Player", runtime()),
        row("Device", DEVICES[ctx.display.device] or ctx.display.device),
        row("Settings", short_path(ctx.cfg.path)),
        row("Data", short_path(ctx.data_dir)),
        header("Credits"),
        row("Built on", "mpv, FFmpeg, libplacebo, libass, LuaJIT"),
        row("Font", "Inter (SIL Open Font License 1.1)"),
        row("Surround", "MIT KEMAR HRTF (Gardner & Martin, 1995)"),
        row("Subtitles", "OpenSubtitles.com"),
        {separator = true},
        {label = "Not affiliated with Valve Corporation."},
        {label = "Steam and Steam Deck are trademarks of Valve Corporation."},
        {label = "Close", action = function() end},
    }
end

function M.open(ctx)
    ctx.menu:open({title = "About", subtitle = "Deck Video Player " .. version,
                   style = "side", items = M.items(ctx)})
end

return M
