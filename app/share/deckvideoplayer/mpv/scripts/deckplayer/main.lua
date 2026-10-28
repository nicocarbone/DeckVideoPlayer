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
local NightMode = require "dvp.nightmode"
local Hdr = require "dvp.hdr"
local KeepAwake = require "dvp.keepawake"
local SubDownload = require "dvp.subdownload"
local About = require "dvp.about"
local Plex = require "dvp.plex"
local Servers = require "dvp.servers"
local Jellyfin = require "dvp.jellyfin"
local Downloads = require "dvp.downloads"

local opts = {
    config_file = "",
    data_dir = "",
    -- Development only: point the subtitle client at a mock server
    -- (tools/mock-opensubtitles.py).
    opensubtitles_url = "",
    -- Development only: never write progress/watched state to Plex servers
    -- (tools/headless-run.sh sets it unless PLEX_WRITE=1).
    plex_readonly = false,
    -- Same for Jellyfin servers (unless JELLYFIN_WRITE=1).
    jellyfin_readonly = false,
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

local configured_hwdec   -- config.ini's hwdec as given to mpv

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
    if hwdec == "auto" then hwdec = config.HWDEC_AUTO end
    configured_hwdec = hwdec
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
local surround = Surround.new(cfg, app_dir and (app_dir .. "/hrtf/mit_kemar_normal_pinna_dfeq.sofa"))
local night = NightMode.new(cfg)

local resume = Resume.new(opts.data_dir)
local keepawake = KeepAwake.new(cfg, opts.data_dir)
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
    finished_path = nil,  -- file the user finished early (R2 Next episode)
}

local toast_layer = ui.layer(60)
local toast_timer
-- `seconds`: how long it stays (default 1.8 s).
local function toast(text, seconds)
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
    toast_timer = mp.add_timeout(seconds or 1.8, function()
        toast_layer:clear()
        toast_timer = nil
    end)
end

-- B during playback closes a toast first. Returns true if one was showing.
local function dismiss_toast()
    if not toast_timer then return false end
    toast_timer:kill()
    toast_timer = nil
    toast_layer:clear()
    return true
end

-- After apply_profile(): its option values are the ones restored. When it
-- learns whether the screen is in HDR mode, an open Video menu is rebuilt
-- (the badges follow mpv's output, see player.lua).
local hdr = Hdr.new(cfg, display.device, function(text)
    if text then toast(text) end
    if menu:is_open() then menu:refresh() end
end)

local function track_id(kind)
    local id = mp.get_property_native("current-tracks/" .. kind .. "/id")
    return id and tostring(id) or "no"
end

local plex = Plex.new(opts.data_dir, {allow_insecure = cfg.plex.allow_insecure_lan})
plex.readonly = opts.plex_readonly
local jellyfin = Jellyfin.new(opts.data_dir, {urls = cfg.jellyfin.server})
jellyfin.readonly = opts.jellyfin_readonly
-- Media servers behind one interface (D55).
local servers = Servers.new({plex, jellyfin})

-- Saves the position of the current file: in resume.json for local files,
-- on the server for Plex / Jellyfin videos (D37, D55). `ending`: the file is
-- being closed (blocking report so it arrives even when the app quits; a
-- finished video is marked watched).
local function save_progress(ending)
    local path = state.current_path
    if not path then return end
    local pos = mp.get_property_number("time-pos")
    if not pos then return end
    local duration = mp.get_property_number("duration")
    -- Skipped the closing credits to the next episode: as if it had ended.
    if ending and state.finished_path == path and duration then pos = duration end
    local item, backend = servers:item_for(path)
    if item then
        if ending then
            backend:report(item, "stopped", pos, duration, true)
            -- The server marks a video watched itself past its threshold
            -- (90 % by default in Plex and Jellyfin); mark it only below
            -- that, or the play would count twice (D39).
            if duration and duration > 0 and Resume.is_finished(pos, duration) and pos / duration < 0.9 then
                backend:set_watched(item, true, nil, true)
            end
        else
            backend:report(item, mp.get_property_native("pause") and "paused" or "playing", pos, duration)
        end
        -- A local copy for "Recently played" (D50); the server stays the
        -- source of truth for the position.
        local key = backend.recent_key(item)
        if key then
            resume:update(key, pos, duration, nil, nil, item.title)
            resume:set_decoder(key, Player.remembered_decoder(mp.get_property("hwdec") == "no", configured_hwdec))
        end
        return
    end
    resume:update(path, pos, duration, track_id("audio"), track_id("sub"))
    resume:set_decoder(path, Player.remembered_decoder(mp.get_property("hwdec") == "no", configured_hwdec))
end

-- Decoding chosen in the Video menu for this video last time (D62).
local function restore_decoder(key)
    local e = key and resume:get(key)
    if e and e.decoder then
        mp.set_property("file-local-options/hwdec", Player.hwdec_choice(e.decoder == "software", configured_hwdec))
    end
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
-- reach the server after the final "stopped" one.
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
            row("View", "Video info"),
            row("L1 / R1", "Page up / down"),
            header("Playback"),
            row("A", "Play / pause"),
            row("D-pad ← →", string.format("Seek −%ds / +%ds", cfg.playback.seek_short, cfg.playback.seek_short)),
            row("L1 / R1", string.format("Seek −%ds / +%ds", cfg.playback.seek_long, cfg.playback.seek_long)),
            row("L2 / R2", "Previous / next chapter (R2 skips an intro or credits)"),
            row("D-pad ↑ ↓", "Volume"),
            row("X / Y", "Subtitles / audio"),
            row("View", "Playback info"),
            row("Menu", "Playback menu"),
            row("B", "Close messages and controls, then stop"),
            {label = "Close", action = function() end},
        },
    })
