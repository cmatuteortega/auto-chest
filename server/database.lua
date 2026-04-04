-- Database wrapper for player persistence
-- Uses lsqlite3 for SQLite operations

-- Set up LuaRocks path (works on both Mac and Linux)
-- On Mac with local install
if love.system.getOS() == "OS X" then
    package.path = package.path .. ';/Users/cmatute1/.luarocks/share/lua/5.1/?.lua;/Users/cmatute1/.luarocks/share/lua/5.1/?/init.lua'
    package.cpath = package.cpath .. ';/Users/cmatute1/.luarocks/lib/lua/5.1/?.so'
end
-- On Linux VPS, system-wide luarocks install will work automatically

local sqlite3 = require("lsqlite3complete")
local bcrypt = require("bcrypt")
local json = require("lib.json")  -- Load json once at module level

local Database = {}
Database.__index = Database

-- Initialize database connection
function Database.new(dbPath)
    local self = setmetatable({}, Database)

    -- Open/create database
    self.db = sqlite3.open(dbPath or "server/players.db")

    if not self.db then
        error("Failed to open database")
    end

    -- Create tables if they don't exist
    self:createTables()

    return self
end

-- Create database schema
function Database:createTables()
    local schema = [[
        CREATE TABLE IF NOT EXISTS players (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            username TEXT UNIQUE NOT NULL,
            password_hash TEXT NOT NULL,
            trophies INTEGER DEFAULT 0,
            coins INTEGER DEFAULT 6,
            active_deck_index INTEGER,
            deck1_json TEXT DEFAULT '{"name":"Deck 1","counts":{}}',
            deck2_json TEXT DEFAULT '{"name":"Deck 2","counts":{}}',
            deck3_json TEXT DEFAULT '{"name":"Deck 3","counts":{}}',
            deck4_json TEXT DEFAULT '{"name":"Deck 4","counts":{}}',
            deck5_json TEXT DEFAULT '{"name":"Deck 5","counts":{}}',
            created_at INTEGER DEFAULT (strftime('%s', 'now')),
            last_login INTEGER
        );

        CREATE INDEX IF NOT EXISTS idx_username ON players(username);
    ]]

    local result = self.db:exec(schema)
    if result ~= sqlite3.OK then
        error("Failed to create tables: " .. self.db:errmsg())
    end

    -- Migrations: add gold and gems columns if they don't exist yet
    pcall(function() self.db:exec("ALTER TABLE players ADD COLUMN gold INTEGER DEFAULT 0") end)
    pcall(function() self.db:exec("ALTER TABLE players ADD COLUMN gems INTEGER DEFAULT 0") end)

    -- Sessions table: always drop and recreate with device_id (no backward compat)
    self.db:exec("DROP TABLE IF EXISTS sessions")
    local sessionSchema = [[
        CREATE TABLE sessions (
            token      TEXT PRIMARY KEY,
            player_id  INTEGER NOT NULL,
            device_id  TEXT NOT NULL DEFAULT '',
            created_at INTEGER DEFAULT (strftime('%s', 'now')),
            FOREIGN KEY (player_id) REFERENCES players(id)
        );
        CREATE INDEX IF NOT EXISTS idx_session_player ON sessions(player_id);
    ]]
    self.db:exec(sessionSchema)
end

