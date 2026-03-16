-- tests/test_battle_determinism.lua
-- Run with: lua tests/test_battle_determinism.lua  (from project root)
--
-- Test 1 (original): Two independent single-battle simulations from the same
--   board state and RNG seed must produce identical outcomes.
--
-- Test 2 (multi-round + upgrades): After a full battle, resetCombatState() is
--   called on all surviving units and a second battle is run. Both a "kept
--   object" board (owner's perspective) and a "fresh object" board (opponent's
--   perspective after applyOpponentMsg re-creates units) must agree.
--
-- Test 3 (repositioned upgraded unit): Simulates the exact desync vector —
--   a unit with Mend (hasHealed) or Guardian (hpBonusApplied) that healed in
--   round 1 is "repositioned" before round 2 by recreating it as a fresh
--   object. After our resetCombatState() fix both boards must agree.

-- ── Package path ─────────────────────────────────────────────────────────────
package.path = package.path .. ";./?.lua;./?/init.lua"

-- ── Minimal LÖVE stubs ───────────────────────────────────────────────────────
---@diagnostic disable-next-line: lowercase-global
love = {
    graphics = {
        newImage   = function() return {
            getWidth  = function() return 16 end,
            getHeight = function() return 16 end,
            setFilter = function() end,
        } end,
        setColor   = function() end,
        draw       = function() end,
        rectangle  = function() end,
        circle     = function() end,
        line       = function() end,
        print      = function() end,
        setFont    = function() end,
        getWidth   = function() return 540 end,
        getHeight  = function() return 960 end,
    },
    filesystem = { read = function() end },
    window     = { getMode = function() return 540, 960, {} end },
}
Fonts = { tiny = { getWidth = function() return 0 end, getHeight = function() return 0 end } }

-- ── Load modules ─────────────────────────────────────────────────────────────
local Grid    = require('src.grid')
local Knight  = require('src.units.knight')
local Boney   = require('src.units.boney')
local Samurai = require('src.units.samurai')

local STUB_SPRITES = { front = {}, back = {}, dead = {} }
local FIXED_DT     = 1 / 60
local MAX_STEPS    = 60 * 120

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

-- ── Test assertions ───────────────────────────────────────────────────────────

local passed = true

