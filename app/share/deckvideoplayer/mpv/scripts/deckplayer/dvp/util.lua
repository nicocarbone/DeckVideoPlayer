-- Small helpers shared by all modules. Pure Lua (5.1/5.2/LuaJIT compatible),
-- except for the few functions that talk to mpv.

local M = {}

function M.trim(s)
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

function M.split(s, sep)
    local out = {}
    for piece in (s .. sep):gmatch("(.-)" .. sep:gsub("%p", "%%%0")) do
        piece = M.trim(piece)
        if piece ~= "" then out[#out + 1] = piece end
    end
    return out
end

function M.clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

function M.round(v)
    return math.floor(v + 0.5)
end

-- "~" and "$VAR" expansion for paths written in config.ini.
function M.expand_path(p)
    local home = os.getenv("HOME") or ""
    p = p:gsub("^~/", home .. "/"):gsub("^~$", home)
    p = p:gsub("%${?([%w_]+)}?", function(var) return os.getenv(var) or "" end)
    if #p > 1 then p = p:gsub("/+$", "") end
    return p
end

function M.join(dir, name)
    if dir:sub(-1) == "/" then return dir .. name end
    return dir .. "/" .. name
end

function M.basename(p)
    return p:match("([^/]+)/*$") or p
end

function M.dirname(p)
    local d = p:match("^(.*)/[^/]*$")
    if d == nil then return "." end
    if d == "" then return "/" end
    return d
end

function M.extension(name)
    local ext = name:match("%.([^%./]+)$")
    return ext and ext:lower() or ""
end

function M.strip_extension(name)
    return (name:gsub("%.[^%./]+$", ""))
end

-- Seconds -> "1:02:03" / "2:03".
function M.format_time(sec, force_hours)
    if sec == nil or sec ~= sec or sec < 0 then sec = 0 end
    sec = math.floor(sec + 0.5)
    local h = math.floor(sec / 3600)
    local m = math.floor(sec / 60) % 60
    local s = sec % 60
    if h > 0 or force_hours then
        return string.format("%d:%02d:%02d", h, m, s)
    end
    return string.format("%d:%02d", m, s)
end

-- Escape text so libass renders it literally (same approach as mpv's osc).
function M.ass_escape(s)
    s = s:gsub("\\", "\\\239\187\191")
    s = s:gsub("{", "\\{")
    s = s:gsub("^ ", "\\h")
    s = s:gsub("\n", "\\N")
    return s
end

-- UTF-8 aware length/truncation (Lua 5.1 has no utf8 library).
local UTF8_CHAR = "[\1-\127\194-\244][\128-\191]*"

function M.utf8_len(s)
    local n = 0
    for _ in s:gmatch(UTF8_CHAR) do n = n + 1 end
    return n
end

function M.utf8_truncate(s, max_chars)
    if max_chars < 1 then return "" end
    if M.utf8_len(s) <= max_chars then return s end
    local out, n = {}, 0
    for ch in s:gmatch(UTF8_CHAR) do
        n = n + 1
        if n >= max_chars then break end
        out[n] = ch
    end
    return M.trim(table.concat(out)) .. "…"
end

-- Sort key giving "natural" order: "Episode 2" < "Episode 10".
function M.natural_key(s)
    return (s:lower():gsub("%d+", function(d)
        d = d:gsub("^0+", "")
        if #d < 12 then d = string.rep("0", 12 - #d) .. d end
        return d
    end))
end

function M.read_file(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local data = f:read("*a")
    f:close()
    return data
end

-- Write via temp file + rename so a crash never leaves a truncated file.
function M.write_file_atomic(path, data)
    local tmp = path .. ".tmp"
    local f, err = io.open(tmp, "wb")
    if not f then return false, err end
    f:write(data)
    f:close()
    return os.rename(tmp, path)
end

function M.is_dir(path)
    local utils = require "mp.utils"
    local info = utils.file_info(path)
    return info ~= nil and info.is_dir
end

function M.mkdir_p(path)
    if M.is_dir(path) then return true end
    local r = mp.command_native({
        name = "subprocess", args = {"mkdir", "-p", path},
        playback_only = false, capture_stdout = true, capture_stderr = true,
    })
    return r and r.status == 0
end

function M.shallow_copy(t)
    local c = {}
    for k, v in pairs(t) do c[k] = v end
    return c
end

return M
