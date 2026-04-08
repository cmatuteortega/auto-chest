-- tests/test_battle_determinism.lua
-- Run with: lua tests/test_battle_determinism.lua  (from project root)
--
-- Tests 1-8  (original): Knight / Boney / Samurai — single-battle, multi-round,
--   repositioned units, Vengeance reset, timing, concurrent attacks, Fury, drift.
--
-- Tests 9-22 (new): one test group per previously-uncovered unit; each group has:
--   Tier A — resetCombatState() field verification (unit-specific fields)
--   Tier B — single-battle determinism (run same board twice, outcomes must agree)
--   Tier C — multi-round: original objects reset vs. fresh objects recreated
--
-- Test 23 (new): 5-round match with all unit types represented.
--
-- Any FAIL lines indicate a real determinism bug; fixes are applied in this repo
-- and reported in the test run output above the final summary.

-- ── Package path ─────────────────────────────────────────────────────────────
package.path = package.path .. ";./?.lua;./?/init.lua"

-- ── Minimal LÖVE stubs ───────────────────────────────────────────────────────
---@diagnostic disable-next-line: lowercase-global
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
    filesystem = { read = function() end },
    window     = { getMode = function() return 540, 960, {} end },
    math       = { newRandomGenerator = function()
        return { random = math.random, setSeed = math.randomseed }
    end },
    timer      = { getTime = function() return 0 end },
}
Fonts = { tiny = {
    getWidth  = function() return 0 end,
    getHeight = function() return 0 end,
} }

-- ── Load modules ─────────────────────────────────────────────────────────────
local Grid     = require('src.grid')
local Knight   = require('src.units.knight')
local Boney    = require('src.units.boney')
local Samurai  = require('src.units.samurai')
local Amalgam  = require('src.units.amalgam')
local Bonk     = require('src.units.bonk')
local Bull     = require('src.units.bull')
local Burrow   = require('src.units.burrow')
local Catapult = require('src.units.catapult')
local Clavicula= require('src.units.clavicula')
local Humerus  = require('src.units.humerus')
local Mage     = require('src.units.mage')
local Marc     = require('src.units.marc')
local Marrow   = require('src.units.marrow')
local Mend     = require('src.units.mend')
local Migraine = require('src.units.migraine')
local Sinner   = require('src.units.sinner')
local Tomb     = require('src.units.tomb')

-- Basic sprite stub (all melee / most ranged units)
local STUB_SPRITES = { front = {}, back = {}, dead = {} }
-- Extended sprite stub for units needing extra sprite fields
local STUB_SPRITES_EXT = {
    front    = {}, back = {}, dead = {},
    freeForm = { front = {}, back = {}, dead = {} },  -- Sinner form-change sprites
    directions = {},                                    -- Marc directional sprites
}

local FIXED_DT  = 1 / 60
local MAX_STEPS = 60 * 120

-- ── Helpers ───────────────────────────────────────────────────────────────────

local function runBattle(grid)
    for step = 1, MAX_STEPS do
        local allUnits = grid:getAllUnits()
        for _, unit in ipairs(allUnits) do
            unit:update(FIXED_DT, grid)
        end
        local p1, p2 = 0, 0
        for _, unit in ipairs(allUnits) do
            if not unit.isDead then
                if unit.owner == 1 then p1 = p1 + 1 else p2 = p2 + 1 end
            end
        end
        if p1 == 0 or p2 == 0 then
            return (p1 > 0 and 1 or 2), step, allUnits
        end
    end
    return 0, MAX_STEPS, grid:getAllUnits()
end

local function healthSnapshot(allUnits)
    local entries = {}
    for _, u in ipairs(allUnits) do
        table.insert(entries, string.format("%d:%s:%d", u.owner, u.unitType, u.health))
    end
    table.sort(entries)
    return table.concat(entries, "|")
end

-- Reset all units and re-place at home positions (mirrors resetRound logic)
local function resetBoard(grid, unitList)
    for row = 1, grid.rows do
        for col = 1, grid.cols do
            local cell = grid.cells[row][col]
            cell.unit = nil; cell.occupied = false; cell.reserved = false
        end
    end
    for _, unit in ipairs(unitList) do
        unit:resetCombatState()
        unit.col = unit.homeCol
        unit.row = unit.homeRow
        grid:placeUnit(unit.homeCol, unit.homeRow, unit)
    end
end

local function makeUnit(UClass, row, col, owner, level, sprites)
    local u = UClass(row, col, owner, sprites or STUB_SPRITES)
    for i = 1, (level or 0) do u:upgrade(i) end
    u.homeRow = row; u.homeCol = col
    return u
end

-- Run two identical boards and verify they agree: returns wA, sA, uA, wB, sB, uB
local function runPair(gridA, gridB, seed)
    math.randomseed(seed)
    for _, u in ipairs(gridA:getAllUnits()) do u:onBattleStart(gridA) end
    math.randomseed(seed)
    for _, u in ipairs(gridB:getAllUnits()) do u:onBattleStart(gridB) end
    math.randomseed(seed); local wA, sA, uA = runBattle(gridA)
    math.randomseed(seed); local wB, sB, uB = runBattle(gridB)
    return wA, sA, uA, wB, sB, uB
end

-- Build two grids from unit lists and run them as a pair
local function buildAndRunPair(unitsA, unitsB, seed)
    local gA, gB = Grid(), Grid()
    for _, u in ipairs(unitsA) do gA:placeUnit(u.col, u.row, u) end
    for _, u in ipairs(unitsB) do gB:placeUnit(u.col, u.row, u) end
    return runPair(gA, gB, seed)
end

-- ── Test assertions ───────────────────────────────────────────────────────────

local passed = true
local totalFails = 0

local function check(label, a, b)
    if a ~= b then
        io.write(string.format("FAIL [%s]\n  A: %s\n  B: %s\n", label, tostring(a), tostring(b)))
        passed = false
        totalFails = totalFails + 1
    else
        io.write(string.format("PASS [%s]: %s\n", label, tostring(a)))
    end
end

-- ════════════════════════════════════════════════════════════════════════════
-- TEST 1 — Original: two independent single-battle simulations must agree
-- ════════════════════════════════════════════════════════════════════════════
print("── Test 1: single-battle determinism ──────────────────────────────────")

local function buildBoard1()
    local grid = Grid()
    local units = {
        Knight(8, 3, 1, STUB_SPRITES),
        Boney(7,  2, 1, STUB_SPRITES),
        Knight(1, 3, 2, STUB_SPRITES),
        Boney(2,  4, 2, STUB_SPRITES),
    }
    for _, u in ipairs(units) do grid:placeUnit(u.col, u.row, u) end
    for _, u in ipairs(grid:getAllUnits()) do u:onBattleStart(grid) end
    return grid
end

math.randomseed(42); local gA = buildBoard1()
math.randomseed(42); local gB = buildBoard1()
local wA, sA, uA = runBattle(gA)
local wB, sB, uB = runBattle(gB)
check("t1_winner",   wA, wB)
check("t1_steps",    sA, sB)
check("t1_health",   healthSnapshot(uA), healthSnapshot(uB))

-- ════════════════════════════════════════════════════════════════════════════
-- TEST 2 — Multi-round: reset + second battle must agree
-- ════════════════════════════════════════════════════════════════════════════
print("── Test 2: multi-round (no reposition) ────────────────────────────────")

local function makeUnit_old(UClass, row, col, owner, level)
    local u = UClass(row, col, owner, STUB_SPRITES)
    for i = 1, level do u:upgrade(i) end
    u.homeRow = row; u.homeCol = col
    return u
end

local unitsR1_A = {
    makeUnit_old(Knight,  8, 3, 1, 2),
    makeUnit_old(Boney,   7, 2, 1, 1),
    makeUnit_old(Samurai, 6, 1, 1, 2),
    makeUnit_old(Knight,  1, 3, 2, 0),
    makeUnit_old(Boney,   2, 4, 2, 0),
}
local unitsR1_B = {
    makeUnit_old(Knight,  8, 3, 1, 2),
    makeUnit_old(Boney,   7, 2, 1, 1),
    makeUnit_old(Samurai, 6, 1, 1, 2),
    makeUnit_old(Knight,  1, 3, 2, 0),
    makeUnit_old(Boney,   2, 4, 2, 0),
}
local gridA2, gridB2 = Grid(), Grid()
for _, u in ipairs(unitsR1_A) do gridA2:placeUnit(u.col, u.row, u) end
for _, u in ipairs(unitsR1_B) do gridB2:placeUnit(u.col, u.row, u) end
math.randomseed(7)
for _, u in ipairs(gridA2:getAllUnits()) do u:onBattleStart(gridA2) end
math.randomseed(7)
for _, u in ipairs(gridB2:getAllUnits()) do u:onBattleStart(gridB2) end

for _, u in ipairs(unitsR1_A) do u.homeCol = u.col; u.homeRow = u.row end
for _, u in ipairs(unitsR1_B) do u.homeCol = u.col; u.homeRow = u.row end

math.randomseed(7); runBattle(gridA2)
math.randomseed(7); runBattle(gridB2)

resetBoard(gridA2, unitsR1_A)

local gridB2r2 = Grid()
local freshB2 = {
    makeUnit_old(Knight,  8, 3, 1, 2),
    makeUnit_old(Boney,   7, 2, 1, 1),
    makeUnit_old(Samurai, 6, 1, 1, 2),
    makeUnit_old(Knight,  1, 3, 2, 0),
    makeUnit_old(Boney,   2, 4, 2, 0),
}
for _, u in ipairs(freshB2) do gridB2r2:placeUnit(u.col, u.row, u) end

math.randomseed(13)
for _, u in ipairs(gridA2:getAllUnits()) do u:onBattleStart(gridA2) end
math.randomseed(13)
for _, u in ipairs(gridB2r2:getAllUnits()) do u:onBattleStart(gridB2r2) end

math.randomseed(13); local wA2, sA2, uA2 = runBattle(gridA2)
math.randomseed(13); local wB2, sB2, uB2 = runBattle(gridB2r2)
check("t2_winner",   wA2, wB2)
check("t2_steps",    sA2, sB2)
check("t2_health",   healthSnapshot(uA2), healthSnapshot(uB2))

-- ════════════════════════════════════════════════════════════════════════════
-- TEST 3 — Repositioned upgraded unit (Mend + Guardian desync vector)
-- ════════════════════════════════════════════════════════════════════════════
print("── Test 3: repositioned upgraded unit (Mend + Guardian desync vector) ─")

local knightA      = makeUnit_old(Knight, 8, 3, 1, 3)
local boney1A      = makeUnit_old(Boney,  7, 2, 1, 1)
local enemy1A      = makeUnit_old(Knight, 1, 3, 2, 0)
local enemy2A      = makeUnit_old(Boney,  2, 4, 2, 0)
local r1unitsA     = {knightA, boney1A, enemy1A, enemy2A}

local gridA3 = Grid()
for _, u in ipairs(r1unitsA) do
    u.homeCol = u.col; u.homeRow = u.row
    gridA3:placeUnit(u.col, u.row, u)
