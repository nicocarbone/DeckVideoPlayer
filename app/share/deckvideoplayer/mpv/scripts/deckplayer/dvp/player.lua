-- The playback screen: on-screen controls overlay, info panel and the
-- in-player menus (audio, subtitles, settings).
--
-- Timers only run while something is visible, so steady playback with the
-- overlay hidden costs no Lua work at all.

local ui = require "dvp.ui"
local util = require "dvp.util"
local media = require "dvp.media"
local library = require "dvp.library"
local Menu = require "dvp.menu"
local cropdetect = require "dvp.cropdetect"

local M = {}
M.__index = M

-- ctx: cfg, menu, display, surround, subtitles, stop(), quit(), toast(text)
function M.new(ctx)
    local self = setmetatable({}, M)
    self.ctx = ctx
    self.cfg = ctx.cfg
    self.layer = ui.layer(10)
    self.info_layer = ui.layer(20)
    self.overlay_visible = false
    self.info_visible = false
    self.active = false
    -- Per-file data that doesn't change every frame, cached so the 0.5 s
    -- overlay redraw doesn't re-marshal track/chapter lists from mpv.
    self.title_text = ""
    self.video_track = nil
    self.chapters = {}
    mp.observe_property("chapter-list", "native", function(_, list) self.chapters = list or {} end)
    -- Picture mode is per file: remember the user's configured defaults
    -- (mpv.conf / user mpv.conf) and restore them when a new file starts.
    self.zoom_defaults = {
        panscan = mp.get_property_number("panscan", 0),
        keepaspect = mp.get_property_bool("keepaspect", true),
    }
    self.zoom_touched = false
    self.timer = mp.add_periodic_timer(0.5, function() self:tick() end)
    self.timer:kill()
    self.hide_timer = nil
    return self
end

---------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------

function M:start()
    self.active = true
    self.video_track = nil
    local name = util.basename(mp.get_property("path") or "")
    local item = self.ctx.plex and self.ctx.plex:item_for(mp.get_property("path"))
    self.title_text = item and item.title or library.display_name(name, false, self.cfg.interface.clean_names)
    if self.zoom_touched then
        mp.set_property_number("panscan", self.zoom_defaults.panscan)
        mp.set_property_bool("keepaspect", self.zoom_defaults.keepaspect)
        self.zoom_touched = false
    end
    self.crop_bars = false   -- video-crop itself is file-local
    self:show_overlay()
end

-- Called by main.lua once the file's tracks are known.
function M:on_file_loaded()
    self.video_track = media.selected_track("video")
    self:render()
end

function M:stop_screen()
    self.active = false
    self.overlay_visible = false
    self.info_visible = false
    if self.stats_visible then self:toggle_stats() end   -- not over the library
    self.layer:clear()
    self.info_layer:clear()
    self.timer:kill()
    if self.hide_timer then self.hide_timer:kill() end
end

-- The 0.5 s tick only runs while the overlay or info panel is visible and
-- the video plays: paused, nothing on screen changes by itself.
function M:update_timer()
    if self.active and (self.overlay_visible or self.info_visible) and not mp.get_property_native("pause") then
        self.timer:resume()
    else
        self.timer:kill()
    end
end

function M:tick()
    if self.overlay_visible then self:render() end
    if self.info_visible then self:render_info() end
end

function M:show_overlay(sticky_seconds)
    if not self.active then return end
    self.overlay_visible = true
    if self.hide_timer then self.hide_timer:kill() end
    local timeout = sticky_seconds or self.cfg.interface.overlay_timeout
    self.hide_timer = mp.add_timeout(timeout, function()
        -- Stay visible while paused (unpausing re-arms the timeout, see
        -- on_pause_change; nothing to redraw meanwhile) or while a menu is
        -- open over the video (checked again later).
        if mp.get_property_native("pause") then return end
        if self.ctx.menu:is_open() then
            self:show_overlay()
            return
        end
        self:hide_overlay()
    end)
    self:render()
    self:update_timer()
end

function M:hide_overlay()
    self.overlay_visible = false
    if self.hide_timer then self.hide_timer:kill() end
    self.layer:clear()
    self:update_timer()
end

function M:on_pause_change(paused)
    if not self.active then return end
    if paused or self.overlay_visible then self:show_overlay() else self:update_timer() end
    if self.info_visible then self:render_info() end   -- e.g. Keep awake stops/starts
end

---------------------------------------------------------------------------
-- Actions
---------------------------------------------------------------------------