-- Register a new player
function Database:registerPlayer(username, password)
    -- Check if username already exists
    local stmt = self.db:prepare("SELECT id FROM players WHERE username = ?")
    stmt:bind_values(username)

    if stmt:step() == sqlite3.ROW then
        stmt:finalize()
        return nil, "Username already taken"
    end
    stmt:finalize()

    -- Hash password
    local hash = bcrypt.digest(password, 10) -- 10 rounds

    -- Insert new player with 5 empty deck slots
    local emptyDeck = '{"name":"Deck %d","counts":{}}'
    stmt = self.db:prepare([[
        INSERT INTO players (username, password_hash, trophies, coins, active_deck_index,
                           deck1_json, deck2_json, deck3_json, deck4_json, deck5_json)
        VALUES (?, ?, 0, 6, NULL, ?, ?, ?, ?, ?)
    ]])
    stmt:bind_values(username, hash,
        string.format(emptyDeck, 1),
        string.format(emptyDeck, 2),
        string.format(emptyDeck, 3),
        string.format(emptyDeck, 4),
        string.format(emptyDeck, 5))

    local result = stmt:step()
    stmt:finalize()

    if result ~= sqlite3.DONE then
        return nil, "Failed to create player"
    end

    -- Get the new player ID
    local playerId = self.db:last_insert_rowid()

    return {
        id = playerId,
        username = username,
        trophies = 0,
        coins = 6,
        gold = 0,
        gems = 0,
        activeDeckIndex = nil,
        decks = {
            json.decode(string.format(emptyDeck, 1)),
            json.decode(string.format(emptyDeck, 2)),
            json.decode(string.format(emptyDeck, 3)),
            json.decode(string.format(emptyDeck, 4)),
            json.decode(string.format(emptyDeck, 5))
        }
    }
end

-- Authenticate a player
function Database:loginPlayer(username, password)
    local stmt = self.db:prepare([[
        SELECT id, username, password_hash, trophies, coins, active_deck_index,
               deck1_json, deck2_json, deck3_json, deck4_json, deck5_json,
               gold, gems
        FROM players WHERE username = ?
    ]])
    stmt:bind_values(username)

    if stmt:step() ~= sqlite3.ROW then
        stmt:finalize()
        return nil, "Invalid credentials"
    end

    local playerId = stmt:get_value(0)
    local storedUsername = stmt:get_value(1)
    local passwordHash = stmt:get_value(2)
    local trophies = stmt:get_value(3)
    local coins = stmt:get_value(4)
    local activeDeckIndex = stmt:get_value(5)
    local deck1Json = stmt:get_value(6)
    local deck2Json = stmt:get_value(7)
    local deck3Json = stmt:get_value(8)
    local deck4Json = stmt:get_value(9)
    local deck5Json = stmt:get_value(10)
    local gold = stmt:get_value(11) or 0
    local gems = stmt:get_value(12) or 0
    stmt:finalize()

    -- Verify password
    if not bcrypt.verify(password, passwordHash) then
        return nil, "Invalid credentials"
    end

    -- Update last login
    stmt = self.db:prepare("UPDATE players SET last_login = strftime('%s', 'now') WHERE id = ?")
    stmt:bind_values(playerId)
    stmt:step()
    stmt:finalize()

    -- Parse deck JSONs
    local decks = {
        json.decode(deck1Json) or {name = "Deck 1", counts = {}},
        json.decode(deck2Json) or {name = "Deck 2", counts = {}},
        json.decode(deck3Json) or {name = "Deck 3", counts = {}},
        json.decode(deck4Json) or {name = "Deck 4", counts = {}},
        json.decode(deck5Json) or {name = "Deck 5", counts = {}}
    }

    return {
        id = playerId,
        username = storedUsername,
        trophies = trophies,
        coins = coins,
        gold = gold,
        gems = gems,
        activeDeckIndex = activeDeckIndex,
        decks = decks
    }
end

