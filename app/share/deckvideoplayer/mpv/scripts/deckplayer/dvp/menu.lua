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
--     on_cancel = fn,   -- called when dismissed with B (not when an item is chosen)
--   }
-- Menus stack: opening a menu while another is open pushes it; B pops.

local ui = require "dvp.ui"

local M = {}
M.__index = M

function M.new()
    return setmetatable({stack = {}, layer = ui.layer(50)}, M)
end

function M:is_open()
    return #self.stack > 0
end

function M:top()
    return self.stack[#self.stack]
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

function M:render()
    local spec = self:top()
    if not spec then
        self.layer:clear()
        return
    end
    local t = ui.theme
    local W, H = ui.size()
    local a = ui.ass()
    local items = spec.items

    local pw, px, py, ph, list_top, max_rows
    if spec.style == "center" then
        pw = math.min(620, W - 64)
        local rows = math.min(#items, 8)
        ph = 96 + (spec.message and 44 or 0) + rows * ROW_H + 64
        px, py = (W - pw) / 2, (H - ph) / 2
        -- Dim everything behind a dialog.
        a:rect(0, 0, W, H, {color = t.black, opacity = 0.55})
        a:rect(px, py, pw, ph, {radius = 18, color = t.panel, opacity = 0.98})
        list_top = py + 88 + (spec.message and 44 or 0)
        max_rows = rows
    else
        pw = math.min(500, W * 0.45)
        px, py, ph = W - pw, 0, H
        a:rect(px - 60, 0, pw + 60, H, {color = t.black, opacity = 0.5, blur = 40})
        a:rect(px, py, pw, ph, {color = t.panel, opacity = 0.94})
        list_top = 104
        max_rows = math.floor((H - list_top - 80) / ROW_H)
    end

    a:text(px + 32, py + 52, spec.title or "", {size = 32, bold = true})
    if spec.subtitle then
        a:text(px + 32, py + 84, spec.subtitle, {size = 18, color = t.subtext})
    end
    if spec.message then
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
        local sel = idx == spec.selected
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
            local value_w = 0
            if value then
                value = tostring(value)
                value_w = ui.text_width(value, FS - 2) + (item.adjust and 44 or 0)
            end
            local label_w = (x1 - 18) - tx - value_w - 12
            a:text(tx, cy, ui.fit_text(item.label, FS, label_w), {size = FS, color = fg, bold = item.header})
            if value then
                local vx = x1 - 18
                if item.adjust then
                    a:icon_triangle(vx - 6, cy, 12, "right", {color = sel and t.text or t.subtext})
                    vx = vx - 22
                end
                a:text(vx, cy, value, {size = FS - 2, align = 6, color = sel and t.text or t.subtext})
                if item.adjust then
                    local lx = vx - ui.text_width(value, FS - 2) - 14
                    a:icon_triangle(lx, cy, 12, "left", {color = sel and t.text or t.subtext})
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

    self.layer:set(a:build())
end

return M