local function check(label, a, b)
    if a ~= b then
        io.write(string.format("FAIL [%s]\n  A: %s\n  B: %s\n", label, tostring(a), tostring(b)))
        passed = false
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
--   Board A = original unit objects after resetCombatState (owner's view)
--   Board B = fresh unit objects recreated at same positions (opponent's view
--             via applyOpponentMsg — units NOT repositioned between rounds)
-- ════════════════════════════════════════════════════════════════════════════
print("── Test 2: multi-round (no reposition) ────────────────────────────────")

local function makeUnit(UClass, row, col, owner, level)
    local u = UClass(row, col, owner, STUB_SPRITES)
    for i = 1, level do u:upgrade(i) end
    u.homeRow = row; u.homeCol = col
    return u
end

-- Build round 1 — both boards identical
local unitsR1_A = {
    makeUnit(Knight,  8, 3, 1, 2),   -- level-2 Knight with Guardian+Mend
    makeUnit(Boney,   7, 2, 1, 1),   -- level-1 Boney with Mend
    makeUnit(Samurai, 6, 1, 1, 2),   -- level-2 Samurai with Vengeance
    makeUnit(Knight,  1, 3, 2, 0),
    makeUnit(Boney,   2, 4, 2, 0),
}
local unitsR1_B = {
    makeUnit(Knight,  8, 3, 1, 2),
    makeUnit(Boney,   7, 2, 1, 1),
    makeUnit(Samurai, 6, 1, 1, 2),
    makeUnit(Knight,  1, 3, 2, 0),
    makeUnit(Boney,   2, 4, 2, 0),
}
local gridA2, gridB2 = Grid(), Grid()
for _, u in ipairs(unitsR1_A) do gridA2:placeUnit(u.col, u.row, u) end
for _, u in ipairs(unitsR1_B) do gridB2:placeUnit(u.col, u.row, u) end
math.randomseed(7)
for _, u in ipairs(gridA2:getAllUnits()) do u:onBattleStart(gridA2) end
math.randomseed(7)
for _, u in ipairs(gridB2:getAllUnits()) do u:onBattleStart(gridB2) end

-- Save home positions (mirrors startBattle())
for _, u in ipairs(unitsR1_A) do u.homeCol = u.col; u.homeRow = u.row end
for _, u in ipairs(unitsR1_B) do u.homeCol = u.col; u.homeRow = u.row end

math.randomseed(7); runBattle(gridA2)
math.randomseed(7); runBattle(gridB2)

-- Round 2: reset board A (original objects), rebuild board B (fresh objects)
resetBoard(gridA2, unitsR1_A)

-- Board B: recreate units fresh at same positions (no reposition — same level)
local gridB2r2 = Grid()
local freshB2 = {
    makeUnit(Knight,  8, 3, 1, 2),
    makeUnit(Boney,   7, 2, 1, 1),
    makeUnit(Samurai, 6, 1, 1, 2),
    makeUnit(Knight,  1, 3, 2, 0),
    makeUnit(Boney,   2, 4, 2, 0),
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
-- TEST 3 — Repositioned upgraded unit (the exact desync vector)
--   Round 1 runs; Knight heals (hasHealed=true), Guardian fires (hpBonusApplied).
--   Before round 2, the Knight is "repositioned" — on board A the original
--   object is properly reset (resetCombatState) and moved to the new position;
--   on board B a brand-new object is created at the new position (what
--   applyOpponentMsg does). Both boards MUST produce identical round-2 outcomes.
-- ════════════════════════════════════════════════════════════════════════════
print("── Test 3: repositioned upgraded unit (Mend + Guardian desync vector) ─")

-- Round 1 — build board A and run the battle
local knightA      = makeUnit(Knight, 8, 3, 1, 3)  -- IronWill + Guardian + Mend
local boney1A      = makeUnit(Boney,  7, 2, 1, 1)
local enemy1A      = makeUnit(Knight, 1, 3, 2, 0)
local enemy2A      = makeUnit(Boney,  2, 4, 2, 0)
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

-- resetBoard mirrors resetRound(): reset all unit objects and re-place at home positions
resetBoard(gridA3, r1unitsA)

-- "Reposition" Knight before round 2: drag from (row=8,col=3) → (row=8,col=2)
local newRow, newCol = 8, 2
-- Remove from old cell and re-place at new cell (mirrors game drag logic)
gridA3.cells[knightA.row][knightA.col].unit     = nil
gridA3.cells[knightA.row][knightA.col].occupied = false
knightA.col = newCol; knightA.row = newRow
knightA.homeCol = newCol; knightA.homeRow = newRow
gridA3:placeUnit(newCol, newRow, knightA)

-- Board B (opponent's view via applyOpponentMsg): fresh objects at the exact
-- same positions as board A's units after the reposition.
local gridB3r2 = Grid()
local freshUnitsB = {
    makeUnit(Knight, newRow,               newCol,          1, 3),  -- repositioned Knight (fresh)
    makeUnit(Boney,  boney1A.row,          boney1A.col,     1, 1),  -- Boney at home (fresh)
    makeUnit(Knight, enemy1A.row,          enemy1A.col,     2, 0),
    makeUnit(Boney,  enemy2A.row,          enemy2A.col,     2, 0),
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

local samA = makeUnit(Samurai, 8, 1, 1, 2)  -- upgrade 2 = Vengeance
samA.homeCol = samA.col; samA.homeRow = samA.row

-- Manually simulate that some ally deaths were observed in round 1
samA.damageFromAlliedDeaths = 3
samA.allyDeathsObserved = { [{}] = true, [{}] = true, [{}] = true }

-- resetCombatState must wipe this
samA:resetCombatState()
check("t4_samurai_damage_reset",  samA.damageFromAlliedDeaths, 0)
check("t4_samurai_observed_reset", next(samA.allyDeathsObserved) == nil and "empty" or "not_empty", "empty")

-- ════════════════════════════════════════════════════════════════════════════
-- Result
-- ════════════════════════════════════════════════════════════════════════════
print("")
if passed then
    print("All determinism tests passed.")
    os.exit(0)
else
    print("Determinism test FAILED — simulation is non-deterministic.")
    os.exit(1)
end
