-- Headless smoke test for src/bot_manager.lua (matchmaking bot opponent).
-- Run from project root: lua tests/test_bot_manager.lua
-- Optionally vary the RNG seed: SEED=<n> lua tests/test_bot_manager.lua

package.path = package.path .. ";./?.lua;./?/init.lua"

-- ── Minimal LÖVE stubs (mirrors tests/test_battle_determinism.lua) ──────────
love = {
    graphics = {
        newImage  = function() return {
            getWidth  = function() return 16 end,
            getHeight = function() return 16 end,
            setFilter = function() end,
        } end,
        newShader  = function() return {} end,
        newQuad    = function() return {} end,
        setShader  = function() end,
        setScissor = function() end,
        setColor   = function() end,
        setLineWidth = function() end,
        draw       = function() end,
        rectangle  = function() end,
        circle     = function() end,
        line       = function() end,
        polygon    = function() end,
        print      = function() end,
        printf     = function() end,
        setFont    = function() end,
        push       = function() end,
        pop        = function() end,
        translate  = function() end,
        scale      = function() end,
        rotate     = function() end,
        getWidth   = function() return 540 end,
        getHeight  = function() return 960 end,
    },
    filesystem = { read = function() end, write = function() end, getInfo = function() return nil end },
    window     = { getMode = function() return 540, 960, {} end },
    math       = { newRandomGenerator = function()
        return { random = math.random, setSeed = math.randomseed }
    end },
    timer      = { getTime = function() return 0 end },
}
Fonts = { tiny = { getWidth = function() return 0 end, getHeight = function() return 0 end } }
AudioManager = {
    playSFX = function() end, playTap = function() end, playMusic = function() end,
    stopMusic = function() end, setBattleMode = function() end,
}

math.randomseed(tonumber(os.getenv("SEED") or "42"))

local Grid          = require('src.grid')
local UnitRegistry  = require('src.unit_registry')
local SpellRegistry = require('src.spell_registry')
local DeckManager   = require('src.deck_manager')
local BotManager    = require('src.bot_manager')

local failures = 0
local function check(name, cond, detail)
    if cond then
        print("PASS [" .. name .. "]")
    else
        failures = failures + 1
        print("FAIL [" .. name .. "] " .. (detail or ""))
    end
end

-- ── Player deck fixture (includes a spell to verify substitution) ───────────
DeckManager.reset()
DeckManager._data.activeDeckIndex = 1
local counts = DeckManager._data.decks[1].counts
for k in pairs(counts) do counts[k] = 0 end
counts.knight = 4; counts.marc = 3; counts.boney = 4
counts.marrow = 3; counts.mage = 2; counts.arrows = 2   -- 18 cards, 1 spell type

-- ── Fake GameScreen ──────────────────────────────────────────────────────────
local received = {}
local game = {
    grid                 = Grid(),
    roundNumber          = 1,
    state                = "setup",
    timer                = 30,
    isTutorial           = false,
    localRoundEndReady   = false,
    opponentRoundEndReady = false,
    winner               = nil,
}
function game:handleNetworkMessage(msg)
    table.insert(received, msg)
    if msg.type == "ready" then self.opponentReady = true end
    if msg.type == "final_board" then self.opponentFinalBoard = msg end
    if msg.type == "round_end_ready" then self.opponentRoundEndReady = true end
end

-- A few player units on the board (owner 1, rows 5-8)
game.grid:placeUnit(2, 7, UnitRegistry.createUnit("knight", 7, 2, 1, {}))
game.grid:placeUnit(2, 8, UnitRegistry.createUnit("marc",   8, 2, 1, {}))

local bot = BotManager.new(game)

-- ── Deck generation ──────────────────────────────────────────────────────────
local total = 0
local hasSpell = false
for ut, c in pairs(bot.deckCounts) do
    total = total + c
    if SpellRegistry.isSpell(ut) then hasSpell = true end
    check("copies_cap_" .. ut, c >= 1 and c <= 4, ut .. "=" .. c)
end
check("deck_size", total >= 12 and total <= 20, "total=" .. total)
check("no_spells_in_bot_deck", not hasSpell)

-- ── Round 1 setup simulation ─────────────────────────────────────────────────
local dt = 1 / 60
local elapsed = 0
while elapsed < 35 and not bot.readySent do
    bot:update(dt)
    elapsed = elapsed + dt
    game.timer = math.max(0, game.timer - dt)
end
check("bot_readies", bot.readySent, "no ready after 35s")
check("ready_msg_received", received[#received] and received[#received].type == "ready")
check("roster_nonempty", #bot.roster > 0, "roster=" .. #bot.roster)
check("coins_nonnegative", bot.coins >= 0, "coins=" .. bot.coins)

local seen = {}
local bandsOk, cellsOk = true, true
for _, e in ipairs(bot.roster) do
    if e.col < 1 or e.col > 5 or e.row < 1 or e.row > 4 then cellsOk = false end
    local key = e.col .. "," .. e.row
    if seen[key] then cellsOk = false end
    seen[key] = true
    local info = UnitRegistry.getUnitDisplayInfo(e.unitType)
    local ranged = (info.rng or 0) > 0
    local override = (e.unitType == "tomb" or e.unitType == "loot" or e.unitType == "effigy")
    if not override then
        if ranged and e.row > 2 then bandsOk = false end
        if not ranged and e.row < 3 then bandsOk = false end
    end
end
check("cells_valid_unique", cellsOk)
check("bands_respected", bandsOk)

-- ── Pre-battle: final_board snapshot ─────────────────────────────────────────
game.state = "pre_battle"
bot:update(dt)
check("final_board_sent", game.opponentFinalBoard ~= nil)
check("final_board_matches_roster",
      game.opponentFinalBoard and #game.opponentFinalBoard.units == #bot.roster)

-- ── Battle end handshake ─────────────────────────────────────────────────────
game.state = "battle_ending"
game.winner = 1
game.localRoundEndReady = true
bot:update(dt)
check("round_end_ready_sent", game.opponentRoundEndReady)

-- ── Round 2: economy + repositioning ─────────────────────────────────────────
local coinsBefore = bot.coins
game.state = "setup"
game.timer = 30
game.roundNumber = 2
game.localRoundEndReady = false
game.opponentRoundEndReady = false
bot:update(dt)
check("round2_income", bot.coins == coinsBefore + 9,   -- +6 round, +3 consolation (bot lost)
      "coins=" .. bot.coins .. " expected=" .. (coinsBefore + 9))
check("round2_flags_reset", not bot.readySent and not bot.finalBoardSent)

local rosterBefore = #bot.roster
elapsed = 0
while elapsed < 35 and not bot.readySent do
    bot:update(dt)
    elapsed = elapsed + dt
    game.timer = math.max(0, game.timer - dt)
end
check("round2_readies", bot.readySent)
local grewOrUpgraded = #bot.roster > rosterBefore
for _, e in ipairs(bot.roster) do
    if e.level > 0 then grewOrUpgraded = true end
end
check("round2_spent_coins", grewOrUpgraded, "roster=" .. #bot.roster .. " before=" .. rosterBefore)

-- ── Timer-expiry failsafe (round 3 with instant 0 timer) ─────────────────────
game.state = "setup"; game.timer = 0; game.roundNumber = 3
bot:update(dt)  -- round transition
bot:update(dt)  -- failsafe ready
check("timer_failsafe_ready", bot.readySent)

print(failures == 0 and "\nAll bot manager tests passed." or ("\n" .. failures .. " FAILURES"))
os.exit(failures == 0 and 0 or 1)