end
math.randomseed(99)
for _, u in ipairs(gridA3:getAllUnits()) do u:onBattleStart(gridA3) end
math.randomseed(99)
runBattle(gridA3)

resetBoard(gridA3, r1unitsA)

local newRow, newCol = 8, 2
gridA3.cells[knightA.row][knightA.col].unit     = nil
gridA3.cells[knightA.row][knightA.col].occupied = false
knightA.col = newCol; knightA.row = newRow
knightA.homeCol = newCol; knightA.homeRow = newRow
gridA3:placeUnit(newCol, newRow, knightA)

local gridB3r2 = Grid()
local freshUnitsB = {
    makeUnit_old(Knight, newRow,      newCol,      1, 3),
    makeUnit_old(Boney,  boney1A.row, boney1A.col, 1, 1),
    makeUnit_old(Knight, enemy1A.row, enemy1A.col, 2, 0),
    makeUnit_old(Boney,  enemy2A.row, enemy2A.col, 2, 0),
}
for _, u in ipairs(freshUnitsB) do gridB3r2:placeUnit(u.col, u.row, u) end

math.randomseed(55)
for _, u in ipairs(gridA3:getAllUnits())    do u:onBattleStart(gridA3)    end
math.randomseed(55)
for _, u in ipairs(gridB3r2:getAllUnits()) do u:onBattleStart(gridB3r2) end

math.randomseed(55); local wA3, sA3, uA3 = runBattle(gridA3)
math.randomseed(55); local wB3, sB3, uB3 = runBattle(gridB3r2)
check("t3_winner",   wA3, wB3)
check("t3_steps",    sA3, sB3)
check("t3_health",   healthSnapshot(uA3), healthSnapshot(uB3))

-- ════════════════════════════════════════════════════════════════════════════
-- TEST 4 — Samurai Vengeance: damageFromAlliedDeaths resets between rounds
-- ════════════════════════════════════════════════════════════════════════════
print("── Test 4: Samurai Vengeance reset ─────────────────────────────────────")

local samA = makeUnit_old(Samurai, 8, 1, 1, 2)
samA.homeCol = samA.col; samA.homeRow = samA.row

samA.damageFromAlliedDeaths = 3
samA.allyDeathsObserved = { [{}] = true, [{}] = true, [{}] = true }

samA:resetCombatState()
check("t4_samurai_damage_reset",   samA.damageFromAlliedDeaths, 0)
check("t4_samurai_observed_reset", next(samA.allyDeathsObserved) == nil and "empty" or "not_empty", "empty")

-- ════════════════════════════════════════════════════════════════════════════
-- TEST 5 — Exact damage timing: fires at tick pendingAttackDelay, not before
-- ════════════════════════════════════════════════════════════════════════════
print("── Test 5: exact damage timing (integer tick countdown) ────────────────")

local function buildTimingBoard()
    local g = Grid()
    local attacker = Knight(5, 3, 1, STUB_SPRITES)
    local target   = Knight(4, 3, 2, STUB_SPRITES)
    g:placeUnit(attacker.col, attacker.row, attacker)
    g:placeUnit(target.col,   target.row,   target)
    attacker:onBattleStart(g)
    target:onBattleStart(g)
    return g, attacker, target
end

local gT5a, att5a, tgt5a = buildTimingBoard()
local gT5b, att5b, tgt5b = buildTimingBoard()

-- Some units (e.g. Knight) play a battle-start action animation before the first
-- attack, so we advance both boards in lockstep until pendingAttackDelay is set.
local units5a = gT5a:getAllUnits()
local units5b = gT5b:getAllUnits()
for _ = 1, 200 do
    for _, u in ipairs(units5a) do u:update(FIXED_DT, gT5a) end
    for _, u in ipairs(units5b) do u:update(FIXED_DT, gT5b) end
    if att5a.pendingAttackDelay > 0 then break end
end

-- pendingAttackDelay is now set; read remaining ticks until damage fires.
-- Decrement happens on the NEXT tick, so current value == full remaining delay.
local delay5 = att5a.pendingAttackDelay
local hpBefore5a = tgt5a.health
local hpBefore5b = tgt5b.health

for _ = 1, delay5 - 1 do
    for _, u in ipairs(units5a) do u:update(FIXED_DT, gT5a) end
    for _, u in ipairs(units5b) do u:update(FIXED_DT, gT5b) end
end
check("t5_no_damage_before_delay", tgt5a.health, hpBefore5a)
check("t5_both_boards_agree_pre",  tgt5a.health, tgt5b.health)

for _, u in ipairs(units5a) do u:update(FIXED_DT, gT5a) end
for _, u in ipairs(units5b) do u:update(FIXED_DT, gT5b) end
check("t5_damage_fires_at_delay",  tgt5a.health < hpBefore5a, true)
check("t5_both_boards_agree_post", tgt5a.health, tgt5b.health)

-- ════════════════════════════════════════════════════════════════════════════
-- TEST 6 — Concurrent melee attacks on the same target
-- ════════════════════════════════════════════════════════════════════════════
print("── Test 6: concurrent melee attacks on same target ─────────────────────")

local function buildConcurrentBoard()
    local g = Grid()
    local k1    = Knight(5, 2, 1, STUB_SPRITES)
    local k2    = Knight(5, 4, 1, STUB_SPRITES)
    local enemy = Knight(4, 3, 2, STUB_SPRITES)
    g:placeUnit(k1.col, k1.row, k1)
    g:placeUnit(k2.col, k2.row, k2)
    g:placeUnit(enemy.col, enemy.row, enemy)
    k1:onBattleStart(g); k2:onBattleStart(g); enemy:onBattleStart(g)
    return g
end

math.randomseed(200); local gC1 = buildConcurrentBoard()
math.randomseed(200); local gC2 = buildConcurrentBoard()
local wC1, sC1, uC1 = runBattle(gC1)
local wC2, sC2, uC2 = runBattle(gC2)
check("t6_winner",  wC1, wC2)
check("t6_steps",   sC1, sC2)
check("t6_health",  healthSnapshot(uC1), healthSnapshot(uC2))

-- ════════════════════════════════════════════════════════════════════════════
-- TEST 7 — Boney Fury (attackSpeed changes mid-battle)
-- ════════════════════════════════════════════════════════════════════════════
print("── Test 7: Boney Fury attackSpeed change determinism ───────────────────")

local function buildFuryBoard()
    local g = Grid()
    local furyBoney   = makeUnit_old(Boney,  5, 3, 1, 2)
    local toughKnight = makeUnit_old(Knight, 4, 3, 2, 1)
    furyBoney.homeCol  = furyBoney.col;  furyBoney.homeRow  = furyBoney.row
    toughKnight.homeCol = toughKnight.col; toughKnight.homeRow = toughKnight.row
    g:placeUnit(furyBoney.col,   furyBoney.row,   furyBoney)
    g:placeUnit(toughKnight.col, toughKnight.row, toughKnight)
    furyBoney:onBattleStart(g)
    toughKnight:onBattleStart(g)
    return g
end

math.randomseed(301); local gF1 = buildFuryBoard()
math.randomseed(301); local gF2 = buildFuryBoard()
local wF1, sF1, uF1 = runBattle(gF1)
local wF2, sF2, uF2 = runBattle(gF2)
check("t7_fury_winner",  wF1, wF2)
check("t7_fury_steps",   sF1, sF2)
check("t7_fury_health",  healthSnapshot(uF1), healthSnapshot(uF2))

-- ════════════════════════════════════════════════════════════════════════════
-- TEST 8 — 5-round accumulated drift detection
-- ════════════════════════════════════════════════════════════════════════════
print("── Test 8: 5-round accumulated drift detection ─────────────────────────")

local function makeRound8Units_A()
    return {
        makeUnit_old(Knight,  8, 2, 1, 2),
        makeUnit_old(Boney,   7, 4, 1, 2),
        makeUnit_old(Samurai, 6, 1, 1, 1),
        makeUnit_old(Knight,  1, 2, 2, 1),
        makeUnit_old(Boney,   2, 4, 2, 1),
        makeUnit_old(Samurai, 3, 3, 2, 0),
    }
end
local function makeRound8Units_B() return makeRound8Units_A() end

local gridA8 = Grid()
local gridB8 = Grid()
local unitsA8 = makeRound8Units_A()
local unitsB8 = makeRound8Units_B()

for _, u in ipairs(unitsA8) do
    u.homeCol = u.col; u.homeRow = u.row
    gridA8:placeUnit(u.col, u.row, u)
end
for _, u in ipairs(unitsB8) do
    u.homeCol = u.col; u.homeRow = u.row
    gridB8:placeUnit(u.col, u.row, u)
end

for round = 1, 5 do
    local seed8 = 400 + round * 17

    math.randomseed(seed8)
    for _, u in ipairs(gridA8:getAllUnits()) do u:onBattleStart(gridA8) end
    math.randomseed(seed8)
    for _, u in ipairs(gridB8:getAllUnits()) do u:onBattleStart(gridB8) end

    math.randomseed(seed8); local wA8, sA8, uA8 = runBattle(gridA8)
    math.randomseed(seed8); local wB8, sB8, uB8 = runBattle(gridB8)

    local rStr = "t8_r" .. round
    check(rStr .. "_winner", wA8, wB8)
    check(rStr .. "_steps",  sA8, sB8)
    check(rStr .. "_health", healthSnapshot(uA8), healthSnapshot(uB8))

    if round < 5 then
        resetBoard(gridA8, unitsA8)

        gridB8 = Grid()
        unitsB8 = makeRound8Units_B()
        for _, u in ipairs(unitsB8) do
            u.homeCol = u.col; u.homeRow = u.row
            gridB8:placeUnit(u.col, u.row, u)
        end
    end
end

-- ════════════════════════════════════════════════════════════════════════════
-- TEST 9 — Amalgam (Unholy Resilience + Corpse Explosion)
-- ════════════════════════════════════════════════════════════════════════════
print("── Test 9: Amalgam (revival mechanic) ──────────────────────────────────")

-- Tier A: reset clears invulnerability state
do
    local am = makeUnit(Amalgam, 5, 3, 1, 2)
    am.invulnTimer            = 0.6
    am.invulnCooldown         = 5.2
    am.corpseExplosionPending = true
    am:resetCombatState()
    check("t9A_invulnTimer",            am.invulnTimer,            0)
    check("t9A_invulnCooldown",         am.invulnCooldown,         0)
    check("t9A_corpseExplosionPending", am.corpseExplosionPending, false)
end

-- Tier B: single-battle determinism (Amalgam vs two attackers to stress passive)
do
    local function makeAmalgamBoard()
        local units = {
            makeUnit(Amalgam, 5, 3, 1, 2),   -- Bone Armor + Corpse Explosion
            makeUnit(Boney,   3, 2, 2, 1),
            makeUnit(Boney,   3, 4, 2, 1),
        }
        return units
    end
    local wA, sA, uA, wB, sB, uB = buildAndRunPair(makeAmalgamBoard(), makeAmalgamBoard(), 901)
    check("t9B_winner", wA, wB)
    check("t9B_steps",  sA, sB)
    check("t9B_health", healthSnapshot(uA), healthSnapshot(uB))
