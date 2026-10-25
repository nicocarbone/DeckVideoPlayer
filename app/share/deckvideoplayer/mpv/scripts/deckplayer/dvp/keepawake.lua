-- Keeps the screen awake while a video plays (D43).
--
-- SteamOS game mode dims and sleeps on Steam's own idle timer, which
-- honours org.freedesktop.ScreenSaver inhibitions but not mpv's own
-- screensaver handling. The inhibition lasts as long as the D-Bus
-- connection that asked for it, so the helper program dvp-keep-awake
-- (helper/) holds it: it runs only while a video plays (not paused) and is
-- killed on pause and stop. What it achieved is shown in the info panel.

local util = require "dvp.util"

local M = {}
M.__index = M

local HELPER = "dvp-keep-awake"

-- Helper command line.
function M.args(status_file)
    return {HELPER, "--status", status_file}
end

-- Parses the helper's status file ("request: …").
function M.parse_status(text)
    local out = {}
    for key, value in (text or ""):gmatch("(%w+): ([^\n]*)") do out[key] = value end
    return out
end

-- data_dir: fallback for the status file when XDG_RUNTIME_DIR is unset
-- (private, unlike /tmp).
function M.new(cfg, data_dir)
    local self = setmetatable({}, M)
    self.enabled = cfg.display.keep_awake
    self.playing = false
    self.job = nil
    local dir = os.getenv("XDG_RUNTIME_DIR")
    if not dir or dir == "" then dir = (data_dir and data_dir ~= "") and data_dir or "/tmp" end
    self.status_file = util.join(dir, "dvp-keep-awake-" .. tostring(mp.get_property("pid") or "0") .. ".status")
    return self
end

function M:start()
    if not self.enabled then return end
    os.remove(self.status_file)
    self.error = nil
    local job
    job = mp.command_native_async({name = "subprocess", args = M.args(self.status_file), playback_only = false},
        function(_, result, err)
            if self.job ~= job then return end   -- killed by stop()
            -- It should run until stop(): any exit means the screen is no
            -- longer kept awake. Exit 1 = request failed (the status file
            -- says why); anything else gets its own message.
            self.job = nil
            local status = result and result.status
            if err or not status or status < 0 then
                self.error = (result and result.error_string ~= "" and result.error_string) or err or "failed"
                if self.error == "init" then self.error = HELPER .. " not found" end
            elseif status ~= 1 then
                self.error = "stopped unexpectedly (exit " .. tostring(status) .. ")"
            end
        end)
    self.job = job
end

function M:stop()
    if self.job then
        local job = self.job
        self.job = nil
        mp.abort_async_command(job)
    end
    os.remove(self.status_file)
end

-- Called whenever playback starts, pauses, resumes or stops.
function M:set_playing(on)
    if on == self.playing then return end
    self.playing = on
    if on then self:start() else self:stop() end
end

-- Info panel rows ({label, value}): none when disabled or paused.
function M:info_lines()
    if not self.enabled or not self.playing then return {} end
    if self.error then return {{"Keep awake", self.error}} end
    local s = M.parse_status(util.read_file(self.status_file))
    return {{"Keep awake", s.request or "starting…"}}
end

return M
