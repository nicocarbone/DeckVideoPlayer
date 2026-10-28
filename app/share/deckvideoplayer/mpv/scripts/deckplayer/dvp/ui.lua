-- Drawing primitives on top of mpv's ASS OSD overlays.
--
-- All layout is done in a virtual coordinate space that is 800 units tall
-- (the Steam Deck's native height) and as wide as the screen's aspect ratio
-- requires, so the same layout scales cleanly from 1280x800 to 4K.

local util = require "dvp.util"

local M = {}

M.BASE_HEIGHT = 800
M.scale = 1.0

M.theme = {
    font    = "Inter",
    bg      = "0E1217",
    panel   = "181E26",
    panel2  = "232B36",
    accent  = "1A9FFF",
    text    = "FFFFFF",
    subtext = "9AA7B5",
    dim     = "5C6773",
    good    = "5BD18B",
    warn    = "F2B84B",
    bad     = "FF6464",
    black   = "000000",
}

function M.configure(cfg)
    M.scale = util.clamp(cfg.interface.ui_scale or 1, 0.5, 3)
    local accent = (cfg.interface.accent_color or ""):gsub("^#", "")
    if accent:match("^%x%x%x%x%x%x$") then M.theme.accent = accent:upper() end
end

-- "RRGGBB" -> ASS "&HBBGGRR&"
local function color(hex)
    return string.format("&H%s%s%s&", hex:sub(5, 6), hex:sub(3, 4), hex:sub(1, 2))
end

-- opacity 0..1 -> ASS alpha (00 = opaque, FF = transparent)
local function alpha(opacity)
    return string.format("&H%02X&", util.clamp(util.round(255 * (1 - (opacity or 1))), 0, 255))
end

local function num(v)
    -- Compact number formatting for drawing commands.
    local s = string.format("%.2f", v)
    s = s:gsub("0+$", ""):gsub("%.$", "")
    return s
end

-- Current virtual canvas size.
function M.size()
    local dim = mp.get_property_native("osd-dimensions") or {}
    local w, h = dim.w or 0, dim.h or 0
    if w <= 0 or h <= 0 then w, h = 1280, 800 end
    local vh = M.BASE_HEIGHT / M.scale
    local vw = vh * w / h
    return math.floor(vw), math.floor(vh)
end

---------------------------------------------------------------------------
-- Layers: one mpv OSD overlay each, stacked by z.
---------------------------------------------------------------------------

function M.layer(z)
    local ov = mp.create_osd_overlay("ass-events")
    ov.z = z
    local layer = {visible = false}
    function layer:set(ass)
        local w, h = M.size()
        ov.res_x, ov.res_y = w, h
        ov.data = ass
        ov:update()
        self.visible = true
    end
    function layer:clear()
        if self.visible then
            ov:remove()
            self.visible = false
        end
    end
    return layer
end

---------------------------------------------------------------------------
-- ASS builder
---------------------------------------------------------------------------

local Ass = {}
Ass.__index = Ass

function M.ass()
    return setmetatable({parts = {}}, Ass)
end

function Ass:build()
    return table.concat(self.parts, "\n")
end

function Ass:raw(s)
    self.parts[#self.parts + 1] = s
    return self
end

local function rrect_path(x, y, w, h, r)
    r = math.min(r or 0, w / 2, h / 2)
    if r <= 0.5 then
        return string.format("m %s %s l %s %s %s %s %s %s",
            num(x), num(y), num(x + w), num(y), num(x + w), num(y + h), num(x), num(y + h))
    end
    local k = r * 0.4477 -- control point offset for a circular-looking corner
    local p = {
        "m", x + r, y,
        "l", x + w - r, y,
        "b", x + w - k, y, x + w, y + k, x + w, y + r,
        "l", x + w, y + h - r,
        "b", x + w, y + h - k, x + w - k, y + h, x + w - r, y + h,
        "l", x + r, y + h,
        "b", x + k, y + h, x, y + h - k, x, y + h - r,
        "l", x, y + r,
        "b", x, y + k, x + k, y, x + r, y,
    }
    for i, v in ipairs(p) do
        if type(v) == "number" then p[i] = num(v) end
    end
    return table.concat(p, " ")
end
M.rrect_path = rrect_path

-- Generic filled vector drawing. `path` uses absolute canvas coordinates.
-- o: color, opacity, blur, border, border_color, border_opacity
function Ass:path(path, o)
    o = o or {}
    local tags = string.format("{\\an7\\pos(0,0)\\bord%s\\shad0\\1c%s\\1a%s",
        num(o.border or 0), color(o.color or M.theme.text), alpha(o.opacity))
    if o.border and o.border > 0 then
        tags = tags .. string.format("\\3c%s\\3a%s", color(o.border_color or M.theme.black),
            alpha(o.border_opacity or o.opacity))
    end
    if o.blur then tags = tags .. "\\blur" .. num(o.blur) end
    if o.clip then
        tags = tags .. string.format("\\clip(%d,%d,%d,%d)", o.clip[1], o.clip[2], o.clip[3], o.clip[4])
    end
    return self:raw(tags .. "\\p1}" .. path .. "{\\p0}")
end

function Ass:rect(x, y, w, h, o)
    o = o or {}
    return self:path(rrect_path(x, y, w, h, o.radius or 0), o)
end

function Ass:circle(cx, cy, r, o)
    return self:path(rrect_path(cx - r, cy - r, 2 * r, 2 * r, r), o)
end

function Ass:polygon(points, o)
    local p = {"m", num(points[1]), num(points[2]), "l"}
    for i = 3, #points, 2 do
        p[#p + 1] = num(points[i])
        p[#p + 1] = num(points[i + 1])
    end
    return self:path(table.concat(p, " "), o)
end

-- Text. o: size, color, opacity, align (ASS numpad, default 4 = left-middle),
-- bold, italic, clip {x1,y1,x2,y2}, outline (px), font. Never wraps (\\q2):
-- long text is shortened or scrolled by the caller instead.
function Ass:text(x, y, str, o)
    o = o or {}
    local tags = string.format("{\\q2\\an%d\\pos(%s,%s)\\fn%s\\fs%s\\b%d\\i%d\\shad0\\1c%s\\1a%s",
        o.align or 4, num(x), num(y), o.font or M.theme.font, num(o.size or 26),
        o.bold and 1 or 0, o.italic and 1 or 0, color(o.color or M.theme.text), alpha(o.opacity))
    if o.outline then
        tags = tags .. string.format("\\bord%s\\3c%s\\3a%s", num(o.outline), color(M.theme.black),
            alpha((o.opacity or 1) * 0.6))
    else
        tags = tags .. "\\bord0"
    end
    if o.clip then
        tags = tags .. string.format("\\clip(%d,%d,%d,%d)", o.clip[1], o.clip[2], o.clip[3], o.clip[4])
    end
    return self:raw(tags .. "}" .. util.ass_escape(str))
end

---------------------------------------------------------------------------
-- Text measuring. libass has no cheap per-string measuring API, so widths
-- are estimated per character class from Inter's real advance widths
-- (measured with fontTools; D32). Units: fraction of the ASS font size
-- (libass sizes text by ascender+descender = 1.21 em for Inter, so
-- 1 em = 0.826 \fs).
---------------------------------------------------------------------------

local EM = 0.826
-- Average advance widths per class (em), Inter Regular; classes are
-- disjoint (the "lowercase" average excludes the narrow/semi/wide letters).
local NARROW = {}   -- 0.28 em
for c in ("iIlj.,:;'|!`"):gmatch(".") do NARROW[c] = true end
local SEMI = {}     -- 0.39 em
for c in ("ftr()[]{}\"/-"):gmatch(".") do SEMI[c] = true end
local WIDE = {}     -- 0.92 em
for c in ("mwMW@%"):gmatch(".") do WIDE[c] = true end

local function char_em(ch)
    local b = ch:byte(1)
    if ch == "·" then return 0.29 end
    if b >= 0xF0 then return 1.2 end          -- emoji etc.
    if b >= 0xE0 then return 1.0 end          -- CJK, "…" and other 3-byte chars
    if b >= 0x80 then return 0.6 end          -- accented Latin, Greek, Cyrillic
    if ch == " " then return 0.28 end
    if NARROW[ch] then return 0.28 end
    if SEMI[ch] then return 0.39 end
    if WIDE[ch] then return 0.92 end
    if ch:match("%u") then return 0.68 end
    if ch:match("%d") then return 0.6 end
    return 0.58                                -- other lowercase and punctuation
end

local UTF8_CHAR = "[\1-\127\194-\244][\128-\191]*"

function M.text_width(str, size, bold)
    local em = 0
    for ch in str:gmatch(UTF8_CHAR) do em = em + char_em(ch) end
    return em * EM * size * (bold and 1.04 or 1)
end

-- Truncates with "…" so the result fits in max_w. (Half a unit of slack:
-- widths computed as a + b - b can differ from a by a rounding error.)
function M.fit_text(str, size, max_w, bold)
    if M.text_width(str, size, bold) <= max_w + 0.5 then return str end
    local unit = EM * size * (bold and 1.04 or 1)
    local budget = max_w / unit - 1.0         -- room for the ellipsis
    local out, em = {}, 0
    for ch in str:gmatch(UTF8_CHAR) do
        em = em + char_em(ch)
        if em > budget then break end
        out[#out + 1] = ch
    end
    return util.trim(table.concat(out)) .. "…"
end

---------------------------------------------------------------------------
-- Marquee: text too long for its box scrolls inside it (selected menu row,
-- selected library entry). One instance per screen; `redraw` is called
-- while something scrolls. Scrolling stops after a few passes, so a screen
-- left alone does no work (battery). Usage in a render function:
--   m:begin(); ...; m:draw(ass, key, x, y, text, max_w, opts); ...; m:finish()
---------------------------------------------------------------------------

local Marquee = {}
Marquee.__index = Marquee
local MQ_SPEED, MQ_PAUSE, MQ_PASSES, MQ_FPS = 45, 1.2, 3, 24

function M.marquee(redraw)
    return setmetatable({redraw = redraw}, Marquee)
end

function Marquee:begin()
    self.scrolling = false
end

-- Pure: horizontal offset at time t (seconds since the text was selected)
-- for text `overflow` units wider than its box, or nil once finished.
function M.marquee_offset(t, overflow)
    local travel = overflow / MQ_SPEED
    local cycle = MQ_PAUSE + travel + MQ_PAUSE
    if t >= cycle * MQ_PASSES then return nil end
    local phase = t % cycle
    if phase < MQ_PAUSE then return 0 end
    return math.min(overflow, (phase - MQ_PAUSE) * MQ_SPEED)
end

-- Draws `str` left-aligned in [x, x + max_w] at y; scrolls when it doesn't fit.
function Marquee:draw(a, key, x, y, str, max_w, o)
    local w = M.text_width(str, o.size, o.bold)
    if w <= max_w + 0.5 then return a:text(x, y, str, o) end
    if key ~= self.key or str ~= self.text then
        self.key, self.text, self.t0 = key, str, mp.get_time()
    end
    local off = M.marquee_offset(mp.get_time() - self.t0, w - max_w + (o.size or 26) * 0.3)
    if not off or off == 0 then
        -- Resting (before scrolling, or after the last pass): "…" version.
        if off then self.scrolling = true end
        return a:text(x, y, M.fit_text(str, o.size, max_w, o.bold), o)
    end
    self.scrolling = true
    local size = o.size or 26
    local clipped = util.shallow_copy(o)
    clipped.clip = {math.floor(x), math.floor(y - size), math.ceil(x + max_w), math.ceil(y + size)}
    return a:text(x - off, y, str, clipped)
end

function Marquee:finish()
    if self.scrolling then
        if not self.timer then self.timer = mp.add_periodic_timer(1 / MQ_FPS, self.redraw) end
    else
        if self.timer then
            self.timer:kill()
            self.timer = nil
        end
    end
end

-- Forget the current text (e.g. the screen was hidden).
function Marquee:reset()
    self.key = nil
    self.scrolling = false
    self:finish()
end

---------------------------------------------------------------------------
-- Icons
---------------------------------------------------------------------------

function Ass:icon_folder(x, cy, s, o)
    local h = s * 0.74
    local y = cy - h / 2
    self:rect(x, y - s * 0.08, s * 0.42, s * 0.2, {radius = s * 0.06, color = o.color, opacity = o.opacity})
    return self:rect(x, y, s, h, {radius = s * 0.1, color = o.color, opacity = o.opacity})
end

function Ass:icon_video(x, cy, s, o)
    local h = s * 0.74
    local y = cy - h / 2
    self:rect(x, y, s, h, {radius = s * 0.12, color = o.color, opacity = o.opacity})
    local tx, ty = x + s * 0.4, cy
    return self:polygon({tx, ty - h * 0.24, tx + s * 0.28, ty, tx, ty + h * 0.24},
        {color = o.inner or M.theme.bg, opacity = o.opacity})
end

function Ass:icon_drive(x, cy, s, o)
    local h = s * 0.62
    local y = cy - h / 2
    self:rect(x, y, s, h, {radius = s * 0.14, color = o.color, opacity = o.opacity})
    return self:circle(x + s * 0.78, cy, s * 0.07, {color = o.inner or M.theme.bg, opacity = o.opacity})
end

-- QR code from a module matrix (matrix[x][y] > 0 = dark, as made by
-- dvp/qrencode.lua) in a `size`-wide square at (x, y), on a white square
-- with the 4-module quiet zone scanners need. Dark modules are merged into
-- horizontal runs: one drawing, a few hundred rectangles at most.
function Ass:qr(x, y, size, matrix, o)
    o = o or {}
    local n = #matrix
    local cell = size / (n + 8)
    self:rect(x, y, size, size, {radius = cell * 2, color = "FFFFFF"})
    local parts = {}
    local ox, oy = x + 4 * cell, y + 4 * cell
    for row = 1, n do
        local col = 1
        while col <= n do
            if matrix[col][row] > 0 then
                local start = col
                while col <= n and matrix[col][row] > 0 do col = col + 1 end
                local x0, x1 = ox + (start - 1) * cell, ox + (col - 1) * cell
                local y0, y1 = oy + (row - 1) * cell, oy + row * cell
                parts[#parts + 1] = string.format("m %.2f %.2f l %.2f %.2f %.2f %.2f %.2f %.2f",
                    x0, y0, x1, y0, x1, y1, x0, y1)
            else
                col = col + 1
            end
        end
    end
    return self:path(table.concat(parts, " "), {color = o.color or "000000"})
end

-- Media server (Plex): two stacked rack units with status lights.
-- A network share: a folder on a network line (stem down to a bar).
function Ass:icon_network(x, cy, s, o)
    local fx, fw, fh = x + s * 0.12, s * 0.76, s * 0.44
    local fy = cy - s * 0.38
    self:rect(fx, fy - s * 0.07, s * 0.32, s * 0.16, {radius = s * 0.05, color = o.color, opacity = o.opacity})
    self:rect(fx, fy, fw, fh, {radius = s * 0.08, color = o.color, opacity = o.opacity})
    self:rect(x + s * 0.46, fy + fh, s * 0.08, s * 0.2, {color = o.color, opacity = o.opacity})
    return self:rect(x, fy + fh + s * 0.2, s, s * 0.09, {radius = s * 0.045, color = o.color, opacity = o.opacity})
end

function Ass:icon_server(x, cy, s, o)
    local w, h = s, s * 0.34
    for i = 0, 1 do
        local y = cy - s * 0.38 + i * (h + s * 0.08)
        self:rect(x, y, w, h, {radius = s * 0.08, color = o.color, opacity = o.opacity})
        self:circle(x + w - s * 0.18, y + h / 2, s * 0.06, {color = o.inner or M.theme.bg, opacity = o.opacity})
        self:rect(x + s * 0.14, y + h / 2 - s * 0.03, s * 0.36, s * 0.06,
                  {color = o.inner or M.theme.bg, opacity = o.opacity})
    end
    return self
end

-- microSD card: portrait card with the top-right corner cut, three contacts.
function Ass:icon_sdcard(x, cy, s, o)
    local x1, x2 = x + s * 0.2, x + s * 0.8
    local y1, y2 = cy - s * 0.42, cy + s * 0.42
    local c = s * 0.2
    self:polygon({x1, y1, x2 - c, y1, x2, y1 + c, x2, y2, x1, y2}, {color = o.color, opacity = o.opacity})
    for i = 0, 2 do
        self:rect(x1 + s * (0.09 + i * 0.13), y1 + s * 0.08, s * 0.07, s * 0.18,
            {color = o.inner or M.theme.bg, opacity = o.opacity})
    end
    return self
end

function Ass:icon_check(cx, cy, s, o)
    self:circle(cx, cy, s / 2, {color = o.color or M.theme.good, opacity = o.opacity})
    local u = s / 12
    local pts = {
        cx - 3.6 * u, cy + 0.0 * u,
        cx - 2.0 * u, cy - 1.6 * u,
        cx - 0.9 * u, cy - 0.5 * u,
        cx + 2.6 * u, cy - 4.0 * u,
        cx + 4.2 * u, cy - 2.4 * u,
        cx - 0.9 * u, cy + 2.7 * u,
    }
    return self:polygon(pts, {color = o.inner or M.theme.bg, opacity = o.opacity})
end

function Ass:icon_play(cx, cy, s, o)
    return self:polygon({cx - s * 0.35, cy - s * 0.45, cx + s * 0.45, cy, cx - s * 0.35, cy + s * 0.45}, o)
end

function Ass:icon_pause(cx, cy, s, o)
    local bw, gap = s * 0.3, s * 0.2
    self:rect(cx - gap / 2 - bw, cy - s / 2, bw, s, {radius = bw * 0.2, color = o.color, opacity = o.opacity})
    return self:rect(cx + gap / 2, cy - s / 2, bw, s, {radius = bw * 0.2, color = o.color, opacity = o.opacity})
end

function Ass:icon_triangle(cx, cy, s, dir, o)
    local pts
    if dir == "left" then
        pts = {cx + s * 0.35, cy - s * 0.5, cx - s * 0.4, cy, cx + s * 0.35, cy + s * 0.5}
    else
        pts = {cx - s * 0.35, cy - s * 0.5, cx + s * 0.4, cy, cx - s * 0.35, cy + s * 0.5}
    end
    return self:polygon(pts, o)
end

---------------------------------------------------------------------------
-- Controller button glyphs + hint bars
---------------------------------------------------------------------------

local function glyph_width(btn, s)
    if btn == "A" or btn == "B" or btn == "X" or btn == "Y" then return s end
    if btn == "DPAD" or btn == "DPAD_LR" or btn == "DPAD_UD" then return s end
    if btn == "MENU" or btn == "VIEW" then return s * 1.25 end
    return s * 1.45 -- L1 R1 L2 R2
end

-- Draws a button glyph with its left edge at x, vertically centered on cy.
-- Returns the glyph width.
function Ass:button(btn, x, cy, s, o)
    o = o or {}
    local fg = o.color or M.theme.text
    local bg = o.inner or M.theme.bg
    local op = o.opacity or 1
    local w = glyph_width(btn, s)
    if btn == "A" or btn == "B" or btn == "X" or btn == "Y" then
        self:circle(x + s / 2, cy, s / 2, {color = fg, opacity = op})
        self:text(x + s / 2, cy, btn, {align = 5, size = s * 0.72, bold = true, color = bg, opacity = op})
    elseif btn == "DPAD" or btn == "DPAD_LR" or btn == "DPAD_UD" then
        local t = s * 0.36
        local hl = M.theme.accent
        self:rect(x, cy - t / 2, s, t, {radius = t * 0.25, color = fg, opacity = op})
        self:rect(x + s / 2 - t / 2, cy - s / 2, t, s, {radius = t * 0.25, color = fg, opacity = op})
        if btn == "DPAD_LR" then
            self:rect(x, cy - t / 2, t, t, {radius = t * 0.25, color = hl, opacity = op})
            self:rect(x + s - t, cy - t / 2, t, t, {radius = t * 0.25, color = hl, opacity = op})
        elseif btn == "DPAD_UD" then
            self:rect(x + s / 2 - t / 2, cy - s / 2, t, t, {radius = t * 0.25, color = hl, opacity = op})
            self:rect(x + s / 2 - t / 2, cy + s / 2 - t, t, t, {radius = t * 0.25, color = hl, opacity = op})
        end
    elseif btn == "MENU" then
        self:rect(x, cy - s / 2, w, s, {radius = s / 2, color = fg, opacity = op})
        local lw, lh = w * 0.44, s * 0.09
        for i = -1, 1 do
            self:rect(x + (w - lw) / 2, cy + i * s * 0.19 - lh / 2, lw, lh, {radius = lh / 2, color = bg, opacity = op})
        end
    elseif btn == "VIEW" then
        self:rect(x, cy - s / 2, w, s, {radius = s / 2, color = fg, opacity = op})
        local q = s * 0.3
        self:rect(x + w * 0.5 - q * 0.75, cy - q * 0.75, q, q,
            {radius = q * 0.15, color = fg, opacity = op, border = s * 0.06, border_color = bg})
        self:rect(x + w * 0.5 - q * 0.25, cy - q * 0.25, q, q,
            {radius = q * 0.15, color = fg, opacity = op, border = s * 0.06, border_color = bg})
    else
        self:rect(x, cy - s / 2, w, s, {radius = s * 0.28, color = fg, opacity = op})
        self:text(x + w / 2, cy, btn, {align = 5, size = s * 0.6, bold = true, color = bg, opacity = op})
    end
    return w
end

-- hints: list of {button, label}. Draws right-aligned ending at x_right.
-- Width Ass:hints() would use for these hints.
function M.hints_width(hints, o)
    o = o or {}
    local s = o.size or 26
    local fs = o.font_size or s * 0.82
    local total = 0
    for i, h in ipairs(hints) do
        total = total + glyph_width(h[1], s) + s * 0.35 + M.text_width(h[2], fs) + (i > 1 and s * 0.95 or 0)
    end
    return total
end

function Ass:hints(hints, x_right, cy, o)
    o = o or {}
    local s = o.size or 26
    local fs = o.font_size or s * 0.82
    local gap = s * 0.35
    local spacing = s * 0.95
    local total = 0
    local widths = {}
    for i, h in ipairs(hints) do
        widths[i] = glyph_width(h[1], s) + gap + M.text_width(h[2], fs)
        total = total + widths[i] + (i > 1 and spacing or 0)
    end
    local x = x_right - total
    if o.align == "left" then x = o.x_left end
    for i, h in ipairs(hints) do
        local gw = self:button(h[1], x, cy, s, {color = o.color, inner = o.inner, opacity = o.opacity})
        self:text(x + gw + gap, cy, h[2], {size = fs, color = o.color or M.theme.text,
            opacity = o.opacity, outline = o.outline})
        x = x + widths[i] + spacing
    end
    return total
end

return M