-- Create session token (device_id binds token to a specific device)
function Database:createSession(playerId, deviceId)
    -- Purge expired sessions for this player (> 30 days)
    self.db:exec(string.format(
        "DELETE FROM sessions WHERE player_id = %d AND created_at < %d",
        playerId, os.time() - 30 * 24 * 3600
    ))

    -- Generate random token
    local chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
    local token = ""
    for i = 1, 32 do
        local rand = math.random(1, #chars)
        token = token .. chars:sub(rand, rand)
    end

    -- Store session with device_id
    local stmt = self.db:prepare("INSERT INTO sessions (token, player_id, device_id) VALUES (?, ?, ?)")
    stmt:bind_values(token, playerId, deviceId or "")
    stmt:step()
    stmt:finalize()

    return token
end

-- Validate session token — also checks device_id match and 30-day expiry
function Database:validateSession(token, deviceId)
    local stmt = self.db:prepare([[
        SELECT s.player_id, s.device_id, s.created_at,
               p.username, p.trophies, p.coins, p.active_deck_index,
               p.deck1_json, p.deck2_json, p.deck3_json, p.deck4_json, p.deck5_json,
               p.gold, p.gems
        FROM sessions s
        JOIN players p ON s.player_id = p.id
        WHERE s.token = ?
    ]])
    stmt:bind_values(token)

    if stmt:step() ~= sqlite3.ROW then
        stmt:finalize()
        return nil
    end

    local playerId      = stmt:get_value(0)
    local storedDevice  = stmt:get_value(1)
    local createdAt     = stmt:get_value(2)
    local username      = stmt:get_value(3)
    local trophies      = stmt:get_value(4)
    local coins         = stmt:get_value(5)
    local activeDeckIndex = stmt:get_value(6)
    local deck1Json     = stmt:get_value(7)
    local deck2Json     = stmt:get_value(8)
    local deck3Json     = stmt:get_value(9)
    local deck4Json     = stmt:get_value(10)
    local deck5Json     = stmt:get_value(11)
    local gold          = stmt:get_value(12) or 0
    local gems          = stmt:get_value(13) or 0
    stmt:finalize()

    -- Reject if device_id doesn't match
    if storedDevice ~= (deviceId or "") then
        return nil
    end

    -- Reject if token is older than 30 days
    if createdAt and (os.time() - createdAt) > 30 * 24 * 3600 then
        return nil
    end

    local decks = {
        json.decode(deck1Json) or {name = "Deck 1", counts = {}},
        json.decode(deck2Json) or {name = "Deck 2", counts = {}},
        json.decode(deck3Json) or {name = "Deck 3", counts = {}},
        json.decode(deck4Json) or {name = "Deck 4", counts = {}},
        json.decode(deck5Json) or {name = "Deck 5", counts = {}}
    }

    return {
        id = playerId,
        username = username,
        trophies = trophies,
        coins = coins,
        gold = gold,
        gems = gems,
        activeDeckIndex = activeDeckIndex,
        decks = decks
    }
end

-- Delete all sessions for a player (called on credential login to invalidate old tokens)
function Database:deletePlayerSessions(playerId)
    local stmt = self.db:prepare("DELETE FROM sessions WHERE player_id = ?")
    stmt:bind_values(playerId)
    stmt:step()
    stmt:finalize()
end

-- Get player by ID
function Database:getPlayer(playerId)
    local stmt = self.db:prepare([[
        SELECT id, username, trophies, coins, active_deck_index,
               deck1_json, deck2_json, deck3_json, deck4_json, deck5_json,
               gold, gems
        FROM players WHERE id = ?
    ]])
    stmt:bind_values(playerId)

    if stmt:step() ~= sqlite3.ROW then
        stmt:finalize()
        return nil
    end

    local id = stmt:get_value(0)
    local username = stmt:get_value(1)
    local trophies = stmt:get_value(2)
    local coins = stmt:get_value(3)
    local activeDeckIndex = stmt:get_value(4)
    local deck1Json = stmt:get_value(5)
    local deck2Json = stmt:get_value(6)
    local deck3Json = stmt:get_value(7)
    local deck4Json = stmt:get_value(8)
    local deck5Json = stmt:get_value(9)
    local gold = stmt:get_value(10) or 0
    local gems = stmt:get_value(11) or 0
    stmt:finalize()

    local decks = {
        json.decode(deck1Json) or {name = "Deck 1", counts = {}},
        json.decode(deck2Json) or {name = "Deck 2", counts = {}},
        json.decode(deck3Json) or {name = "Deck 3", counts = {}},
        json.decode(deck4Json) or {name = "Deck 4", counts = {}},
        json.decode(deck5Json) or {name = "Deck 5", counts = {}}
    }

    return {
        id = id,
        username = username,
        trophies = trophies,
        coins = coins,
        gold = gold,
        gems = gems,
        activeDeckIndex = activeDeckIndex,
        decks = decks
    }
end

-- Update player trophies
function Database:updateTrophies(playerId, delta)
    local stmt = self.db:prepare([[
        UPDATE players
        SET trophies = MAX(0, trophies + ?)
        WHERE id = ?
    ]])
    stmt:bind_values(delta, playerId)
    stmt:step()
    stmt:finalize()

    -- Return new trophy count
    stmt = self.db:prepare("SELECT trophies FROM players WHERE id = ?")
    stmt:bind_values(playerId)

    if stmt:step() == sqlite3.ROW then
        local newTrophies = stmt:get_value(0)
        stmt:finalize()
        return newTrophies
    end

    stmt:finalize()
    return 0
end

-- Add gold to a player (delta can be negative)
function Database:updateGold(playerId, delta)
    local stmt = self.db:prepare([[
        UPDATE players SET gold = MAX(0, gold + ?) WHERE id = ?
    ]])
    stmt:bind_values(delta, playerId)
    stmt:step()
    stmt:finalize()

    stmt = self.db:prepare("SELECT gold FROM players WHERE id = ?")
    stmt:bind_values(playerId)
    local newGold = 0
    if stmt:step() == sqlite3.ROW then newGold = stmt:get_value(0) end
    stmt:finalize()
    return newGold
end

-- Add gems to a player (delta can be negative)
function Database:addGems(playerId, delta)
    local stmt = self.db:prepare([[
        UPDATE players SET gems = MAX(0, gems + ?) WHERE id = ?
    ]])
    stmt:bind_values(delta, playerId)
    stmt:step()
    stmt:finalize()

    stmt = self.db:prepare("SELECT gems FROM players WHERE id = ?")
    stmt:bind_values(playerId)
    local newGems = 0
    if stmt:step() == sqlite3.ROW then newGems = stmt:get_value(0) end
    stmt:finalize()
    return newGems
end

-- Get a player's current gems
function Database:getGems(playerId)
    local stmt = self.db:prepare("SELECT gems FROM players WHERE id = ?")
    stmt:bind_values(playerId)
    local gems = 0
    if stmt:step() == sqlite3.ROW then gems = stmt:get_value(0) end
    stmt:finalize()
    return gems
end

-- Update a specific deck slot (1-5)
function Database:updateDeckSlot(playerId, deckIndex, deckData)
    if deckIndex < 1 or deckIndex > 5 then
        return false, "Invalid deck index"
    end

    local deckJson = json.encode(deckData)
    local columnName = "deck" .. deckIndex .. "_json"

    local stmt = self.db:prepare("UPDATE players SET " .. columnName .. " = ? WHERE id = ?")
    stmt:bind_values(deckJson, playerId)
    stmt:step()
    stmt:finalize()

    return true
end

-- Update active deck index
function Database:updateActiveDeck(playerId, deckIndex)
    local stmt = self.db:prepare("UPDATE players SET active_deck_index = ? WHERE id = ?")
    stmt:bind_values(deckIndex, playerId)
    stmt:step()
    stmt:finalize()

    return true
end

-- Update all deck data at once (for bulk sync)
function Database:updateAllDecks(playerId, activeDeckIndex, decks)
    if #decks ~= 5 then
        return false, "Must provide exactly 5 decks"
    end

    local stmt = self.db:prepare([[
        UPDATE players
        SET active_deck_index = ?,
            deck1_json = ?, deck2_json = ?, deck3_json = ?, deck4_json = ?, deck5_json = ?
        WHERE id = ?
    ]])

    stmt:bind_values(
        activeDeckIndex,
        json.encode(decks[1]),
        json.encode(decks[2]),
        json.encode(decks[3]),
        json.encode(decks[4]),
        json.encode(decks[5]),
        playerId
    )

    stmt:step()
    stmt:finalize()

    return true
end

-- Update player coins
function Database:updateCoins(playerId, coins)
    local stmt = self.db:prepare("UPDATE players SET coins = ? WHERE id = ?")
    stmt:bind_values(coins, playerId)
    stmt:step()
    stmt:finalize()

    return true
end

-- Close database connection
function Database:close()
    if self.db then
        self.db:close()
    end
end

return Database
