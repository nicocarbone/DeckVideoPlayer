-- Modal list menus (track selection, settings, dialogs).
--
-- Menu spec:
--   {
--     title = "Audio",
--     style = "side" | "center",
--     items = {
--       {label = "English", checked = true, action = fn},
--       {label = "Subtitle size", value = fn_or_string, adjust = fn(dir)},
--       {label = "Info", disabled = true},
--     },
--     selected = 1,
--     message = "…",    -- center dialogs: one line under the title
--     code = "2VKW",    -- center dialogs: a big code to type elsewhere (Plex sign-in)
--     qr = matrix,      -- center dialogs: QR code (dvp/qrencode.lua) left of the
--                       -- message lines and the code (message may hold "\n")
--     on_cancel = fn,   -- called when dismissed with B (not when an item is chosen)
--   }
-- Menus stack: opening a menu while another is open pushes it; B pops.

local ui = require "dvp.ui"

local M = {}
M.__index = M

function M.new()
    local self = setmetatable({stack = {}, layer = ui.layer(50)}, M)
    -- The selected row scrolls when its text doesn't fit.
    self.marquee = ui.marquee(function() self:render() end)
    return self
end

function M:is_open()
    return #self.stack > 0
end

function M:top()
    return self.stack[#self.stack]
end

-- Width of a side menu on a canvas W units wide.
function M.side_width(W)
    return math.min(500, W * 0.45)
end

local function selectable(item)
    return item and not item.disabled and not item.separator
end

local function first_selectable(items, from, dir)
    local n = #items
    local i = from
    for _ = 1, n do
        if selectable(items[i]) then return i end
        i = i + dir
        if i < 1 then i = n elseif i > n then i = 1 end
    end
    return from
end

function M:open(spec)
    spec.selected = first_selectable(spec.items, spec.selected or 1, 1)
    spec.scroll = 0
    table.insert(self.stack, spec)
    self:render()
end

function M:close_top()
    local spec = table.remove(self.stack)
    if spec and spec.on_cancel then spec.on_cancel() end
    self:render()
end

function M:close_all()
    while #self.stack > 0 do
        local spec = table.remove(self.stack)
        if spec.on_cancel then spec.on_cancel() end
    end
    self:render()
end

-- Replace the items of the top menu (e.g. after a value changed) keeping the cursor.
function M:refresh()
    local spec = self:top()
    if spec and spec.rebuild then
        spec.items = spec.rebuild()
        spec.selected = math.min(spec.selected, #spec.items)
    end
    self:render()
end

-- Change fields (items, subtitle…) of a menu that may still be open, e.g.
-- when an asynchronous search finishes. Returns false if it was closed.
function M:update(spec, fields)
    for _, s in ipairs(self.stack) do
        if s == spec then
            for k, v in pairs(fields) do spec[k] = v end
            spec.selected = first_selectable(spec.items, 1, 1)
            spec.scroll = 0
            if self:top() == spec then self:render() end
            return true
        end
    end
    return false
end

function M:handle(action)
    local spec = self:top()
    if not spec then return false end
    local items = spec.items
    local item = items[spec.selected]
    if action == "up" or action == "down" then
        local dir = action == "up" and -1 or 1
        local i = spec.selected + dir
        if i < 1 then i = #items elseif i > #items then i = 1 end
        spec.selected = first_selectable(items, i, dir)
        self:render()
    elseif action == "lb" or action == "rb" then
        local i = action == "lb" and 1 or #items
        spec.selected = first_selectable(items, i, action == "lb" and 1 or -1)
        self:render()
    elseif action == "left" or action == "right" then
        if item and item.adjust then
            item.adjust(action == "left" and -1 or 1)
            self:refresh()
        end
    elseif action == "confirm" then
        if selectable(item) then
            if item.action then
                -- Close first so the action can open another menu or screen.
                if not item.keep_open then table.remove(self.stack) end
                item.action()
                self:refresh()
            elseif item.adjust then
                item.adjust(1)
                self:refresh()
            end
        end
    elseif action == "back" or action == spec.close_action then
        self:close_top()
    elseif action == "menu" and spec.style == "side" then
        self:close_all()
    end
    return true
end

---------------------------------------------------------------------------
-- Rendering
---------------------------------------------------------------------------

local ROW_H = 52
local FS = 25

local function value_text(item)
    local v = item.value
    if type(v) == "function" then v = v() end
    return v
end

-- Splits the row's text area between label and value: both full when they
-- fit; otherwise the label keeps up to 45% and the value gets the rest.
-- Pure (unit-tested). Returns label_w, value_w (value_w includes `extra`,
-- the space for ◀ ▶ arrows).
function M.split_row(avail, label_need, value_need, extra, gap)
    if value_need <= 0 then return math.min(label_need, avail), 0 end
    value_need = value_need + extra
    if label_need + gap + value_need <= avail then return label_need, value_need end
    local label_w = math.min(label_need, math.max(avail * 0.45, avail - gap - value_need))
    return label_w, avail - gap - label_w
end

function M:render()
    local spec = self:top()
    self.marquee:begin()
    if not spec then
        self.marquee:finish()
        self.layer:clear()
        return
    end
    local t = ui.theme
    local W, H = ui.size()
    local a = ui.ass()
    local items = spec.items

    local pw, px, py, ph, list_top, max_rows
    local message_drawn = false
    if spec.style == "center" and spec.qr then
        -- QR on the left; message lines and the big code on the right.
        pw = math.min(760, W - 64)
        local qr_size = 232
        local rows = math.min(#items, 8)
        ph = 88 + qr_size + 24 + rows * ROW_H + 64
        px, py = (W - pw) / 2, (H - ph) / 2
        a:rect(0, 0, W, H, {color = t.black, opacity = 0.55})
        a:rect(px, py, pw, ph, {radius = 18, color = t.panel, opacity = 0.98})
        a:qr(px + 32, py + 84, qr_size, spec.qr)
        local tx, tw = px + 32 + qr_size + 32, pw - qr_size - 96
        local ty = py + 104
        for line in tostring(spec.message or ""):gmatch("[^\n]+") do
            a:text(tx, ty, ui.fit_text(line, 22, tw), {size = 22, color = t.subtext})
            ty = ty + 32
        end
        if spec.code then
            local spaced = tostring(spec.code):gsub("(.)", "%1 "):gsub(" $", "")
            a:rect(tx, ty + 6, tw, 92, {radius = 14, color = t.panel2})
            a:text(tx + tw / 2, ty + 52, spaced, {size = 58, bold = true, align = 5, color = t.accent})
        end
        list_top = py + 84 + qr_size + 24
        max_rows = rows
        message_drawn = true
    elseif spec.style == "center" then
        pw = math.min(620, W - 64)
        local rows = math.min(#items, 8)
        local code_h = spec.code and 96 or 0
        ph = 96 + (spec.message and 44 or 0) + code_h + rows * ROW_H + 64
        px, py = (W - pw) / 2, (H - ph) / 2
        -- Dim everything behind a dialog.
        a:rect(0, 0, W, H, {color = t.black, opacity = 0.55})
        a:rect(px, py, pw, ph, {radius = 18, color = t.panel, opacity = 0.98})
        list_top = py + 88 + (spec.message and 44 or 0) + code_h
        max_rows = rows
        if spec.code then
            -- Spaced-out letters read better from across the room.
            local spaced = tostring(spec.code):gsub("(.)", "%1 "):gsub(" $", "")
            a:rect(px + 32, list_top - code_h + 8, pw - 64, code_h - 20,
                   {radius = 14, color = t.panel2})
            a:text(W / 2, list_top - code_h / 2 - 2, spaced, {size = 58, bold = true, align = 5, color = t.accent})
        end
    else
        pw = M.side_width(W)
        px, py, ph = W - pw, 0, H
        a:rect(px - 60, 0, pw + 60, H, {color = t.black, opacity = 0.5, blur = 40})
        a:rect(px, py, pw, ph, {color = t.panel, opacity = 0.98})
        list_top = 104
        max_rows = math.floor((H - list_top - 80) / ROW_H)
    end

    a:text(px + 32, py + 52, ui.fit_text(spec.title or "", 32, pw - 64, true), {size = 32, bold = true})
    if spec.subtitle then
        a:text(px + 32, py + 84, ui.fit_text(spec.subtitle, 18, pw - 64), {size = 18, color = t.subtext})
    end
    if spec.message and not message_drawn then
        a:text(px + 32, py + 104, ui.fit_text(spec.message, 22, pw - 64), {size = 22, color = t.subtext})
    end

    -- Keep the cursor visible.
    if spec.selected > spec.scroll + max_rows then spec.scroll = spec.selected - max_rows end
    if spec.selected <= spec.scroll then spec.scroll = spec.selected - 1 end
    spec.scroll = math.max(0, math.min(spec.scroll, #items - max_rows))

    local x0, x1 = px + 16, px + pw - 16
    for row = 1, math.min(max_rows, #items) do
        local idx = spec.scroll + row
        local item = items[idx]
        local y = list_top + (row - 1) * ROW_H
        local cy = y + ROW_H / 2
        -- A list with nothing selectable ("Searching…") shows no cursor.
        local sel = idx == spec.selected and selectable(item)
        if item.separator then
            a:rect(x0 + 16, cy, x1 - x0 - 32, 1.5, {color = t.dim, opacity = 0.6})
        else
            if sel then
                a:rect(x0, y + 3, x1 - x0, ROW_H - 6, {radius = 12, color = t.accent})
            end
            local fg = item.disabled and t.dim or ((item.header and not sel) and t.accent or t.text)
            local tx = x0 + 18
            if item.checked ~= nil then
                if item.checked then
                    a:icon_check(tx + 11, cy, 22, {color = sel and t.text or t.accent,
                                                  inner = sel and t.accent or t.panel})
                else
                    a:circle(tx + 11, cy, 10, {color = t.dim, opacity = 0.0,
                                              border = 2, border_color = sel and t.text or t.dim,
                                              border_opacity = 1})
                end
                tx = tx + 36
            end
            local value = value_text(item)
            value = value and tostring(value)
            local arrows = item.adjust and 44 or 0
            local label_need = ui.text_width(item.label, FS, item.header)
            local value_need = value and ui.text_width(value, FS - 2) or 0
            local label_w, value_w = M.split_row((x1 - 18) - tx, label_need, value_need, arrows, 24)
            local value_box = value_w - arrows
            -- Only the selected row scrolls, and only one of its texts: the
            -- value when it is cut (e.g. a long subtitle name), else the label.
            -- (+0.5: value_box is computed by subtraction, so it can be a
            -- rounding error below value_need when the value fits exactly.)
            local scroll_value = sel and value and value_need > value_box + 0.5
            local scroll_label = sel and not scroll_value and label_need > label_w + 0.5
            local label_o = {size = FS, color = fg, bold = item.header}
            if scroll_label then
                self.marquee:draw(a, tostring(spec) .. "#" .. idx, tx, cy, item.label, label_w, label_o)
            else
                a:text(tx, cy, ui.fit_text(item.label, FS, label_w, item.header), label_o)
            end
            if value then
                local vx = x1 - 18
                local vcolor = sel and t.text or t.subtext
                if item.adjust then
                    a:icon_triangle(vx - 6, cy, 12, "right", {color = vcolor})
                    vx = vx - 22
                end
                local vo = {size = FS - 2, color = vcolor}
                if scroll_value then
                    self.marquee:draw(a, tostring(spec) .. "#" .. idx .. "v", vx - value_box, cy,
                                      value, value_box, vo)
                else
                    vo.align = 6
                    a:text(vx, cy, ui.fit_text(value, FS - 2, value_box), vo)
                end
                if item.adjust then
                    local lx = vx - math.min(value_need, value_box) - 14
                    a:icon_triangle(lx, cy, 12, "left", {color = vcolor})
                end
            end
        end
    end

    -- Scroll indicator
    if #items > max_rows then
        local track_h = max_rows * ROW_H
        local bar_h = math.max(30, track_h * max_rows / #items)
        local bar_y = list_top + (track_h - bar_h) * spec.scroll / (#items - max_rows)
        a:rect(px + pw - 8, bar_y, 4, bar_h, {radius = 2, color = t.subtext, opacity = 0.7})
    end

    local hints = {{"A", "Select"}, {"B", "Back"}}
    local cur = items[spec.selected]
    if cur and cur.adjust then table.insert(hints, 1, {"DPAD_LR", "Adjust"}) end
    a:hints(hints, px + pw - 28, py + ph - 36, {size = 26})

    self.marquee:finish()
    self.layer:set(a:build())
end

return M
