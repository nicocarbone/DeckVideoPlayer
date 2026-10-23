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

-- Removable media: actual mount points under /run/media or /media (where
-- SteamOS mounts the microSD card and USB drives), read from mountinfo.
function M.parse_mountinfo(text)
    local points = {}
    for line in text:gmatch("[^\n]+") do
        local mount_point = line:match("^%S+ %S+ %S+ %S+ (%S+)")
        if mount_point then
            mount_point = mount_point:gsub("\\(%d%d%d)", function(o) return string.char(tonumber(o, 8)) end)
            if mount_point:match("^/run/media/.+") or mount_point:match("^/media/.+") then
                points[#points + 1] = mount_point
            end
        end
    end
    return points
end

local function removable_roots()
    local roots, seen = {}, {}
    local text = util.read_file("/proc/self/mountinfo") or ""
    local points = M.parse_mountinfo(text)
    table.sort(points)
    for _, path in ipairs(points) do
        if not seen[path] and util.is_dir(path) then
            seen[path] = true
            roots[#roots + 1] = {name = util.basename(path), path = path, kind = "removable"}
        end
    end
    return roots
end

-- Returns the list of top-level sources that currently exist.
function M.sources(cfg)
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
    return out
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
    for _, list in ipairs({dirs, files}) do
        for _, e in ipairs(list) do
            e.label = M.display_name(e.name, e.is_dir, clean)
            e.key = util.natural_key(e.label)
        end
        if sort_mode == "date" then
            table.sort(list, function(a, b)
                if a.mtime ~= b.mtime then return (a.mtime or 0) > (b.mtime or 0) end
                return a.key < b.key
            end)
        else
            table.sort(list, function(a, b) return a.key < b.key end)
        end
    end
    local out = dirs
    for _, f in ipairs(files) do out[#out + 1] = f end
    return out
end

return M
