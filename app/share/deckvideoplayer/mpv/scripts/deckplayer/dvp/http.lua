-- HTTP through curl, shared by the network features (OpenSubtitles, Plex).
--
-- curl is part of the Flatpak runtime and of SteamOS. Its configuration
-- (URL, headers, body) is passed on stdin with `-K -`, so tokens and
-- passwords never appear in a process list. Requests are asynchronous by
-- default so the UI never blocks; `request_sync` exists for the few places
-- that must wait (an mpv hook before a file opens) and uses short timeouts.

local utils = require "mp.utils"
local msg = require "mp.msg"
local util = require "dvp.util"

local M = {}

-- A double-quoted string for a curl config file.
function M.curl_quote(s)
    -- NUL would end the value early in curl's config parser: drop it.
    s = tostring(s):gsub("%z", ""):gsub('[\\"]', "\\%0"):gsub("\n", "\\n"):gsub("\r", "\\r"):gsub("\t", "\\t")
    return '"' .. s .. '"'
end

local function urlencode(s)
    return (s:gsub("[^%w%-%._~ ]", function(c) return string.format("%%%02X", c:byte()) end):gsub(" ", "+"))
end

-- Sorted query string (stable output, makes requests and tests predictable).
-- `lower` lowercases values (the OpenSubtitles API wants that).
function M.query_string(params, lower)
    local keys = {}
    for k in pairs(params) do keys[#keys + 1] = k end
    table.sort(keys)
    local parts = {}
    for _, k in ipairs(keys) do
        local v = tostring(params[k])
        if lower then v = v:lower() end
        parts[#parts + 1] = k .. "=" .. urlencode(v)
    end
    return table.concat(parts, "&")
end

-- Pure: the curl config for a request. req: url, method ("GET" default,
-- "POST", "PUT"…), headers {name = value} or list of "Name: value",
-- body (table -> JSON), raw_body + content_type (a text body as is, e.g.
-- SOAP XML for DLNA), output (file path), timeout (s, default 25),
-- follow (bool, follow redirects; default false: curl forwards custom
-- headers such as tokens to the redirect target, even on another host),
-- max_size (bytes, abort larger downloads).
-- Long downloads (dvp/downloads.lua): timeout = 0 (no time limit; a
-- transfer slower than 1 KB/s for a minute is aborted instead), resume
-- (continue `output` where it ends), fail (an HTTP error writes nothing).
-- Only http(s) URLs are fetched, and redirects only to https (D39).
function M.curl_config(req)
    local q = M.curl_quote
    local timeout = req.timeout or 25
    local lines = {
        "silent", "show-error",
        "proto = " .. q("=http,https"),
        "proto-redir = " .. q("=https"),
    }
    if timeout == 0 then
        lines[#lines + 1] = "connect-timeout = 15"
        lines[#lines + 1] = "speed-limit = 1000"
        lines[#lines + 1] = "speed-time = 60"
    else
        lines[#lines + 1] = "max-time = " .. tostring(timeout)
        lines[#lines + 1] = "connect-timeout = " .. tostring(math.min(timeout, 10))
    end
    lines[#lines + 1] = "write-out = " .. q("\n%{http_code}")
    if req.fail then lines[#lines + 1] = "fail" end
    if req.resume then lines[#lines + 1] = "continue-at = " .. q("-") end
    if req.max_size then lines[#lines + 1] = "max-filesize = " .. tostring(req.max_size) end
    local headers = {}
    for k, v in pairs(req.headers or {}) do
        headers[#headers + 1] = type(k) == "number" and v or (k .. ": " .. v)
    end
    table.sort(headers)
    for _, h in ipairs(headers) do lines[#lines + 1] = "header = " .. q(h) end
    if req.method and req.method ~= "GET" then lines[#lines + 1] = "request = " .. q(req.method) end
    if req.body then
        lines[#lines + 1] = "header = " .. q("Content-Type: application/json")
        lines[#lines + 1] = "data-binary = " .. q(utils.format_json(req.body))
    elseif req.raw_body then
        lines[#lines + 1] = "header = " .. q("Content-Type: " .. (req.content_type or "text/plain"))
        lines[#lines + 1] = "data-binary = " .. q(req.raw_body)
    elseif req.follow then
        lines[#lines + 1] = "location"
    end
    if req.output then lines[#lines + 1] = "output = " .. q(req.output) end
    lines[#lines + 1] = "url = " .. q(req.url)
    return table.concat(lines, "\n") .. "\n"
end

-- curl exit codes worth explaining (everything else: "Network error").
M.CURL_ERRORS = {
    [6] = "No internet connection", [7] = "Cannot connect to the server",
    [28] = "The server did not answer (timeout)", [35] = "Secure connection failed",
    [60] = "The server's certificate is not valid", [63] = "The file is too large",
}

-- Pure: turns curl's subprocess result into code, body (see `request`).
function M.parse_result(res, tag)
    if not res or res.status ~= 0 then
        local status = res and res.status
        msg.verbose((tag or "http") .. ": curl failed (" .. tostring(status) .. "): "
            .. util.trim(tostring(res and res.stderr or res and res.error_string or "")))
        return nil, M.CURL_ERRORS[status] or "Network error"
    end
    local out = res.stdout or ""
    local code = tonumber(out:match("(%d%d%d)%s*$"))
    local text = out:gsub("\n?%d%d%d%s*$", "")
    local body = text ~= "" and utils.parse_json(text) or nil
    if body == nil then body = text end
    return code, body
end

-- Runs one request asynchronously. cb(code, body): code is the HTTP status,
-- or nil with body = error text when no response arrived; body is decoded
-- JSON when possible, else the raw text. `req.tag` names the caller in logs.
function M.request(req, cb)
    mp.command_native_async({
        name = "subprocess", args = {"curl", "-K", "-"},
        stdin_data = M.curl_config(req),
        capture_stdout = true, capture_stderr = true, playback_only = false,
    }, function(_, res) cb(M.parse_result(res, req.tag)) end)
end

-- A long download to `req.output` (see curl_config). cb(code, status,
-- killed): the HTTP status (nil if none arrived), curl's exit status, and
-- whether it was stopped with M.abort. Returns the handle for M.abort.
function M.download(req, cb)
    return mp.command_native_async({
        name = "subprocess", args = {"curl", "-K", "-"},
        stdin_data = M.curl_config(req),
        capture_stdout = true, capture_stderr = true, playback_only = false,
    }, function(_, res)
        res = res or {}
        if res.status ~= 0 and res.stderr then
            msg.verbose((req.tag or "http") .. ": curl " .. tostring(res.status) .. ": " .. util.trim(res.stderr))
        end
        local code = tonumber(tostring(res.stdout or ""):match("(%d%d%d)%s*$"))
        cb(code ~= 0 and code or nil, res.status, res.killed_by_us == true)
    end)
end

function M.abort(handle)
    if handle then mp.abort_async_command(handle) end
end

-- Same, blocking. Only for short calls where mpv must wait anyway.
function M.request_sync(req)
    local res = mp.command_native({
        name = "subprocess", args = {"curl", "-K", "-"},
        stdin_data = M.curl_config(req),
        capture_stdout = true, capture_stderr = true, playback_only = false,
    })
    return M.parse_result(res, req.tag)
end

return M
