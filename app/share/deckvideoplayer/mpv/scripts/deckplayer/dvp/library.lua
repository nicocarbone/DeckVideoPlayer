-- Library sources and directory listing.
--
-- A "source" is a browsable root. Today only local folders exist (configured
-- folders plus removable media such as the microSD card); network shares or
-- media servers can be added later as new source kinds with the same
-- list()/entry shape.

local utils = require "mp.utils"
local util = require "dvp.util"

local M = {}

local function ext_set(csv)
    local set = {}
    for _, e in ipairs(util.split(csv, ",")) do set[e:lower():gsub("^%.", "")] = true end
    return set
end

-- Release-style names ("The.Movie.2019.1080p") read better with spaces.
function M.display_name(name, is_dir, clean)
    local n = is_dir and name or util.strip_extension(name)
    if clean and not n:find(" ") then
        n = n:gsub("[._]+", " ")
        n = util.trim(n)
    end
    if n == "" then n = name end
    return n
end

local function unescape(s)
    return (s:gsub("\\(%d%d%d)", function(o) return string.char(tonumber(o, 8)) end))
end

-- Not volumes: an in-memory /run/media/<user> etc. (seen in some setups).
local PSEUDO_FS = {tmpfs = true, ramfs = true, autofs = true, overlay = true, proc = true,
                   sysfs = true, devtmpfs = true, cgroup2 = true}

