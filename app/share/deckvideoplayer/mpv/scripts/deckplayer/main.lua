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
local Surround = require "dvp.surround"
local SubDownload = require "dvp.subdownload"
local About = require "dvp.about"
local Plex = require "dvp.plex"

local opts = {
    config_file = "",
    data_dir = "",
    -- Development only: point the subtitle client at a mock server
    -- (tools/mock-opensubtitles.py).
    opensubtitles_url = "",
    -- Development only: never write progress/watched state to Plex servers
    -- (tools/headless-run.sh sets it unless PLEX_WRITE=1).
    plex_readonly = false,
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

-- The app's share directory (…/share/deckvideoplayer) is three levels above
-- this script (mpv/scripts/deckplayer).
local app_dir = script_dir and util.dirname(util.dirname(util.dirname(script_dir)))
local surround = Surround.new(cfg, app_dir and (app_dir .. "/hrtf/mit_kemar_normal_pinna.sofa"))

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

local plex = Plex.new(opts.data_dir, {allow_insecure = cfg.plex.allow_insecure_lan})
plex.readonly = opts.plex_readonly

-- Saves the position of the current file: in resume.json for local files,
-- on the server for Plex videos (D37). `ending`: the file is being closed
-- (blocking report so it arrives even when the app quits; a finished video
-- is marked watched).
local function save_progress(ending)
    local path = state.current_path
    if not path then return end
    local pos = mp.get_property_number("time-pos")
    if not pos then return end
    local duration = mp.get_property_number("duration")
    local item = plex:item_for(path)
    if item then
        if ending then
            plex:report(item, "stopped", pos, duration, true)
            -- Plex marks a video watched itself past its "video played
            -- threshold" (90 % by default); scrobble only below that, or
            -- the play would count twice (D39).
            if duration and duration > 0 and Resume.is_finished(pos, duration) and pos / duration < 0.9 then
                plex:set_watched(item, true, nil, true)
            end
        else
            plex:report(item, mp.get_property_native("pause") and "paused" or "playing", pos, duration)
        end
        return
    end
    resume:update(path, pos, duration, track_id("audio"), track_id("sub"))
end

-- `start`: seconds, or nil for "the saved position, if any" (on_load).
local function play(list, start)
    if #list == 0 then return end
    state.from_ui = true
    state.pending_start = {}
    if start then state.pending_start[list[1]] = start end
    mp.commandv("loadfile", list[1], "replace")
    for i = 2, #list do mp.commandv("loadfile", list[i], "append") end
end

-- Progress is saved by the on_unload hook, which mpv runs for stop and
-- quit too. Saving here as well would race: an async "playing" report could
-- reach Plex after the final "stopped" one.
local function stop_playback()
    mp.commandv("stop")
end

local function quit()
    state.quitting = true
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
            row("D-pad ← →", string.format("Seek −%ds / +%ds", cfg.playback.seek_short, cfg.playback.seek_short)),
            row("L1 / R1", string.format("Seek −%ds / +%ds", cfg.playback.seek_long, cfg.playback.seek_long)),
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
    help = help, toast = toast, surround = surround,
    app_dir = app_dir, data_dir = opts.data_dir, plex = plex,
}
ctx.about = function() About.open(ctx) end
ctx.subtitles = SubDownload.new(ctx, opts.data_dir, opts.opensubtitles_url)
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
        if state.screen == "player" then
            player:render()
        elseif not menu:is_open() then
            browser:render()   -- the selected entry may scroll again
        end
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
    state.resumed_at = nil   -- may be left over from a file that failed to open
    local path = mp.get_property("path")
    state.loading_path = path  -- known even if the file then fails to open
    if not path then return end
    -- Track choices and sync offsets are per file: set them file-locally so
    -- whatever the user changes during this file is undone when it ends
    -- (mpv otherwise keeps runtime changes of aid/sid/delays for the next
    -- file). The saved choice from resume.json below overrides them.
    mp.set_property("file-local-options/aid", "auto")
    mp.set_property("file-local-options/sid", cfg.playback.subtitles == "off" and "no" or "auto")
    mp.set_property_number("file-local-options/sub-delay", 0)
    mp.set_property_number("file-local-options/audio-delay", 0)
    local start = state.pending_start[path]
    state.pending_start[path] = nil
    local item = plex:item_for(path)
    state.plex_subs = nil
    if item then
        -- Plex: the token goes in a header (never in the URL), and the
        -- server's resume point and subtitle files are fetched now.
        local prep = plex:prepare(item)
        -- Streaming token only if the server answered (don't wait twice for
        -- an unreachable server).
        if prep.ok then
            mp.set_property("file-local-options/http-header-fields", plex:header_fields(item))
        end
        mp.set_property("file-local-options/force-media-title", item.title or "")
        state.plex_subs = prep.subs
        if start == nil and cfg.playback.resume and prep.pos
            and not Resume.is_finished(prep.pos, (item.duration or 0) / 1000) then
            start = prep.pos
            state.resumed_at = start
        end
        if start and start > 0 then mp.set_property("file-local-options/start", tostring(start)) end
        return
    end
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

-- Subtitles downloaded earlier for this video are added after the file is
-- opened but before tracks are selected, so they take part in selection.
mp.add_hook("on_preloaded", 50, function()
    ctx.subtitles:load_stored(mp.get_property("path"))
    -- Subtitle files stored next to a Plex video on the server.
    for _, s in ipairs(state.plex_subs or {}) do
        mp.commandv("sub-add", s.url, "auto", s.title, s.lang)
    end
end)

-- Properties are still readable here, for every reason a file ends
-- (stop, end of file, next in playlist, quit).
mp.add_hook("on_unload", 50, function()
    save_progress(true)
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
    display:match(fps, function() player:render() end)
    player:on_file_loaded()
    if state.resumed_at then
        toast("Resumed at " .. util.format_time(state.resumed_at))
        state.resumed_at = nil
    end
end)

mp.register_event("end-file", function(ev)
    if ev.reason == "error" then
        -- A Plex server may have restarted (stale streaming token) or the
        -- network changed: reconnect and ask for a new token next time.
        local item = plex:item_for(state.loading_path)
        if item then plex:forget_session(item.machine) end
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
    browser:show(state.last_played)
end)

mp.observe_property("pause", "bool", function(_, paused)
    if paused and state.current_path then
        save_progress()
        resume:flush()
    elseif paused == false then
        -- Resuming: if Steam re-applied its own refresh setting meanwhile
        -- (e.g. from the Quick Access Menu), ask for our rate again.
        display:reassert(function() player:render() end)
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
