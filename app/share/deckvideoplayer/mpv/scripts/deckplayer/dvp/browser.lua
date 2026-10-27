-- The library browser: the app's home screen, shown whenever mpv is idle.

local ui = require "dvp.ui"
local util = require "dvp.util"
local library = require "dvp.library"
local Resume = require "dvp.resume"
local qrencode = require "dvp.qrencode"
local VideoInfo = require "dvp.videoinfo"

local M = {}
M.__index = M

local HEADER_H = 126
local FOOTER_H = 72
local ROW_H = 60
local ROW_GAP = 4
local FS = 26

-- ctx: cfg, resume, menu, plex, servers, play(list, start), quit(), quit_dialog(), help(), toast(text)
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
    -- The selected entry scrolls when its name doesn't fit.
    self.marquee = ui.marquee(function() self:render() end)
    return self
end

function M:location()
    return self.stack[#self.stack]
end

local function loc_key(loc)
    return loc and loc.path or "<root>"
end

-- Re-reads the configured folders and mounted drives, so an SD card or USB
-- drive inserted while the app runs shows up. Cheap (reads mountinfo).
-- Also picks the "Recently played" videos (skipping files that are gone or
-- on a drive that isn't inserted: one stat per listed file; server videos
-- while signed in to their server).
function M:refresh_sources()
    local servers = self.ctx.servers
    self.sources = library.sources(self.cfg, servers:sources())
    self.recents = self.ctx.resume:recent(self.cfg.interface.recently_played, function(path)
        local available = servers:recent_available(path)
        if available ~= nil then return available end
        return util.file_exists(path)
    end)
    local top = self.stack[1]
    if top and top.is_root and not self:single_source() then
        -- No longer single-source: the folder becomes a normal level, so B
        -- goes back to the source list instead of offering to quit.
        top.is_root = nil
    end
end

-- One source and nothing recently played: the start screen is skipped.
function M:single_source()
    return #self.sources == 1 and #self.recents == 0
end

-- Short tag of where a "Recently played" video is: "Local", "SD Card",
-- "USB", "Plex", "Jellyfin"; with the server's name when several servers
-- of that kind are signed in. The same video played from two places has
-- two rows (each place keeps its own progress); the tags tell them apart.
function M:recent_tag(path, backend, id)
    if not backend then return library.source_tag(library.source_for(self.sources, path)) end
    local count = 0
    for _, s in ipairs(self.sources) do
        if s.kind == backend.ID then count = count + 1 end
    end
    local server = count > 1 and backend:server(id)
    return server and (backend.NAME .. " · " .. server.name) or backend.NAME
end

-- Entries of the start screen: the sources, then "Recently played".
function M:root_entries()
    local entries = {}
    for _, s in ipairs(self.sources) do
        entries[#entries + 1] = {
            label = s.name, name = s.name, path = s.path, is_dir = true, source = s.kind, server = s.server,
        }
    end
    if #self.recents > 0 then
        entries[#entries + 1] = {header = true, label = "Recently played"}
        for _, path in ipairs(self.recents) do
            local backend, id, key = self.ctx.servers:parse_recent_key(path)
            if backend then
                -- Played from a media server: opened through the server (D50).
                local label = (self.ctx.resume:get(path) or {}).title or (backend.NAME .. " video")
                entries[#entries + 1] = {
                    label = label, name = label, path = path, is_dir = false, recent = true,
                    server_recent = backend.recent_ref(id, key), tag = self:recent_tag(path, backend, id),
                }
            else
                local name = util.basename(path)
                entries[#entries + 1] = {
                    label = library.display_name(name, false, self.cfg.interface.clean_names),
                    name = name, path = path, is_dir = false, recent = true, tag = self:recent_tag(path),
                }
            end
        end
    end
    return entries
end

-- Nearest selectable entry from `i` in direction `dir` (section headers
-- can't be selected), else the other way.
function M:selectable(i, dir)
    local n = #self.entries
    for _, d in ipairs({dir, -dir}) do
        local j = i
        while j >= 1 and j <= n do
            if not self.entries[j].header then return j end
            j = j + d
        end
    end
    return util.clamp(i, 1, math.max(1, n))
end

-- Rebuilds the entry list for the current location.
function M:load()
    local loc = self:location()
    self.error = nil
    if not loc then
        self:refresh_sources()
        -- With a single source there is no point in showing the root list.
        if self:single_source() then
            local s = self.sources[1]
            self.stack = {{path = s.path, label = s.name, is_root = true, server = s.server}}
            return self:load()
        end
        self.entries = self:root_entries()
    elseif loc.server then
        return self:load_server(loc)
    else
        local entries, err = library.list(loc.path, self.cfg, self.sort)
        if not entries then
            self.error = err or "cannot read folder"
            entries = {}
        end
        self.entries = entries
    end
    self.loading = false
    local remembered = self.cursor[loc_key(loc)]
    self.selected = self:selectable(util.clamp(remembered or 1, 1, math.max(1, #self.entries)), 1)
    self.scroll = 0
end

-- Media server listings arrive asynchronously: show "Loading…", then fill
-- in if the user is still at that location. `self.after_load` (optional)
-- runs once the entries are there (e.g. to restore the cursor on a path).
function M:load_server(loc)
    self.entries = {}
    self.loading = true
    self.selected, self.scroll = 1, 0
    self.ctx.servers:for_ref(loc.server):list(loc.server, function(entries, err)
        if self:location() ~= loc then return end
        self.loading = false
        self.error = err
        self.entries = entries or {}
        if self:sortable() then library.sort_entries(self.entries, self.sort) end
        local remembered = self.cursor[loc_key(loc)]
        self.selected = util.clamp(remembered or 1, 1, math.max(1, #self.entries))
        local after = self.after_load
        self.after_load = nil
        if after then after() end
        self:render()
    end)
end

-- Server listings kept in the server's order: the server page, "Continue
-- watching", "Next up", and seasons/episodes (by number, whatever the sort).
local SERVER_ORDER = {root = true, ondeck = true, nextup = true, seasons = true, episodes = true,
                      series_episodes = true}
-- Listings of unrelated videos: play just the chosen one.
local SINGLE_PLAY = {ondeck = true, nextup = true}

-- Whether Y sorts this listing (not the source list, nor server listings
-- kept in server order).
function M:sortable()
    local loc = self:location()
    if not loc then return false end
    return not (loc.server and SERVER_ORDER[loc.server.kind])
end

-- Progress of an entry: server entries carry their own state, local files
-- use resume.json. Same shape either way: {pos, duration, watched}.
function M:entry_state(e)
    if e.state then return e.state end
    return self.ctx.resume:get(e.path)
end

-- Position worth offering to resume from, or nil.
function M:resume_position(e)
    if e.state then
        local s = e.state
        if s.pos and s.pos >= Resume.MIN_POSITION and not Resume.is_finished(s.pos, s.duration or 0) then
            return s.pos
        end
        return nil
    end
    return self.ctx.resume:position(e.path)
end

-- `select` (optional): path to put the cursor on, also when the listing
-- arrives later (media servers).
function M:show(select)
    self.active = true
    self:refresh_sources()
    if select then self.after_load = function() self:select_path(select) end end
    self:load()
    if select and not self.loading then
        self.after_load = nil
        self:select_path(select)
    end
    self:render()
end

function M:reload()
    local cur = self.entries[self.selected]
    self:refresh_sources()
    if cur then self.after_load = function() self:select_path(cur.path) end end
    self:load()
    if cur and not self.loading then
        self.after_load = nil
        self:select_path(cur.path)
    end
    self:render()
end

-- After signing in to a server: from the only folder (the start screen was
-- skipped), go to the start screen, where the new server now is.
function M:reload_to_start()
    if #self.stack == 1 and self.stack[1].is_root then self.stack = {} end
    self:reload()
end

-- True at the top level (source list, or the only source's folder).
function M:at_start()
    local top = self.stack[1]
    return #self.stack == 0 or (#self.stack == 1 and top.is_root == true)
end

function M:hide()
    self.active = false
    self.marquee:reset()
    self.layer:clear()
end

-- Move the cursor to `path` if it is in the current listing (a server
-- stream URL also finds its "Recently played" entry).
function M:select_path(path)
    local servers = self.ctx.servers
    local alt = servers:recent_key(servers:item_for(path))
    for i, e in ipairs(self.entries) do
        if e.path == path or (alt and e.path == alt) then
            self.selected = i
            self.cursor[loc_key(self:location())] = i
            return
        end
    end
end

function M:enter(entry)
    self.after_load = nil   -- meant for a listing we are leaving
    self.cursor[loc_key(self:location())] = self.selected
    table.insert(self.stack, {path = entry.path, label = entry.label, server = entry.server})
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
    self.after_load = function() self:select_path(from) end
    self:load()
    if not self.loading then
        self.after_load = nil
        self:select_path(from)
    end
    self:render()
end

-- Files of the current folder from `index` onwards (for auto-play next).
function M:playlist_from(index)
    if self.entries[index].recent then return self:recent_playlist(self.entries[index].path) end
    local list = {}
    local first
    for i, e in ipairs(self.entries) do
        if not e.is_dir then
            if i == index then first = #list + 1 end
            list[#list + 1] = e.path
        end
    end
    local loc = self:location()
    -- "Continue watching" / "Next up" mix unrelated videos: play just the chosen one.
    if not self.cfg.playback.autoplay_next or (loc and loc.server and SINGLE_PLAY[loc.server.kind]) then
        return {self.entries[index].path}
    end
    local out = {}
    for i = first, #list do out[#out + 1] = list[i] end
    return out
end

-- A recently played file continues with the rest of its own folder.
function M:recent_playlist(path)
    if not self.cfg.playback.autoplay_next then return {path} end
    local out
    -- By name whatever the folder sort (not shown on the start screen), so
    -- episodes continue in order.
    for _, e in ipairs(library.list(util.dirname(path), self.cfg, "name") or {}) do
        if e.path == path then out = {} end
        if out and not e.is_dir then out[#out + 1] = e.path end
    end
    return out or {path}
end

function M:open_file(index, from_start)
    local entry = self.entries[index]
    self.cursor[loc_key(self:location())] = index
    if entry.server_recent then return self:open_server_recent(entry, from_start) end
    self:start(entry, self:playlist_from(index), from_start)
end

-- A server video from "Recently played": asks its server for the current
-- state (and the rest of the season), then plays as from its listing.
function M:open_server_recent(entry, from_start)
    if self.opening then return end
    self.opening = true
    local r = entry.server_recent
    local backend = self.ctx.servers:for_ref(r)
    -- The first request may have to find the server: say something is happening.
    self.ctx.toast("Opening from " .. backend.NAME .. "…")
    backend:resolve(r.machine, r.key, self.cfg.playback.autoplay_next, function(fresh, list, err)
        self.opening = false
        -- The server's progress (maybe from another device) for the row.
        if fresh then
            self.ctx.resume:sync(entry.path, fresh.state)
            if self.active and not self:location() then self:render() end
        end
        -- Only if the user is still on this row of the start screen, with
        -- nothing else opened meanwhile.
        local cur = self.entries[self.selected]
        if not self.active or self:location() or self.ctx.menu:is_open()
            or not (cur and cur.path == entry.path) then return end
        if not fresh then
            self.ctx.toast(err or "Can't open this video")
            return
        end
        self:start(fresh, list, from_start)
    end)
end

function M:start(entry, list, from_start)
    local pos = self.cfg.playback.resume and self:resume_position(entry)
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
        -- No explicit choice unless X (from start): playback then uses the
        -- latest saved position (for servers, fresh from the server: the
        -- listing may be older than a play on another device).
        self.ctx.play(list, from_start and 0 or nil)
    end
end

function M:toggle_sort()
    self.sort = self.sort == "name" and "date" or "name"
    local cur = self.entries[self.selected]
    if self.loading then
        -- The listing on its way is sorted with the new order when it lands.
        if cur then self.after_load = function() self:select_path(cur.path) end end
    else
        -- Entries carry names and dates: re-sort in place, no new listing
        -- (for servers, no new request).
        library.sort_entries(self.entries, self.sort)
        if cur then self:select_path(cur.path) end
    end
    self:render()
    self.ctx.toast("Sorted by " .. (self.sort == "name" and "name" or "date added"))
end

-- Marks a video watched (no position) or unwatched (no mark, no position):
-- on the server for Plex / Jellyfin videos, in resume.json for local files.
function M:mark(entry, watched)
    local resume = self.ctx.resume
    -- The copy shown in "Recently played" follows.
    local function mark_recent(key)
        if not key or not resume:get(key) then return end
        if watched then resume:mark_watched(key) else resume:mark_unwatched(key) end
        resume:flush()
    end
    if entry.server or entry.server_recent then
        local item = entry.server or entry.server_recent
        local duration = (entry.state or {}).duration
        local backend = self.ctx.servers:for_ref(item)
        backend:connect(item.machine, function(base, err)
            if not base then self.ctx.toast(err or ("Can't reach the " .. backend.NAME .. " server")) return end
            backend:set_watched(item, watched, function(ok)
                if not ok then self.ctx.toast(backend.NAME .. " didn't accept the change") return end
                if entry.server then entry.state = {duration = duration, watched = watched or nil} end
                mark_recent(backend.recent_key(item))
                self:render()
            end)
        end)
        return
    end
    if watched then
        self.ctx.resume:mark_watched(entry.path)
    else
        self.ctx.resume:mark_unwatched(entry.path)
    end
    self.ctx.resume:flush()
    self:render()
end

-- Hides a server item from "Continue watching" (also in its other apps),
-- keeping its progress (Plex only, D55).
function M:remove_from_continue(entry)
    local loc = self:location()
    local backend = self.ctx.servers:for_ref(entry.server)
    backend:remove_from_continue(entry.server, function(ok)
        if not ok then self.ctx.toast(backend.NAME .. " didn't accept the change") return end
        self.ctx.toast("Removed from Continue watching")
        if self:location() ~= loc then return end
        for i, e in ipairs(self.entries) do
            if e == entry then
                table.remove(self.entries, i)
                self.selected = util.clamp(self.selected, 1, math.max(1, #self.entries))
                break
            end
        end
        self:render()
    end)
end

function M:video_info(entry)
    VideoInfo.open(self.ctx, entry, library.source_label(library.source_for(self.sources, entry.path)))
end

function M:open_menu()
    local items = {}
    if self:sortable() then
        items[1] = {label = "Sort by", value = function() return self.sort == "name" and "Name" or "Date" end,
                    adjust = function() self:toggle_sort() end}
    end
    table.insert(items, {label = "Reload library", action = function() self:reload() end})
    if not self:at_start() then
        table.insert(items, {label = "Go to library start", action = function()
            local top = self.stack[1]
            self.stack = (top and top.is_root) and {top} or {}
            self.after_load = nil
            self:load()
            self:render()
        end})
    end
    local cur = self.entries[self.selected]
    if cur and not cur.is_dir then
        -- A partly watched video offers both: finish it, or clear its progress.
        local st = self:entry_state(cur) or {}
        if not st.watched or st.pos then
            table.insert(items, {label = "Mark as watched", action = function() self:mark(cur, true) end})
        end
        if st.watched or st.pos then
            table.insert(items, {label = "Mark as unwatched", action = function() self:mark(cur, false) end})
        end
    end
    local loc = self:location()
    local cur_backend = cur and self.ctx.servers:for_ref(cur.server)
    if cur_backend and cur_backend.remove_from_continue and not cur.is_dir
        and loc and loc.server and loc.server.kind == "ondeck" then
        table.insert(items, {label = "Remove from Continue watching", action = function()
            self:remove_from_continue(cur)
        end})
    end
    if cur and cur.recent then
        table.insert(items, {label = "Remove from recently played", action = function()
            self.ctx.resume:hide_recent(cur.path)
            self.ctx.resume:flush()
            self:reload()
        end})
    end
    if cur and not cur.is_dir then
        table.insert(items, {label = "Video info", action = function() self:video_info(cur) end})
    end
    local plex = self.ctx.plex
    if plex and plex:signed_in() then
        table.insert(items, {label = "Plex account", value = plex:username() or "signed in",
                             action = function() self:plex_account_menu() end})
    elseif plex then
        table.insert(items, {label = "Sign in to Plex…", action = function() self:plex_sign_in() end})
    end
    local jf = self.ctx.jellyfin
    if jf and jf:signed_in() then
        local names = {}
        for _, s in ipairs(jf:servers()) do names[#names + 1] = s.name end
        table.insert(items, {label = "Jellyfin servers", value = table.concat(names, ", "),
                             action = function() self:jellyfin_menu() end})
    elseif jf then
        table.insert(items, {label = "Add a Jellyfin server…", action = function() self:jellyfin_add() end})
    end
    table.insert(items, {label = "Controls", action = function() self.ctx.help() end})
    table.insert(items, {label = "About", action = function() self.ctx.about() end})
    table.insert(items, {label = "Quit Deck Video Player", action = function() self.ctx.quit() end})
    self.ctx.menu:open({title = "Menu", style = "side", items = items})
end

---------------------------------------------------------------------------
-- Plex account (sign-in with a code entered at plex.tv/link)
---------------------------------------------------------------------------

function M:plex_sign_in()
    local plex, menu = self.ctx.plex, self.ctx.menu
    local timer, cancelled = nil, false
    -- Closing the dialog also drops the PINs, so answers still in flight
    -- neither sign in nor touch whatever is on screen by then.
    local function stop()
        cancelled = true
        if timer then timer:kill() end
        plex:cancel_pin()
    end
    local spec = {
        title = "Sign in to Plex", style = "center",
        message = "Getting a code…",
        -- (Choosing an item doesn't call on_cancel, so Cancel stops too.)
        items = {{label = "Cancel", action = stop}},
        on_cancel = stop,
    }
    menu:open(spec)
    plex:start_pin(function(code, url, err)
        if cancelled then
            plex:cancel_pin()
            return
        end
        if not code then
            menu:update(spec, {message = "Could not reach plex.tv: " .. tostring(err)})
            return
        end
        -- QR code: scanning it opens Plex's sign-in page with the code
        -- filled in; typing the short code at plex.tv/link also works.
        local ok, matrix = false, nil
        if url then ok, matrix = qrencode.qrcode(url) end
        local fields = ok and {qr = matrix, code = code,
                               message = "Scan with your phone,\nor open " .. plex.LINK_URL .. " and enter:"}
            or {code = code, message = "On a phone or PC, open " .. plex.LINK_URL .. " and enter:"}
        if not menu:update(spec, fields) then return end
        -- Poll every 2 s while the dialog is open (only then: battery).
        local busy = false
        timer = mp.add_periodic_timer(2, function()
            if busy then return end
            busy = true
            plex:poll_pin(function(done, perr)
                busy = false
                if cancelled then return end
                if done then
                    timer:kill()
                    menu:close_all()
                    if perr then
                        self.ctx.toast("Signed in, but the server list failed: " .. tostring(perr))
                    else
                        self.ctx.toast("Signed in to Plex as " .. (plex:username() or "?"))
                    end
                    self:reload_to_start()
                elseif perr then
                    timer:kill()
                    menu:update(spec, {message = perr, code = false, qr = false})
                end
            end)
        end)
    end)
end

function M:plex_account_menu()
    local plex = self.ctx.plex
    local servers = {}
    for _, s in ipairs(plex.account.servers or {}) do servers[#servers + 1] = s.name end
    self.ctx.menu:open({title = "Plex", subtitle = plex:username(), style = "side", items = {
        {label = "Servers", value = #servers > 0 and table.concat(servers, ", ") or "none"},
        {label = "Refresh server list", action = function()
            self.ctx.toast("Asking plex.tv…")
            plex:refresh_account(function(err)
                self.ctx.toast(err or "Plex server list updated")
                self:reload()
            end)
        end},
        {label = "Sign out", action = function()
            plex:sign_out()
            self.stack = {}
            self:load()
            self:render()
            self.ctx.toast("Signed out of Plex")
        end},
    }})
end

---------------------------------------------------------------------------
-- Jellyfin servers (found on the LAN or in config.ini; Quick Connect, D55)
---------------------------------------------------------------------------

-- Lists the servers found, to sign in to one.
function M:jellyfin_add()
    local jf, menu = self.ctx.jellyfin, self.ctx.menu
    local spec = {title = "Add a Jellyfin server", subtitle = "On your network, and in config.ini",
                  style = "side", items = {{label = "Looking for servers…", disabled = true}}}
    menu:open(spec)
    jf:discover(function(found)
        local items = {}
        for _, s in ipairs(found) do
            local host = s.url:match("^https?://(.*)$")
            items[#items + 1] = {label = s.name, value = jf:server(s.id) and "Signed in" or host,
                                 action = function() self:jellyfin_sign_in(s) end}
        end
        if #items == 0 then items[1] = {label = "No servers found", disabled = true} end
        items[#items + 1] = {separator = true}
        items[#items + 1] = {label = "Search again", action = function() self:jellyfin_add() end}
        items[#items + 1] = {label = "Not listed? See [jellyfin] in config.ini", disabled = true}
        menu:update(spec, {items = items})
    end)
end

-- Quick Connect: a code to approve in a Jellyfin app where the user is
-- signed in (profile → Quick Connect). The QR code opens that page of the
-- server's web app on a phone on the same network.
function M:jellyfin_sign_in(server)
    local jf, menu = self.ctx.jellyfin, self.ctx.menu
    local timer, cancelled = nil, false
    -- Closing the dialog also drops the code, so answers still in flight
    -- neither sign in nor touch whatever is on screen by then.
    local function stop()
        cancelled = true
        if timer then timer:kill() end
        jf:cancel_quick_connect()
    end
    local spec = {
        title = "Sign in to " .. server.name, style = "center",
        message = "Getting a code…",
        -- (Choosing an item doesn't call on_cancel, so Cancel stops too.)
        items = {{label = "Cancel", action = stop}},
        on_cancel = stop,
    }
    menu:open(spec)
    jf:start_quick_connect(server, function(code, err)
        if cancelled then return end
        if not code then
            menu:update(spec, {message = tostring(err)})
            return
        end
        local ok, matrix = qrencode.qrcode(server.url .. "/web/#/quickconnect")
        local fields = ok and {qr = matrix, code = code,
                               message = "Scan with your phone, or in Jellyfin\nopen your profile → Quick Connect\nand enter:"}
            or {code = code, message = "In Jellyfin, open your profile → Quick Connect and enter:"}
        if not menu:update(spec, fields) then return end
        -- Poll every 3 s while the dialog is open (only then: battery).
        local busy = false
        timer = mp.add_periodic_timer(3, function()
            if busy then return end
            busy = true
            jf:poll_quick_connect(function(done, perr)
                busy = false
                if cancelled then return end
                if done then
                    timer:kill()
                    menu:close_all()
                    local s = jf:server(server.id)
                    self.ctx.toast("Signed in to " .. server.name .. " as " .. tostring(s and s.username or "?"))
                    self:reload_to_start()
                elseif perr then
                    timer:kill()
                    menu:update(spec, {message = perr, code = false, qr = false})
                end
            end)
        end)
    end)
end

function M:jellyfin_menu()
    local jf = self.ctx.jellyfin
    local items = {}
    for _, s in ipairs(jf:servers()) do
        items[#items + 1] = {label = s.name, value = s.username,
                             action = function() self:jellyfin_server_menu(s) end}
    end
    items[#items + 1] = {separator = true}
    items[#items + 1] = {label = "Add a server…", action = function() self:jellyfin_add() end}
    self.ctx.menu:open({title = "Jellyfin", style = "side", items = items})
end

function M:jellyfin_server_menu(s)
    local jf = self.ctx.jellyfin
    self.ctx.menu:open({title = s.name, subtitle = s.username, style = "side", items = {
        {label = "Address", value = s.url, disabled = true},
        {label = "Sign out", action = function()
            jf:sign_out(s.id)
            self.stack = {}
            self:load()
            self:render()
            self.ctx.toast("Signed out of " .. s.name)
        end},
    }})
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
        local d = action == "up" and -1 or 1
        local i = self.selected
        -- Wrap at the ends; skip section headers.
        repeat
            i = i + d
            if i < 1 then i = n elseif i > n then i = 1 end
        until not self.entries[i].header or i == self.selected
        self.selected = i
        self:render()
    elseif action == "lb" or action == "rb" or action == "left" or action == "right" then
        if n == 0 then return end
        local page = self:visible_rows() - 1
        local dir = (action == "lb" or action == "left") and -1 or 1
        self.selected = self:selectable(util.clamp(self.selected + dir * page, 1, n), dir)
        self:render()
    elseif action == "lt" then
        self.selected = self:selectable(1, 1)
        self:render()
    elseif action == "rt" then
        self.selected = self:selectable(math.max(1, n), -1)
        self:render()
    elseif action == "confirm" then
        if not entry then return end
        if entry.is_dir then self:enter(entry) else self:open_file(self.selected, false) end
    elseif action == "x" then
        if entry and not entry.is_dir then self:open_file(self.selected, true) end
    elseif action == "y" then
        if self:sortable() then self:toggle_sort() end
    elseif action == "view" then
        if entry and not entry.is_dir then self:video_info(entry) end
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

-- One list row: icon, name, and progress / watched mark / chevron.
function M:draw_row(a, e, x0, x1, y, sel)
    local t = ui.theme
    local cy = y + ROW_H / 2
    if sel then
        a:rect(x0, y, x1 - x0, ROW_H, {radius = 14, color = t.accent})
    end
    local icon_color = sel and t.text or (e.is_dir and t.accent or t.subtext)
    local inner = sel and t.accent or t.bg
    local ix = x0 + 20
    if e.source == "plex" or e.source == "jellyfin" then
        a:icon_server(ix, cy, 30, {color = icon_color, inner = inner})
    elseif e.source == "sdcard" then
        a:icon_sdcard(ix, cy, 30, {color = icon_color, inner = inner})
    elseif e.source == "usb" or e.source == "removable" then
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
        -- Which kind of server a server source is (names alone may not say).
        local backend = e.source and self.ctx.servers:get(e.source)
        if backend then
            a:text(rx - 30, cy, backend.NAME, {size = 18, align = 6, color = sel and t.text or t.subtext})
            status_w = status_w + 8 + ui.text_width(backend.NAME, 18)
        end
        if e.state and e.state.watched then
            a:icon_check(rx - 40, cy, 24, {color = sel and t.text or t.good, inner = sel and t.accent or t.bg})
            status_w = 62
        end
    else
        local r = self:entry_state(e)
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
        -- Where a "Recently played" video is (Local, SD Card, Plex…).
        if e.tag then
            local tag = ui.fit_text(e.tag, 16, 240)
            local tw = ui.text_width(tag, 16) + 20
            local tx1 = rx - status_w - (status_w > 0 and 18 or 0)
            a:rect(tx1 - tw, cy - 14, tw, 28, {radius = 14, color = sel and t.text or t.dim,
                                               opacity = sel and 0.25 or 0.35})
            a:text(tx1 - tw / 2, cy, tag, {size = 16, align = 5, color = sel and t.text or t.subtext})
            status_w = rx - (tx1 - tw)
        end
    end

    local tx = ix + 52
    local max_w = (x1 - 22 - status_w - 24) - tx
    local label_o = {size = FS, bold = sel, color = t.text}
    if sel and not self.ctx.menu:is_open() then
        self.marquee:draw(a, e.path or e.label, tx, cy, e.label, max_w, label_o)
    else
        a:text(tx, cy, ui.fit_text(e.label, FS, max_w, sel), label_o)
    end
end

function M:render()
    if not self.active then return end
    self.marquee:begin()
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
    a:text(margin, 72, ui.fit_text(title, 36, W * 0.6, true), {size = 36, bold = true})
    if #self.stack > 1 then
        a:text(margin, 102, ui.fit_text(self:breadcrumb(), 16, W * 0.6), {size = 16, color = t.dim})
    end

    local n_dirs, n_files = 0, 0
    for _, e in ipairs(self.entries) do
        if e.is_dir then n_dirs = n_dirs + 1 else n_files = n_files + 1 end
    end
    local counts = {}
    if not loc then
        counts[1] = #self.sources .. (#self.sources == 1 and " source" or " sources")
    elseif n_files > 0 then counts[#counts + 1] = n_files .. (n_files == 1 and " video" or " videos") end
    if loc and n_dirs > 0 then counts[#counts + 1] = n_dirs .. (n_dirs == 1 and " folder" or " folders") end
    a:text(W - margin, 50, table.concat(counts, " · "), {size = 20, align = 6, color = t.subtext})
    if self:sortable() then
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
        if e.header then
            a:text(x0 + 20, y + ROW_H - 18, e.label:upper(), {size = 16, bold = true, color = t.dim})
            a:rect(x0 + 20, y + ROW_H - 4, x1 - x0 - 40, 1, {color = t.dim, opacity = 0.5})
        else
            self:draw_row(a, e, x0, x1, y, idx == self.selected)
        end
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
        if self.loading then
            a:text(W / 2, cy, "Loading…", {size = 30, bold = true, align = 5, color = t.subtext})
        elseif self.error then
            local backend = loc and self.ctx.servers:for_ref(loc.server)
            local what = backend and ("Cannot load from " .. backend.NAME) or "Cannot open this folder"
            a:text(W / 2, cy, what, {size = 30, bold = true, align = 5})
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
        if not cur.is_dir and self.cfg.playback.resume and self:resume_position(cur) then
            hints[#hints + 1] = {"X", "Play from start"}
        end
    end
    hints[#hints + 1] = {"B", (loc and not (loc.is_root and #self.stack == 1)) and "Back" or "Quit"}
    if self:sortable() then hints[#hints + 1] = {"Y", "Sort"} end
    if cur and not cur.is_dir then hints[#hints + 1] = {"VIEW", "Info"} end
    hints[#hints + 1] = {"MENU", "Menu"}
    a:hints(hints, W - margin, H - FOOTER_H / 2, {size = 28})

    self.marquee:finish()
    self.layer:set(a:build())
end

return M
