-- BotManager: virtual opponent for online bot matches.
-- Attached to a GameScreen when the server pairs the player with a bot
-- (match_found carries is_bot = true). It acts as a virtual network peer:
-- it never touches the socket, instead injecting the same relay messages a
-- human client would send (ready / final_board / round_end_ready) directly
-- into game:handleNetworkMessage(). Its units live in a virtual roster
-- during setup and materialize through the final_board snapshot at battle
-- start — exactly how a human opponent's board arrives — so the online
-- round flow, desync handling and round-1 concealment all work unchanged.

local UnitRegistry  = require('src.unit_registry')
local SpellRegistry = require('src.spell_registry')
local DeckManager   = require('src.deck_manager')

local BotManager = {}
BotManager.__index = BotManager

local BOT_ZONE_ROWS = 4     -- P2 zone: canonical rows 1..4 (row 4 = front line)
local MAX_COPIES    = 4
local DECK_MIN_CARDS = 12

-- Placement bands (canonical rows, ordered by preference).
local FRONT_ROWS = {4, 3}
local MID_ROWS   = {3, 2}
local BACK_ROWS  = {2, 1}

-- Units whose role doesn't follow from attack range alone.
local BAND_OVERRIDES = {
    tomb   = "back",   -- structure: keep it safe
    loot   = "back",   -- structure: opponent gets paid if it dies
    effigy = "mid",    -- ward: wants allies within 1 cell, not the front line
}

local function isRangedType(unitType)
    local info = UnitRegistry.getUnitDisplayInfo(unitType)
    return (info.rng or 0) > 0
end

-- All unit types whose cost is within ±1 of `cost` (used for deck swaps).
local function unitsNearCost(cost)
    local pool = {}
    for _, ut in ipairs(UnitRegistry.getAllUnitTypes()) do
        if math.abs((UnitRegistry.unitCosts[ut] or 3) - cost) <= 1 then
            table.insert(pool, ut)
        end
    end
    table.sort(pool)
    return pool
end

-- ── Constructor ──────────────────────────────────────────────────────────────

function BotManager.new(game)
    local self = setmetatable({}, BotManager)
    self.game = game

    self.deckCounts = self:generateDeck()
    self.drawPile   = {}
    for unitType, count in pairs(self.deckCounts) do
        for _ = 1, count do table.insert(self.drawPile, unitType) end
    end

    self.roster     = {}   -- virtual board: {unitType, col, row, level}
    self.hand       = {}
    self.coins      = 6
    self.lastRound  = game.roundNumber
    self.lastWinner = nil

    self:startRound(true)
    return self
end

-- ── Deck generation ──────────────────────────────────────────────────────────

