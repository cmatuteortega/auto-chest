-- AutoChest – Relay Server with Authentication & Matchmaking
-- Run with: love server/ (from the auto-chest root directory)
-- Clients connect, authenticate, and join matchmaking queue.
-- Server pairs players based on trophy count and forwards messages between them.

local enet = require("enet")

-- Set up path for database module
package.path = package.path .. ';../?.lua'

local Database = require("server.database")

local PORT    = 12345
local MAX_CONNECTIONS = 16

local host    = nil
local db      = nil
local queue   = {}    -- matchmaking queue: {peer, player_id, username, trophies, queue_time}
local rooms   = {}    -- keyed by tostring(peer): {peer, partner, role, player_id, username, trophies}
local sessions = {}   -- keyed by tostring(peer): {player_id, username, token}
local log     = {}
local logLimit = 18

local logFile = nil

local function pushLog(msg)
    table.insert(log, msg)
    if #log > logLimit then table.remove(log, 1) end
    print(msg)

    -- Also write to file for debugging
    if logFile then
        logFile:write(os.date("%H:%M:%S") .. " - " .. msg .. "\n")
        logFile:flush()
    end
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

-- Matchmaking: find opponent within trophy range
local function findMatch(player)
    local baseTrophyRange = 100
    local waitTime = love.timer.getTime() - player.queue_time
    local expandedRange = baseTrophyRange + math.floor(waitTime / 5) * 50
    local maxRange = 500

    expandedRange = math.min(expandedRange, maxRange)

    for i, opponent in ipairs(queue) do
        if opponent.peer ~= player.peer then
            local trophyDiff = math.abs(player.trophies - opponent.trophies)
            if trophyDiff <= expandedRange then
                -- Found a match!
                table.remove(queue, i)
                return opponent
            end
        end
    end

    return nil
end

-- Try to match all players in queue
local function processMatchmaking()
    local i = 1
    while i <= #queue do
        local player = queue[i]
        local opponent = findMatch(player)

        if opponent then
            -- Remove player from queue
            table.remove(queue, i)

            -- Create room
            local p1, p2 = player, opponent
            rooms[tostring(p1.peer)] = {
                peer = p1.peer,
                partner = p2.peer,
                role = 1,
                player_id = p1.player_id,
                username = p1.username,
                trophies = p1.trophies
            }
            rooms[tostring(p2.peer)] = {
                peer = p2.peer,
                partner = p1.peer,
                role = 2,
                player_id = p2.player_id,
                username = p2.username,
                trophies = p2.trophies
            }

            -- Send match_found to both
            p1.peer:send(encode("match_found", {
                role = 1,
                opponent_name = p2.username,
                opponent_trophies = p2.trophies,
                my_trophies = p1.trophies
            }))
            p2.peer:send(encode("match_found", {
                role = 2,
                opponent_name = p1.username,
                opponent_trophies = p1.trophies,
                my_trophies = p2.trophies
            }))

            pushLog("Match: " .. p1.username .. " (" .. p1.trophies .. ") vs " .. p2.username .. " (" .. p2.trophies .. ")")

            -- Don't increment i, continue from same position
        else
            i = i + 1
        end
    end
end

local function handleConnect(peer)
    pushLog("Client connected: " .. tostring(peer))
end