-- Removable media: actual mount points under /run/media or /media (where
-- SteamOS mounts the microSD card and USB drives), read from mountinfo.
-- Returns {path, source} with source = the device ("/dev/mmcblk0p1"); the
-- source survives Flatpak's bind mounts because it names the filesystem.
function M.parse_mountinfo(text)
    local points = {}
    for line in text:gmatch("[^\n]+") do
        local mount_point = line:match("^%S+ %S+ %S+ %S+ (%S+)")
        local fstype, source = line:match(" %- (%S+) (%S+)")
        if mount_point and not PSEUDO_FS[fstype or ""] then
            mount_point = unescape(mount_point)
            if mount_point:match("^/run/media/.+") or mount_point:match("^/media/.+") then
                points[#points + 1] = {path = mount_point, source = source and unescape(source) or ""}
            end
        end
    end
    return points
end

-- Mount folder names that are IDs, not names a person gave the volume:
-- UUIDs, FAT/exFAT serials ("1A2B-3C4D"), kernel device names.
local function is_generated_name(name)
    return (#name >= 8 and name:match("^[%x%-]+$") ~= nil)
        or name:match("^mmcblk%d") ~= nil or name:match("^sd%a%d*$") ~= nil
        or name:match("^nvme%d") ~= nil
end

-- Kind and display name of a removable volume (pure, unit-tested):
-- microSD -> "sdcard", "SD Card" / "SD Card (Label)"; USB -> "usb",
-- the label or "USB drive"; anything else -> "removable", folder name.
function M.removable_info(path, source)
    local base = util.basename(path)
    local label = not is_generated_name(base) and base or nil
    if source:match("^/dev/mmcblk") then
        return "sdcard", label and ("SD Card (" .. label .. ")") or "SD Card"
    elseif source:match("^/dev/sd") or source:match("^/dev/nvme") then
        return "usb", label or "USB drive"
    end
    return "removable", base
end

local function removable_roots()
    local roots, seen, names = {}, {}, {}
    local text = util.read_file("/proc/self/mountinfo") or ""
    local points = M.parse_mountinfo(text)
    table.sort(points, function(a, b) return a.path < b.path end)
    for _, p in ipairs(points) do
        if not seen[p.path] and util.is_dir(p.path) then
            seen[p.path] = true
            local kind, name = M.removable_info(p.path, p.source)
            -- Two unlabelled USB drives: "USB drive", "USB drive 2".
            names[name] = (names[name] or 0) + 1
            if names[name] > 1 then name = name .. " " .. names[name] end
            roots[#roots + 1] = {name = name, path = p.path, kind = kind}
        end
    end
    return roots
end

-- Returns the list of top-level sources that currently exist. `extra`:
-- more sources appended at the end (Plex servers, see dvp/plex.lua).
function M.sources(cfg, extra)
    local out, seen = {}, {}
    for _, folder in ipairs(cfg.library.folder) do
        local path = util.expand_path(folder)
        if util.is_dir(path) and not seen[path] then
            seen[path] = true
            out[#out + 1] = {name = util.basename(path), path = path, kind = "folder"}
        end
    end
    if cfg.library.removable_media then
        for _, r in ipairs(removable_roots()) do
            if not seen[r.path] then
                seen[r.path] = true
                out[#out + 1] = r
            end
        end
    end
    for _, s in ipairs(extra or {}) do out[#out + 1] = s end
    return out
end

-- The local source (folder or drive) a file is in: the one with the
-- longest matching path, or nil. Pure.
function M.source_for(sources, path)
    local best
    for _, s in ipairs(sources) do
        local p = s.path
        if p and p:sub(1, 1) == "/" and (#p > (best and #best.path or 0)) then
            local prefix = p:sub(-1) == "/" and p or (p .. "/")
            if path == p or path:sub(1, #prefix) == prefix then best = s end
        end
    end
    return best
end

-- Where a local file is, short (a tag on "Recently played" rows) and long
-- (Video info): "Local" / "Local · Videos", "SD Card" / "SD Card (Label)",
-- "USB" / "USB drive · Label". `source`: from source_for (nil: "Local"). Pure.
function M.source_tag(source)
    local kind = source and source.kind
    if kind == "sdcard" then return "SD Card" end
    if kind == "usb" then return "USB" end
    if kind == "removable" then return "Drive" end
    return "Local"
end

function M.source_label(source)
    if not source then return "Local" end
    local kind, name = source.kind, source.name
    if kind == "sdcard" then return name end
    if kind == "usb" then return name == "USB drive" and name or ("USB drive · " .. name) end
    if kind == "removable" then return "Drive · " .. name end
    return "Local · " .. name
end

-- Sorts entries in place: folders first, then files; by natural name
-- order, or by date (newest first) when mode == "date". The name used is
-- `sort_name`, else `name`, else `label`; dates come from `mtime`.
function M.sort_entries(entries, mode)
    local dirs, files = {}, {}
    for _, e in ipairs(entries) do
        e.key = util.natural_key(e.sort_name or e.name or e.label)
        if e.is_dir then dirs[#dirs + 1] = e else files[#files + 1] = e end
    end
    for _, list in ipairs({dirs, files}) do
        if mode == "date" then
            table.sort(list, function(a, b)
                if a.mtime ~= b.mtime then return (a.mtime or 0) > (b.mtime or 0) end
                return a.key < b.key
            end)
        else
            table.sort(list, function(a, b) return a.key < b.key end)
        end
    end
    for i = #entries, 1, -1 do entries[i] = nil end
    for _, e in ipairs(dirs) do entries[#entries + 1] = e end
    for _, e in ipairs(files) do entries[#entries + 1] = e end
    return entries
end

-- Lists a directory: folders first, then video files.
-- Returns entries {name, label, path, is_dir, mtime, size} or nil, err.
function M.list(path, cfg, sort_mode)
    local names, err = utils.readdir(path, "all")
    if not names then return nil, err end
    local exts = M._exts
    if not exts or M._exts_src ~= cfg.library.extensions then
        exts = ext_set(cfg.library.extensions)
        M._exts, M._exts_src = exts, cfg.library.extensions
    end
    local dirs, files = {}, {}
    for _, name in ipairs(names) do
        if cfg.library.show_hidden or name:sub(1, 1) ~= "." then
            local full = util.join(path, name)
            local info = utils.file_info(full)
            if info then
                if info.is_dir then
                    dirs[#dirs + 1] = {name = name, path = full, is_dir = true, mtime = info.mtime}
                elseif info.is_file and exts[util.extension(name)] then
                    files[#files + 1] = {name = name, path = full, is_dir = false,
                                         mtime = info.mtime, size = info.size}
                end
            end
        end
    end
    local clean = cfg.interface.clean_names
    local out = {}
    for _, list in ipairs({dirs, files}) do
        for _, e in ipairs(list) do
            e.label = M.display_name(e.name, e.is_dir, clean)
            -- Sort by the cleaned label (name keeps the real file name).
            e.sort_name = e.label
            out[#out + 1] = e
        end
    end
    return M.sort_entries(out, sort_mode)
end

return M