-- Build a deck similar to the player's active deck: mostly the same unit
-- types with the same copy counts (duplicates are kept — the bot uses them
-- to upgrade), while ~30% of types (and all spells) swap to a random unit
-- of similar cost so each bot feels a little different.
function BotManager:generateDeck()
    local counts = {}
    local total  = 0

    local function add(unitType, n)
        local have = counts[unitType] or 0
        n = math.min(n, MAX_COPIES - have)
        if n <= 0 then return end
        counts[unitType] = have + n
        total = total + n
    end

    local playerDeck = DeckManager.getActiveDeck()
    if playerDeck then
        for utype, count in pairs(playerDeck.counts) do
            if count > 0 then
                local cost    = UnitRegistry.unitCosts[utype] or 3
                local botType = utype
                if SpellRegistry.isSpell(utype)
                   or not UnitRegistry.unitClasses[utype]
                   or math.random() < 0.3 then
                    local pool = unitsNearCost(cost)
                    botType = pool[math.random(#pool)]
                end
                add(botType, count)
            end
        end
    end

    -- Pad thin decks by stacking copies of already-picked units first
    -- (favours same-unit copies), falling back to cheap starters.
    local fallback = { "boney", "marrow", "knight", "marc", "mage", "burrow" }
    while total < DECK_MIN_CARDS do
        local stackable = {}
        for ut, c in pairs(counts) do
            if c < MAX_COPIES then table.insert(stackable, ut) end
        end
        table.sort(stackable)
        if #stackable > 0 and math.random() < 0.7 then
            add(stackable[math.random(#stackable)], 1)
        else
            add(fallback[math.random(#fallback)], 1)
        end
    end

    return counts
end

-- ── Round lifecycle ──────────────────────────────────────────────────────────

function BotManager:startRound(isFirst)
    if not isFirst then
        self.coins = self.coins + 6
        if self.lastWinner == 1 then
            self.coins = self.coins + 3   -- consolation coins: bot lost the round
        end
        self.lastWinner = nil
    end
    self.readySent         = false
    self.doneSpending      = false
    self.finalBoardSent    = false
    self.rerolledThisRound = false
    self.actionTimer       = 2.0 + math.random() * 2.0
    self:drawHand()
    if not isFirst then
        self:maybeReposition()
    end
end

function BotManager:shufflePile()
    local pile = self.drawPile
    for i = #pile, 2, -1 do
        local j = math.random(i)
        pile[i], pile[j] = pile[j], pile[i]
    end
end

-- Return any unplayed hand to the pile, reshuffle, draw up to 3.
function BotManager:drawHand()
    for _, t in ipairs(self.hand) do table.insert(self.drawPile, t) end
    self.hand = {}
    self:shufflePile()
    for _ = 1, 3 do
        if #self.drawPile == 0 then break end
        table.insert(self.hand, table.remove(self.drawPile))
    end
end

-- ── Board reading / placement ────────────────────────────────────────────────

-- Column the player's army is centred on (canonical coords; player = owner 1).
function BotManager:playerFocusCol()
    local sum, n = 0, 0
    for _, u in ipairs(self.game.grid:getAllUnits()) do
        if u.owner == 1 and not u.isDead then
            sum = sum + u.col
            n = n + 1
        end
    end
    if n == 0 then return 3 end
    return math.max(1, math.min(5, math.floor(sum / n + 0.5)))
end

function BotManager:isCellFree(col, row)
    for _, e in ipairs(self.roster) do
        if e.col == col and e.row == row then return false end
    end
    return true
end

function BotManager:bandRows(unitType)
    local override = BAND_OVERRIDES[unitType]
    if override == "back" then return BACK_ROWS end
    if override == "mid"  then return MID_ROWS  end
    return isRangedType(unitType) and BACK_ROWS or FRONT_ROWS
end

-- Free cell for unitType: bruisers in the front rows, ranged in the back,
-- columns ordered by distance to where the player's units are massing.
function BotManager:findPlacementCell(unitType)
    local rows   = self:bandRows(unitType)
    local target = self:playerFocusCol()
    if math.random() < 0.5 then
        target = math.max(1, math.min(5, target + math.random(-1, 1)))
    end

    local cols = {1, 2, 3, 4, 5}
    table.sort(cols, function(a, b)
        return math.abs(a - target) < math.abs(b - target)
    end)

    for _, row in ipairs(rows) do
        for _, col in ipairs(cols) do
            if self:isCellFree(col, row) then return col, row end
        end
    end
    -- Preferred band full: any free cell in the zone
    for row = 1, BOT_ZONE_ROWS do
        for col = 1, 5 do
            if self:isCellFree(col, row) then return col, row end
        end
    end
    return nil
end

-- Rounds 2+: sometimes shift the bruiser farthest from the player's focus
-- column back toward it (counter-positioning between rounds).
function BotManager:maybeReposition()
    if #self.roster == 0 or math.random() >= 0.6 then return end
    local target = self:playerFocusCol()

    local pick, worst = nil, 1
    for _, e in ipairs(self.roster) do
        if not BAND_OVERRIDES[e.unitType] and not isRangedType(e.unitType) then
            local d = math.abs(e.col - target)
            if d > worst then pick, worst = e, d end
        end
    end
    if not pick then return end

    local oldCol, oldRow = pick.col, pick.row
    pick.col, pick.row = -1, -1   -- vacate so findPlacementCell sees the cell as free
    local col, row = self:findPlacementCell(pick.unitType)
    if col then
        pick.col, pick.row = col, row
    else
        pick.col, pick.row = oldCol, oldRow
    end
end

-- ── Setup-phase decision making ──────────────────────────────────────────────

-- Highest-level copy below max, so duplicates push one unit toward level 3.
function BotManager:findUpgradeTarget(cardType)
    local best
    for _, e in ipairs(self.roster) do
        if e.unitType == cardType and e.level < 3 and (not best or e.level > best.level) then
            best = e
        end
    end
    return best
end

-- One human-paced action per call. Returns true if something was done.
function BotManager:takeAction()
    -- 1. Upgrade a placed unit with a matching hand card
    for i, cardType in ipairs(self.hand) do
        local cost = UnitRegistry.unitCosts[cardType] or 3
        if self.coins >= cost then
            local entry = self:findUpgradeTarget(cardType)
            if entry then
                self.coins = self.coins - cost
                table.remove(self.hand, i)
                entry.level = entry.level + 1
                return true
            end
        end
    end

    -- 2. Place the most expensive affordable hand card
    local bestIdx, bestCost
    for i, cardType in ipairs(self.hand) do
        local cost = UnitRegistry.unitCosts[cardType] or 3
        if self.coins >= cost and (not bestCost or cost > bestCost) then
            local col = self:findPlacementCell(cardType)
            if col then bestIdx, bestCost = i, cost end
        end
    end
    if bestIdx then
        local cardType = table.remove(self.hand, bestIdx)
        local col, row = self:findPlacementCell(cardType)
        self.coins = self.coins - bestCost
        table.insert(self.roster, { unitType = cardType, col = col, row = row, level = 0 })
        return true
    end

    -- 3. Hand is dead weight but coins remain: reroll once per round
    if not self.rerolledThisRound and #self.hand > 0
       and self.coins >= 3 and #self.drawPile >= 3 then
        self.rerolledThisRound = true
        self.coins = self.coins - 1
        self:drawHand()
        return true
    end

    return false
end

-- ── Virtual peer messages ────────────────────────────────────────────────────

function BotManager:sendReady()
    self.readySent = true
    self.game:handleNetworkMessage({ type = "ready" })
end

-- Authoritative end-of-setup snapshot, mirroring captureFinalBoard() on a
-- human client. activeUpgrades lists sequential tree picks; units with fewer
-- tree entries than levels are topped up by applyOpponentSnapshot().
function BotManager:buildFinalBoard()
    local units = {}
    for _, e in ipairs(self.roster) do
        local info = UnitRegistry.getUnitDisplayInfo(e.unitType)
        local ups  = {}
        for i = 1, math.min(e.level, #(info.upgrades or {})) do
            table.insert(ups, i)
        end
        table.insert(units, {
            unitType       = e.unitType,
            col            = e.col,
            row            = e.row,
            level          = e.level,
            activeUpgrades = ups,
        })
    end
    return { type = "final_board", units = units, spells = {} }
end

-- ── Update (called every frame from GameScreen:update) ──────────────────────

function BotManager:update(dt)
    local game = self.game

    -- resetRound() bumped the round and returned to setup
    if game.roundNumber ~= self.lastRound then
        self.lastRound = game.roundNumber
        self:startRound(false)
    end

    if game.state == "setup" then
        if self.readySent then return end

        -- Timer expired: both sides must auto-ready (mirrors human clients)
        if game.timer <= 0 and not game.isTutorial then
            self:sendReady()
            return
        end

        self.actionTimer = self.actionTimer - dt
        if self.actionTimer <= 0 then
            if self.doneSpending then
                self:sendReady()
            elseif self:takeAction() then
                self.actionTimer = 1.2 + math.random() * 2.0
            else
                -- Nothing left to buy: linger briefly, then ready up
                self.doneSpending = true
                self.actionTimer  = 1.5 + math.random() * 2.5
            end
        end

    elseif game.state == "pre_battle" then
        -- Provide the final_board snapshot the battle start waits on
        if not self.finalBoardSent then
            self.finalBoardSent = true
            game:handleNetworkMessage(self:buildFinalBoard())
        end

    elseif game.state == "battle_ending" then
        -- Round-end handshake: agree with the local simulation's winner
        if game.localRoundEndReady and not game.opponentRoundEndReady then
            self.lastWinner = game.winner
            game:handleNetworkMessage({ type = "round_end_ready", winner = game.winner })
        end
    end
end

return BotManager
