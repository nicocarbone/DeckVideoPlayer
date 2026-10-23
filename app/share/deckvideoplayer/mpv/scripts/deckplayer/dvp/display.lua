-- Display handling: device detection, rendering profile, HDR and
-- refresh-rate matching under gamescope (SteamOS game mode).
--
-- Refresh-rate matching works by setting the GAMESCOPE_DYNAMIC_REFRESH root
-- window property, the same mechanism Steam's per-game refresh slider uses.
-- gamescope only honours it for panels with a dynamic refresh table (Steam
-- Deck LCD/OLED and some other handhelds) and ignores it while VRR is active.

local util = require "dvp.util"
local msg = require "mp.msg"

local M = {}
M.__index = M

-- Valid dynamic refresh rates from gamescope's display profiles
-- (scripts/00-gamescope/displays/valve.steamdeck.*.lua).
local DECK_OLED_RATES = {45, 47, 48, 49, 50, 51, 53, 55, 56, 59, 60, 62, 64, 65, 66, 68,
                         72, 73, 76, 77, 78, 80, 81, 82, 84, 85, 86, 87, 88, 90}
local DECK_LCD_RATES = {}
for hz = 40, 60 do DECK_LCD_RATES[#DECK_LCD_RATES + 1] = hz end

local ATOM_INTERNAL = "GAMESCOPE_DYNAMIC_REFRESH"

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
        int XChangeProperty(Display *dpy, Window w, Atom property, Atom type, int format,
                            int mode, const unsigned char *data, int nelements);
        int XDeleteProperty(Display *dpy, Window w, Atom property);
        int XGetWindowProperty(Display *dpy, Window w, Atom property, long offset, long length,
                               int del, Atom req_type, Atom *actual_type, int *actual_format,
                               unsigned long *nitems, unsigned long *bytes_after,
                               unsigned char **prop);
        int XFree(void *data);
        int XFlush(Display *dpy);
    ]])
    if not cdef_ok then return false end
    local lib_ok, lib = pcall(ffi.load, "libX11.so.6")
    if not lib_ok then return false end
    X.ffi, X.lib = ffi, lib
    return true
end

local XA_CARDINAL = 6
local PROP_MODE_REPLACE = 0

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

-- value == nil deletes the property.
function M.set_root_cardinal(name, value)
    if ffi_init() then
        return with_display(function(dpy, root)
            local ffi, lib = X.ffi, X.lib
            local atom = lib.XInternAtom(dpy, name, 0)
            if value == nil then
                lib.XDeleteProperty(dpy, root, atom)
            else
                -- Format-32 properties are passed as C longs by Xlib.
                local data = ffi.new("unsigned long[1]", value)
                lib.XChangeProperty(dpy, root, atom, XA_CARDINAL, 32, PROP_MODE_REPLACE,
                    ffi.cast("const unsigned char*", data), 1)
            end
            lib.XFlush(dpy)
            return true
        end) == true
    end
    local args
    if value == nil then
        args = {"xprop", "-root", "-remove", name}
    else
        args = {"xprop", "-root", "-f", name, "32c", "-set", name, tostring(value)}
    end
    return xprop(args) ~= nil
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

    if dcfg.refresh_rates ~= "auto" then
        self.rates = M.parse_rates(dcfg.refresh_rates)
    elseif self.device == "deck-oled" then
        self.rates = DECK_OLED_RATES
    elseif self.device == "deck-lcd" then
        self.rates = DECK_LCD_RATES
    else
        self.rates = {}
    end
    self.refresh_enabled = dcfg.refresh_match ~= "off" and self.gamescope and #self.rates > 0
    self.original_rate = nil   -- value of the atom before we touched it
    self.current_rate = nil    -- rate we requested, nil when untouched
    return self
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
        self.device, self.quality, tostring(self.gamescope), tostring(self.refresh_enabled)))
end

-- Called once the video's frame rate is known.
function M:match(fps)
    if not self.refresh_enabled then return nil end
    local hz = M.choose_rate(fps, self.rates, self.cfg.display.refresh_prefer)
    if not hz then
        self:restore()
        return nil
    end
    if self.original_rate == nil then
        local v = M.get_root_cardinal(ATOM_INTERNAL)
        if v == nil then
            msg.warn("cannot access X11 root window; refresh-rate matching disabled")
            self.refresh_enabled = false
            return nil
        end
        self.original_rate = v -- false when unset
    end
    if self.current_rate ~= hz and M.set_root_cardinal(ATOM_INTERNAL, hz) then
        msg.info(string.format("refresh rate -> %d Hz for %.3f fps", hz, fps))
        self.current_rate = hz
    end
    if self.current_rate then
        mp.set_property_number("display-fps-override", self.current_rate)
    end
    return self.current_rate
end

-- Give the refresh rate back to Steam's setting.
function M:restore()
    if self.current_rate == nil then return end
    local orig = self.original_rate
    M.set_root_cardinal(ATOM_INTERNAL, orig ~= false and orig or nil)
    mp.set_property_number("display-fps-override", 0)
    msg.info("refresh rate restored")
    self.current_rate = nil
end

return M
