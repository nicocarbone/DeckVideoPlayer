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

-- The folder downloads go to ([library] download_folder), or nil (unset,
-- or not an absolute path).
function M.download_folder(cfg)
    local f = cfg.library.download_folder
    if not f or f == "" then return nil end
    f = util.expand_path(f)
    if f:sub(1, 1) ~= "/" then return nil end
    return f
end

-- Returns the list of top-level sources that currently exist. `extra`:
-- more sources appended at the end (Plex servers, see dvp/plex.lua).
-- The download folder is a source of its own while it holds something,
-- even inside another one: that is where offline videos are.
function M.sources(cfg, extra)
    local out, seen = {}, {}
    local folders = util.shallow_copy(cfg.library.folder)
    local downloads = M.download_folder(cfg)
    if downloads and #(util.readdir(downloads, "all") or {}) > 0 then folders[#folders + 1] = downloads end
    for _, folder in ipairs(folders) do
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

---------------------------------------------------------------------------
-- Deleting local videos (D60). Only files on this device: never a media
-- server's (they are URLs, and no server request deletes anything), never
-- a network share mounted into a library folder.
---------------------------------------------------------------------------

-- Every mount point with its filesystem type, from mountinfo (pure).
function M.parse_mounts(text)
    local mounts = {}
    for line in tostring(text or ""):gmatch("[^\n]+") do
        local mount_point = line:match("^%S+ %S+ %S+ %S+ (%S+)")
        local fstype = line:match(" %- (%S+) ")
        if mount_point and fstype then
            mounts[#mounts + 1] = {path = unescape(mount_point), fstype = fstype}
        end
    end
    return mounts
end

-- The mount a path is on: the longest matching mount point (pure).
function M.mount_for(mounts, path)
    local best
    for _, m in ipairs(mounts) do
        local p = m.path
        local prefix = p:sub(-1) == "/" and p or (p .. "/")
        if (path == p or path:sub(1, #prefix) == prefix) and (not best or #p > #best.path) then best = m end
    end
    return best
end

-- Filesystems that live on another machine.
local NETWORK_FS = {
    cifs = true, smb3 = true, smbfs = true, nfs = true, nfs4 = true, ceph = true, glusterfs = true,
    ["9p"] = true, afs = true, davfs = true, ["fuse.sshfs"] = true, ["fuse.rclone"] = true,
    ["fuse.gvfsd-fuse"] = true, ["fuse.davfs2"] = true, ["fuse.s3fs"] = true,
    ["fuse.curlftpfs"] = true, ["fuse.smbnetfs"] = true,
}

function M.is_network_fs(fstype)
    return NETWORK_FS[fstype or ""] == true
end

-- Library sources that hold files of this device.
local LOCAL_KINDS = {folder = true, sdcard = true, usb = true, removable = true}

-- Whether `name` has one of the configured video extensions.
function M.is_video(name, cfg)
    local exts = M._exts
    if not exts or M._exts_src ~= cfg.library.extensions then
        exts = ext_set(cfg.library.extensions)
        M._exts, M._exts_src = exts, cfg.library.extensions
    end
    return exts[util.extension(name)] == true
end

-- Why `path` can't be deleted, or nil when it can (pure): it must be a
-- video file inside a local library source (not the source itself), with
-- a plain absolute path, and not on a network share.
function M.delete_refusal(path, sources, mounts, cfg)
    if type(path) ~= "string" or path:sub(1, 1) ~= "/" or path:find("//", 1, true)
        or path:find("/%.%.?/") or path:find("/%.%.?$") or path:find("%z") then
        return "Only videos on this device can be deleted"
    end
    local source = M.source_for(sources, path)
    if not source or not LOCAL_KINDS[source.kind] or path == source.path then
        return "Only videos on this device can be deleted"
    end
    if not M.is_video(util.basename(path), cfg) then return "Not a video file" end
    local mount = M.mount_for(mounts, path)
    if mount and M.is_network_fs(mount.fstype) then return "Videos on a network share can't be deleted" end
    return nil
end

local SUB_EXTS = {srt = true, ass = true, ssa = true, vtt = true, sub = true, idx = true, sup = true, smi = true}

-- Subtitle files that belong to `video` (a name in a folder of `names`):
-- "<video name>.srt", "<video name>.en.forced.srt"… A subtitle that matches
-- a longer video name too ("Film.Extended.en.srt" next to "Film.mkv" and
-- "Film.Extended.mkv") belongs to that one. Pure.
function M.sidecar_subtitles(video, names)
    local videos = {}
    for _, n in ipairs(names) do
        if not SUB_EXTS[util.extension(n)] then videos[#videos + 1] = util.strip_extension(n) .. "." end
    end
    local base = util.strip_extension(video) .. "."
    local out = {}
    for _, n in ipairs(names) do
        if SUB_EXTS[util.extension(n)] and n:sub(1, #base) == base then
            local owner = base
            for _, v in ipairs(videos) do
                if #v > #owner and n:sub(1, #v) == v then owner = v end
            end
            if owner == base then out[#out + 1] = n end
        end
    end
    table.sort(out)
    return out
end

-- Deletes a local video and its subtitle files. Folders left empty inside
-- the download folder go too (a show's season folder), never the download
-- folder itself. Returns true, or false and a message.
function M.delete_video(path, sources, cfg)
    local mounts = M.parse_mounts(util.read_file("/proc/self/mountinfo") or "")
    local refusal = M.delete_refusal(path, sources, mounts, cfg)
    if refusal then return false, refusal end
    local info = utils.file_info(path)
    if not info or not info.is_file then return false, "The file is gone" end
    local dir = util.dirname(path)
    local ok, err = os.remove(path)
    if not ok then
        err = tostring(err)
        if err:find("Read%-only") or err:find("Permission denied") then
            return false, "Can't delete: this folder is read-only"
        end
        return false, "Can't delete: " .. err
    end
    for _, n in ipairs(M.sidecar_subtitles(util.basename(path), util.readdir(dir, "files") or {})) do
        os.remove(util.join(dir, n))
    end
    local downloads = M.download_folder(cfg)
    while downloads and dir ~= downloads and dir:sub(1, #downloads + 1) == downloads .. "/" do
        local left = util.readdir(dir, "all")
        if not left or #left > 0 or not os.remove(dir) then break end
        dir = util.dirname(dir)
    end
    return true
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
    local names, err = util.readdir(path, "all")
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
