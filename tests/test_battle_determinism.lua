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
-- TEST 5 — Exact damage timing: fires at tick pendingAttackDelay, not before
--
-- Regression guard for the float-comparison desync bug:
--   OLD code: `attackAnimProgress >= 2/3`  → may fire tick 17 or 19 on some FPUs
--   NEW code: integer countdown            → always fires at exactly tick 18
--
-- We verify THREE things:
--   a) Damage NOT applied after (delay-1) ticks  → not too early
--   b) Damage IS applied after delay ticks        → not too late
--   c) Both independent sims agree on step count  → deterministic
-- ════════════════════════════════════════════════════════════════════════════
print("── Test 5: exact damage timing (integer tick countdown) ────────────────")

local function buildTimingBoard()
    local g = Grid()
    -- Place P1 Knight directly above P2 Knight (adjacent, melee range).
    -- Row 5 = P1 zone top; row 4 = P2 zone bottom.  colDiff=0, rowDiff=1 → in range.
    local attacker = Knight(5, 3, 1, STUB_SPRITES)
    local target   = Knight(4, 3, 2, STUB_SPRITES)
    g:placeUnit(attacker.col, attacker.row, attacker)
    g:placeUnit(target.col,   target.row,   target)
    attacker:onBattleStart(g)
    target:onBattleStart(g)
    return g, attacker, target
end

-- Build two identical boards and run them in lockstep to detect any tick drift.
local gT5a, att5a, tgt5a = buildTimingBoard()
local gT5b, att5b, tgt5b = buildTimingBoard()

-- Determine expected delay from the unit's own calculation (mirrors startMeleeAnimation).
-- We expose it indirectly: run 1 tick so the attack is queued, then read the field.
local units5a = gT5a:getAllUnits()
local units5b = gT5b:getAllUnits()
for _, u in ipairs(units5a) do u:update(FIXED_DT, gT5a) end
for _, u in ipairs(units5b) do u:update(FIXED_DT, gT5b) end

local delay5 = att5a.pendingAttackDelay  -- read after first tick; should be delay-1 now
-- delay5 is (delay - 1) because one tick has already been consumed.
-- We need to run delay5 more ticks to reach tick 0 (the firing tick).
local hpBefore5a = tgt5a.health
local hpBefore5b = tgt5b.health

-- Run (delay5 - 1) more ticks: damage must NOT have fired yet.
for _ = 1, delay5 - 1 do
    for _, u in ipairs(units5a) do u:update(FIXED_DT, gT5a) end
    for _, u in ipairs(units5b) do u:update(FIXED_DT, gT5b) end
end
check("t5_no_damage_before_delay", tgt5a.health, hpBefore5a)  -- not yet
check("t5_both_boards_agree_pre",  tgt5a.health, tgt5b.health)

-- Run the final 1 tick: damage MUST fire now.
for _, u in ipairs(units5a) do u:update(FIXED_DT, gT5a) end
for _, u in ipairs(units5b) do u:update(FIXED_DT, gT5b) end
check("t5_damage_fires_at_delay",  tgt5a.health < hpBefore5a, true)  -- took damage
check("t5_both_boards_agree_post", tgt5a.health, tgt5b.health)       -- in sync

-- ════════════════════════════════════════════════════════════════════════════
-- TEST 6 — Concurrent melee attacks on the same target
--
-- Two P1 units are simultaneously in range of one P2 unit.  Both queue their
-- deferred attacks in tick 1.  The attacks must fire in the same deterministic
-- order on both simulations (board A and board B run independently).
-- ════════════════════════════════════════════════════════════════════════════
print("── Test 6: concurrent melee attacks on same target ─────────────────────")

local function buildConcurrentBoard()
    local g = Grid()
    -- Two P1 Knights flanking one P2 Knight
    local k1    = Knight(5, 2, 1, STUB_SPRITES)  -- row 5 col 2
    local k2    = Knight(5, 4, 1, STUB_SPRITES)  -- row 5 col 4
    local enemy = Knight(4, 3, 2, STUB_SPRITES)  -- row 4 col 3 (diagonal from both)
    g:placeUnit(k1.col,    k1.row,    k1)
    g:placeUnit(k2.col,    k2.row,    k2)
    g:placeUnit(enemy.col, enemy.row, enemy)
    k1:onBattleStart(g)
    k2:onBattleStart(g)
    enemy:onBattleStart(g)
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
--
-- Boney with Fury upgrade starts above 50% HP, takes damage, crosses the
-- threshold, and Fury kicks in (attackSpeed * 1.5).  The delay for the NEXT
-- attack is recomputed by startMeleeAnimation using the new attackSpeed.
-- Both simulations must produce identical outcomes.
-- ════════════════════════════════════════════════════════════════════════════
print("── Test 7: Boney Fury attackSpeed change determinism ───────────────────")

local function buildFuryBoard()
    local g = Grid()
    -- Fury Boney (level 2 = Mend + Fury) vs a higher-HP Knight so the battle lasts long enough
    -- for Fury to trigger.
    local furyBoney = makeUnit(Boney,  5, 3, 1, 2)   -- level 2: Mend + Fury
    local toughKnight = makeUnit(Knight, 4, 3, 2, 1)  -- level 1 Knight (more HP)
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
-- TEST 8 — 5-round match: accumulated drift detection
--
-- Runs a 5-round match (reset+battle loop).  Board A keeps original objects
-- (like the local player's view); board B recreates units fresh each round
-- (like the opponent's view via applyOpponentMsg).  Both must agree on every
-- round's winner, step count, and surviving health.
--
-- This specifically targets bugs that only appear after multiple rounds of
-- accumulated state (the reported desync occurred around round 3-4).
-- ════════════════════════════════════════════════════════════════════════════
print("── Test 8: 5-round accumulated drift detection ─────────────────────────")

-- Unit composition for the 5-round test (richer than Test 2)
local function makeRound8Units_A()
    return {
        makeUnit(Knight,  8, 2, 1, 2),  -- level-2 Knight
        makeUnit(Boney,   7, 4, 1, 2),  -- level-2 Boney (Mend+Fury)
        makeUnit(Samurai, 6, 1, 1, 1),  -- level-1 Samurai (Bloodthirst)
        makeUnit(Knight,  1, 2, 2, 1),
        makeUnit(Boney,   2, 4, 2, 1),
        makeUnit(Samurai, 3, 3, 2, 0),
    }
end
local function makeRound8Units_B()
    return makeRound8Units_A()  -- same composition, fresh objects
end

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
        -- Board A: reset existing objects (local player view)
        resetBoard(gridA8, unitsA8)

        -- Board B: recreate fresh objects (opponent applyOpponentMsg view)
        gridB8 = Grid()
        unitsB8 = makeRound8Units_B()
        for _, u in ipairs(unitsB8) do
            u.homeCol = u.col; u.homeRow = u.row
            gridB8:placeUnit(u.col, u.row, u)
        end
    end
end

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
