-- Finds black bars encoded into the video (a 4:3 show stored in a 16:9
-- frame, a widescreen film with letterbox bars) from one frame, so the
-- picture can be cropped to its real edges with mpv's video-crop.
--
-- Works on a "screenshot-raw" frame (bgr0, any decoder, hardware included)
-- instead of the cropdetect filter, which needs software decoding.

local M = {}

M.THRESHOLD = 40      -- brightest channel (0-255) still counted as black
M.SAMPLES = 64        -- pixels checked along each line
M.MAX_BAR = 0.4       -- a bar covers at most this much of a side
M.MIN_BAR = 0.01      -- thinner bars are ignored (encoder edge noise)

-- pixel(x, y) -> brightest channel of that pixel (0-255).
-- Returns {x=, y=, w=, h=} of the picture inside the bars, or nil when
-- there are no bars (or the frame is too dark to tell: then the picture
-- found would be implausibly small).
function M.bounds(pixel, w, h)
    local T, N = M.THRESHOLD, M.SAMPLES
    local function row_dark(y)
        for i = 0, N - 1 do
            if pixel(math.floor((i + 0.5) * w / N), y) > T then return false end
        end
        return true
    end
    local function col_dark(x)
        for i = 0, N - 1 do
            if pixel(x, math.floor((i + 0.5) * h / N)) > T then return false end
        end
        return true
    end
    local max_y, max_x = math.floor(h * M.MAX_BAR), math.floor(w * M.MAX_BAR)
    local top, bottom, left, right = 0, 0, 0, 0
    while top < max_y and row_dark(top) do top = top + 1 end
    while bottom < max_y and row_dark(h - 1 - bottom) do bottom = bottom + 1 end
    while left < max_x and col_dark(left) do left = left + 1 end
    while right < max_x and col_dark(w - 1 - right) do right = right + 1 end
    -- Encoded bars come in pairs (letterbox: top and bottom; pillarbox: left
    -- and right), so each pair is cropped by its thinner side: a dark sky
    -- at the top or a shadow on one side is picture, not a bar.
    local v, s = math.min(top, bottom), math.min(left, right)
    -- A pair dark up to the limit is a dark scene, not bars.
    if v >= max_y or s >= max_x then return nil end
    local function bar(n, size)
        if n < size * M.MIN_BAR then return 0 end
        return n - n % 2   -- even values: chroma subsampling
    end
    v, s = bar(v, h), bar(s, w)
    if v + s == 0 then return nil end
    return {x = s, y = v, w = w - 2 * s, h = h - 2 * v}
end

-- Bounds from a screenshot-raw result ({w, h, stride, data} in bgr0).
function M.from_screenshot(shot)
    if not shot or not shot.data or not shot.w or not shot.h then return nil end
    local data, stride = shot.data, shot.stride or shot.w * 4
    local function pixel(x, y)
        local b, g, r = data:byte(y * stride + x * 4 + 1, y * stride + x * 4 + 3)
        return math.max(b or 0, g or 0, r or 0)
    end
    return M.bounds(pixel, shot.w, shot.h)
end

return M
