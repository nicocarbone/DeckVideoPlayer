-- Deck Video Player: a controller-driven front end for mpv, tuned for the
-- Steam Deck / SteamOS game mode.
--
-- mpv runs with --idle and --force-window; while idle this script shows the
-- library browser, and while a file plays it shows the playback overlay.

local msg = require "mp.msg"
local options = require "mp.options"

-- Make the dvp.* modules next to this file loadable on every mpv version.
local script_dir = mp.get_script_directory and mp.get_script_directory()
if script_dir then
    package.path = script_dir .. "/?.lua;" .. package.path
end

local util = require "dvp.util"
local config = require "dvp.config"
local ui = require "dvp.ui"
local input = require "dvp.input"
local Display = require "dvp.display"
local Resume = require "dvp.resume"
local Menu = require "dvp.menu"
local Browser = require "dvp.browser"
local Player = require "dvp.player"

local opts = {
    config_file = "",
    data_dir = "",
}
options.read_options(opts, "deckplayer")

local cfg, warnings = config.load(opts.config_file)
for _, w in ipairs(warnings) do msg.warn("config.ini: " .. w) end
if not cfg.loaded then
    msg.warn("config file not found (" .. tostring(opts.config_file) .. "), using defaults")
end
ui.configure(cfg)

if opts.data_dir ~= "" then util.mkdir_p(opts.data_dir) end

---------------------------------------------------------------------------
-- mpv options derived from config.ini
---------------------------------------------------------------------------

local function apply_playback_options()
    local pb = cfg.playback
    if pb.audio_languages ~= "" then mp.set_property("alang", pb.audio_languages) end
    if pb.subtitle_languages ~= "" then mp.set_property("slang", pb.subtitle_languages) end
    if pb.subtitles == "off" then
        mp.set_property("sid", "no")
    elseif pb.subtitles == "always" then
        mp.set_property("subs-with-matching-audio", "yes")
        mp.set_property("subs-fallback", "yes")
    elseif pb.subtitles == "forced" then
        mp.set_property("subs-with-matching-audio", "forced")
        mp.set_property("subs-fallback", "no")
        mp.set_property("subs-fallback-forced", "always")
    else
        -- auto: subtitles in your language unless the audio already is
        -- (forced subtitles are still shown).
        mp.set_property("subs-with-matching-audio", "forced")
        mp.set_property("subs-fallback", "default")
    end
    mp.set_property_number("volume-max", math.max(100, pb.volume_max))
    mp.set_property_number("volume", util.clamp(pb.volume, 0, pb.volume_max))
    if pb.audio_passthrough ~= "" and pb.audio_passthrough ~= "no" then
        mp.set_property("audio-spdif", pb.audio_passthrough)
    end
    local hwdec = pb.hwdec
    if hwdec == "auto" then hwdec = "vaapi,vulkan,auto-safe" end
    mp.set_property("hwdec", hwdec)
end

local display = Display.new(cfg)
display:apply_profile()
apply_playback_options()

---------------------------------------------------------------------------
-- Shared state and services
---------------------------------------------------------------------------

local resume = Resume.new(opts.data_dir)
local menu = Menu.new()
local state = {
    screen = "browser",
    quitting = false,
    pending_start = {},   -- path -> start position chosen in the browser
    current_path = nil,
    last_played = nil,
    from_ui = false,      -- set once the library has started any playback
    external = false,     -- launched with files (CLI / "Open with"): quit when done
    resumed_at = nil,     -- position restored automatically, announced on load
}

local toast_layer = ui.layer(60)
local toast_timer
local function toast(text)
    local t = ui.theme
    local W, H = ui.size()
    local a = ui.ass()
    local fs = 22
    local w = ui.text_width(text, fs) + 48
    local y = H * 0.17
    a:rect((W - w) / 2, y - 24, w, 48, {radius = 24, color = t.panel2, opacity = 0.95})
    a:text(W / 2, y, text, {size = fs, align = 5})
    toast_layer:set(a:build())
    if toast_timer then toast_timer:kill() end
    toast_timer = mp.add_timeout(1.8, function() toast_layer:clear() end)
end

local function track_id(kind)
    local id = mp.get_property_native("current-tracks/" .. kind .. "/id")
    return id and tostring(id) or "no"
end

local function save_progress()
    local path = state.current_path
    if not path then return end
    local pos = mp.get_property_number("time-pos")
    if not pos then return end
    resume:update(path, pos, mp.get_property_number("duration"), track_id("audio"), track_id("sub"))
end

local function play(list, start)
    if #list == 0 then return end
    state.from_ui = true
    state.pending_start = {[list[1]] = start or 0}
    mp.commandv("loadfile", list[1], "replace")
    for i = 2, #list do mp.commandv("loadfile", list[i], "append") end
end

local function stop_playback()
    save_progress()
    resume:flush()
    mp.commandv("stop")
end

local function quit()
    state.quitting = true
    save_progress()
    resume:flush()
    display:restore()
    mp.commandv("quit")
