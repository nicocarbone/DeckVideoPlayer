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

function M.init(dispatch)
    for action, keys in pairs(M.KEYS) do
        for i, key in ipairs(keys) do
            mp.add_forced_key_binding(key, "dvp-" .. action .. "-" .. i, function()
                dispatch(action)
            end, {repeatable = REPEATABLE[action] or false})
        end
    end
end

return M
