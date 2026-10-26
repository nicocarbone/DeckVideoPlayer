-- HDR choices (D52), in the Video menu with defaults from config.ini
-- ([display] hdr, hdr_mapping, hdr_peak, sdr_to_hdr). Menu changes last
-- for the session, like night mode.
--
-- HDR on/off: off makes mpv tone-map everything to SDR
--   (`target-colorspace-hint=no`), even HDR files on an HDR screen.
-- HDR mapping, for HDR sources:
--   static  mpv sends the source's whole-film metadata; gamescope / the TV
--           fits it to the display (the default, as up to v0.4.0).
--   dynamic the same, with per-scene metadata (Dolby Vision / HDR10+, or
--           measured) passed to the display
--           (`target-colorspace-hint-mode=source-dynamic`).
--   app     mpv tone-maps to `peak` nits itself (per-scene metadata, peak
--           detection) and tells the display the content peaks there.
-- SDR to HDR, for SDR sources: mpv's inverse tone mapping to PQ / BT.2020
-- with highlights up to `itm` nits (0 = off).
--
-- The choices only make sense on a screen in HDR mode: on an SDR output
-- "app" and SDR to HDR dim and wash out the picture. Whether the screen is
-- in HDR mode is learnt from what mpv outputs (`screen`: nil until known),
-- and the choices are dropped while it isn't. A known HDR screen is checked
-- again with each file (the Deck may have been docked to an SDR TV); a
-- known SDR one only becomes HDR again when mpv outputs HDR (an HDR file
-- after HDR was turned on in SteamOS), so it doesn't flicker every file.
-- Nothing runs while idle: options change only when a file's transfer
-- function becomes known or a choice changes, plus one check per file
-- until the screen is known.

local M = {}
M.__index = M

M.MAPPINGS = {"static", "dynamic", "app"}
M.LABELS = {static = "Display", dynamic = "Display, per scene", app = "App"}   -- menu
M.DESCRIPTIONS = {dynamic = "Display maps, per-scene metadata"}                 -- info panel
M.PEAK_MIN, M.PEAK_MAX, M.PEAK_STEP = 300, 2000, 100
M.ITM_LEVELS = {0, 300, 400, 600, 1000}
M.CHECK_DELAY = 1.5

-- Options this module sets; their values at start are restored.
M.PROPS = {"target-colorspace-hint", "target-colorspace-hint-mode", "target-peak", "target-trc",
           "target-prim", "inverse-tone-mapping", "hdr-compute-peak"}

local function is_hdr(gamma) return gamma == "pq" or gamma == "hlg" end
M.is_hdr = is_hdr

-- Pure: peak from config.ini, clamped and rounded to the menu's step.
function M.clamp_peak(n)
    n = math.floor((tonumber(n) or 1000) / M.PEAK_STEP + 0.5) * M.PEAK_STEP
    return math.max(M.PEAK_MIN, math.min(M.PEAK_MAX, n))
end

-- Pure: config.ini's sdr_to_hdr ("off" or one of ITM_LEVELS) in nits.
function M.parse_itm(v)
    return tonumber(v) or 0
end

-- Pure: the choices that actually apply to source `s.gamma` (nil while
-- unknown): {mapping = ..., itm = ...}, or nil for "nothing beyond the
-- defaults". `s.screen == false` (no HDR output) drops them all.
function M.effective(s)
    if not s.enabled or not s.gamma or s.screen == false then return nil end
    if is_hdr(s.gamma) then
        if s.mapping == "static" then return nil end
        return {mapping = s.mapping}
    end
    if s.itm > 0 then return {itm = s.itm} end
    return nil
end

-- Pure: option values for state `s` = {enabled, gamma, mapping, peak, itm,
-- screen}, starting from `defaults`.
function M.options(s, defaults)
    local o = {}
    for k, v in pairs(defaults) do o[k] = v end
    if not s.enabled then
        o["target-colorspace-hint"] = "no"
        return o
    end
    local e = M.effective(s)
    if not e then return o end
    if e.mapping == "dynamic" then
        o["target-colorspace-hint-mode"] = "source-dynamic"
    elseif e.mapping == "app" then
        o["target-peak"] = tostring(s.peak)
        o["hdr-compute-peak"] = "yes"
    elseif e.itm then
        o["inverse-tone-mapping"] = "yes"
        o["target-trc"] = "pq"
        o["target-prim"] = "bt.2020"
        o["target-peak"] = tostring(e.itm)
    end
    return o