end

local ctx = {
    cfg = cfg, resume = resume, menu = menu, display = display,
    play = play, stop = stop_playback, quit = quit, quit_dialog = quit_dialog,
    help = help, toast = toast, dismiss_toast = dismiss_toast, surround = surround, night = night, keepawake = keepawake,
    hdr = hdr,
    app_dir = app_dir, data_dir = opts.data_dir, plex = plex, jellyfin = jellyfin, servers = servers,
    finished = function() state.finished_path = state.current_path end,
}
ctx.about = function() About.open(ctx) end
ctx.subtitles = SubDownload.new(ctx, opts.data_dir, opts.opensubtitles_url)
ctx.downloads = Downloads.new(ctx, opts.data_dir)
local browser = Browser.new(ctx)
local player = Player.new(ctx)

-- Downloads (D60): the library follows them; finishing is announced there,
-- not over a playing video.
ctx.changed = function(job)
    if state.screen ~= "browser" then return end
    if job and job.status == "done" then
        toast("Downloaded: " .. job.title)
    elseif job and job.status == "failed" then
        toast("Download failed: " .. tostring(job.error))
    end
    browser:downloads_changed()
end
ctx.play_path = function(path) browser:play_path(path) end
ctx.browse = function(folder, select) browser:open_folder(folder, select) end
ctx.delete = function(path, label) browser:delete_dialog(path, label) end

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
    state.finished_path = nil
    player:set_markers({})   -- the previous file's, while this one is prepared
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
    local item, backend = servers:item_for(path)
    state.server_subs = nil
    if item then
        -- Media server: a token, if any, goes in a header (never in the
        -- URL), and the server's resume point and subtitle files are
        -- fetched now.
        local prep = backend:prepare(item)
        state.server_prepared = prep.ok
        state.server_unreachable = prep.unreachable
        -- Streaming header only if the server answered (don't wait twice for
        -- an unreachable server).
        if prep.ok then
            mp.set_property("file-local-options/http-header-fields", backend:header_fields(item))
        elseif prep.unreachable then
            -- Fail now instead of waiting for a network timeout, and drop the
            -- rest of the playlist: every next episode would wait as well.
            mp.commandv("playlist-clear")
            mp.set_property("stream-open-filename", "dvp-server-unreachable://")
        end
        mp.set_property("file-local-options/force-media-title", item.title or "")
        restore_decoder(backend.recent_key(item))
        state.server_subs = prep.subs
        player:set_markers(prep.markers)
        if start == nil and cfg.playback.resume and prep.pos
            and not Resume.is_finished(prep.pos, (item.duration or 0) / 1000) then
            start = prep.pos
            state.resumed_at = start
        end
        if start and start > 0 then mp.set_property("file-local-options/start", tostring(start)) end
        return
    end
    local entry = resume:get(path)
    restore_decoder(path)
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
    -- Subtitle files stored next to a server video (Plex, Jellyfin).
    for _, s in ipairs(state.server_subs or {}) do
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

-- Periodic save so progress survives Steam force-closing the app. Runs
-- only while a file is open (started on file-loaded, stopped when idle).
local save_timer = mp.add_periodic_timer(30, function()
    if state.current_path and not mp.get_property_native("pause") then
        save_progress()
        resume:flush()
    end
end)
save_timer:kill()

mp.register_event("file-loaded", function()
    state.current_path = mp.get_property("path")
    if not save_timer:is_enabled() then save_timer:resume() end
    state.last_played = state.current_path
    local fps = mp.get_property_number("container-fps")
    display:match(fps, function() player:render() end)
    keepawake:set_playing(not mp.get_property_native("pause"))
    if state.resumed_at then
        toast("Resumed at " .. util.format_time(state.resumed_at))
        state.resumed_at = nil
    end
    -- After the toast above: "Skipped intro" (skip_intro = auto) replaces it.
    player:on_file_loaded()
end)

mp.register_event("end-file", function(ev)
    if ev.reason == "error" then
        local item, backend = servers:item_for(state.loading_path)
        if item and state.server_prepared then
            -- The server answered: keep the connection for the next episode;
            -- only the streaming token may be stale (server restart).
            backend:forget_token(item.machine)
        elseif item then
            -- Unreachable: reconnect (maybe another address) next time.
            backend:forget_session(item.machine)
        end
        toast(item and state.server_unreachable and ("Can't reach the " .. backend.NAME .. " server")
              or "Could not play this file")
        msg.error("playback failed: " .. tostring(ev.file_error))
    end
    state.current_path = nil
end)

mp.observe_property("idle-active", "bool", function(_, idle)
    if not idle or state.quitting then return end
    if state.external then
        quit()
        return
    end
    state.screen = "browser"
    save_timer:kill()
    keepawake:set_playing(false)
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
    if state.current_path then keepawake:set_playing(paused == false) end
    player:on_pause_change(paused)
end)

mp.observe_property("osd-dimensions", "native", function()
    if state.screen == "browser" then browser:render() else player:render() end
    player:render_marker()
    player:render_info()
    menu:render()
end)

mp.register_event("shutdown", function()
    save_timer:kill()
    ctx.downloads:shutdown()
    keepawake:set_playing(false)
    save_progress()
    resume:flush()
    display:restore()
end)

msg.info("Deck Video Player ready (config: " .. tostring(cfg.path) .. ")")