function M:seek(seconds, exact)
    mp.commandv("seek", tostring(seconds), exact and "relative+exact" or "relative+keyframes")
    self:show_overlay()
end

function M:chapter(dir)
    local chapters = mp.get_property_number("chapters", 0)
    if chapters > 0 then
        local cur = mp.get_property_number("chapter", -1)
        if dir < 0 then
            -- Like most players: jump to the start of the current chapter
            -- first, unless we are already near it.
            local list = self.chapters
            local pos = mp.get_property_number("time-pos", 0)
            local ch = list[cur + 1]
            if ch and pos - ch.time > 3 then
                mp.commandv("seek", tostring(ch.time), "absolute")
                self:show_overlay()
                return
            end
        end
        mp.commandv("add", "chapter", tostring(dir))
        self.ctx.toast(dir > 0 and "Next chapter" or "Previous chapter")
    else
        self:seek(dir * 300)
    end
    self:show_overlay()
end

function M:change_volume(delta)
    local max = self.cfg.playback.volume_max
    local v = util.clamp(mp.get_property_number("volume", 100) + delta, 0, max)
    mp.set_property_number("volume", v)
    self.ctx.toast(string.format("Volume %d%%", v))
end

-- mpv's own statistics overlay (stats.lua); tracked so B can close it.
function M:toggle_stats()
    self.stats_visible = not self.stats_visible
    mp.commandv("script-binding", "stats/display-stats-toggle")
end

function M:toggle_info()
    self.info_visible = not self.info_visible
    if self.info_visible then self:render_info() else self.info_layer:clear() end
    self:update_timer()
end

function M:handle(action)
    local pb = self.cfg.playback
    if action == "confirm" or action == "playpause" then
        mp.commandv("cycle", "pause")
        self:show_overlay()
    elseif action == "back" then
        -- B dismisses what is on screen first; with nothing shown, it stops.
        if self.overlay_visible then
            self:hide_overlay()
        elseif self.info_visible then
            self:toggle_info()
        elseif self.stats_visible then
            self:toggle_stats()
        else
            self.ctx.stop()
        end
    elseif action == "stop" then
        self.ctx.stop()
    elseif action == "left" then
        self:seek(-pb.seek_short, true)
    elseif action == "right" then
        self:seek(pb.seek_short, true)
    elseif action == "lb" then
        self:seek(-pb.seek_long)
    elseif action == "rb" then
        self:seek(pb.seek_long)
    elseif action == "lt" then
        self:chapter(-1)
    elseif action == "rt" then
        self:chapter(1)
    elseif action == "up" then
        self:change_volume(5)
    elseif action == "down" then
        self:change_volume(-5)
    elseif action == "x" then
        self:open_subtitle_menu()
    elseif action == "y" then
        self:open_audio_menu()
    elseif action == "menu" then
        self:open_main_menu()
    elseif action == "view" then
        self:toggle_info()
    end
end

---------------------------------------------------------------------------
-- Menus
---------------------------------------------------------------------------