end

-- Tier C: multi-round (original objects reset vs fresh objects)
do
    local unitsA = {
        makeUnit(Amalgam, 5, 3, 1, 2),
        makeUnit(Boney,   3, 2, 2, 1),
        makeUnit(Boney,   3, 4, 2, 1),
    }
    local gA, gB = Grid(), Grid()
    for _, u in ipairs(unitsA) do gA:placeUnit(u.col, u.row, u) end

    local unitsB_r1 = {
        makeUnit(Amalgam, 5, 3, 1, 2),
        makeUnit(Boney,   3, 2, 2, 1),
        makeUnit(Boney,   3, 4, 2, 1),
    }
    for _, u in ipairs(unitsB_r1) do gB:placeUnit(u.col, u.row, u) end

    -- Round 1
    math.randomseed(902)
    for _, u in ipairs(gA:getAllUnits()) do u:onBattleStart(gA) end
    math.randomseed(902)
    for _, u in ipairs(gB:getAllUnits()) do u:onBattleStart(gB) end
    math.randomseed(902); runBattle(gA)
    math.randomseed(902); runBattle(gB)

    -- Round 2 setup
    resetBoard(gA, unitsA)
    gB = Grid()
    local unitsB_r2 = {
        makeUnit(Amalgam, 5, 3, 1, 2),
        makeUnit(Boney,   3, 2, 2, 1),
        makeUnit(Boney,   3, 4, 2, 1),
    }
    for _, u in ipairs(unitsB_r2) do gB:placeUnit(u.col, u.row, u) end

    math.randomseed(903)
    for _, u in ipairs(gA:getAllUnits()) do u:onBattleStart(gA) end
    math.randomseed(903)
    for _, u in ipairs(gB:getAllUnits()) do u:onBattleStart(gB) end
    math.randomseed(903); local wA, sA, uA = runBattle(gA)
    math.randomseed(903); local wB, sB, uB = runBattle(gB)
    check("t9C_winner", wA, wB)
    check("t9C_steps",  sA, sB)
    check("t9C_health", healthSnapshot(uA), healthSnapshot(uB))
end

-- ════════════════════════════════════════════════════════════════════════════
-- TEST 10 — Bonk (Power Strike hit counter)
-- ════════════════════════════════════════════════════════════════════════════
print("── Test 10: Bonk (Power Strike hit counter) ─────────────────────────────")

-- Tier A: hitCount resets
do
    local b = makeUnit(Bonk, 5, 3, 1, 0)
    b.hitCount = 7
    b:resetCombatState()
    check("t10A_hitCount", b.hitCount, 0)
end

-- Tier B
do
    local function makeBonkBoard()
        return {
            makeUnit(Bonk,   5, 3, 1, 2),   -- Brute Force + Cleave
            makeUnit(Knight, 3, 2, 2, 0),
            makeUnit(Knight, 3, 4, 2, 0),
        }
    end
    local wA, sA, uA, wB, sB, uB = buildAndRunPair(makeBonkBoard(), makeBonkBoard(), 1001)
    check("t10B_winner", wA, wB)
    check("t10B_steps",  sA, sB)
    check("t10B_health", healthSnapshot(uA), healthSnapshot(uB))
end

-- Tier C
do
    local unitsA = {
        makeUnit(Bonk,   5, 3, 1, 1),
        makeUnit(Knight, 3, 2, 2, 0),
        makeUnit(Knight, 3, 4, 2, 0),
    }
    local gA = Grid()
    for _, u in ipairs(unitsA) do gA:placeUnit(u.col, u.row, u) end

    local function freshBonkUnits()
        return {
            makeUnit(Bonk,   5, 3, 1, 1),
            makeUnit(Knight, 3, 2, 2, 0),
            makeUnit(Knight, 3, 4, 2, 0),
        }
    end
    local gB = Grid()
    for _, u in ipairs(freshBonkUnits()) do gB:placeUnit(u.col, u.row, u) end

    math.randomseed(1002)
    for _, u in ipairs(gA:getAllUnits()) do u:onBattleStart(gA) end
    math.randomseed(1002)
    for _, u in ipairs(gB:getAllUnits()) do u:onBattleStart(gB) end
    math.randomseed(1002); runBattle(gA)
    math.randomseed(1002); runBattle(gB)

    resetBoard(gA, unitsA)
    gB = Grid()
    for _, u in ipairs(freshBonkUnits()) do gB:placeUnit(u.col, u.row, u) end

    math.randomseed(1003)
    for _, u in ipairs(gA:getAllUnits()) do u:onBattleStart(gA) end
    math.randomseed(1003)
    for _, u in ipairs(gB:getAllUnits()) do u:onBattleStart(gB) end
    math.randomseed(1003); local wA, sA, uA = runBattle(gA)
    math.randomseed(1003); local wB, sB, uB = runBattle(gB)
    check("t10C_winner", wA, wB)
    check("t10C_steps",  sA, sB)
    check("t10C_health", healthSnapshot(uA), healthSnapshot(uB))
end

-- ════════════════════════════════════════════════════════════════════════════
-- TEST 11 — Clavicula (Whirlwind counter + War Spoils kill bonus)
-- ════════════════════════════════════════════════════════════════════════════
print("── Test 11: Clavicula (Whirlwind + War Spoils) ──────────────────────────")

-- Tier A
do
    local c = makeUnit(Clavicula, 5, 3, 1, 2)
    c.hitCounter      = 9
    c.killDamageBonus = 3
    c.spinFlag        = true
    c:resetCombatState()
    check("t11A_hitCounter",      c.hitCounter,      0)
    check("t11A_killDamageBonus", c.killDamageBonus, 0)
    check("t11A_spinFlag",        c.spinFlag,        false)
end

-- Tier B
do
    local function makeClavBoard()
        return {
            makeUnit(Clavicula, 5, 3, 1, 2),
            makeUnit(Knight,    3, 2, 2, 0),
            makeUnit(Knight,    3, 4, 2, 0),
        }
    end
    local wA, sA, uA, wB, sB, uB = buildAndRunPair(makeClavBoard(), makeClavBoard(), 1101)
    check("t11B_winner", wA, wB)
    check("t11B_steps",  sA, sB)
    check("t11B_health", healthSnapshot(uA), healthSnapshot(uB))
end

-- Tier C
do
    local unitsA = {
        makeUnit(Clavicula, 5, 3, 1, 2),
        makeUnit(Knight,    3, 2, 2, 0),
        makeUnit(Knight,    3, 4, 2, 0),
    }
    local gA = Grid()
    for _, u in ipairs(unitsA) do gA:placeUnit(u.col, u.row, u) end

    local function freshClavUnits()
        return {
            makeUnit(Clavicula, 5, 3, 1, 2),
            makeUnit(Knight,    3, 2, 2, 0),
            makeUnit(Knight,    3, 4, 2, 0),
        }
    end
    local gB = Grid()
    for _, u in ipairs(freshClavUnits()) do gB:placeUnit(u.col, u.row, u) end

    math.randomseed(1102)
    for _, u in ipairs(gA:getAllUnits()) do u:onBattleStart(gA) end
    math.randomseed(1102)
    for _, u in ipairs(gB:getAllUnits()) do u:onBattleStart(gB) end
    math.randomseed(1102); runBattle(gA)
    math.randomseed(1102); runBattle(gB)

    resetBoard(gA, unitsA)
    gB = Grid()
    for _, u in ipairs(freshClavUnits()) do gB:placeUnit(u.col, u.row, u) end

    math.randomseed(1103)
    for _, u in ipairs(gA:getAllUnits()) do u:onBattleStart(gA) end
    math.randomseed(1103)
    for _, u in ipairs(gB:getAllUnits()) do u:onBattleStart(gB) end
    math.randomseed(1103); local wA, sA, uA = runBattle(gA)
    math.randomseed(1103); local wB, sB, uB = runBattle(gB)
    check("t11C_winner", wA, wB)
    check("t11C_steps",  sA, sB)
    check("t11C_health", healthSnapshot(uA), healthSnapshot(uB))
end

-- ════════════════════════════════════════════════════════════════════════════
-- TEST 12 — Humerus (Cleave + Royal Command)
-- ════════════════════════════════════════════════════════════════════════════
print("── Test 12: Humerus (Cleave + Royal Command) ────────────────────────────")

-- Tier A
do
    local h = makeUnit(Humerus, 5, 3, 1, 2)
    h.hitCounter          = 4
    h.royalCommandCleared = true
    h:resetCombatState()
    check("t12A_hitCounter",          h.hitCounter,          0)
    check("t12A_royalCommandCleared", h.royalCommandCleared, false)
end

-- Tier B
do
    local function makeHumerusBoard()
        return {
            makeUnit(Humerus, 5, 3, 1, 2),
            makeUnit(Boney,   3, 2, 2, 0),
            makeUnit(Boney,   3, 4, 2, 0),
        }
    end
    local wA, sA, uA, wB, sB, uB = buildAndRunPair(makeHumerusBoard(), makeHumerusBoard(), 1201)
    check("t12B_winner", wA, wB)
    check("t12B_steps",  sA, sB)
    check("t12B_health", healthSnapshot(uA), healthSnapshot(uB))
end

-- Tier C
do
    local unitsA = {
        makeUnit(Humerus, 5, 3, 1, 2),
        makeUnit(Boney,   3, 2, 2, 0),
        makeUnit(Boney,   3, 4, 2, 0),
    }
    local gA = Grid()
    for _, u in ipairs(unitsA) do gA:placeUnit(u.col, u.row, u) end

    local function freshHumerusUnits()
        return {
            makeUnit(Humerus, 5, 3, 1, 2),
            makeUnit(Boney,   3, 2, 2, 0),
            makeUnit(Boney,   3, 4, 2, 0),
        }
    end
    local gB = Grid()
    for _, u in ipairs(freshHumerusUnits()) do gB:placeUnit(u.col, u.row, u) end

    math.randomseed(1202)
    for _, u in ipairs(gA:getAllUnits()) do u:onBattleStart(gA) end
    math.randomseed(1202)
    for _, u in ipairs(gB:getAllUnits()) do u:onBattleStart(gB) end
    math.randomseed(1202); runBattle(gA)
    math.randomseed(1202); runBattle(gB)

    resetBoard(gA, unitsA)
    gB = Grid()
    for _, u in ipairs(freshHumerusUnits()) do gB:placeUnit(u.col, u.row, u) end

    math.randomseed(1203)
    for _, u in ipairs(gA:getAllUnits()) do u:onBattleStart(gA) end
    math.randomseed(1203)
    for _, u in ipairs(gB:getAllUnits()) do u:onBattleStart(gB) end
    math.randomseed(1203); local wA, sA, uA = runBattle(gA)
    math.randomseed(1203); local wB, sB, uB = runBattle(gB)
    check("t12C_winner", wA, wB)
    check("t12C_steps",  sA, sB)
    check("t12C_health", healthSnapshot(uA), healthSnapshot(uB))
