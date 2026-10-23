-- Display handling: device detection, rendering profile, HDR and
-- refresh-rate matching under gamescope (SteamOS game mode).
--
-- Refresh-rate matching asks gamescope for a rate through its private
-- gamescope_control Wayland protocol, the same request Steam's refresh
-- slider sends (helper program dvp-gamescope-refresh, see helper/). The
-- rates a display can switch to come from gamescope itself (empty for TVs
-- and nested sessions). The rate in effect is read back from the
-- GAMESCOPE_DISPLAY_REFRESH_RATE_FEEDBACK root property when possible, so
-- the UI never claims a switch that was contradicted. gamescope only sets
-- that property on its first Xwayland server (Steam's); in SteamOS game
-- mode apps run on the second one, so there the switch can't be confirmed
-- and is shown as "requested". gamescope ignores requests while VRR is
-- active. See docs/DECISIONS.md D6 and D31.

local util = require "dvp.util"
local msg = require "mp.msg"

local M = {}
M.__index = M

local HELPER = "dvp-gamescope-refresh"
local ATOM_FEEDBACK = "GAMESCOPE_DISPLAY_REFRESH_RATE_FEEDBACK"
-- gamescope switches after the target has been stable for 600 ms, then the
-- panel needs a moment: check the result after this long.
local VERIFY_DELAY = 2.0

---------------------------------------------------------------------------
-- X11 root window property access. Prefer LuaJIT FFI (no subprocess, works
-- inside the Flatpak sandbox); fall back to the xprop tool.
---------------------------------------------------------------------------

local X = {}

local function ffi_init()
    if X.tried then return X.lib ~= nil end
    X.tried = true
    local ok, ffi = pcall(require, "ffi")
    if not ok then return false end
    local cdef_ok = pcall(ffi.cdef, [[
        typedef struct _XDisplay Display;
        typedef unsigned long XID;
        typedef XID Window;
        typedef unsigned long Atom;
        Display *XOpenDisplay(const char *name);
        int XCloseDisplay(Display *dpy);
        Window XDefaultRootWindow(Display *dpy);
        Atom XInternAtom(Display *dpy, const char *name, int only_if_exists);
        int XGetWindowProperty(Display *dpy, Window w, Atom property, long offset, long length,
                               int del, Atom req_type, Atom *actual_type, int *actual_format,
                               unsigned long *nitems, unsigned long *bytes_after,
                               unsigned char **prop);
        int XFree(void *data);
    ]])
    if not cdef_ok then return false end
    local lib_ok, lib = pcall(ffi.load, "libX11.so.6")
    if not lib_ok then return false end
    X.ffi, X.lib = ffi, lib
    return true
end

local XA_CARDINAL = 6

local function with_display(fn)
    local dpy = X.lib.XOpenDisplay(nil)
    if dpy == nil then return nil end
    local ok, res = pcall(fn, dpy, X.lib.XDefaultRootWindow(dpy))
    X.lib.XCloseDisplay(dpy)
    if ok then return res end
    msg.warn("X11 call failed: " .. tostring(res))
    return nil
end

local function xprop(args)
    local r = mp.command_native({
        name = "subprocess", args = args, playback_only = false,
        capture_stdout = true, capture_stderr = true,
    })
    if not r or r.status ~= 0 then return nil end
    return r.stdout or ""
end

-- Returns the CARDINAL value, false if the property is unset, nil on error.
function M.get_root_cardinal(name)
    if ffi_init() then
        return with_display(function(dpy, root)
            local ffi, lib = X.ffi, X.lib
            local atom = lib.XInternAtom(dpy, name, 1)
            if atom == 0 then return false end
            local actual_type = ffi.new("Atom[1]")
            local actual_format = ffi.new("int[1]")
            local nitems = ffi.new("unsigned long[1]")
            local after = ffi.new("unsigned long[1]")
            local prop = ffi.new("unsigned char*[1]")
            local status = lib.XGetWindowProperty(dpy, root, atom, 0, 1, 0, XA_CARDINAL,
                actual_type, actual_format, nitems, after, prop)
            if status ~= 0 or nitems[0] < 1 or prop[0] == nil then
                if prop[0] ~= nil then lib.XFree(prop[0]) end
                return false
            end
            local value = tonumber(ffi.cast("unsigned long*", prop[0])[0])
            lib.XFree(prop[0])
            return value
        end)
    end
    local out = xprop({"xprop", "-root", name})
    if not out then return nil end
    local v = out:match("=%s*(%d+)")
    if v then return tonumber(v) end
    return false
end

---------------------------------------------------------------------------
-- Device / environment detection
---------------------------------------------------------------------------

local function read_sys(path)
    local s = util.read_file(path)
    return s and util.trim(s) or ""
end

function M.detect_device()
    local vendor = read_sys("/sys/class/dmi/id/sys_vendor")
    local product = read_sys("/sys/class/dmi/id/product_name")
    if vendor == "Valve" or product == "Jupiter" or product == "Galileo" then
        if product == "Galileo" then return "deck-oled" end
        if product == "Jupiter" then return "deck-lcd" end
    end
    return "tv"
end

function M.in_gamescope()
    return os.getenv("GAMESCOPE_WAYLAND_DISPLAY") ~= nil
        or (os.getenv("XDG_CURRENT_DESKTOP") or ""):lower() == "gamescope"
end

-- Parses "45-90" or "48,60,72" into a sorted list of integer rates.
function M.parse_rates(spec)
    local rates = {}
    local lo, hi = spec:match("^%s*(%d+)%s*%-%s*(%d+)%s*$")
    if lo then
        for hz = tonumber(lo), tonumber(hi) do rates[#rates + 1] = hz end
    else
        for _, v in ipairs(util.split(spec, ",")) do
            local n = tonumber(v)
            if n then rates[#rates + 1] = math.floor(n) end
        end
    end
    table.sort(rates)
    return rates
end

-- Picks a refresh rate that is an integer multiple of `fps` (within 0.5%),
-- preferring the lowest (battery) or highest (smoothest UI) candidate.
function M.choose_rate(fps, rates, prefer)
    if not fps or fps <= 0 or #rates == 0 then return nil end
    local best
    for _, hz in ipairs(rates) do
        local n = math.floor(hz / fps + 0.5)
        if n >= 1 and math.abs(hz - n * fps) / hz <= 0.005 then
            if not best or (prefer == "high" and hz > best) or (prefer ~= "high" and hz < best) then
                best = hz
            end
        end
    end
    return best
end

---------------------------------------------------------------------------
-- Instance
---------------------------------------------------------------------------

-- Parses the helper's output:
-- "connector=eDP-1 internal=1 only_refresh=1 rates=45,47,48" ->
-- {connector = "eDP-1", internal = true, rates = {45, 47, 48}}
function M.parse_helper_info(text)
    local info = {rates = {}}
    info.connector = text:match("connector=(%S*)") or ""
    info.internal = text:match("internal=1") ~= nil
    local rates = text:match("rates=([%d,]*)")
    if rates and rates ~= "" then info.rates = M.parse_rates(rates) end
    return info
end

-- Runs the helper; returns parsed info or nil, error text.
local function run_helper(args)
    local r = mp.command_native({
        name = "subprocess", args = args, playback_only = false,
        capture_stdout = true, capture_stderr = true,
    })
    if not r or r.status ~= 0 then
        return nil, util.trim((r and (r.stderr ~= "" and r.stderr or r.error_string)) or "failed")
    end
    return M.parse_helper_info(r.stdout or "")
end

function M.new(cfg)
    local self = setmetatable({cfg = cfg}, M)
    local dcfg = cfg.display
    self.device = dcfg.device ~= "auto" and dcfg.device or M.detect_device()
    self.gamescope = M.in_gamescope()

    local quality = dcfg.quality
    if quality == "auto" then
        quality = self.device == "tv" and "high" or "balanced"
    end
    self.quality = quality

    -- Explicit list from config.ini, else whatever gamescope reports.
    self.config_rates = dcfg.refresh_rates ~= "auto" and M.parse_rates(dcfg.refresh_rates) or nil
    -- possible: we are in gamescope and the helper works; on: user choice
    -- (config.ini default, playback menu toggle).
    self.refresh_possible = self.gamescope
    self.refresh_on = dcfg.refresh_match ~= "off"
    self.original_hz = nil    -- refresh rate before our first request
    self.requested_hz = nil   -- rate we asked for, nil when untouched
    self.actual_hz = nil      -- rate gamescope reported after the request
    self.verified = nil       -- nil: not checked yet / unreadable; true / false
    self.verify_timer = nil
    return self
end

-- Refresh rate gamescope is driving the display at, or nil.
function M:current_hz()
    local v = M.get_root_cardinal(ATOM_FEEDBACK)
    return v and v > 0 and v or nil
end

-- Apply mpv options for the chosen quality/HDR settings. Called once at
-- startup, while idle.
function M:apply_profile()
    mp.commandv("apply-profile", "dvp-quality-" .. self.quality)
    if self.cfg.display.hdr == "off" then
        mp.set_property("target-colorspace-hint", "no")
    end
    if self.cfg.display.display_resample then
        mp.set_property("video-sync", "display-resample")
    end
    msg.info(string.format("device=%s quality=%s gamescope=%s refresh-match=%s",
        self.device, self.quality, tostring(self.gamescope), tostring(self.refresh_possible and self.refresh_on)))
end

-- Called once the video's frame rate is known. `on_result(actual_hz,
-- requested_hz)` is called once gamescope's answer can be checked; returns
-- the requested rate (or nil when no switch was attempted).
function M:match(fps, on_result)
    if not (self.refresh_possible and self.refresh_on) then return nil end
    -- Until the new rate is known, let mpv measure instead of keeping the
    -- previous file's value.
    if self.requested_hz then mp.set_property_number("display-fps-override", 0) end
    local info, err = run_helper({HELPER, "info"})
    if not info then
        msg.warn("refresh-rate matching disabled: " .. tostring(err))
        self.refresh_possible = false
        return nil
    end
    local rates = self.config_rates or info.rates
    -- One rate (or none) means gamescope can't switch this display.
    if #rates < 2 then
        self:restore()
        return nil
    end
    local hz = M.choose_rate(fps, rates, self.cfg.display.refresh_prefer)
    if not hz then
        self:restore()
        return nil
    end
    if self.original_hz == nil then
        self.original_hz = self:current_hz() or false
        self.max_hz = rates[#rates]
    end
    local ok, set_err = run_helper({HELPER, "set", tostring(hz)})
    if not ok then
        msg.warn("refresh-rate request failed: " .. tostring(set_err))
        return nil
    end
    msg.info(string.format("refresh rate: requested %d Hz for %.3f fps", hz, fps))
    self.requested_hz = hz
    self.actual_hz = nil
    self.verified = nil
    if self.verify_timer then self.verify_timer:kill() end
    self.verify_timer = mp.add_timeout(VERIFY_DELAY, function()
        self:verify(on_result)
    end)
    return hz
end

function M:verify(on_result)
    if not self.requested_hz then return end
    local actual = self:current_hz()
    self.actual_hz = actual
    if actual == nil then
        -- Second Xwayland server (normal in SteamOS game mode): gamescope's
        -- feedback isn't visible here. The request was accepted, so assume it.
        msg.info(string.format("refresh rate: requested %d Hz (gamescope's feedback "
            .. "isn't readable from this X server, so not confirmed)", self.requested_hz))
        mp.set_property_number("display-fps-override", self.requested_hz)
    elseif actual == self.requested_hz then
        self.verified = true
        msg.info(string.format("refresh rate: display now at %d Hz", actual))
        mp.set_property_number("display-fps-override", actual)
    else
        self.verified = false
        msg.warn(string.format("refresh rate: requested %d Hz but the display is at %s Hz",
            self.requested_hz, tostring(actual)))
        mp.set_property_number("display-fps-override", 0)
    end
    if on_result then on_result(actual, self.requested_hz) end
end

-- Playback menu toggle. Returns the requested rate when switching on.
function M:set_matching(on, fps, on_result)
    self.refresh_on = on
    if on then return self:match(fps, on_result) end
    self:restore()
    return nil
end

-- Asks again if something (e.g. Steam re-applying its own setting after the
-- Quick Access Menu) changed the rate. Cheap: one property read.
function M:reassert(on_result)
    if not self.requested_hz then return end
    -- Without readable feedback, simply ask again (cheap, idempotent).
    if self:current_hz() == self.requested_hz then return end
    if run_helper({HELPER, "set", tostring(self.requested_hz)}) then
        msg.info("refresh rate: re-requested " .. self.requested_hz .. " Hz")
        if self.verify_timer then self.verify_timer:kill() end
        self.verify_timer = mp.add_timeout(VERIFY_DELAY, function() self:verify(on_result) end)
    end
end

-- Gives the display back: to the rate it had before, or to native (0) when
-- that was the highest rate (the usual case).
function M:restore()
    if self.requested_hz == nil then return end
    if self.verify_timer then self.verify_timer:kill() end
    local orig = self.original_hz
    local target = (orig and self.max_hz and orig < self.max_hz) and orig or 0
    run_helper({HELPER, "set", tostring(target)})
    mp.set_property_number("display-fps-override", 0)
    msg.info("refresh rate restored" .. (target > 0 and (" to " .. target .. " Hz") or ""))
    self.requested_hz, self.actual_hz, self.verified = nil, nil, nil
end

return M