local function handleMessage(peer, eventName, msgData)
    -- Handle authentication messages
    if eventName == "login" then
        local username = msgData.username
        local password = msgData.password

        local player, err = db:loginPlayer(username, password)

        if player then
            local token = db:createSession(player.id)
            sessions[tostring(peer)] = {
                player_id = player.id,
                username = player.username,
                token = token
            }

            peer:send(encode("login_success", {
                player_id = player.id,
                username = player.username,
                trophies = player.trophies,
                coins = player.coins,
                gold = player.gold,
                gems = player.gems,
                active_deck_index = player.activeDeckIndex,
                decks = player.decks,
                token = token
            }))

            pushLog("Login: " .. username)
        else
            peer:send(encode("login_failed", {reason = err or "Invalid credentials"}))
            pushLog("Failed login: " .. username)
        end

    elseif eventName == "register" then
        local username = msgData.username
        local password = msgData.password

        local player, err = db:registerPlayer(username, password)

        if player then
            peer:send(encode("register_success", {
                player_id = player.id,
                username = player.username
            }))
            pushLog("Registration: " .. username)
        else
            peer:send(encode("register_failed", {reason = err or "Registration failed"}))
            pushLog("Failed registration: " .. username)
        end

    elseif eventName == "queue_join" then
        local session = sessions[tostring(peer)]
        if not session then
            peer:send(encode("error", {reason = "Not authenticated"}))
            return
        end

        -- Get latest player data
        local player = db:getPlayer(session.player_id)
        if not player then
            peer:send(encode("error", {reason = "Player not found"}))
            return
        end

        -- Add to matchmaking queue
        table.insert(queue, {
            peer = peer,
            player_id = player.id,
            username = player.username,
            trophies = player.trophies,
            queue_time = love.timer.getTime()
        })

        peer:send(encode("queue_joined", {}))
        pushLog("Queue join: " .. player.username .. " (" .. player.trophies .. " trophies)")

    elseif eventName == "queue_leave" then
        -- Remove from queue
        for i, entry in ipairs(queue) do
            if entry.peer == peer then
                table.remove(queue, i)
                peer:send(encode("queue_left", {}))
                pushLog("Queue leave: " .. entry.username)
                break
            end
        end

    elseif eventName == "update_deck_slot" then
        local session = sessions[tostring(peer)]
        if not session then
            peer:send(encode("error", {reason = "Not authenticated"}))
            return
        end

        local deckIndex = msgData.deck_index
        local deckData = msgData.deck_data

        if not deckIndex or not deckData then
            peer:send(encode("error", {reason = "Invalid deck update"}))
            return
        end

        local success, err = db:updateDeckSlot(session.player_id, deckIndex, deckData)
        if success then
            peer:send(encode("deck_updated", {deck_index = deckIndex}))
            pushLog("Deck " .. deckIndex .. " updated: " .. session.username)
        else
            peer:send(encode("error", {reason = err or "Failed to update deck"}))
        end

    elseif eventName == "update_active_deck" then
        local session = sessions[tostring(peer)]
        if not session then
            peer:send(encode("error", {reason = "Not authenticated"}))
            return
        end

        local deckIndex = msgData.deck_index

        db:updateActiveDeck(session.player_id, deckIndex)
        peer:send(encode("active_deck_updated", {deck_index = deckIndex}))
        pushLog("Active deck set to " .. tostring(deckIndex) .. ": " .. session.username)

    elseif eventName == "sync_decks" then
        local session = sessions[tostring(peer)]
        if not session then
            peer:send(encode("error", {reason = "Not authenticated"}))
            return
        end

        local activeDeckIndex = msgData.active_deck_index
        local decks = msgData.decks

        if not decks or #decks ~= 5 then
            peer:send(encode("error", {reason = "Invalid deck data"}))
            return
        end

        local success, err = db:updateAllDecks(session.player_id, activeDeckIndex, decks)
        if success then
            peer:send(encode("decks_synced", {}))
            pushLog("All decks synced: " .. session.username)
        else
            peer:send(encode("error", {reason = err or "Failed to sync decks"}))
        end

    elseif eventName == "match_result" then
        local winnerId = msgData.winner_id
        local session = sessions[tostring(peer)]

        if not session then return end

        local room = rooms[tostring(peer)]
        if not room or not room.partner then return end

        local partnerRoom = rooms[tostring(room.partner)]
        if not partnerRoom then return end

        -- Determine winner and loser
        local winnerData, loserData

        if winnerId == room.player_id then
            winnerData = {id = room.player_id, trophies = room.trophies}
            loserData = {id = partnerRoom.player_id, trophies = partnerRoom.trophies}
        else
            winnerData = {id = partnerRoom.player_id, trophies = partnerRoom.trophies}
            loserData = {id = room.player_id, trophies = room.trophies}
        end

        -- Update trophies
        db:updateTrophies(winnerData.id, 20)
        db:updateTrophies(loserData.id, -15)

        -- Award gold: +10 winner, +5 loser
        local winnerNewGold = db:updateGold(winnerData.id, 10)
        local loserNewGold  = db:updateGold(loserData.id, 5)
        local winnerGems    = db:getGems(winnerData.id)
        local loserGems     = db:getGems(loserData.id)

        -- Send currency updates to each player
        local winnerPeer = (winnerId == room.player_id) and room.peer or room.partner
        local loserPeer  = (winnerId == room.player_id) and room.partner or room.peer
        if winnerPeer then winnerPeer:send(encode("currency_update", {gold = winnerNewGold, gems = winnerGems})) end
        if loserPeer  then loserPeer:send(encode("currency_update",  {gold = loserNewGold,  gems = loserGems}))  end

        pushLog("Match result: Winner +10g, Loser +5g")

        -- Clean up rooms so both peers can re-queue immediately
        rooms[tostring(room.partner)] = nil
        rooms[tostring(peer)] = nil

    elseif eventName == "reconnect_with_token" then
        local token = msgData.token
        if not token or not db then
            peer:send(encode("login_failed", {reason = "No token"}))
            return
        end
        local player = db:validateSession(token)
        if player then
            sessions[tostring(peer)] = {
                player_id = player.id,
                username = player.username,
                token = token
            }
            peer:send(encode("login_success", {
                player_id = player.id,
                username = player.username,
                trophies = player.trophies,
                coins = player.coins,
                gold = player.gold,
                gems = player.gems,
                active_deck_index = player.activeDeckIndex,
                decks = player.decks,
                token = token
            }))
            pushLog("Reconnect: " .. player.username)
        else
            peer:send(encode("login_failed", {reason = "Invalid or expired token"}))
        end

    elseif eventName == "shop_purchase" then
        -- Spend gems to buy gold
        local session = sessions[tostring(peer)]
        if not session then
            peer:send(encode("error", {reason = "Not authenticated"}))
            return
        end

        local costs = {gold_1000 = 10, gold_5000 = 50, gold_10000 = 100}
        local gold_amounts = {gold_1000 = 1000, gold_5000 = 5000, gold_10000 = 10000}
        local item = msgData.item
        local gemCost = costs[item]
        local goldGain = gold_amounts[item]

        if not gemCost then
            peer:send(encode("error", {reason = "Unknown item"}))
            return
        end

        local currentGems = db:getGems(session.player_id)
        if currentGems < gemCost then
            peer:send(encode("shop_error", {reason = "Not enough gems"}))
            return
        end

        local newGems = db:addGems(session.player_id, -gemCost)
        local newGold = db:updateGold(session.player_id, goldGain)
        peer:send(encode("currency_update", {gold = newGold, gems = newGems}))
        pushLog("Shop purchase: " .. session.username .. " bought " .. item)

    elseif eventName == "gem_purchase" then
        -- Placeholder: grant gems directly (no real payment)
        local session = sessions[tostring(peer)]
        if not session then
            peer:send(encode("error", {reason = "Not authenticated"}))
            return
        end

        local gem_amounts = {gems_10 = 10, gems_50 = 50, gems_100 = 100}
        local package = msgData.package
        local gemGain = gem_amounts[package]

        if not gemGain then
            peer:send(encode("error", {reason = "Unknown package"}))
            return
        end

        local newGems = db:addGems(session.player_id, gemGain)
        local currentGold = db:updateGold(session.player_id, 0)  -- read current gold
        pushLog("Gem purchase (mock): " .. session.username .. " +" .. gemGain .. " gems -> newGems=" .. tostring(newGems) .. " gold=" .. tostring(currentGold))
        peer:send(encode("currency_update", {gold = currentGold, gems = newGems}))

    elseif eventName == "relay" then
        -- Forward game messages to partner
        local room = rooms[tostring(peer)]
        if room and room.partner then
            -- Re-encode the relay message content
            room.partner:send(encode("relay", msgData))
        end
    end