end

-- ════════════════════════════════════════════════════════════════════════════
-- TEST 13 — Mage (Fireball + Arcane Surge)
-- KEY: if Arcane Surge is active when a round ends, attackSpeed must be
-- restored in resetCombatState() — otherwise round 2 starts with wrong speed.
-- ════════════════════════════════════════════════════════════════════════════
print("── Test 13: Mage (Fireball + Arcane Surge attackSpeed reset) ────────────")

-- Tier A: all mage-specific fields are cleared, including attackSpeed
do
    local m = makeUnit(Mage, 5, 3, 1, 2)
    m.hitCounter    = 7
    m.fireballReady = true
    m.fireball      = {}
    m.firePatches   = {{}}
    m.arcaneTimer   = 2.5
    m.arcaneActive  = true
    m.preArcaneSpeed = 0.55
    m.attackSpeed    = 0.825  -- boosted by Arcane Surge
    m:resetCombatState()
    check("t13A_hitCounter",    m.hitCounter,    0)
    check("t13A_fireballReady", m.fireballReady, false)
    check("t13A_fireball",      m.fireball,      nil)
    check("t13A_firePatches",   #m.firePatches,  0)
    check("t13A_arcaneTimer",   m.arcaneTimer,   0)
    check("t13A_arcaneActive",  m.arcaneActive,  false)
    check("t13A_preArcaneSpeed",m.preArcaneSpeed,nil)
    -- CRITICAL: attackSpeed must be restored to base value
    check("t13A_attackSpeed",   m.attackSpeed,   m.baseAttackSpeed)
end

-- Tier B: single-battle determinism with Arcane Surge triggering
do
    local function makeMageBoard()
        return {
            makeUnit(Mage,   5, 3, 1, 2),   -- Burning Ground + Arcane Surge
            makeUnit(Knight, 2, 2, 2, 0),
            makeUnit(Knight, 2, 4, 2, 0),
        }
    end
    local wA, sA, uA, wB, sB, uB = buildAndRunPair(makeMageBoard(), makeMageBoard(), 1301)
    check("t13B_winner", wA, wB)
    check("t13B_steps",  sA, sB)
    check("t13B_health", healthSnapshot(uA), healthSnapshot(uB))
end

-- Tier C: multi-round — original Mage (reset) vs fresh Mage (recreated).
-- If resetCombatState does NOT restore attackSpeed, the Arcane-Surge-boosted
-- speed will carry over and board A will disagree with board B in round 2.
do
    local unitsA = {
        makeUnit(Mage,   5, 3, 1, 2),
        makeUnit(Knight, 2, 2, 2, 0),
        makeUnit(Knight, 2, 4, 2, 0),
    }
    local gA = Grid()
    for _, u in ipairs(unitsA) do gA:placeUnit(u.col, u.row, u) end

    local function freshMageUnits()
        return {
            makeUnit(Mage,   5, 3, 1, 2),
            makeUnit(Knight, 2, 2, 2, 0),
            makeUnit(Knight, 2, 4, 2, 0),
        }
    end
    local gB = Grid()
    for _, u in ipairs(freshMageUnits()) do gB:placeUnit(u.col, u.row, u) end

    math.randomseed(1302)
    for _, u in ipairs(gA:getAllUnits()) do u:onBattleStart(gA) end
    math.randomseed(1302)
    for _, u in ipairs(gB:getAllUnits()) do u:onBattleStart(gB) end
    math.randomseed(1302); runBattle(gA)
    math.randomseed(1302); runBattle(gB)

    resetBoard(gA, unitsA)
    gB = Grid()
    for _, u in ipairs(freshMageUnits()) do gB:placeUnit(u.col, u.row, u) end

    math.randomseed(1303)
    for _, u in ipairs(gA:getAllUnits()) do u:onBattleStart(gA) end
    math.randomseed(1303)
    for _, u in ipairs(gB:getAllUnits()) do u:onBattleStart(gB) end
    math.randomseed(1303); local wA, sA, uA = runBattle(gA)
    math.randomseed(1303); local wB, sB, uB = runBattle(gB)
    check("t13C_winner", wA, wB)
    check("t13C_steps",  sA, sB)
    check("t13C_health", healthSnapshot(uA), healthSnapshot(uB))
end

-- ════════════════════════════════════════════════════════════════════════════
-- TEST 14 — Marc (Sniper Focus + Piercing Arrow)
-- ════════════════════════════════════════════════════════════════════════════
print("── Test 14: Marc (Sniper Focus + Piercing Arrow) ────────────────────────")

-- Tier A
do
    local m = makeUnit(Marc, 8, 3, 1, 2)
    m.attackCount   = 5
    m.currentTarget = {}
    m:resetCombatState()
    check("t14A_attackCount",   m.attackCount,   0)
    check("t14A_currentTarget", m.currentTarget, nil)
end

-- Tier B: two Knights at different distances — sniper targets furthest
do
    local function makeMarcBoard()
        return {
            makeUnit(Marc,   8, 3, 1, 2),   -- Headshot + Piercing Arrow, range 6
            makeUnit(Knight, 4, 3, 2, 0),   -- distance 4
            makeUnit(Knight, 2, 3, 2, 0),   -- distance 6 (furthest, should be targeted)
        }
    end
    local wA, sA, uA, wB, sB, uB = buildAndRunPair(makeMarcBoard(), makeMarcBoard(), 1401)
    check("t14B_winner", wA, wB)
    check("t14B_steps",  sA, sB)
    check("t14B_health", healthSnapshot(uA), healthSnapshot(uB))
end

-- Tier C
do
    local unitsA = {
        makeUnit(Marc,   8, 3, 1, 2),
        makeUnit(Knight, 4, 3, 2, 0),
        makeUnit(Knight, 2, 3, 2, 0),
    }
    local gA = Grid()
    for _, u in ipairs(unitsA) do gA:placeUnit(u.col, u.row, u) end

    local function freshMarcUnits()
        return {
            makeUnit(Marc,   8, 3, 1, 2),
            makeUnit(Knight, 4, 3, 2, 0),
            makeUnit(Knight, 2, 3, 2, 0),
        }
    end
    local gB = Grid()
    for _, u in ipairs(freshMarcUnits()) do gB:placeUnit(u.col, u.row, u) end

    math.randomseed(1402)
    for _, u in ipairs(gA:getAllUnits()) do u:onBattleStart(gA) end
    math.randomseed(1402)
    for _, u in ipairs(gB:getAllUnits()) do u:onBattleStart(gB) end
    math.randomseed(1402); runBattle(gA)
    math.randomseed(1402); runBattle(gB)

    resetBoard(gA, unitsA)
    gB = Grid()
    for _, u in ipairs(freshMarcUnits()) do gB:placeUnit(u.col, u.row, u) end

    math.randomseed(1403)
    for _, u in ipairs(gA:getAllUnits()) do u:onBattleStart(gA) end
    math.randomseed(1403)
    for _, u in ipairs(gB:getAllUnits()) do u:onBattleStart(gB) end
    math.randomseed(1403); local wA, sA, uA = runBattle(gA)
    math.randomseed(1403); local wB, sB, uB = runBattle(gB)
    check("t14C_winner", wA, wB)
    check("t14C_steps",  sA, sB)
    check("t14C_health", healthSnapshot(uA), healthSnapshot(uB))
end

-- ════════════════════════════════════════════════════════════════════════════
-- TEST 15 — Mend (ally healing + speed buff)
-- ════════════════════════════════════════════════════════════════════════════
print("── Test 15: Mend (ally healing + speed buff revert) ─────────────────────")

-- Tier A: healBuffs reverts ally speed, then clears
do
    local m = makeUnit(Mend, 6, 3, 1, 0)
    local fakeAlly = { isDead = false, attackSpeed = 1.5, unitType = "knight" }
    m.hitCounter = 4
    m.healPending = true
    m.healBuffs = { { unit = fakeAlly, timer = 1, baseSpeed = 1.0 } }
    m:resetCombatState()
    check("t15A_hitCounter",   m.hitCounter,         0)
    check("t15A_healPending",  m.healPending,        false)
    check("t15A_healBuffs",    #m.healBuffs,         0)
    check("t15A_allySpeedReverted", fakeAlly.attackSpeed, 1.0)
end

-- Tier B: Mend + 2 allies vs 2 enemies
do
    local function makeMendBoard()
        return {
            makeUnit(Mend,   7, 3, 1, 1),   -- hitCounter heal + speed buff
            makeUnit(Knight, 6, 2, 1, 0),
            makeUnit(Knight, 6, 4, 1, 0),
            makeUnit(Knight, 2, 2, 2, 0),
            makeUnit(Knight, 2, 4, 2, 0),
        }
    end
    local wA, sA, uA, wB, sB, uB = buildAndRunPair(makeMendBoard(), makeMendBoard(), 1501)
    check("t15B_winner", wA, wB)
    check("t15B_steps",  sA, sB)
    check("t15B_health", healthSnapshot(uA), healthSnapshot(uB))
end

-- Tier C
do
    local unitsA = {
        makeUnit(Mend,   7, 3, 1, 1),
        makeUnit(Knight, 6, 2, 1, 0),
        makeUnit(Knight, 6, 4, 1, 0),
        makeUnit(Knight, 2, 2, 2, 0),
        makeUnit(Knight, 2, 4, 2, 0),
    }
    local gA = Grid()
    for _, u in ipairs(unitsA) do gA:placeUnit(u.col, u.row, u) end

    local function freshMendUnits()
        return {
            makeUnit(Mend,   7, 3, 1, 1),
            makeUnit(Knight, 6, 2, 1, 0),
            makeUnit(Knight, 6, 4, 1, 0),
            makeUnit(Knight, 2, 2, 2, 0),
            makeUnit(Knight, 2, 4, 2, 0),
        }
    end
    local gB = Grid()
    for _, u in ipairs(freshMendUnits()) do gB:placeUnit(u.col, u.row, u) end

    math.randomseed(1502)
    for _, u in ipairs(gA:getAllUnits()) do u:onBattleStart(gA) end
    math.randomseed(1502)
    for _, u in ipairs(gB:getAllUnits()) do u:onBattleStart(gB) end
    math.randomseed(1502); runBattle(gA)
    math.randomseed(1502); runBattle(gB)

    resetBoard(gA, unitsA)
    gB = Grid()
    for _, u in ipairs(freshMendUnits()) do gB:placeUnit(u.col, u.row, u) end

    math.randomseed(1503)
    for _, u in ipairs(gA:getAllUnits()) do u:onBattleStart(gA) end
    math.randomseed(1503)
    for _, u in ipairs(gB:getAllUnits()) do u:onBattleStart(gB) end
    math.randomseed(1503); local wA, sA, uA = runBattle(gA)
    math.randomseed(1503); local wB, sB, uB = runBattle(gB)
    check("t15C_winner", wA, wB)
    check("t15C_steps",  sA, sB)
    check("t15C_health", healthSnapshot(uA), healthSnapshot(uB))
end

-- ════════════════════════════════════════════════════════════════════════════
-- TEST 16 — Migraine (stun + explosion counter)
-- ════════════════════════════════════════════════════════════════════════════
print("── Test 16: Migraine (stun + explosion counter) ─────────────────────────")

-- Tier A
do
    local mg = makeUnit(Migraine, 5, 3, 1, 1)
    mg.hitCounter       = 7
    mg.mitosisFlag      = true
    mg.soulDrainPending = true
    mg.soulDrainAmount  = 3
    mg.explosionPending = true
    mg.explosionFlash   = {}
    mg.firePatches      = {{}}
    mg:resetCombatState()
    check("t16A_hitCounter",       mg.hitCounter,       0)
    check("t16A_mitosisFlag",      mg.mitosisFlag,      false)
    check("t16A_soulDrainPending", mg.soulDrainPending, false)
    check("t16A_soulDrainAmount",  mg.soulDrainAmount,  0)
    check("t16A_explosionPending", mg.explosionPending, false)
    check("t16A_explosionFlash",   mg.explosionFlash,   nil)
    check("t16A_firePatches",      #mg.firePatches,     0)
end

-- Tier B
do
    local function makeMigraineBoard()
        return {
            makeUnit(Migraine, 5, 3, 1, 1),
            makeUnit(Knight,   3, 2, 2, 0),
            makeUnit(Knight,   3, 4, 2, 0),
        }
    end
    local wA, sA, uA, wB, sB, uB = buildAndRunPair(makeMigraineBoard(), makeMigraineBoard(), 1601)
    check("t16B_winner", wA, wB)
    check("t16B_steps",  sA, sB)
    check("t16B_health", healthSnapshot(uA), healthSnapshot(uB))
end

-- Tier C
do
    local unitsA = {
        makeUnit(Migraine, 5, 3, 1, 1),
        makeUnit(Knight,   3, 2, 2, 0),
        makeUnit(Knight,   3, 4, 2, 0),
    }
    local gA = Grid()
    for _, u in ipairs(unitsA) do gA:placeUnit(u.col, u.row, u) end

    local function freshMigraineUnits()
        return {
            makeUnit(Migraine, 5, 3, 1, 1),
            makeUnit(Knight,   3, 2, 2, 0),
            makeUnit(Knight,   3, 4, 2, 0),
        }
    end
    local gB = Grid()
    for _, u in ipairs(freshMigraineUnits()) do gB:placeUnit(u.col, u.row, u) end

    math.randomseed(1602)
    for _, u in ipairs(gA:getAllUnits()) do u:onBattleStart(gA) end
    math.randomseed(1602)
    for _, u in ipairs(gB:getAllUnits()) do u:onBattleStart(gB) end
    math.randomseed(1602); runBattle(gA)
    math.randomseed(1602); runBattle(gB)

    resetBoard(gA, unitsA)
    gB = Grid()
    for _, u in ipairs(freshMigraineUnits()) do gB:placeUnit(u.col, u.row, u) end

    math.randomseed(1603)
    for _, u in ipairs(gA:getAllUnits()) do u:onBattleStart(gA) end
    math.randomseed(1603)
    for _, u in ipairs(gB:getAllUnits()) do u:onBattleStart(gB) end
    math.randomseed(1603); local wA, sA, uA = runBattle(gA)
    math.randomseed(1603); local wB, sB, uB = runBattle(gB)
    check("t16C_winner", wA, wB)
    check("t16C_steps",  sA, sB)
    check("t16C_health", healthSnapshot(uA), healthSnapshot(uB))
end

-- ════════════════════════════════════════════════════════════════════════════
-- TEST 17 — Sinner (form change: hitCounter, isFree, attackSpeed, sprites)
-- ════════════════════════════════════════════════════════════════════════════
print("── Test 17: Sinner (form change reset) ──────────────────────────────────")

-- Tier A
do
    local s = makeUnit(Sinner, 5, 3, 1, 1, STUB_SPRITES_EXT)
    s.hitCounter        = 14
    s.isFree            = true
    s.formChangePending = true
    s.burstFlash        = {}
    s.attackSpeed       = 1.3   -- free-form speed
    -- Simulate that form change happened and sprites were swapped
    s.sprites           = s.freeSprites or {}
    s:resetCombatState()
    check("t17A_hitCounter",        s.hitCounter,        0)
    check("t17A_isFree",            s.isFree,            false)
    check("t17A_formChangePending", s.formChangePending, false)
    check("t17A_burstFlash",        s.burstFlash,        nil)
    check("t17A_attackSpeed",       s.attackSpeed,       s.baseAttackSpeed)
    check("t17A_sprites",           s.sprites,           s.chainedSprites)
end

-- Tier B: Sinner (level 1 = Early Release, 10-hit trigger) vs 3 Boneys
do
    local function makeSinnerBoard()
        return {
            makeUnit(Sinner, 5, 3, 1, 1, STUB_SPRITES_EXT),
            makeUnit(Boney,  3, 2, 2, 0),
            makeUnit(Boney,  3, 3, 2, 0),
            makeUnit(Boney,  3, 4, 2, 0),
        }
    end
    local wA, sA, uA, wB, sB, uB = buildAndRunPair(makeSinnerBoard(), makeSinnerBoard(), 1701)
    check("t17B_winner", wA, wB)
    check("t17B_steps",  sA, sB)
    check("t17B_health", healthSnapshot(uA), healthSnapshot(uB))
end

-- Tier C
do
    local unitsA = {
        makeUnit(Sinner, 5, 3, 1, 1, STUB_SPRITES_EXT),
        makeUnit(Boney,  3, 2, 2, 0),
        makeUnit(Boney,  3, 3, 2, 0),
        makeUnit(Boney,  3, 4, 2, 0),
    }
    local gA = Grid()
    for _, u in ipairs(unitsA) do gA:placeUnit(u.col, u.row, u) end

    local function freshSinnerUnits()
        return {
            makeUnit(Sinner, 5, 3, 1, 1, STUB_SPRITES_EXT),
            makeUnit(Boney,  3, 2, 2, 0),
            makeUnit(Boney,  3, 3, 2, 0),
            makeUnit(Boney,  3, 4, 2, 0),
        }
    end
    local gB = Grid()
    for _, u in ipairs(freshSinnerUnits()) do gB:placeUnit(u.col, u.row, u) end

    math.randomseed(1702)
    for _, u in ipairs(gA:getAllUnits()) do u:onBattleStart(gA) end
    math.randomseed(1702)
    for _, u in ipairs(gB:getAllUnits()) do u:onBattleStart(gB) end
    math.randomseed(1702); runBattle(gA)
    math.randomseed(1702); runBattle(gB)

    resetBoard(gA, unitsA)
    gB = Grid()
    for _, u in ipairs(freshSinnerUnits()) do gB:placeUnit(u.col, u.row, u) end

    math.randomseed(1703)
    for _, u in ipairs(gA:getAllUnits()) do u:onBattleStart(gA) end
    math.randomseed(1703)
    for _, u in ipairs(gB:getAllUnits()) do u:onBattleStart(gB) end
    math.randomseed(1703); local wA, sA, uA = runBattle(gA)
    math.randomseed(1703); local wB, sB, uB = runBattle(gB)
    check("t17C_winner", wA, wB)
    check("t17C_steps",  sA, sB)
    check("t17C_health", healthSnapshot(uA), healthSnapshot(uB))
end

-- ════════════════════════════════════════════════════════════════════════════
-- TEST 18 — Tomb (corpse state + ally healing)
-- ════════════════════════════════════════════════════════════════════════════
print("── Test 18: Tomb (corpse state + ally healing) ──────────────────────────")

-- Tier A
do
    local t = makeUnit(Tomb, 5, 3, 1, 0)
    local dummyUnit = {}
    t.justDied        = true
    t.martyrdomApplied = true
    t.corpsePositions = { ["2,3"] = true, ["3,3"] = true }
    t.healedUnits     = { [dummyUnit] = { ["2,3"] = true } }
    t:resetCombatState()
    check("t18A_justDied",         t.justDied,         false)
    check("t18A_martyrdomApplied", t.martyrdomApplied, false)
    check("t18A_corpsePositions",  next(t.corpsePositions) == nil and "empty" or "not_empty", "empty")
    check("t18A_healedUnits",      next(t.healedUnits)     == nil and "empty" or "not_empty", "empty")
end

-- Tier B: Tomb dies → corpse heals ally Knight
do
    local function makeTombBoard()
        return {
            makeUnit(Tomb,   5, 3, 1, 1),   -- Martyr's Blessing: ally regen
            makeUnit(Knight, 6, 3, 1, 0),   -- ally that should get healed
            makeUnit(Knight, 2, 2, 2, 0),
            makeUnit(Knight, 2, 4, 2, 0),
        }
    end
    local wA, sA, uA, wB, sB, uB = buildAndRunPair(makeTombBoard(), makeTombBoard(), 1801)
    check("t18B_winner", wA, wB)
    check("t18B_steps",  sA, sB)
    check("t18B_health", healthSnapshot(uA), healthSnapshot(uB))
end

-- Tier C
do
    local unitsA = {
        makeUnit(Tomb,   5, 3, 1, 1),
        makeUnit(Knight, 6, 3, 1, 0),
        makeUnit(Knight, 2, 2, 2, 0),
        makeUnit(Knight, 2, 4, 2, 0),
    }
    local gA = Grid()
    for _, u in ipairs(unitsA) do gA:placeUnit(u.col, u.row, u) end

    local function freshTombUnits()
        return {
            makeUnit(Tomb,   5, 3, 1, 1),
            makeUnit(Knight, 6, 3, 1, 0),
            makeUnit(Knight, 2, 2, 2, 0),
            makeUnit(Knight, 2, 4, 2, 0),
        }
    end
    local gB = Grid()
    for _, u in ipairs(freshTombUnits()) do gB:placeUnit(u.col, u.row, u) end

    math.randomseed(1802)
    for _, u in ipairs(gA:getAllUnits()) do u:onBattleStart(gA) end
    math.randomseed(1802)
    for _, u in ipairs(gB:getAllUnits()) do u:onBattleStart(gB) end
    math.randomseed(1802); runBattle(gA)
    math.randomseed(1802); runBattle(gB)

    resetBoard(gA, unitsA)
    gB = Grid()
    for _, u in ipairs(freshTombUnits()) do gB:placeUnit(u.col, u.row, u) end

    math.randomseed(1803)
    for _, u in ipairs(gA:getAllUnits()) do u:onBattleStart(gA) end
    math.randomseed(1803)
    for _, u in ipairs(gB:getAllUnits()) do u:onBattleStart(gB) end
    math.randomseed(1803); local wA, sA, uA = runBattle(gA)
    math.randomseed(1803); local wB, sB, uB = runBattle(gB)
    check("t18C_winner", wA, wB)
    check("t18C_steps",  sA, sB)
    check("t18C_health", healthSnapshot(uA), healthSnapshot(uB))
end

-- ════════════════════════════════════════════════════════════════════════════
-- TEST 19 — Bull (charge + fire patches)
-- ════════════════════════════════════════════════════════════════════════════
print("── Test 19: Bull (charge + fire patches) ────────────────────────────────")

-- Tier A
do
    local b = makeUnit(Bull, 6, 3, 1, 1)
    b.isCharging      = true
    b.chargeTimer     = 0.3
    b.chargeEnemy     = {}
    b.chargeTrail     = {{}}
    b.firePatches     = {{}}
    b.ragingBullTimer = 1.5
    b:resetCombatState()
    check("t19A_isCharging",      b.isCharging,      false)
    check("t19A_chargeTimer",     b.chargeTimer,     0)
    check("t19A_chargeEnemy",     b.chargeEnemy,     nil)
    check("t19A_chargeTrail",     #b.chargeTrail,    0)
    check("t19A_firePatches",     #b.firePatches,    0)
    check("t19A_ragingBullTimer", b.ragingBullTimer, 0)
    check("t19A_attackSpeed",     b.attackSpeed,     b.baseAttackSpeed)
end

-- Tier B
do
    local function makeBullBoard()
        return {
            makeUnit(Bull,   6, 3, 1, 1),
            makeUnit(Knight, 2, 3, 2, 0),
            makeUnit(Knight, 3, 5, 2, 0),
        }
    end
    local wA, sA, uA, wB, sB, uB = buildAndRunPair(makeBullBoard(), makeBullBoard(), 1901)
    check("t19B_winner", wA, wB)
    check("t19B_steps",  sA, sB)
    check("t19B_health", healthSnapshot(uA), healthSnapshot(uB))
end

-- Tier C
do
    local unitsA = {
        makeUnit(Bull,   6, 3, 1, 1),
        makeUnit(Knight, 2, 3, 2, 0),
        makeUnit(Knight, 3, 5, 2, 0),
    }
    local gA = Grid()
    for _, u in ipairs(unitsA) do gA:placeUnit(u.col, u.row, u) end

    local function freshBullUnits()
        return {
            makeUnit(Bull,   6, 3, 1, 1),
            makeUnit(Knight, 2, 3, 2, 0),
            makeUnit(Knight, 3, 5, 2, 0),
        }
    end
    local gB = Grid()
    for _, u in ipairs(freshBullUnits()) do gB:placeUnit(u.col, u.row, u) end

    math.randomseed(1902)
    for _, u in ipairs(gA:getAllUnits()) do u:onBattleStart(gA) end
    math.randomseed(1902)
    for _, u in ipairs(gB:getAllUnits()) do u:onBattleStart(gB) end
    math.randomseed(1902); runBattle(gA)
    math.randomseed(1902); runBattle(gB)

    resetBoard(gA, unitsA)
    gB = Grid()
    for _, u in ipairs(freshBullUnits()) do gB:placeUnit(u.col, u.row, u) end

    math.randomseed(1903)
    for _, u in ipairs(gA:getAllUnits()) do u:onBattleStart(gA) end
    math.randomseed(1903)
    for _, u in ipairs(gB:getAllUnits()) do u:onBattleStart(gB) end
    math.randomseed(1903); local wA, sA, uA = runBattle(gA)
    math.randomseed(1903); local wB, sB, uB = runBattle(gB)
    check("t19C_winner", wA, wB)
    check("t19C_steps",  sA, sB)
    check("t19C_health", healthSnapshot(uA), healthSnapshot(uB))
end

-- ════════════════════════════════════════════════════════════════════════════
-- TEST 20 — Burrow (underground state)
-- ════════════════════════════════════════════════════════════════════════════
print("── Test 20: Burrow (underground state) ──────────────────────────────────")

-- Tier A
do
    local b = makeUnit(Burrow, 5, 3, 1, 1)
    b.isBurrowing = true
    b.burrowTimer = 1.5
    b.surgeTimer  = 0.8
    b:resetCombatState()
    check("t20A_isBurrowing", b.isBurrowing, false)
    check("t20A_burrowTimer", b.burrowTimer, 0)
    check("t20A_surgeTimer",  b.surgeTimer,  0)
    check("t20A_attackSpeed", b.attackSpeed, b.baseAttackSpeed)
end

-- Tier B
do
    local function makeBurrowBoard()
        return {
            makeUnit(Burrow, 5, 3, 1, 1),
            makeUnit(Knight, 3, 3, 2, 0),
            makeUnit(Knight, 2, 2, 2, 0),
        }
    end
    local wA, sA, uA, wB, sB, uB = buildAndRunPair(makeBurrowBoard(), makeBurrowBoard(), 2001)
    check("t20B_winner", wA, wB)
    check("t20B_steps",  sA, sB)
    check("t20B_health", healthSnapshot(uA), healthSnapshot(uB))
end

-- Tier C
do
    local unitsA = {
        makeUnit(Burrow, 5, 3, 1, 1),
        makeUnit(Knight, 3, 3, 2, 0),
        makeUnit(Knight, 2, 2, 2, 0),
    }
    local gA = Grid()
    for _, u in ipairs(unitsA) do gA:placeUnit(u.col, u.row, u) end

    local function freshBurrowUnits()
        return {
            makeUnit(Burrow, 5, 3, 1, 1),
            makeUnit(Knight, 3, 3, 2, 0),
            makeUnit(Knight, 2, 2, 2, 0),
        }
    end
    local gB = Grid()
    for _, u in ipairs(freshBurrowUnits()) do gB:placeUnit(u.col, u.row, u) end

    math.randomseed(2002)
    for _, u in ipairs(gA:getAllUnits()) do u:onBattleStart(gA) end
    math.randomseed(2002)
    for _, u in ipairs(gB:getAllUnits()) do u:onBattleStart(gB) end
    math.randomseed(2002); runBattle(gA)
    math.randomseed(2002); runBattle(gB)

    resetBoard(gA, unitsA)
    gB = Grid()
    for _, u in ipairs(freshBurrowUnits()) do gB:placeUnit(u.col, u.row, u) end

    math.randomseed(2003)
    for _, u in ipairs(gA:getAllUnits()) do u:onBattleStart(gA) end
    math.randomseed(2003)
    for _, u in ipairs(gB:getAllUnits()) do u:onBattleStart(gB) end
    math.randomseed(2003); local wA, sA, uA = runBattle(gA)
    math.randomseed(2003); local wB, sB, uB = runBattle(gB)
    check("t20C_winner", wA, wB)
    check("t20C_steps",  sA, sB)
    check("t20C_health", healthSnapshot(uA), healthSnapshot(uB))
end

-- ════════════════════════════════════════════════════════════════════════════
-- TEST 21 — Catapult (AoE projectile + fire patches)
-- ════════════════════════════════════════════════════════════════════════════
print("── Test 21: Catapult (AoE projectile + fire patches) ────────────────────")

-- Tier A
do
    local c = makeUnit(Catapult, 7, 3, 1, 0)
    c.projectile        = {}
    c.pendingProjectile = {}
    c.firePatches       = {{}}
    c.shotFired         = true
    c:resetCombatState()
    check("t21A_projectile",        c.projectile,        nil)
    check("t21A_pendingProjectile", c.pendingProjectile, nil)
    check("t21A_firePatches",       #c.firePatches,      0)
    check("t21A_shotFired",         c.shotFired,         false)
end

-- Tier B: Catapult fires into clustered enemies
do
    local function makeCatapultBoard()
        return {
            makeUnit(Catapult, 7, 3, 1, 0),
            makeUnit(Knight,   2, 2, 2, 0),
            makeUnit(Knight,   2, 3, 2, 0),
            makeUnit(Knight,   2, 4, 2, 0),
        }
    end
    local wA, sA, uA, wB, sB, uB = buildAndRunPair(makeCatapultBoard(), makeCatapultBoard(), 2101)
    check("t21B_winner", wA, wB)
    check("t21B_steps",  sA, sB)
    check("t21B_health", healthSnapshot(uA), healthSnapshot(uB))
end

-- Tier C
do
    local unitsA = {
        makeUnit(Catapult, 7, 3, 1, 0),
        makeUnit(Knight,   2, 2, 2, 0),
        makeUnit(Knight,   2, 3, 2, 0),
        makeUnit(Knight,   2, 4, 2, 0),
    }
    local gA = Grid()
    for _, u in ipairs(unitsA) do gA:placeUnit(u.col, u.row, u) end

    local function freshCatapultUnits()
        return {
            makeUnit(Catapult, 7, 3, 1, 0),
            makeUnit(Knight,   2, 2, 2, 0),
            makeUnit(Knight,   2, 3, 2, 0),
            makeUnit(Knight,   2, 4, 2, 0),
        }
    end
    local gB = Grid()
    for _, u in ipairs(freshCatapultUnits()) do gB:placeUnit(u.col, u.row, u) end

    math.randomseed(2102)
    for _, u in ipairs(gA:getAllUnits()) do u:onBattleStart(gA) end
    math.randomseed(2102)
    for _, u in ipairs(gB:getAllUnits()) do u:onBattleStart(gB) end
    math.randomseed(2102); runBattle(gA)
    math.randomseed(2102); runBattle(gB)

    resetBoard(gA, unitsA)
    gB = Grid()
    for _, u in ipairs(freshCatapultUnits()) do gB:placeUnit(u.col, u.row, u) end

    math.randomseed(2103)
    for _, u in ipairs(gA:getAllUnits()) do u:onBattleStart(gA) end
    math.randomseed(2103)
    for _, u in ipairs(gB:getAllUnits()) do u:onBattleStart(gB) end
    math.randomseed(2103); local wA, sA, uA = runBattle(gA)
    math.randomseed(2103); local wB, sB, uB = runBattle(gB)
    check("t21C_winner", wA, wB)
    check("t21C_steps",  sA, sB)
    check("t21C_health", healthSnapshot(uA), healthSnapshot(uB))
end

-- ════════════════════════════════════════════════════════════════════════════
-- TEST 22 — Marrow (lance + damageBoostTimer)
-- ════════════════════════════════════════════════════════════════════════════
print("── Test 22: Marrow (lance + damageBoostTimer) ───────────────────────────")

-- Tier A
do
    local m = makeUnit(Marrow, 6, 3, 1, 1)
    m.lance            = {}
    m.damageBoostTimer = 1.8
    m:resetCombatState()
    check("t22A_lance",            m.lance,            nil)
    check("t22A_damageBoostTimer", m.damageBoostTimer, 0)
end

-- Tier B: Marrow + 2 Knight allies vs 2 Knight enemies
do
    local function makeMarrowBoard()
        return {
            makeUnit(Marrow, 6, 3, 1, 1),   -- Extended Range
            makeUnit(Knight, 7, 2, 1, 0),
            makeUnit(Knight, 7, 4, 1, 0),
            makeUnit(Knight, 2, 2, 2, 0),
            makeUnit(Knight, 2, 4, 2, 0),
        }
    end
    local wA, sA, uA, wB, sB, uB = buildAndRunPair(makeMarrowBoard(), makeMarrowBoard(), 2201)
    check("t22B_winner", wA, wB)
    check("t22B_steps",  sA, sB)
    check("t22B_health", healthSnapshot(uA), healthSnapshot(uB))
end

-- Tier C
do
    local unitsA = {
        makeUnit(Marrow, 6, 3, 1, 1),
        makeUnit(Knight, 7, 2, 1, 0),
        makeUnit(Knight, 7, 4, 1, 0),
        makeUnit(Knight, 2, 2, 2, 0),
        makeUnit(Knight, 2, 4, 2, 0),
    }
    local gA = Grid()
    for _, u in ipairs(unitsA) do gA:placeUnit(u.col, u.row, u) end

    local function freshMarrowUnits()
        return {
            makeUnit(Marrow, 6, 3, 1, 1),
            makeUnit(Knight, 7, 2, 1, 0),
            makeUnit(Knight, 7, 4, 1, 0),
            makeUnit(Knight, 2, 2, 2, 0),
            makeUnit(Knight, 2, 4, 2, 0),
        }
    end
    local gB = Grid()
    for _, u in ipairs(freshMarrowUnits()) do gB:placeUnit(u.col, u.row, u) end

    math.randomseed(2202)
    for _, u in ipairs(gA:getAllUnits()) do u:onBattleStart(gA) end
    math.randomseed(2202)
    for _, u in ipairs(gB:getAllUnits()) do u:onBattleStart(gB) end
    math.randomseed(2202); runBattle(gA)
    math.randomseed(2202); runBattle(gB)

    resetBoard(gA, unitsA)
    gB = Grid()
    for _, u in ipairs(freshMarrowUnits()) do gB:placeUnit(u.col, u.row, u) end

    math.randomseed(2203)
    for _, u in ipairs(gA:getAllUnits()) do u:onBattleStart(gA) end
    math.randomseed(2203)
    for _, u in ipairs(gB:getAllUnits()) do u:onBattleStart(gB) end
    math.randomseed(2203); local wA, sA, uA = runBattle(gA)
    math.randomseed(2203); local wB, sB, uB = runBattle(gB)
    check("t22C_winner", wA, wB)
    check("t22C_steps",  sA, sB)
    check("t22C_health", healthSnapshot(uA), healthSnapshot(uB))
end

-- ════════════════════════════════════════════════════════════════════════════
-- TEST 23 — Full roster: 5-round match with all 17 unit types
-- Board A keeps original objects; board B recreates fresh each round.
-- ════════════════════════════════════════════════════════════════════════════
print("── Test 23: 5-round full-roster match ───────────────────────────────────")

local function makeRoster23_P1()
    return {
        makeUnit(Knight,   8, 1, 1, 2),
        makeUnit(Samurai,  8, 2, 1, 1),
        makeUnit(Mage,     8, 3, 1, 1),   -- Burning Ground
        makeUnit(Bonk,     8, 4, 1, 1),
        makeUnit(Sinner,   8, 5, 1, 1, STUB_SPRITES_EXT),
        makeUnit(Marrow,   7, 2, 1, 0),
        makeUnit(Mend,     7, 4, 1, 0),
    }
end

local function makeRoster23_P2()
    return {
        makeUnit(Boney,    1, 1, 2, 1),
        makeUnit(Amalgam,  1, 2, 2, 1),
        makeUnit(Humerus,  1, 3, 2, 1),
        makeUnit(Burrow,   1, 4, 2, 1),
        makeUnit(Catapult, 2, 3, 2, 0),
        makeUnit(Tomb,     1, 5, 2, 1),
        makeUnit(Bull,     2, 1, 2, 1),
    }
end

local function makeFullRoster23()
    local units = makeRoster23_P1()
    for _, u in ipairs(makeRoster23_P2()) do table.insert(units, u) end
    return units
end

local gridA23 = Grid()
local gridB23 = Grid()
local unitsA23 = makeFullRoster23()
local unitsB23 = makeFullRoster23()

for _, u in ipairs(unitsA23) do
    u.homeCol = u.col; u.homeRow = u.row
    gridA23:placeUnit(u.col, u.row, u)
end
for _, u in ipairs(unitsB23) do
    u.homeCol = u.col; u.homeRow = u.row
    gridB23:placeUnit(u.col, u.row, u)
end

for round = 1, 5 do
    local seed23 = 500 + round * 23

    math.randomseed(seed23)
    for _, u in ipairs(gridA23:getAllUnits()) do u:onBattleStart(gridA23) end
    math.randomseed(seed23)
    for _, u in ipairs(gridB23:getAllUnits()) do u:onBattleStart(gridB23) end

    math.randomseed(seed23); local wA23, sA23, uA23 = runBattle(gridA23)
    math.randomseed(seed23); local wB23, sB23, uB23 = runBattle(gridB23)

    local rStr = "t23_r" .. round
    check(rStr .. "_winner", wA23, wB23)
    check(rStr .. "_steps",  sA23, sB23)
    check(rStr .. "_health", healthSnapshot(uA23), healthSnapshot(uB23))

    if round < 5 then
        -- Board A: reset original objects (local player view)
        resetBoard(gridA23, unitsA23)

        -- Board B: recreate fresh objects (opponent applyOpponentMsg view)
        gridB23 = Grid()
        unitsB23 = makeFullRoster23()
        for _, u in ipairs(unitsB23) do
            u.homeCol = u.col; u.homeRow = u.row
            gridB23:placeUnit(u.col, u.row, u)
        end
    end
end

-- ════════════════════════════════════════════════════════════════════════════
-- TEST 24 — Royal Command bonus (royalCommandBonus field)
-- ════════════════════════════════════════════════════════════════════════════
print("── Test 24: Royal Command bonus (royalCommandBonus) ─────────────────────")

-- Tier A: royalCommandBonus must be cleared by resetCombatState()
do
    local k = makeUnit(Knight, 7, 3, 1, 0)
    k.royalCommandBonus = 1.2
    k:resetCombatState()
    check("t24A_royalCommandBonus", k.royalCommandBonus, nil)
end

-- Tier B: Humerus + Knight ally vs 2 Boney — two independent runs must agree
do
    local function makeRCBoard()
        return {
            makeUnit(Humerus, 7, 3, 1, 1),   -- Bone Throne
            makeUnit(Knight,  7, 2, 1, 0),
            makeUnit(Boney,   2, 2, 2, 0),
            makeUnit(Boney,   2, 4, 2, 0),
        }
    end
    local wA, sA, uA, wB, sB, uB = buildAndRunPair(makeRCBoard(), makeRCBoard(), 2401)
    check("t24B_winner", wA, wB)
    check("t24B_steps",  sA, sB)
    check("t24B_health", healthSnapshot(uA), healthSnapshot(uB))
end

-- Tier C: multi-round — stale royalCommandBonus must not persist into round 2
do
    local unitsA = {
        makeUnit(Humerus, 7, 3, 1, 1),
        makeUnit(Knight,  7, 2, 1, 0),
        makeUnit(Boney,   2, 2, 2, 0),
        makeUnit(Boney,   2, 4, 2, 0),
    }
    local gA = Grid()
    for _, u in ipairs(unitsA) do gA:placeUnit(u.col, u.row, u) end

    local function freshRCUnits()
        return {
            makeUnit(Humerus, 7, 3, 1, 1),
            makeUnit(Knight,  7, 2, 1, 0),
            makeUnit(Boney,   2, 2, 2, 0),
            makeUnit(Boney,   2, 4, 2, 0),
        }
    end
    local gB = Grid()
    for _, u in ipairs(freshRCUnits()) do gB:placeUnit(u.col, u.row, u) end

    math.randomseed(2402)
    for _, u in ipairs(gA:getAllUnits()) do u:onBattleStart(gA) end
    math.randomseed(2402)
    for _, u in ipairs(gB:getAllUnits()) do u:onBattleStart(gB) end
    math.randomseed(2402); runBattle(gA)
    math.randomseed(2402); runBattle(gB)

    resetBoard(gA, unitsA)
    gB = Grid()
    for _, u in ipairs(freshRCUnits()) do gB:placeUnit(u.col, u.row, u) end

    math.randomseed(2403)
    for _, u in ipairs(gA:getAllUnits()) do u:onBattleStart(gA) end
    math.randomseed(2403)
    for _, u in ipairs(gB:getAllUnits()) do u:onBattleStart(gB) end
    math.randomseed(2403); local wA, sA, uA = runBattle(gA)
    math.randomseed(2403); local wB, sB, uB = runBattle(gB)
    check("t24C_winner", wA, wB)
    check("t24C_steps",  sA, sB)
    check("t24C_health", healthSnapshot(uA), healthSnapshot(uB))
end

-- ════════════════════════════════════════════════════════════════════════════
-- TEST 25 — Mage repositioned after Arcane Surge fires in round 1
-- Board A: original Mage reset (attackSpeed restored) then moved to col 2.
-- Board B: fresh Mage created at col 2.
-- Round 2 must agree.
-- ════════════════════════════════════════════════════════════════════════════
print("── Test 25: Mage repositioned (post-Arcane Surge) ───────────────────────")

do
    -- Round 1: Mage (Arcane Surge upgrade) vs 3 Boney — enough targets to trigger fireball
    local mageA = makeUnit(Mage, 8, 3, 1, 2)   -- Burning Ground + Arcane Surge
    local unitsA25 = {
        mageA,
        makeUnit(Knight, 7, 2, 1, 0),
        makeUnit(Boney,  2, 2, 2, 0),
        makeUnit(Boney,  2, 3, 2, 0),
        makeUnit(Boney,  2, 4, 2, 0),
    }
    local gA25 = Grid()
    for _, u in ipairs(unitsA25) do gA25:placeUnit(u.col, u.row, u) end

    math.randomseed(2501)
    for _, u in ipairs(gA25:getAllUnits()) do u:onBattleStart(gA25) end
    math.randomseed(2501); runBattle(gA25)

    -- Reposition Mage from col 3 → col 2 between rounds
    resetBoard(gA25, unitsA25)
    mageA.col     = 2; mageA.row     = 8
    mageA.homeCol = 2; mageA.homeRow = 8
    -- clear old cell, place at new position
    gA25.cells[8][3].unit = nil; gA25.cells[8][3].occupied = false
    gA25:placeUnit(2, 8, mageA)

    -- Board B: fresh Mage already at col 2, same board composition
    local gB25 = Grid()
    local unitsB25 = {
        makeUnit(Mage,   8, 2, 1, 2),   -- fresh, col 2
        makeUnit(Knight, 7, 2, 1, 0),
        makeUnit(Boney,  2, 2, 2, 0),
        makeUnit(Boney,  2, 3, 2, 0),
        makeUnit(Boney,  2, 4, 2, 0),
    }
    for _, u in ipairs(unitsB25) do gB25:placeUnit(u.col, u.row, u) end

    math.randomseed(2502)
    for _, u in ipairs(gA25:getAllUnits()) do u:onBattleStart(gA25) end
    math.randomseed(2502)
    for _, u in ipairs(gB25:getAllUnits()) do u:onBattleStart(gB25) end
    math.randomseed(2502); local wA25, sA25, uA25 = runBattle(gA25)
    math.randomseed(2502); local wB25, sB25, uB25 = runBattle(gB25)
    check("t25_winner", wA25, wB25)
    check("t25_steps",  sA25, sB25)
    check("t25_health", healthSnapshot(uA25), healthSnapshot(uB25))
end

-- ════════════════════════════════════════════════════════════════════════════
-- TEST 26 — Sinner repositioned after form change in round 1
-- Board A: original Sinner reset (isFree=false, sprites restored) then moved.
-- Board B: fresh Sinner at new position.
-- Round 2 must agree.
-- ════════════════════════════════════════════════════════════════════════════
print("── Test 26: Sinner repositioned (post-form-change) ──────────────────────")

do
    local sinnerA = makeUnit(Sinner, 5, 3, 1, 1, STUB_SPRITES_EXT)  -- Early Release (threshold=10)
    local unitsA26 = {
        sinnerA,
        makeUnit(Boney, 3, 1, 2, 0),
        makeUnit(Boney, 3, 2, 2, 0),
        makeUnit(Boney, 3, 3, 2, 0),
        makeUnit(Boney, 3, 4, 2, 0),
    }
    local gA26 = Grid()
    for _, u in ipairs(unitsA26) do gA26:placeUnit(u.col, u.row, u) end

    math.randomseed(2601)
    for _, u in ipairs(gA26:getAllUnits()) do u:onBattleStart(gA26) end
    math.randomseed(2601); runBattle(gA26)

    -- Reposition Sinner from col 3 → col 4 between rounds
    resetBoard(gA26, unitsA26)
    sinnerA.col     = 4; sinnerA.row     = 5
    sinnerA.homeCol = 4; sinnerA.homeRow = 5
    gA26.cells[5][3].unit = nil; gA26.cells[5][3].occupied = false
    gA26:placeUnit(4, 5, sinnerA)

    -- Board B: fresh Sinner at col 4
    local gB26 = Grid()
    local unitsB26 = {
        makeUnit(Sinner, 5, 4, 1, 1, STUB_SPRITES_EXT),
        makeUnit(Boney,  3, 1, 2, 0),
        makeUnit(Boney,  3, 2, 2, 0),
        makeUnit(Boney,  3, 3, 2, 0),
        makeUnit(Boney,  3, 4, 2, 0),
    }
    for _, u in ipairs(unitsB26) do gB26:placeUnit(u.col, u.row, u) end

    math.randomseed(2602)
    for _, u in ipairs(gA26:getAllUnits()) do u:onBattleStart(gA26) end
    math.randomseed(2602)
    for _, u in ipairs(gB26:getAllUnits()) do u:onBattleStart(gB26) end
    math.randomseed(2602); local wA26, sA26, uA26 = runBattle(gA26)
    math.randomseed(2602); local wB26, sB26, uB26 = runBattle(gB26)
    check("t26_winner", wA26, wB26)
    check("t26_steps",  sA26, sB26)
    check("t26_health", healthSnapshot(uA26), healthSnapshot(uB26))
end

-- ════════════════════════════════════════════════════════════════════════════
-- TEST 27 — Level-3 upgrade combos
-- Mage (all 3 upgrades), Sinner (all 3 upgrades), Amalgam (all 3 upgrades)
-- Two identical boards must agree on a single battle, and across two rounds.
-- ════════════════════════════════════════════════════════════════════════════
print("── Test 27: Level-3 upgrade combos ──────────────────────────────────────")

-- Tier B: single-battle determinism
do
    local function makeL3Board()
        return {
            makeUnit(Mage,   8, 2, 1, 3),
            makeUnit(Sinner, 8, 3, 1, 3, STUB_SPRITES_EXT),
            makeUnit(Amalgam,8, 4, 1, 3),
            makeUnit(Boney,  2, 1, 2, 0),
            makeUnit(Boney,  2, 2, 2, 0),
            makeUnit(Boney,  2, 3, 2, 0),
            makeUnit(Boney,  2, 4, 2, 0),
            makeUnit(Boney,  2, 5, 2, 0),
        }
    end
    local wA, sA, uA, wB, sB, uB = buildAndRunPair(makeL3Board(), makeL3Board(), 2701)
    check("t27B_winner", wA, wB)
    check("t27B_steps",  sA, sB)
    check("t27B_health", healthSnapshot(uA), healthSnapshot(uB))
end

-- Tier C: multi-round
do
    local unitsA = {
        makeUnit(Mage,   8, 2, 1, 3),
        makeUnit(Sinner, 8, 3, 1, 3, STUB_SPRITES_EXT),
        makeUnit(Amalgam,8, 4, 1, 3),
        makeUnit(Boney,  2, 1, 2, 0),
        makeUnit(Boney,  2, 2, 2, 0),
        makeUnit(Boney,  2, 3, 2, 0),
        makeUnit(Boney,  2, 4, 2, 0),
        makeUnit(Boney,  2, 5, 2, 0),
    }
    local gA = Grid()
    for _, u in ipairs(unitsA) do gA:placeUnit(u.col, u.row, u) end

    local function freshL3Units()
        return {
            makeUnit(Mage,   8, 2, 1, 3),
            makeUnit(Sinner, 8, 3, 1, 3, STUB_SPRITES_EXT),
            makeUnit(Amalgam,8, 4, 1, 3),
            makeUnit(Boney,  2, 1, 2, 0),
            makeUnit(Boney,  2, 2, 2, 0),
            makeUnit(Boney,  2, 3, 2, 0),
            makeUnit(Boney,  2, 4, 2, 0),
            makeUnit(Boney,  2, 5, 2, 0),
        }
    end
    local gB = Grid()
    for _, u in ipairs(freshL3Units()) do gB:placeUnit(u.col, u.row, u) end

    math.randomseed(2702)
    for _, u in ipairs(gA:getAllUnits()) do u:onBattleStart(gA) end
    math.randomseed(2702)
    for _, u in ipairs(gB:getAllUnits()) do u:onBattleStart(gB) end
    math.randomseed(2702); runBattle(gA)
    math.randomseed(2702); runBattle(gB)

    resetBoard(gA, unitsA)
    gB = Grid()
    for _, u in ipairs(freshL3Units()) do gB:placeUnit(u.col, u.row, u) end

    math.randomseed(2703)
    for _, u in ipairs(gA:getAllUnits()) do u:onBattleStart(gA) end
    math.randomseed(2703)
    for _, u in ipairs(gB:getAllUnits()) do u:onBattleStart(gB) end
    math.randomseed(2703); local wA, sA, uA = runBattle(gA)
    math.randomseed(2703); local wB, sB, uB = runBattle(gB)
    check("t27C_winner", wA, wB)
    check("t27C_steps",  sA, sB)
    check("t27C_health", healthSnapshot(uA), healthSnapshot(uB))
end

-- ════════════════════════════════════════════════════════════════════════════
-- TEST 28 — Amalgam invulnerability actually triggering
-- Pre-set health = 2 so the first Knight hit (3 dmg) triggers Unholy Resilience.
-- Board A and B must agree. Tier C verifies invulnCooldown is cleared on reset.
-- ════════════════════════════════════════════════════════════════════════════
print("── Test 28: Amalgam invulnerability triggering ──────────────────────────")

-- Tier A: invulnTimer and invulnCooldown clear on reset
do
    local a = makeUnit(Amalgam, 6, 3, 1, 2)
    a.invulnTimer            = 0.4
    a.invulnCooldown         = 5.2
    a.corpseExplosionPending = true
    a:resetCombatState()
    check("t28A_invulnTimer",            a.invulnTimer,            0)
    check("t28A_invulnCooldown",         a.invulnCooldown,         0)
    check("t28A_corpseExplosionPending", a.corpseExplosionPending, false)
end

-- Tier B: two boards with health pre-set to 2 — first hit triggers invuln, results must agree
do
    local function makeInvulnBoard()
        local am = makeUnit(Amalgam, 6, 3, 1, 2)   -- Bone Armor + Corpse Explosion
        am.health = 2  -- one hit below threshold; next enemy hit triggers invulnerability
        return {
            am,
            makeUnit(Knight, 2, 2, 2, 0),
            makeUnit(Knight, 2, 4, 2, 0),
        }
    end
    local wA, sA, uA, wB, sB, uB = buildAndRunPair(makeInvulnBoard(), makeInvulnBoard(), 2801)
    check("t28B_winner", wA, wB)
    check("t28B_steps",  sA, sB)
    check("t28B_health", healthSnapshot(uA), healthSnapshot(uB))
end

-- Tier C: reset after invuln triggered in round 1 — round 2 must agree vs fresh
do
    local amalgamA = makeUnit(Amalgam, 6, 3, 1, 2)
    amalgamA.health = 2
    local unitsA28 = {
        amalgamA,
        makeUnit(Knight, 2, 2, 2, 0),
        makeUnit(Knight, 2, 4, 2, 0),
    }
    local gA28 = Grid()
    for _, u in ipairs(unitsA28) do gA28:placeUnit(u.col, u.row, u) end

    local function freshInvulnUnits()
        return {
            makeUnit(Amalgam, 6, 3, 1, 2),
            makeUnit(Knight,  2, 2, 2, 0),
            makeUnit(Knight,  2, 4, 2, 0),
        }
    end
    local gB28 = Grid()
    for _, u in ipairs(freshInvulnUnits()) do gB28:placeUnit(u.col, u.row, u) end

    math.randomseed(2802)
    for _, u in ipairs(gA28:getAllUnits()) do u:onBattleStart(gA28) end
    math.randomseed(2802)
    for _, u in ipairs(gB28:getAllUnits()) do u:onBattleStart(gB28) end
    math.randomseed(2802); runBattle(gA28)
    math.randomseed(2802); runBattle(gB28)

    -- Reset board A; fresh board B has full health (no pre-set)
    resetBoard(gA28, unitsA28)
    gB28 = Grid()
    for _, u in ipairs(freshInvulnUnits()) do gB28:placeUnit(u.col, u.row, u) end

    math.randomseed(2803)
    for _, u in ipairs(gA28:getAllUnits()) do u:onBattleStart(gA28) end
    math.randomseed(2803)
    for _, u in ipairs(gB28:getAllUnits()) do u:onBattleStart(gB28) end
    math.randomseed(2803); local wA28, sA28, uA28 = runBattle(gA28)
    math.randomseed(2803); local wB28, sB28, uB28 = runBattle(gB28)
    check("t28C_winner", wA28, wB28)
    check("t28C_steps",  sA28, sB28)
    check("t28C_health", healthSnapshot(uA28), healthSnapshot(uB28))
end

-- ════════════════════════════════════════════════════════════════════════════
-- Result
-- ════════════════════════════════════════════════════════════════════════════
print("")
if passed then
    print("All determinism tests passed.")
    os.exit(0)
else
    print(string.format("Determinism test FAILED — %d check(s) failed.", totalFails))
    os.exit(1)
end