end

-- Pure: whether mpv should be outputting HDR, so the output tells whether
-- the screen is in HDR mode.
function M.expects_hdr(s)
    if not s.enabled or not s.gamma then return false end
    return is_hdr(s.gamma) or s.itm > 0
end

-- Pure: next value of `list` after `current` in direction `dir` (clamped).
function M.step(list, current, dir)
    for i, v in ipairs(list) do
        if v == current then return list[math.max(1, math.min(#list, i + dir))] end
    end
    return list[1]
end

-- `menu`: the Video menu shows HDR choices (not on a Deck LCD, an SDR
-- panel). `notify(text)` is called when `screen` changes: `text` is a toast
-- to show, or nil (the menu and badges only need a redraw).
function M.new(cfg, device, notify)
    local self = setmetatable({}, M)
    local d = cfg.display
    self.notify = notify or function() end
    self.menu = device ~= "deck-lcd"
    self.enabled = d.hdr ~= "off"
    self.mapping, self.peak, self.itm = d.hdr_mapping, M.clamp_peak(d.hdr_peak), M.parse_itm(d.sdr_to_hdr)
    self.screen = nil
    self.defaults, self.applied = {}, {}
    for _, p in ipairs(M.PROPS) do
        self.defaults[p] = mp.get_property(p)
        self.applied[p] = self.defaults[p]
    end
    self:apply()
    mp.observe_property("video-params/gamma", "string", function(_, gamma)
        -- No video (between files): check a known HDR screen again.
        if not gamma and self.screen then self.screen = nil end
        self.gamma = gamma
        self:apply()
    end)
    -- HDR output proves an HDR screen, also one thought to be SDR.
    mp.observe_property("video-target-params/gamma", "string", function(_, out)
        if is_hdr(out) and not self.screen then
            local was = self.screen
            self.screen = true
            if was == false then
                self:apply()
                self.notify(nil)
            end
        end
    end)
    return self
end

function M:apply()
    local o = M.options(self, self.defaults)
    for _, p in ipairs(M.PROPS) do
        if o[p] ~= nil and o[p] ~= self.applied[p] then
            mp.set_property(p, o[p])
            self.applied[p] = o[p]
        end
    end
    if self.check_timer then self.check_timer:kill() end
    if self.screen == nil and M.expects_hdr(self) then
        self.check_tries = 0
        self.check_timer = mp.add_timeout(M.CHECK_DELAY, function() self:check() end)
    end
end

-- Reads what mpv outputs once the new options have reached a frame.
function M:check()
    local out = mp.get_property("video-target-params/gamma")
    if not out then
        -- Nothing drawn yet (slow start): look again, a few times.
        self.check_tries = self.check_tries + 1
        if self.check_tries < 3 then
            self.check_timer = mp.add_timeout(M.CHECK_DELAY, function() self:check() end)
        end
        return
    end
    if is_hdr(out) then
        self.screen = true
        return
    end
    local before = M.effective(self)
    self.screen = false
    self:apply()
    -- Without HDR output, app mapping and SDR to HDR are dropped.
    if before and (before.itm or before.mapping == "app") then
        self.notify("This screen isn't in HDR mode: "
            .. (before.itm and "SDR to HDR" or "app tone mapping") .. " is off")
    else
        self.notify(nil)
    end
end

-- The Video menu shows HDR choices only for screens that can show them.
function M:show_menu()
    return self.menu and self.screen ~= false
end

function M:toggle()
    self.enabled = not self.enabled
    self:apply()
    return self.enabled
end

function M:set_mapping(dir)
    self.mapping = M.step(M.MAPPINGS, self.mapping, dir)
    self:apply()
end

function M:set_peak(dir)
    self.peak = M.clamp_peak(self.peak + dir * M.PEAK_STEP)
    self:apply()
end

function M:set_itm(dir)
    self.itm = M.step(M.ITM_LEVELS, self.itm, dir)
    self:apply()
end

-- Line for the info panel: what is done to the current file beyond plain
-- HDR passthrough / SDR, or nil.
function M:describe()
    if not self.enabled then return "Off (tone-mapped to SDR)" end
    local e = M.effective(self)
    if not e then return nil end
    if e.mapping == "app" then return string.format("App maps to %d nits", self.peak) end
    if e.mapping then return M.DESCRIPTIONS[e.mapping] end
    return string.format("SDR to HDR, up to %d nits", e.itm)
end

return M
