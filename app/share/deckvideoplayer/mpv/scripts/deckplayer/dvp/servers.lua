-- Media servers (Plex, Jellyfin) behind one interface (D55).
--
-- Each backend (dvp/plex.lua, dvp/jellyfin.lua) has an `ID` ("plex",
-- "jellyfin"), a `NAME` for messages, and the same methods: sources(),
-- signed_in(), server(id), list(loc, cb), connect(id, cb), video_info(ref,
-- cb), resolve(id, key, siblings, cb), item_for(path), prepare(item),
-- header_fields(item), report(...), set_watched(...), describe(path),
-- fetch_range(...), forget_session(id), forget_token(id), and the pure
-- recent_key(item) / parse_recent_key(path) / recent_ref(id, key).
-- Library entries refer to their item with `server` (listings) or
-- `server_recent` ("Recently played"); `backend` in that table names the
-- backend.

local M = {}
M.__index = M

-- backends: list of backend instances, in the order sources are shown.
function M.new(backends)
    local self = setmetatable({list = backends, by_id = {}}, M)
    for _, b in ipairs(backends) do self.by_id[b.ID] = b end
    return self
end

function M:get(id)
    return self.by_id[id]
end

-- The backend of an entry's `server` / `server_recent` table (or an item).
function M:for_ref(ref)
    return ref and self.by_id[ref.backend] or nil
end

-- Library sources of every signed-in server, after the local ones.
function M:sources()
    local out = {}
    for _, b in ipairs(self.list) do
        for _, s in ipairs(b:sources()) do out[#out + 1] = s end
    end
    return out
end

-- The media server item playing from `path` (a stream URL), and its
-- backend; nil for local files.
function M:item_for(path)
    if not path then return nil end
    for _, b in ipairs(self.list) do
        local item = b:item_for(path)
        if item then return item, b end
    end
    return nil
end

-- A "Recently played" key (resume.json): backend, server id, item key.
function M:parse_recent_key(path)
    for _, b in ipairs(self.list) do
        local id, key = b.parse_recent_key(path)
        if id then return b, id, key end
    end
    return nil
end

-- The "Recently played" key of an item, or nil.
function M:recent_key(item)
    local b = self:for_ref(item)
    return b and b.recent_key(item) or nil
end

-- Whether a "Recently played" key can still be opened: its server is
-- signed in. Local paths: nil (the caller checks the file).
function M:recent_available(path)
    local b, id = self:parse_recent_key(path)
    if not b then return nil end
    return b:signed_in() and b:server(id) ~= nil
end

return M
