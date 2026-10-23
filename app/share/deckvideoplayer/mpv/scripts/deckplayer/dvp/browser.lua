-- The library browser: the app's home screen, shown whenever mpv is idle.

local ui = require "dvp.ui"
local util = require "dvp.util"
local library = require "dvp.library"

local M = {}
M.__index = M

local HEADER_H = 126
local FOOTER_H = 72
local ROW_H = 60
local ROW_GAP = 4
local FS = 26

-- ctx: cfg, resume, menu, play(list, start), quit(), quit_dialog(), help(), toast(text)
function M.new(ctx)
    local self = setmetatable({}, M)
    self.ctx = ctx
    self.cfg = ctx.cfg
    self.layer = ui.layer(0)
    self.sort = ctx.cfg.interface.sort
    self.stack = {}          -- navigation history: {path=, label=}
    self.cursor = {}         -- remembered selection per location key
    self.entries = {}
    self.selected = 1
    self.scroll = 0
    self.active = false
    return self
end

function M:location()
    return self.stack[#self.stack]
end

local function loc_key(loc)
    return loc and loc.path or "<root>"
end

-- Rebuilds the entry list for the current location.
function M:load()
    local loc = self:location()
    self.error = nil
    if not loc then
        self.sources = library.sources(self.cfg)
        -- With a single source there is no point in showing the root list.
        if #self.sources == 1 and not self.root_forced then
            self.stack = {{path = self.sources[1].path, label = self.sources[1].name, is_root = true}}
            return self:load()
        end
        self.entries = {}
        for _, s in ipairs(self.sources) do
            self.entries[#self.entries + 1] = {
                label = s.name, name = s.name, path = s.path, is_dir = true, source = s.kind,
            }
        end
    else
        local entries, err = library.list(loc.path, self.cfg, self.sort)
        if not entries then
            self.error = err or "cannot read folder"
            entries = {}
        end
        self.entries = entries
    end
    local remembered = self.cursor[loc_key(loc)]
    self.selected = util.clamp(remembered or 1, 1, math.max(1, #self.entries))
    self.scroll = 0
end

function M:show()
    self.active = true
    self:load()
    self:render()
end

function M:hide()
    self.active = false
    self.layer:clear()
end

-- Move the cursor to `path` if it is in the current listing.
function M:select_path(path)
    for i, e in ipairs(self.entries) do
        if e.path == path then
            self.selected = i
            self.cursor[loc_key(self:location())] = i
            return
        end
    end
end

function M:enter(entry)
    self.cursor[loc_key(self:location())] = self.selected
    table.insert(self.stack, {path = entry.path, label = entry.label})
    self:load()
    self:render()
end

function M:go_back()
    local loc = self:location()
    if not loc then
        self.ctx.quit_dialog()
        return
    end
    if loc.is_root and #self.stack == 1 then
        -- Single-source mode: the source folder is the top level.
        self.ctx.quit_dialog()
        return
    end
    self.cursor[loc_key(loc)] = self.selected
    local from = loc.path
    table.remove(self.stack)
    self:load()
    self:select_path(from)
    self:render()
end

-- Files of the current folder from `index` onwards (for auto-play next).
function M:playlist_from(index)
    local list = {}
    local first
    for i, e in ipairs(self.entries) do
        if not e.is_dir then
            if i == index then first = #list + 1 end
            list[#list + 1] = e.path
        end
    end
    if not self.cfg.playback.autoplay_next then
        return {self.entries[index].path}
    end
    local out = {}
    for i = first, #list do out[#out + 1] = list[i] end
    return out
end

function M:open_file(index, from_start)
    local entry = self.entries[index]
    self.cursor[loc_key(self:location())] = index
    local list = self:playlist_from(index)
    local pos = self.cfg.playback.resume and self.ctx.resume:position(entry.path)
    if pos and not from_start then
        self.ctx.menu:open({
            title = "Resume playback?",
            message = entry.label,
            style = "center",
            items = {
                {label = "Resume from " .. util.format_time(pos), action = function()
                    self.ctx.play(list, pos)
                end},
                {label = "Start from the beginning", action = function()
                    self.ctx.play(list, 0)
                end},
            },
        })
    else
        self.ctx.play(list, 0)
    end
end

function M:toggle_sort()
    self.sort = self.sort == "name" and "date" or "name"
    local cur = self.entries[self.selected]
    self:load()
    if cur then self:select_path(cur.path) end
    self:render()
    self.ctx.toast("Sorted by " .. (self.sort == "name" and "name" or "date added"))
end

function M:open_menu()
    local items = {
        {label = "Sort by", value = function() return self.sort == "name" and "Name" or "Date" end,
         adjust = function() self:toggle_sort() end},
        {label = "Reload library", action = function() self:load(); self:render() end},
    }
    if #self.stack > 0 and self.sources and #self.sources > 1 then
        table.insert(items, {label = "Go to library start", action = function()
            self.stack = {}
            self:load()
            self:render()
        end})
    end
    local cur = self.entries[self.selected]
    if cur and not cur.is_dir then
        if self.ctx.resume:position(cur.path) or self.ctx.resume:is_watched(cur.path) then
            table.insert(items, {label = "Mark as unwatched", action = function()
                self.ctx.resume:forget(cur.path)
                self.ctx.resume:flush()
                self:render()
            end})
        else
            table.insert(items, {label = "Mark as watched", action = function()
                self.ctx.resume:mark_watched(cur.path)
                self.ctx.resume:flush()
                self:render()
            end})
        end
    end
    table.insert(items, {label = "Controls", action = function() self.ctx.help() end})
    table.insert(items, {label = "Quit Deck Video Player", action = function() self.ctx.quit() end})
    self.ctx.menu:open({title = "Menu", style = "side", items = items})
end

function M:visible_rows()
    local _, H = ui.size()
    return math.max(1, math.floor((H - HEADER_H - FOOTER_H + ROW_GAP) / (ROW_H + ROW_GAP)))
end

function M:handle(action)
    local n = #self.entries
    local entry = self.entries[self.selected]
    if action == "up" or action == "down" then
        if n == 0 then return end
        local i = self.selected + (action == "up" and -1 or 1)
        -- Wrap only on a fresh press feel: wrap at the ends.
        if i < 1 then i = n elseif i > n then i = 1 end
        self.selected = i
        self:render()
    elseif action == "lb" or action == "rb" or action == "left" or action == "right" then
        if n == 0 then return end
        local page = self:visible_rows() - 1
        local dir = (action == "lb" or action == "left") and -1 or 1
        self.selected = util.clamp(self.selected + dir * page, 1, n)
        self:render()
    elseif action == "lt" then
        self.selected = 1
        self:render()
    elseif action == "rt" then
        self.selected = math.max(1, n)
        self:render()
    elseif action == "confirm" then
        if not entry then return end
        if entry.is_dir then self:enter(entry) else self:open_file(self.selected, false) end
    elseif action == "x" then
        if entry and not entry.is_dir then self:open_file(self.selected, true) end
    elseif action == "y" then
        if self:location() then self:toggle_sort() end
    elseif action == "back" then
        self:go_back()
    elseif action == "menu" then
        self:open_menu()
    end
end

---------------------------------------------------------------------------
-- Rendering
---------------------------------------------------------------------------

function M:breadcrumb()
    local parts = {"Library"}
    for _, loc in ipairs(self.stack) do parts[#parts + 1] = loc.label end
    return table.concat(parts, "  ›  ")
end

function M:render()
    if not self.active then return end
    local t = ui.theme
    local W, H = ui.size()
    local a = ui.ass()
    local margin = 40

    -- Background
    a:rect(0, 0, W, H, {color = t.bg})
    a:rect(-200, -260, W * 0.7, 420, {color = t.accent, opacity = 0.10, blur = 120})

    -- Header
    local loc = self:location()
    local title = loc and loc.label or "Library"
    a:text(margin, 34, "DECK VIDEO PLAYER", {size = 16, bold = true, color = t.accent})
    a:text(margin, 72, ui.fit_text(title, 36, W * 0.6), {size = 36, bold = true})
    if #self.stack > 1 then
        a:text(margin, 102, ui.fit_text(self:breadcrumb(), 16, W * 0.6), {size = 16, color = t.dim})
    end

    local n_dirs, n_files = 0, 0
    for _, e in ipairs(self.entries) do
        if e.is_dir then n_dirs = n_dirs + 1 else n_files = n_files + 1 end
    end
    local counts = {}
    if n_files > 0 then counts[#counts + 1] = n_files .. (n_files == 1 and " video" or " videos") end
    if n_dirs > 0 then counts[#counts + 1] = n_dirs .. (n_dirs == 1 and " folder" or " folders") end
    a:text(W - margin, 50, table.concat(counts, " · "), {size = 20, align = 6, color = t.subtext})
    if loc then
        a:text(W - margin, 78, "Sorted by " .. (self.sort == "name" and "name" or "date"),
            {size = 16, align = 6, color = t.dim})
    end

    -- List
    local list_top = HEADER_H
    local rows = self:visible_rows()
    local n = #self.entries
    if self.selected > self.scroll + rows then self.scroll = self.selected - rows end
    if self.selected <= self.scroll then self.scroll = self.selected - 1 end
    self.scroll = util.clamp(self.scroll, 0, math.max(0, n - rows))

    local x0, x1 = margin - 12, W - margin + 12
    for row = 1, math.min(rows, n) do
        local idx = self.scroll + row
        local e = self.entries[idx]
        local y = list_top + (row - 1) * (ROW_H + ROW_GAP)
        local cy = y + ROW_H / 2
        local sel = idx == self.selected
        if sel then
            a:rect(x0, y, x1 - x0, ROW_H, {radius = 14, color = t.accent})
        end
        local icon_color = sel and t.text or (e.is_dir and t.accent or t.subtext)
        local inner = sel and t.accent or t.bg
        local ix = x0 + 20
        if e.source == "removable" then
            a:icon_drive(ix, cy, 30, {color = icon_color, inner = inner})
        elseif e.is_dir then
            a:icon_folder(ix, cy, 30, {color = icon_color})
        else
            a:icon_video(ix, cy, 30, {color = icon_color, inner = inner})
        end

        -- Right-hand status (resume progress / watched / chevron)
        local status_w = 0
        local rx = x1 - 22
        if e.is_dir then
            a:icon_triangle(rx - 6, cy, 14, "right", {color = sel and t.text or t.dim})
            status_w = 30
        else
            local r = self.ctx.resume:get(e.path)
            if r and r.watched and not r.pos then
                a:icon_check(rx - 12, cy, 24, {color = sel and t.text or t.good, inner = sel and t.accent or t.bg})
                status_w = 34
            elseif r and r.pos and r.pos >= 30 then
                local label = util.format_time(r.pos)
                if r.duration and r.duration > 0 then
                    local bw = 110
                    local frac = util.clamp(r.pos / r.duration, 0, 1)
                    a:rect(rx - bw, cy - 3, bw, 6, {radius = 3, color = sel and t.text or t.dim,
                                                     opacity = sel and 0.35 or 0.6})
                    a:rect(rx - bw, cy - 3, math.max(6, bw * frac), 6,
                        {radius = 3, color = sel and t.text or t.accent})
                    a:text(rx - bw - 14, cy, label, {size = 18, align = 6, color = sel and t.text or t.subtext})
                    status_w = bw + 14 + ui.text_width(label, 18)
                else
                    a:text(rx, cy, "Resume " .. label, {size = 18, align = 6, color = sel and t.text or t.subtext})
                    status_w = ui.text_width("Resume " .. label, 18)
                end
            end
        end

        local tx = ix + 52
        local max_w = (x1 - 22 - status_w - 24) - tx
        a:text(tx, cy, ui.fit_text(e.label, FS, max_w), {size = FS, bold = sel,
            color = t.text, clip = {tx, y, tx + max_w, y + ROW_H}})
    end

    -- Scrollbar
    if n > rows then
        local track_top, track_h = list_top, rows * (ROW_H + ROW_GAP) - ROW_GAP
        local bar_h = math.max(36, track_h * rows / n)
        local bar_y = track_top + (track_h - bar_h) * self.scroll / (n - rows)
        a:rect(W - 14, track_top, 4, track_h, {radius = 2, color = t.dim, opacity = 0.3})
        a:rect(W - 14, bar_y, 4, bar_h, {radius = 2, color = t.subtext})
    end

    -- Empty states
    if n == 0 then
        local cy = H / 2 - 30
        if self.error then
            a:text(W / 2, cy, "Cannot open this folder", {size = 30, bold = true, align = 5})
            a:text(W / 2, cy + 44, ui.fit_text(tostring(self.error), 20, W - 160),
                {size = 20, align = 5, color = t.subtext})
        elseif not loc then
            a:text(W / 2, cy, "No video folders found", {size = 30, bold = true, align = 5})
            a:text(W / 2, cy + 44, "Add a  folder = /path/to/videos  line to the [library] section of",
                {size = 20, align = 5, color = t.subtext})
            a:text(W / 2, cy + 74, ui.fit_text(self.cfg.path or "config.ini", 20, W - 160),
                {size = 20, align = 5, color = t.accent})
        else
            a:text(W / 2, cy, "No videos here", {size = 30, bold = true, align = 5})
            a:text(W / 2, cy + 44, "This folder has no video files or subfolders.",
                {size = 20, align = 5, color = t.subtext})
        end
    end

    -- Footer
    a:rect(0, H - FOOTER_H, W, FOOTER_H, {color = t.panel, opacity = 0.9})
    local hints = {}
    local cur = self.entries[self.selected]
    if cur then
        hints[#hints + 1] = {"A", cur.is_dir and "Open" or "Play"}
        if not cur.is_dir and self.cfg.playback.resume and self.ctx.resume:position(cur.path) then
            hints[#hints + 1] = {"X", "Play from start"}
        end
    end
    hints[#hints + 1] = {"B", (loc and not (loc.is_root and #self.stack == 1)) and "Back" or "Quit"}
    if loc then hints[#hints + 1] = {"Y", "Sort"} end
    hints[#hints + 1] = {"MENU", "Menu"}
    a:hints(hints, W - margin, H - FOOTER_H / 2, {size = 28})

    self.layer:set(a:build())
end

return M