end

local function quit_dialog()
    menu:open({
        title = "Quit Deck Video Player?",
        style = "center",
        items = {
            {label = "Quit", action = quit},
            {label = "Cancel", action = function() end},
        },
        selected = 2,
    })
end

local function help()
    local function row(label, value) return {label = label, value = value} end
    local function header(label) return {label = label, header = true} end
    menu:open({
        title = "Controls",
        style = "side",
        items = {
            header("Library"),
            row("A", "Open / play"),
            row("X", "Play from start"),
            row("B", "Back"),
            row("Y", "Sort by name / date"),
            row("L1 / R1", "Page up / down"),
            header("Playback"),
            row("A", "Play / pause"),
            row("D-pad ← →", string.format("Seek %ds", cfg.playback.seek_short)),
            row("L1 / R1", string.format("Seek %ds", cfg.playback.seek_long)),
            row("L2 / R2", "Previous / next chapter"),
            row("D-pad ↑ ↓", "Volume"),
            row("X / Y", "Subtitles / audio"),
            row("View", "Playback info"),
            row("Menu", "Playback menu"),
            row("B", "Stop"),
            {label = "Close", action = function() end},
        },
    })
end

local ctx = {
    cfg = cfg, resume = resume, menu = menu, display = display,
    play = play, stop = stop_playback, quit = quit, quit_dialog = quit_dialog,
    help = help, toast = toast,
}
local browser = Browser.new(ctx)
local player = Player.new(ctx)

---------------------------------------------------------------------------
-- Input routing
---------------------------------------------------------------------------

input.init(function(action)
    if action == "quit" then
        quit()
        return
    end
    if menu:is_open() then
        menu:handle(action)
        if state.screen == "player" then player:render() end
        return
    end
    if state.screen == "player" then
        player:handle(action)
    else
        browser:handle(action)
    end
end)

---------------------------------------------------------------------------
-- Playback lifecycle
---------------------------------------------------------------------------

-- Decide the start position (resume) and restore track choices before the
-- file is opened.
mp.add_hook("on_load", 50, function()
    local path = mp.get_property("path")
    if not path then return end
    local start = state.pending_start[path]
    state.pending_start[path] = nil
    local entry = resume:get(path)
    if start == nil and cfg.playback.resume then
        -- Auto-advanced playlist entries and files opened from outside the
        -- library continue where they were left (announced with a toast).
        start = resume:position(path)
        state.resumed_at = start
    end
    if start and start > 0 then
        mp.set_property("file-local-options/start", tostring(start))
    end
    if entry and cfg.playback.resume then
        if entry.aid and entry.aid ~= "no" then mp.set_property("file-local-options/aid", entry.aid) end
        if entry.sid then mp.set_property("file-local-options/sid", entry.sid) end
    end
end)

-- Properties are still readable here, for every reason a file ends
-- (stop, end of file, next in playlist, quit).
mp.add_hook("on_unload", 50, function()
    save_progress()
    resume:flush()
end)

mp.register_event("start-file", function()
    -- Playback that the library didn't start came from the command line or
    -- a file manager: behave like a plain player and quit when it ends.
    if not state.from_ui then state.external = true end
    state.screen = "player"
    browser:hide()
    menu:close_all()
    player:start()
end)

mp.register_event("file-loaded", function()
    state.current_path = mp.get_property("path")
    state.last_played = state.current_path
    local fps = mp.get_property_number("container-fps")
    player.refresh_hz = display:match(fps)
    player:on_file_loaded()
    if state.resumed_at then
        toast("Resumed at " .. util.format_time(state.resumed_at))
        state.resumed_at = nil
    end
end)

mp.register_event("end-file", function(ev)
    if ev.reason == "error" then
        toast("Could not play this file")
        msg.error("playback failed: " .. tostring(ev.file_error))
    end
    state.current_path = nil
end)

-- Periodic save so progress survives Steam force-closing the app.
local save_timer = mp.add_periodic_timer(30, function()
    if state.current_path and not mp.get_property_native("pause") then
        save_progress()
        resume:flush()
    end
end)

mp.observe_property("idle-active", "bool", function(_, idle)
    if not idle or state.quitting then return end
    if state.external then
        quit()
        return
    end
    state.screen = "browser"
    menu:close_all()
    player:stop_screen()
    display:restore()
    browser:show()
    if state.last_played then
        browser:select_path(state.last_played)
        browser:render()
    end
end)

mp.observe_property("pause", "bool", function(_, paused)
    if paused and state.current_path then
        save_progress()
        resume:flush()
    end
    player:on_pause_change(paused)
end)

mp.observe_property("osd-dimensions", "native", function()
    if state.screen == "browser" then browser:render() else player:render() end
    player:render_info()
    menu:render()
end)

mp.register_event("shutdown", function()
    save_timer:kill()
    save_progress()
    resume:flush()
    display:restore()
end)

msg.info("Deck Video Player ready (config: " .. tostring(cfg.path) .. ")")
