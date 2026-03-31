-- DeckManager – Persistent deck storage and runtime draw-pile management

local json         = require('lib.json')
local UnitRegistry = require('src.unit_registry')

local DeckManager = {}

local SAVE_FILE = "decks.json"
local MAX_CARDS = 20
local NUM_SLOTS = 5

-- Persistent data (survives screen switches within one session)
DeckManager._data = nil

-- Transient per-game draw pile (reset each match via initDrawPile)
DeckManager._drawPile = {}

-- ── Helpers ────────────────────────────────────────────────────────────────

local function emptyDeck(i)
    local counts = {}
    for _, u in ipairs(UnitRegistry.getAllUnitTypes()) do counts[u] = 0 end
    return { name = "Deck " .. i, counts = counts }
end

-- ── Persistence ───────────────────────────────────────────────────────────

function DeckManager.reset()
    DeckManager._data = { activeDeckIndex = nil, decks = {} }
    for i = 1, NUM_SLOTS do
        DeckManager._data.decks[i] = emptyDeck(i)
    end
end

function DeckManager.save()
    -- If logged in, sync to server
    if _G.PlayerData and _G.GameSocket then
        _G.GameSocket:send("sync_decks", {
            active_deck_index = DeckManager._data.activeDeckIndex,
            decks = DeckManager._data.decks
        })
    end

    -- Always save locally as backup
    local ok, encoded = pcall(json.encode, DeckManager._data)
    if ok then
        love.filesystem.write(SAVE_FILE, encoded)
    end
end

function DeckManager.load()
    -- If logged in, load from server data
    if _G.PlayerData and _G.PlayerData.decks then
        DeckManager._data = {
            activeDeckIndex = _G.PlayerData.activeDeckIndex,
            decks = _G.PlayerData.decks
        }

        -- Ensure all unit type keys exist in each deck (forward-compat)
        for i = 1, NUM_SLOTS do
            if not DeckManager._data.decks[i] then
                DeckManager._data.decks[i] = emptyDeck(i)
            end
            for _, u in ipairs(UnitRegistry.getAllUnitTypes()) do
                if not DeckManager._data.decks[i].counts[u] then
                    DeckManager._data.decks[i].counts[u] = 0
                end
            end
        end
        return
    end

    -- Otherwise, load from local file
    local content = love.filesystem.read(SAVE_FILE)
    if content then
        local ok, data = pcall(json.decode, content)
        if ok and data and data.decks and #data.decks == NUM_SLOTS then
            -- Ensure all unit type keys exist in each deck (forward-compat)
            for i = 1, NUM_SLOTS do
                for _, u in ipairs(UnitRegistry.getAllUnitTypes()) do
                    if not data.decks[i].counts[u] then
                        data.decks[i].counts[u] = 0
                    end
                end
            end
            DeckManager._data = data
            return
        end
    end
    DeckManager.reset()
    DeckManager.save()
end

-- ── Deck queries ──────────────────────────────────────────────────────────

function DeckManager.getDeck(index)
    return DeckManager._data.decks[index]
end

function DeckManager.getActiveDeck()
    local idx = DeckManager._data.activeDeckIndex
    if not idx then return nil end
    return DeckManager._data.decks[idx]
end

function DeckManager.getTotalCount(deckIndex)
    local deck = DeckManager._data.decks[deckIndex]
    local total = 0
    for _, count in pairs(deck.counts) do
        total = total + count
    end
    return total
end

-- ── Deck editing ──────────────────────────────────────────────────────────

-- delta: +1 or -1. Returns true if count changed.
function DeckManager.adjustCount(deckIndex, unitType, delta)
    local deck    = DeckManager._data.decks[deckIndex]
    local current = deck.counts[unitType] or 0
    if delta > 0 and DeckManager.getTotalCount(deckIndex) >= MAX_CARDS then
        return false
    end
    local newCount = math.max(0, current + delta)
    if newCount == current then return false end
    deck.counts[unitType] = newCount
    DeckManager.save()
    return true
end

-- Set deck at deckIndex as the active battle deck.
-- Toggles off if already active. No-op if deck is empty.
function DeckManager.setActive(deckIndex)
    if DeckManager.getTotalCount(deckIndex) == 0 then return end
    if DeckManager._data.activeDeckIndex == deckIndex then
        DeckManager._data.activeDeckIndex = nil
    else
        DeckManager._data.activeDeckIndex = deckIndex
    end
    DeckManager.save()
end

-- ── Draw pile (per-game, transient) ───────────────────────────────────────

-- Build and shuffle the draw pile from the active deck.
-- Returns true if a valid deck was loaded, false for fallback-to-random.
function DeckManager.initDrawPile()
    DeckManager._drawPile = {}
    if not DeckManager._data then DeckManager.reset() end
    local idx = DeckManager._data.activeDeckIndex
    if not idx then return false end
    local deck  = DeckManager._data.decks[idx]
    local total = DeckManager.getTotalCount(idx)
    if total == 0 then return false end

    -- Expand counts into flat array
    for unitType, count in pairs(deck.counts) do
        for _ = 1, count do
            table.insert(DeckManager._drawPile, unitType)
        end
    end

    -- Fisher-Yates shuffle
    local pile = DeckManager._drawPile
    for i = #pile, 2, -1 do
        local j = math.random(i)
        pile[i], pile[j] = pile[j], pile[i]
    end
    return true
end

-- Draw up to n cards from the top of the pile.
-- Returns array of unitType strings (length 0..n).
function DeckManager.drawCards(n)
    local drawn = {}
    for _ = 1, n do
        if #DeckManager._drawPile == 0 then break end
        table.insert(drawn, table.remove(DeckManager._drawPile))
    end
    return drawn
end

-- Return an array of unitType strings back to the pile (no reshuffle).
function DeckManager.returnCards(unitTypes)
    for _, u in ipairs(unitTypes) do
        table.insert(DeckManager._drawPile, u)
    end
end

-- Return currentHand to pile, reshuffle entire pile, draw n new cards.
-- Returns new drawn array.
function DeckManager.reshuffleAndDraw(currentHand, n)
    DeckManager.returnCards(currentHand)
    local pile = DeckManager._drawPile
    for i = #pile, 2, -1 do
        local j = math.random(i)
        pile[i], pile[j] = pile[j], pile[i]
    end
    return DeckManager.drawCards(n)
end

function DeckManager.pileSize()
    return #DeckManager._drawPile
end

return DeckManager