end

local function handleReceive(peer, data)
    -- Try to decode the message
    if not json then return end

    local ok, decoded = pcall(json.decode, data)
    if ok and type(decoded) == "table" and #decoded == 2 then
        local eventName = decoded[1]
        local msgData = decoded[2] or {}
        handleMessage(peer, eventName, msgData)
    else
        -- Fallback: forward raw data if in a room (backwards compatibility)
        local room = rooms[tostring(peer)]
        if room and room.partner then
            room.partner:send(data)
        end
    end
end

local function handleDisconnect(peer)
    local peerKey = tostring(peer)

    -- Remove from queue
    for i, entry in ipairs(queue) do
        if entry.peer == peer then
            table.remove(queue, i)
            pushLog("Queue player disconnected: " .. entry.username)
            break
        end
    end

    -- Remove from session
    local session = sessions[peerKey]
    if session then
        pushLog("Session closed: " .. session.username)
        sessions[peerKey] = nil
    end

    -- Handle room disconnect
    local room = rooms[peerKey]
    if room then
        -- Notify partner
        if room.partner then
            room.partner:send(encode("opponent_disconnected", {}))
            rooms[tostring(room.partner)] = nil
        end
        rooms[peerKey] = nil
        pushLog("Player disconnected from match (role " .. tostring(room.role) .. ")")
    end
end

-- ── Love2D callbacks ────────────────────────────────────────────────────────

function love.load()
    -- Open log file
    logFile = io.open("server/matchmaking.log", "a")
    if logFile then
        logFile:write("\n========== Server Starting ==========\n")
        logFile:flush()
    end

    -- Initialize database
    db = Database.new("server/players.db")
    pushLog("Database initialized")

    -- Start ENet host
    host = enet.host_create("*:"..PORT, MAX_CONNECTIONS)
    if not host then
        error("Could not start ENet host on port "..PORT)
    end
    pushLog("AutoChest matchmaking server started on port "..PORT)
end

function love.update(dt)
    if not host then return end

    -- Process network events
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

    -- Process matchmaking
    if #queue >= 2 then
        processMatchmaking()
    end
end

function love.draw()
    local lg = love.graphics
    lg.setColor(0.1, 0.1, 0.15)
    lg.rectangle("fill", 0, 0, love.graphics.getWidth(), love.graphics.getHeight())

    lg.setColor(1, 1, 1)
    lg.setFont(love.graphics.newFont(14))
    lg.print("AutoChest Matchmaking Server  –  port "..PORT, 10, 10)

    local connected = 0
    for _ in pairs(rooms) do connected = connected + 1 end
    local queueStr = #queue > 0 and (#queue .. " in queue") or "queue empty"
    lg.print("Active Matches: "..math.floor(connected/2).."  |  "..queueStr, 10, 30)

    lg.setColor(0.7, 0.9, 0.7)
    for i, msg in ipairs(log) do
        lg.print(msg, 10, 50 + (i-1)*12)
    end
end

function love.keypressed(key)
    if key == "escape" then love.event.quit() end
end
