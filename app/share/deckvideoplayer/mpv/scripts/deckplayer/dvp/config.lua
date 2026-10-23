-- config.ini loading. The file format is a plain INI:
--
--   [section]
--   key = value        ; '#' or ';' at the start of a line starts a comment
--   folder = ~/Videos  ; some keys (folder) may be repeated
--
-- Unknown keys are ignored with a warning so a typo never prevents startup.

local util = require "dvp.util"

local M = {}

M.DEFAULT_EXTENSIONS = "mkv,mp4,m4v,avi,mov,wmv,flv,webm,ts,m2ts,mts,mpg,mpeg,mpe,vob,ogv,ogm,3gp,3g2,divx,xvid,rm,rmvb,asf,f4v,hevc,h264,264,265,av1,ivf,y4m,dv,mxf,nut"

-- Each entry: default value and parser type.
local SCHEMA = {
    library = {
        folder           = {default = {"~/Videos"}, type = "list"},
        removable_media  = {default = true, type = "bool"},
        extensions       = {default = M.DEFAULT_EXTENSIONS, type = "string"},
        show_hidden      = {default = false, type = "bool"},
    },
    playback = {
        audio_languages    = {default = "", type = "string"},
        subtitle_languages = {default = "", type = "string"},
        subtitles          = {default = "auto", type = "enum", values = {"auto", "always", "forced", "off"}},
        resume             = {default = true, type = "bool"},
        autoplay_next      = {default = true, type = "bool"},
        seek_short         = {default = 10, type = "number"},
        seek_long          = {default = 60, type = "number"},
        volume             = {default = 100, type = "number"},
        volume_max         = {default = 130, type = "number"},
        audio_passthrough  = {default = "", type = "string"},
        hwdec              = {default = "auto", type = "string"},
    },
    display = {
        device           = {default = "auto", type = "enum", values = {"auto", "deck-oled", "deck-lcd", "tv"}},
        quality          = {default = "auto", type = "enum", values = {"auto", "battery", "balanced", "high"}},
        hdr              = {default = "auto", type = "enum", values = {"auto", "off"}},
        refresh_match    = {default = "auto", type = "enum", values = {"auto", "off"}},
        refresh_rates    = {default = "auto", type = "string"},
        refresh_prefer   = {default = "low", type = "enum", values = {"low", "high"}},
        display_resample = {default = false, type = "bool"},
        gpu_context      = {default = "auto", type = "string"}, -- read by the launcher
    },
    interface = {
        ui_scale         = {default = 1.0, type = "number"},
        clean_names      = {default = true, type = "bool"},
        sort             = {default = "name", type = "enum", values = {"name", "date"}},
        overlay_timeout  = {default = 4, type = "number"},
        accent_color     = {default = "1A9FFF", type = "string"},
    },
}

-- Returns sections[section][key] = {values...} (every occurrence kept).
function M.parse_ini(text)
    local sections, section = {}, ""
    sections[section] = {}
    local line_no = 0
    for line in (text .. "\n"):gmatch("([^\n]*)\n") do
        line_no = line_no + 1
        line = util.trim(line:gsub("\r$", ""))
        if line == "" or line:match("^[#;]") then
            -- comment / blank
        elseif line:match("^%[.*%]$") then
            section = util.trim(line:sub(2, -2)):lower()
            sections[section] = sections[section] or {}
        else
            local key, value = line:match("^([^=]+)=(.*)$")
            if key then
                key = util.trim(key):lower():gsub("[%s%-]", "_")
                value = util.trim(value)
                -- Allow optional quotes around values.
                value = value:match('^"(.*)"$') or value:match("^'(.*)'$") or value
                local s = sections[section]
                s[key] = s[key] or {}
                table.insert(s[key], value)
            end
        end
    end
    return sections
end

local TRUE = {["yes"] = true, ["true"] = true, ["on"] = true, ["1"] = true}
local FALSE = {["no"] = true, ["false"] = true, ["off"] = true, ["0"] = true}

local function convert(spec, values, where, warnings)
    local raw = values[#values]
    if spec.type == "list" then
        local out = {}
        for _, v in ipairs(values) do
            -- A single line may also hold several folders separated by ';'.
            for _, piece in ipairs(util.split(v, ";")) do out[#out + 1] = piece end
        end
        return out
    elseif spec.type == "bool" then
        local l = raw:lower()
        if TRUE[l] then return true end
        if FALSE[l] then return false end
    elseif spec.type == "number" then
        local n = tonumber(raw)
        if n then return n end
    elseif spec.type == "enum" then
        local l = raw:lower()
        for _, allowed in ipairs(spec.values) do
            if l == allowed then return l end
        end
    else
        return raw
    end
    table.insert(warnings, string.format("%s: invalid value '%s', using default", where, raw))
    return spec.default
end

function M.defaults()
    local cfg = {}
    for sname, keys in pairs(SCHEMA) do
        cfg[sname] = {}
        for key, spec in pairs(keys) do
            local d = spec.default
            if type(d) == "table" then d = util.shallow_copy(d) end
            cfg[sname][key] = d
        end
    end
    return cfg
end

-- Merge INI text over the defaults. Returns cfg, warnings.
function M.from_text(text)
    local cfg, warnings = M.defaults(), {}
    local sections = M.parse_ini(text or "")
    for sname, keys in pairs(sections) do
        local schema = SCHEMA[sname]
        for key, values in pairs(keys) do
            local spec = schema and schema[key]
            -- "folders" is accepted as an alias of "folder".
            if not spec and sname == "library" and key == "folders" then
                spec, key = schema.folder, "folder"
            end
            if spec then
                cfg[sname][key] = convert(spec, values, sname .. "." .. key, warnings)
            else
                table.insert(warnings, string.format("unknown option [%s] %s", sname, key))
            end
        end
    end
    return cfg, warnings
end

function M.load(path)
    local text = path and path ~= "" and util.read_file(path) or nil
    local cfg, warnings = M.from_text(text)
    cfg.path = path
    cfg.loaded = text ~= nil
    return cfg, warnings
end

return M