function M:audio_items()
    local items = {}
    for _, t in ipairs(media.tracks("audio")) do
        items[#items + 1] = {
            label = media.track_label(t), value = media.track_detail(t), checked = t.selected,
            action = function()
                mp.set_property_number("aid", t.id)
                self.ctx.toast("Audio: " .. media.track_label(t))
            end,
        }
    end
    if #items == 0 then items[1] = {label = "No audio tracks", disabled = true} end
    local surround = self.ctx.surround
    if surround.available then
        items[#items + 1] = {separator = true}
        items[#items + 1] = {
            label = "Headphone surround",
            value = function() return surround.enabled and "On" or "Off" end,
            adjust = function() self:toggle_surround() end,
        }
    end
    return items
end

function M:toggle_surround()
    local surround = self.ctx.surround
    if not surround:toggle() then
        self.ctx.toast("Headphone surround off")
    elseif surround.active then
        self.ctx.toast("Headphone surround on")
    else
        -- Stereo source: nothing to virtualise, the filter waits for 5.1/7.1.
        self.ctx.toast("Headphone surround on (for 5.1 and 7.1 audio)")
    end
end

function M:subtitle_items()
    local sid = mp.get_property("sid")
    local items = {{
        label = "Off", checked = sid == "no" or sid == nil,
        action = function()
            mp.set_property("sid", "no")
            self.ctx.toast("Subtitles off")
        end,
    }}
    for _, t in ipairs(media.tracks("sub")) do
        items[#items + 1] = {
            label = media.track_label(t), value = media.track_detail(t), checked = t.selected,
            action = function()
                mp.set_property_number("sid", t.id)
                mp.set_property_bool("sub-visibility", true)
                self.ctx.toast("Subtitles: " .. media.track_label(t))
            end,
        }
    end
    local path = mp.get_property("path")
    if self.ctx.subtitles:available(path) then
        items[#items + 1] = {separator = true}
        items[#items + 1] = {label = "Download subtitles…", action = function() self.ctx.subtitles:open(path) end}
    end
    return items
end

local function selected_index(items)
    for i, it in ipairs(items) do
        if it.checked then return i end
    end
    return 1
end

function M:open_audio_menu()
    local items = self:audio_items()
    self.ctx.menu:open({title = "Audio", style = "side", items = items,
                        rebuild = function() return self:audio_items() end,
                        selected = selected_index(items), close_action = "y"})
    self:show_overlay()
end

function M:open_subtitle_menu()
    local items = self:subtitle_items()
    self.ctx.menu:open({title = "Subtitles", style = "side", items = items,
                        selected = selected_index(items), close_action = "x",
                        rebuild = function() return self:subtitle_items() end})
    self:show_overlay()
end

local ZOOM_MODES = {"fit", "bars", "fill", "stretch"}
local ZOOM_LABELS = {fit = "Fit", bars = "Crop black bars", fill = "Fill (crop)", stretch = "Stretch",
                     custom = "Custom"}

-- Current picture mode, read from mpv so it is always truthful (a user
-- mpv.conf may set its own panscan).
function M:zoom_mode()
    if self.crop_bars then return "bars" end
    if not mp.get_property_bool("keepaspect", true) then return "stretch" end
    local panscan = mp.get_property_number("panscan", 0)
    if panscan >= 0.99 then return "fill" end
    if panscan <= 0.01 then return "fit" end
    return "custom"
end

function M:set_zoom(mode)
    mp.set_property_number("panscan", mode == "fill" and 1.0 or 0.0)
    mp.set_property_bool("keepaspect", mode ~= "stretch")
    self.zoom_touched = true
    if mode == "bars" then
        -- Only shown as the mode when a crop was applied: after "no bars
        -- found" the row says Fit, and the next press tries again.
        self.crop_bars = self:crop_black_bars()
    elseif self.crop_bars then
        self.crop_bars = false
        mp.set_property("file-local-options/video-crop", "")
    end
end

-- Black bars encoded into the video (e.g. a 4:3 show stored as 16:9) are
-- part of the picture for Fit/Fill: find them in the current frame and crop
-- them away, then fit what is left. Runs once, when chosen (D42).
function M:crop_black_bars()
    mp.set_property("file-local-options/video-crop", "")
    local shot = mp.command_native({"screenshot-raw", "video", "bgr0"})
    local b = cropdetect.from_screenshot(shot)
    shot = nil
    collectgarbage()   -- a 4K frame is 33 MB
    if b then
        mp.set_property("file-local-options/video-crop", string.format("%dx%d+%d+%d", b.w, b.h, b.x, b.y))
        self.ctx.toast(string.format("Cropped to %dx%d", b.w, b.h))
        return true
    end
    self.ctx.toast("No black bars found (try again in a brighter scene)")
    return false
end

local function cycle(list, current, dir)
    for i, v in ipairs(list) do
        if v == current then return list[(i - 1 + dir) % #list + 1] end
    end
    return list[1]
end

-- Session toggle for refresh-rate matching (config.ini sets the default).
function M:toggle_refresh()
    local display = self.ctx.display
    local on = not display.refresh_on
    local hz = display:set_matching(on, mp.get_property_number("container-fps"),
                                    function() self:render() end)
    if not on then
        self.ctx.toast("Refresh-rate matching off")
    elseif hz then
        self.ctx.toast(string.format("Refresh rate: %d Hz", hz))
    else
        -- e.g. a 30 fps video on a 60 Hz-only screen: nothing to change.
        self.ctx.toast("Refresh-rate matching on (no better rate for this video)")
    end
    self:render()
end

function M:main_menu_items()
    local function prop_num(name, default) return mp.get_property_number(name, default) end
    local items = {}
    local at = media.selected_track("audio")
    local st = media.selected_track("sub")
    items[#items + 1] = {label = "Audio track", value = at and media.track_label(at) or "None",
                         action = function() self:open_audio_menu() end}
    items[#items + 1] = {label = "Subtitles", value = st and media.track_label(st) or "Off",
                         action = function() self:open_subtitle_menu() end}
    items[#items + 1] = {label = "Subtitle size",
        value = function() return string.format("%d%%", util.round(prop_num("sub-scale", 1) * 100)) end,
        adjust = function(d)
            mp.set_property_number("sub-scale", util.clamp(prop_num("sub-scale", 1) + d * 0.1, 0.5, 2.5))
        end}
    items[#items + 1] = {label = "Subtitle position",
        value = function() return tostring(prop_num("sub-pos", 100)) end,
        adjust = function(d)
            mp.set_property_number("sub-pos", util.clamp(prop_num("sub-pos", 100) + d * 2, 50, 150))
        end}
    items[#items + 1] = {label = "Subtitle delay",
        value = function() return string.format("%+.1f s", prop_num("sub-delay", 0)) end,
        adjust = function(d) mp.commandv("add", "sub-delay", tostring(d * 0.1)) end}
    items[#items + 1] = {label = "Audio delay",
        value = function() return string.format("%+.2f s", prop_num("audio-delay", 0)) end,
        adjust = function(d) mp.commandv("add", "audio-delay", tostring(d * 0.05)) end}
    items[#items + 1] = {label = "Volume",
        value = function() return string.format("%d%%", prop_num("volume", 100)) end,
        adjust = function(d)
            mp.set_property_number("volume",
                util.clamp(prop_num("volume", 100) + d * 5, 0, self.cfg.playback.volume_max))
        end}
    items[#items + 1] = {label = "Speed",
        value = function() return string.format("%.2gx", prop_num("speed", 1)) end,
        adjust = function(d)
            mp.set_property_number("speed", util.clamp(prop_num("speed", 1) + d * 0.25, 0.25, 3))
        end}
    items[#items + 1] = {label = "Picture",
        value = function() return ZOOM_LABELS[self:zoom_mode()] end,
        adjust = function(d) self:set_zoom(cycle(ZOOM_MODES, self:zoom_mode(), d)) end}
    local display = self.ctx.display
    if display.refresh_possible then
        items[#items + 1] = {label = "Match refresh rate",
            value = function() return display.refresh_on and "On" or "Off" end,
            adjust = function() self:toggle_refresh() end}
    end
    local pl_pos = mp.get_property_number("playlist-pos", 0)
    local pl_count = mp.get_property_number("playlist-count", 1)
    if pl_pos + 1 < pl_count then
        items[#items + 1] = {label = "Play next video", action = function() mp.commandv("playlist-next") end}
    end
    items[#items + 1] = {label = "Playback info", action = function() self:toggle_info() end}
    items[#items + 1] = {label = "Advanced statistics", action = function() self:toggle_stats() end}
    items[#items + 1] = {label = "About", action = function() self.ctx.about() end}
    items[#items + 1] = {label = "Stop and return to library", action = function() self.ctx.stop() end}
    items[#items + 1] = {label = "Quit Deck Video Player", action = function() self.ctx.quit() end}
    return items
end

function M:open_main_menu()
    self.ctx.menu:open({title = "Playback", style = "side", items = self:main_menu_items(),
                        rebuild = function() return self:main_menu_items() end,
                        close_action = "menu"})
    self:show_overlay()
end

---------------------------------------------------------------------------
-- Overlay rendering
---------------------------------------------------------------------------

function M:title()
    return self.title_text
end

function M:badges()
    local out = {}
    local source, output_hdr, vp = media.hdr_state(self.video_track)
    local res = media.resolution_badge(vp.w, vp.h)
    if res then out[#out + 1] = {text = res} end
    if source and source ~= "SDR" then
        if output_hdr then
            out[#out + 1] = {text = source, color = ui.theme.warn}
        else
            out[#out + 1] = {text = source .. " → SDR", color = ui.theme.subtext}
        end
    end
    local hw = mp.get_property("hwdec-current")
    if hw and hw ~= "" and hw ~= "no" then
        out[#out + 1] = {text = "HW"}
    end
    -- A requested rate, unless gamescope contradicted it (D31).
    local d = self.ctx.display
    if d.requested_hz and d.verified ~= false then
        out[#out + 1] = {text = d.requested_hz .. " Hz"}
    end
    return out
end

function M:render()
    if not self.active or not self.overlay_visible then return end
    local t = ui.theme
    local W, H = ui.size()
    local a = ui.ass()
    local margin = 44

    local pos = mp.get_property_number("time-pos", 0) or 0
    local duration = mp.get_property_number("duration", 0) or 0
    local paused = mp.get_property_native("pause")
    local speed = mp.get_property_number("speed", 1)

    -- Soft gradients behind text (blurred rectangles extending off-screen).
    a:rect(-100, -160, W + 200, 300, {color = t.black, opacity = 0.75, blur = 60})
    a:rect(-100, H - 170, W + 200, 330, {color = t.black, opacity = 0.8, blur = 60})

    -- Title + badges
    -- Leave room for an open side menu (it covers the right ~45%).
    local title_w = W - 2 * margin - 160
    local top = self.ctx.menu:top()
    if top and top.style == "side" then title_w = W - Menu.side_width(W) - 2 * margin end
    a:text(margin, 46, ui.fit_text(self:title(), 30, title_w, true), {size = 30, bold = true, outline = 1})
    local count = mp.get_property_number("playlist-count", 1)
    if count > 1 then
        local idx = mp.get_property_number("playlist-pos", 0) + 1
        a:text(W - margin, 46, string.format("%d / %d", idx, count), {size = 20, align = 6, color = t.subtext})
    end
    local bx = margin
    for _, b in ipairs(self:badges()) do
        local w = ui.text_width(b.text, 16, true) + 20
        a:rect(bx, 72, w, 26, {radius = 6, color = t.black, opacity = 0.35,
                               border = 1.5, border_color = b.color or t.subtext, border_opacity = 0.9})
        a:text(bx + w / 2, 85, b.text, {size = 16, bold = true, align = 5, color = b.color or t.text})
        bx = bx + w + 10
    end

    -- Center pause indicator
    if paused then
        a:circle(W / 2, H / 2, 54, {color = t.black, opacity = 0.45})
        a:icon_pause(W / 2, H / 2, 44, {color = t.text, opacity = 0.95})
    end

    -- Progress bar
    local bar_y = H - 118
    local bx0, bx1 = margin, W - margin
    local bw = bx1 - bx0
    local frac = duration > 0 and util.clamp(pos / duration, 0, 1) or 0
    a:rect(bx0, bar_y - 4, bw, 8, {radius = 4, color = t.text, opacity = 0.25})
    -- Buffered range (network/slow media)
    local cache = mp.get_property_native("demuxer-cache-state")
    if cache and cache["cache-end"] and duration > 0 then
        local cend = util.clamp(cache["cache-end"] / duration, frac, 1)
        if cend > frac then
            a:rect(bx0 + bw * frac, bar_y - 4, bw * (cend - frac), 8, {radius = 4, color = t.text, opacity = 0.2})
        end
    end
    if frac > 0 then
        a:rect(bx0, bar_y - 4, math.max(8, bw * frac), 8, {radius = 4, color = t.accent})
    end
    if duration > 0 then
        for _, ch in ipairs(self.chapters) do
            if ch.time and ch.time > 0 and ch.time < duration then
                a:rect(bx0 + bw * ch.time / duration - 1.5, bar_y - 4, 3, 8, {color = t.black, opacity = 0.6})
            end
        end
    end
    a:circle(bx0 + bw * frac, bar_y, 11, {color = t.text})

    -- Times
    local ty = bar_y + 34
    local force_h = duration >= 3600
    a:text(bx0, ty, util.format_time(pos, force_h), {size = 24, bold = true, outline = 1})
    if duration > 0 then
        local remaining = math.max(0, duration - pos) / (speed > 0 and speed or 1)
        a:text(bx1, ty, "-" .. util.format_time(remaining, force_h), {size = 24, align = 6, outline = 1})
        local ends = os.date("%H:%M", os.time() + math.floor(remaining))
        local chapter = ""
        local list = self.chapters
        local cur = mp.get_property_number("chapter", -1)
        if list[cur + 1] and list[cur + 1].title and list[cur + 1].title ~= "" then
            chapter = list[cur + 1].title .. "  ·  "
        end
        a:text(W / 2, ty, ui.fit_text(chapter .. "Ends at " .. ends, 20, W * 0.45),
            {size = 20, align = 5, color = t.subtext, outline = 1})
    end

    -- Button hints (hidden while a side menu shows its own)
    if self.ctx.menu:is_open() then
        self.layer:set(a:build())
        return
    end
    a:hints({
        {"A", paused and "Play" or "Pause"},
        -- Both shoulders, with a direction: "L1 60s" alone read as a single
        -- 60 s jump and hid that R1 goes forward.
        {"DPAD_LR", string.format("±%ds", self.cfg.playback.seek_short)},
        {"L1", string.format("−%ds", self.cfg.playback.seek_long)},
        {"R1", string.format("+%ds", self.cfg.playback.seek_long)},
        {"X", "Subtitles"},
        {"Y", "Audio"},
        {"MENU", "Menu"},
        -- The bar is only on screen when B would hide it (B again stops).
        {"B", "Hide"},
    }, bx1, H - 34, {size = 24, outline = 1})

    self.layer:set(a:build())
end

---------------------------------------------------------------------------
-- Info panel (View button)
---------------------------------------------------------------------------

function M:info_lines()
    local lines = {}
    local function add(k, v) if v and v ~= "" then lines[#lines + 1] = {k, v} end end
    local source, output_hdr, vp, target = media.hdr_state(self.video_track)
    local vt = self.video_track
    local fps = mp.get_property_number("container-fps")
    if vt then
        local v = media.codec(vt.codec)
        if vp.w then v = v .. string.format(" · %dx%d", vp.w, vp.h) end
        if fps then v = v .. string.format(" · %.3f fps", fps) end
        add("Video", v)
    end
    local hw = mp.get_property("hwdec-current")
    add("Decoder", (hw and hw ~= "" and hw ~= "no") and ("Hardware (" .. hw .. ")") or "Software")
    if source then
        local s = source
        if vp.primaries then s = s .. " · " .. vp.primaries end
        add("Source", s)
    end
    local out = target.gamma and (target.gamma .. " / " .. (target.primaries or "?")) or "?"
    add("Output", (output_hdr and "HDR passthrough · " or "SDR · ") .. out)
    if vp["max-luma"] and vp["max-luma"] > 0 then
        add("Mastering", string.format("%d nits", util.round(vp["max-luma"])))
    end
    add("Display", self:refresh_text())
    local at = media.selected_track("audio")
    if at then add("Audio", media.track_label(at) .. " · " .. media.track_detail(at)) end
    add("Stream", self.ctx.plex and self.ctx.plex:describe(mp.get_property("path")))
    local ao = mp.get_property("current-ao")
    if ao then add("Audio out", ao .. (self.ctx.surround.active and " · headphone surround" or "")) end
    for _, l in ipairs(self.ctx.keepawake:info_lines()) do add(l[1], l[2]) end
    local drop = mp.get_property_number("frame-drop-count", 0)
    local vo_drop = mp.get_property_number("vo-delayed-frame-count", 0)
    local mistimed = mp.get_property_number("mistimed-frame-count", 0)
    add("Dropped", string.format("%d decoder · %d late · %d mistimed", drop or 0, vo_drop or 0, mistimed or 0))
    local cache = mp.get_property_number("demuxer-cache-duration")
    if cache then add("Buffered", string.format("%.0f s", cache)) end
    return lines
end

-- "48 Hz (matched)" (confirmed by gamescope), "48 Hz (requested)" (feedback
-- not readable, the usual case in SteamOS game mode), "90 Hz (asked for
-- 48 Hz)" (contradicted), or the plain current rate. Live.
function M:refresh_text()
    local d = self.ctx.display
    local now = d.gamescope and d:current_hz()
    if d.requested_hz then
        if now == d.requested_hz then return now .. " Hz (matched)" end
        if now then return string.format("%d Hz (asked for %d Hz)", now, d.requested_hz) end
        return d.requested_hz .. " Hz (requested)"
    end
    if now then return now .. " Hz" end
    local dfps = mp.get_property_number("display-fps")
    return dfps and string.format("%.2f Hz", dfps) or "?"
end

function M:render_info()
    if not self.active or not self.info_visible then return end
    local t = ui.theme
    local W = ui.size()
    local a = ui.ass()
    local lines = self:info_lines()
    local pw = math.min(560, W - 80)
    local ph = 70 + #lines * 32
    local px, py = W - pw - 32, 120
    a:rect(px, py, pw, ph, {radius = 16, color = t.panel, opacity = 0.88})
    a:text(px + 24, py + 34, "Playback info", {size = 24, bold = true})
    for i, l in ipairs(lines) do
        local y = py + 70 + (i - 1) * 32
        a:text(px + 24, y, l[1], {size = 18, color = t.subtext})
        a:text(px + 150, y, ui.fit_text(l[2], 18, pw - 174), {size = 18})
    end
    self.info_layer:set(a:build())
end

return M
