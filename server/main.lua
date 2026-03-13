-- AutoChest – Relay Server
-- Run with: love server/ (from the auto-chest root directory)
-- Both game clients connect to this server's IP on PORT.
-- The server pairs them as P1 and P2 and forwards all messages between them.

local enet = require("enet")

local PORT    = 12345
local MAX_CONNECTIONS = 16

local host    = nil
local waiting = nil   -- peer waiting for an opponent
local rooms   = {}    -- keyed by tostring(peer): {peer, partner, role}
local log     = {}
local logLimit = 18

local function pushLog(msg)
    table.insert(log, msg)
    if #log > logLimit then table.remove(log, 1) end
    print(msg)
end

-- Build a sock.lua-compatible JSON packet: ["eventName", data]
-- Requires lib/json.lua to be available when running from the project root.
-- Falls back to a hand-rolled encoder for simple tables if json is not loaded.
local json
local ok, mod = pcall(require, "lib.json")
if ok then json = mod end

local function encode(eventName, data)
    if json then
        return json.encode({eventName, data})
    end
    -- Minimal fallback encoder (numbers, strings, booleans only at top level)
    local function val(v)
        local t = type(v)
        if t == "number"  then return tostring(v) end
        if t == "boolean" then return tostring(v) end
        if t == "string"  then return '"' .. v:gsub('"', '\\"') .. '"' end
        if t == "table" then
            local arr, obj = {}, {}
            for k, vv in pairs(v) do
                if type(k) == "number" then
                    arr[k] = val(vv)
                else
                    table.insert(obj, '"'..k..'":'..val(vv))
                end
            end
            if #arr > 0 then
                return "["..table.concat(arr, ",").."]"
            else
                return "{"..table.concat(obj, ",").."}"
            end
        end
        return "null"
    end
    return "["..val(eventName)..","..val(data).."]"
end

local function handleConnect(peer)
    if waiting == nil then
        waiting = peer
        peer:send(encode("waiting", {role = 1}))
        pushLog("P1 connected ("..tostring(peer).."). Waiting for P2…")
    else
        local p1 = waiting
        local p2 = peer
        waiting  = nil

        rooms[tostring(p1)] = {peer = p1, partner = p2, role = 1}
        rooms[tostring(p2)] = {peer = p2, partner = p1, role = 2}

        p1:send(encode("match_found", {role = 1}))
        p2:send(encode("match_found", {role = 2}))
        pushLog("Match started! P1="..tostring(p1).."  P2="..tostring(p2))
    end
end

local function handleReceive(peer, data)
    local room = rooms[tostring(peer)]
    if room and room.partner then
        -- Forward raw packet to the partner unchanged
        room.partner:send(data)
    end
end

local function handleDisconnect(peer)
    -- Cancel if still waiting
    if waiting == peer then
        waiting = nil
        pushLog("Waiting player disconnected.")
        return
    end

    local room = rooms[tostring(peer)]
    if room then
        -- Notify partner
        if room.partner then
            room.partner:send(encode("opponent_disconnected", {}))
            rooms[tostring(room.partner)] = nil
        end
        rooms[tostring(peer)] = nil
        pushLog("Player disconnected (role "..tostring(room.role)..")")
    end
end

-- ── Love2D callbacks ────────────────────────────────────────────────────────

function love.load()
    host = enet.host_create("*:"..PORT, MAX_CONNECTIONS)
    if not host then
        error("Could not start ENet host on port "..PORT)
    end
    pushLog("AutoChest relay server started on port "..PORT)
end

function love.update()
    if not host then return end
    local event = host:service(0)
    while event do
        if event.type == "connect" then
            handleConnect(event.peer)
        elseif event.type == "receive" then
            handleReceive(event.peer, event.data)
        elseif event.type == "disconnect" then
            handleDisconnect(event.peer)
        end
        event = host:service(0)
    end
end

function love.draw()
    local lg = love.graphics
    lg.setColor(0.1, 0.1, 0.15)
    lg.rectangle("fill", 0, 0, love.graphics.getWidth(), love.graphics.getHeight())

    lg.setColor(1, 1, 1)
    lg.setFont(love.graphics.newFont(14))
    lg.print("AutoChest Relay Server  –  port "..PORT, 10, 10)

    local connected = 0
    for _ in pairs(rooms) do connected = connected + 1 end
    local waitingStr = waiting and "1 waiting" or "none waiting"
    lg.print("Rooms: "..math.floor(connected/2).."  |  "..waitingStr, 10, 30)

    lg.setColor(0.7, 0.9, 0.7)
    for i, msg in ipairs(log) do
        lg.print(msg, 10, 50 + (i-1)*12)
    end
end

function love.keypressed(key)
    if key == "escape" then love.event.quit() end
end
