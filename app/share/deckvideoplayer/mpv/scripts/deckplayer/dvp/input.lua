-- Maps controller buttons and keyboard keys to abstract actions.
--
-- Every key is bound once (forced, so it wins over anything else) and routed
-- to a single dispatch function; the active screen/menu decides what each
-- action means. Gamepad key names come from mpv's SDL2 gamepad support.

local M = {}

M.KEYS = {
    up       = {"GAMEPAD_DPAD_UP", "GAMEPAD_LEFT_STICK_UP", "UP", "WHEEL_UP"},
    down     = {"GAMEPAD_DPAD_DOWN", "GAMEPAD_LEFT_STICK_DOWN", "DOWN", "WHEEL_DOWN"},
    left     = {"GAMEPAD_DPAD_LEFT", "GAMEPAD_LEFT_STICK_LEFT", "LEFT"},
    right    = {"GAMEPAD_DPAD_RIGHT", "GAMEPAD_LEFT_STICK_RIGHT", "RIGHT"},
    confirm  = {"GAMEPAD_ACTION_DOWN", "ENTER", "KP_ENTER", "SPACE"},
    back     = {"GAMEPAD_ACTION_RIGHT", "BS", "ESC", "MBTN_BACK"},
    x        = {"GAMEPAD_ACTION_LEFT", "x", "s"},
    y        = {"GAMEPAD_ACTION_UP", "y", "a"},
    menu     = {"GAMEPAD_START", "m", "TAB"},
    view     = {"GAMEPAD_BACK", "i", "v"},
    lb       = {"GAMEPAD_LEFT_SHOULDER", "PGUP"},
    rb       = {"GAMEPAD_RIGHT_SHOULDER", "PGDWN"},
    lt       = {"GAMEPAD_LEFT_TRIGGER", "HOME", "PREV"},
    rt       = {"GAMEPAD_RIGHT_TRIGGER", "END", "NEXT"},
    playpause = {"PLAYPAUSE", "PLAY", "PAUSE", "p"},
    stop     = {"STOP"},
    quit     = {"CLOSE_WIN", "POWER", "Q", "Ctrl+q"},
}

-- Actions that fire repeatedly while the button is held.
local REPEATABLE = {
    up = true, down = true, left = true, right = true,
    lb = true, rb = true,   -- not the triggers: holding R2 on "Skip intro"
                            -- must not go on to the next chapter
}

-- Analog triggers (D90): mpv turns them into key presses at a fixed
-- threshold with no hysteresis, so one pull crossing it slowly gives
-- down/up/down… within milliseconds, and so does a touch on a stick while
-- a trigger is held (its "up" ends the trigger's press in mpv). A pull
-- counts only when the trigger's events have been quiet for SETTLE
-- seconds and COOLDOWN seconds after the last pull. It acts at once: no
-- delay on a single pull.
M.ANALOG = {GAMEPAD_LEFT_TRIGGER = true, GAMEPAD_RIGHT_TRIGGER = true}
M.SETTLE, M.COOLDOWN = 0.12, 0.25

-- Pure: whether a trigger's key event ("down", "up", "repeat", "press")
-- at `now` (seconds) is a new pull. `st` keeps the time of the trigger's
-- last event and of its last pull.
function M.trigger_pull(st, event, now)
    local quiet = st.last == nil or now - st.last >= M.SETTLE
    st.last = now
    if event ~= "down" and event ~= "press" then return false end
    if not quiet or (st.pull and now - st.pull < M.COOLDOWN) then return false end
    st.pull = now
    return true
end

function M.init(dispatch)
    for action, keys in pairs(M.KEYS) do
        for i, key in ipairs(keys) do
            local name = "dvp-" .. action .. "-" .. i
            if M.ANALOG[key] then
                local st = {}
                mp.add_forced_key_binding(key, name, function(e)
                    if M.trigger_pull(st, e.event, mp.get_time()) then dispatch(action) end
                end, {complex = true})
            else
                mp.add_forced_key_binding(key, name, function()
                    dispatch(action)
                end, {repeatable = REPEATABLE[action] or false})
            end
        end
    end
end

return M
