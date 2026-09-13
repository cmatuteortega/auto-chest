-- lib/iap/transport/filedrop.lua
-- Lua <-> native message transport built on plain files in the LÖVE save
-- directory.
--
-- Why files rather than a localhost socket or a JNI binding:
--   * no extra permissions, no open port other apps could talk to,
--   * identical shape on Android and iOS,
--   * survives the app being backgrounded mid-purchase — the reply is simply
--     still sitting on disk when the game comes back.
--
-- Layout, relative to love.filesystem.getSaveDirectory():
--
--   <dir>/to_native/<seq>.json   message body written by Lua
--   <dir>/to_native/<seq>.rdy    written *after* the body; native waits for it
--   <dir>/to_lua/<seq>.json      message body written by native
--   <dir>/to_lua/<seq>.rdy       written *after* the body; Lua waits for it
--
-- Neither side can rename atomically through love.filesystem, so the .rdy
-- marker is the commit: a reader that sees .rdy knows the body is complete.
-- The reader deletes the marker first, then the body, so a half-consumed
-- message is never re-read.

local PATH = (...):gsub("[^%.]+%.[^%.]+$", "")
local util = require(PATH .. "util")

local FileDrop = {}
FileDrop.__index = FileDrop

local function defaultFs()
    local lf = love and love.filesystem
    return {
        createDirectory   = function(p)    return lf and lf.createDirectory(p) end,
        getDirectoryItems = function(p)    return lf and lf.getDirectoryItems(p) or {} end,
        read              = function(p)    return lf and lf.read(p) end,
        write             = function(p, d) return lf and lf.write(p, d) end,
        remove            = function(p)    return lf and lf.remove(p) end,
        getInfo           = function(p)    return lf and lf.getInfo(p) end,
    }
end

-- opts: { dir, poll, json, fs }
function FileDrop.new(opts)
    opts = opts or {}
    local self = setmetatable({
        dir      = opts.dir  or "iap_bridge",
        poll     = opts.poll or 0.25,
        json     = assert(opts.json, "filedrop: json library required"),
        fs       = opts.fs or defaultFs(),
        timer    = 0,
        seq      = 0,
        -- Session prefix keeps filenames unique across restarts, so a stale
        -- request left on disk can never collide with a fresh one.
        session  = string.format("%d%s", util.wallclock(), util.uid(4)),
    }, FileDrop)

    self.outDir = self.dir .. "/to_native"
    self.inDir  = self.dir .. "/to_lua"

    self.fs.createDirectory(self.dir)
    self.fs.createDirectory(self.outDir)
    self.fs.createDirectory(self.inDir)

    return self
end

function FileDrop:describe()
    local base = (love and love.filesystem and love.filesystem.getSaveDirectory
        and love.filesystem.getSaveDirectory()) or "<save dir>"
    return base .. "/" .. self.dir
end

-- Write one message for the native side. Returns true, or false plus a reason.
function FileDrop:send(msg)
    local ok, encoded = pcall(self.json.encode, msg)
    if not ok then
        return false, "encode failed: " .. tostring(encoded)
    end

    self.seq = self.seq + 1
    local name = string.format("%s-%06d", self.session, self.seq)

    local wrote, err = self.fs.write(self.outDir .. "/" .. name .. ".json", encoded)
    if not wrote then
        return false, "write failed: " .. tostring(err)
    end

    -- Commit marker. If this fails the body is orphaned rather than half-read;
    -- the native side sweeps bodies without markers on startup.
    wrote, err = self.fs.write(self.outDir .. "/" .. name .. ".rdy", "1")
    if not wrote then
        self.fs.remove(self.outDir .. "/" .. name .. ".json")
        return false, "commit failed: " .. tostring(err)
    end

    util.debug("-> native %s", encoded)
    return true
end

-- Drain everything the native side has committed since the last poll.
-- Returns an array of decoded message tables (possibly empty).
function FileDrop:receive(dt)
    self.timer = self.timer + (dt or 0)
    if self.timer < self.poll then return {} end
    self.timer = 0

    local markers = {}
    for _, item in ipairs(self.fs.getDirectoryItems(self.inDir)) do
        local name = item:match("^(.+)%.rdy$")
        if name then markers[#markers + 1] = name end
    end
    if #markers == 0 then return {} end

    -- Filenames are sortable by construction, so messages are delivered in the
    -- order the native side produced them.
    table.sort(markers)

    local out = {}
    for _, name in ipairs(markers) do
        local body = self.fs.read(self.inDir .. "/" .. name .. ".json")

        -- Consume before decoding: a message that cannot be decoded is poison
        -- and must not be retried forever.
        self.fs.remove(self.inDir .. "/" .. name .. ".rdy")
        self.fs.remove(self.inDir .. "/" .. name .. ".json")

        if body then
            local ok, decoded = pcall(self.json.decode, body)
            if ok and type(decoded) == "table" then
                util.debug("<- native %s", body)
                out[#out + 1] = decoded
            else
                util.err("undecodable message from native (%s): %s",
                    tostring(decoded), tostring(body):sub(1, 200))
            end
        else
            util.warn("marker %s had no body", name)
        end
    end

    return out
end

-- Drop anything left over from a previous run of the *game* that the native
-- side never picked up. Replies waiting in to_lua are deliberately kept: those
-- are usually completed purchases we still owe the player.
function FileDrop:sweepStaleRequests()
    local removed = 0
    for _, item in ipairs(self.fs.getDirectoryItems(self.outDir)) do
        self.fs.remove(self.outDir .. "/" .. item)
        removed = removed + 1
    end
    if removed > 0 then
        util.debug("swept %d stale request file(s)", removed)
    end
end

return FileDrop
