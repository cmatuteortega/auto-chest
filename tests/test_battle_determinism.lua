-- tests/test_battle_determinism.lua
-- Run with: lua tests/test_battle_determinism.lua  (from project root)
--
-- Verifies that two independent battle simulations started from the same
-- board state and RNG seed produce identical outcomes: same winner, same
-- per-unit health snapshot, and same step count.  This catches regressions
-- in the fixed-timestep loop, pathfinding tie-breaking, and target-selection
-- tie-breaking.

-- ── Package path ─────────────────────────────────────────────────────────────
package.path = package.path .. ";./?.lua;./?/init.lua"

-- ── Minimal LÖVE stubs (no graphics, no filesystem) ──────────────────────────
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
-- Stub Fonts global referenced by some draw paths
Fonts = { tiny = { getWidth = function() return 0 end, getHeight = function() return 0 end } }

-- ── Load modules ─────────────────────────────────────────────────────────────
local Grid   = require('src.grid')
local Knight = require('src.units.knight')
local Boney  = require('src.units.boney')

-- ── Board factory ────────────────────────────────────────────────────────────
-- Stub sprite table accepted by BaseUnit:new
local STUB_SPRITES = { front = {}, back = {}, dead = {} }

local function buildBoard()
    -- Simple 2v2 layout on an 8-row × 5-col grid:
    --   P1 (owner=1, rows 5-8): Knight row=8 col=3, Boney row=7 col=2
    --   P2 (owner=2, rows 1-4): Knight row=1 col=3, Boney row=2 col=4
    local grid = Grid()

    local units = {
        Knight(8, 3, 1, STUB_SPRITES),
        Boney(7,  2, 1, STUB_SPRITES),
        Knight(1, 3, 2, STUB_SPRITES),
        Boney(2,  4, 2, STUB_SPRITES),
    }

    for _, u in ipairs(units) do
        grid:placeUnit(u.col, u.row, u)
    end

    -- Fire onBattleStart hooks (Knight taunt, etc.)
    for _, u in ipairs(grid:getAllUnits()) do
        u:onBattleStart(grid)
    end

    return grid
end

-- ── Simulation runner ─────────────────────────────────────────────────────────
local FIXED_DT  = 1 / 60
local MAX_STEPS = 60 * 120  -- 2-minute safety cap

local function runSimulation(grid)
    for step = 1, MAX_STEPS do
        local allUnits = grid:getAllUnits()
        for _, unit in ipairs(allUnits) do
            unit:update(FIXED_DT, grid)
        end

        local p1Alive, p2Alive = 0, 0
        for _, unit in ipairs(allUnits) do
            if not unit.isDead then
                if unit.owner == 1 then p1Alive = p1Alive + 1
                else                    p2Alive = p2Alive + 1
                end
            end
        end

        if p1Alive == 0 or p2Alive == 0 then
            return (p1Alive > 0 and 1 or 2), step, allUnits
        end
    end
    -- Timed out (draw)
    return 0, MAX_STEPS, grid:getAllUnits()
end

-- ── Health snapshot helper ────────────────────────────────────────────────────
local function healthSnapshot(allUnits)
    local entries = {}
    for _, u in ipairs(allUnits) do
        table.insert(entries, string.format("%d:%s:%d", u.owner, u.unitType, u.health))
    end
    table.sort(entries)
    return table.concat(entries, "|")
end

-- ── Run two independent simulations ──────────────────────────────────────────
math.randomseed(42)
local gridA = buildBoard()

math.randomseed(42)
local gridB = buildBoard()

local winnerA, stepsA, unitsA = runSimulation(gridA)
local winnerB, stepsB, unitsB = runSimulation(gridB)

-- ── Assertions ───────────────────────────────────────────────────────────────
local passed = true

local function check(label, a, b)
    if a ~= b then
        io.write(string.format("FAIL [%s]\n  run A: %s\n  run B: %s\n", label, tostring(a), tostring(b)))
        passed = false
    else
        io.write(string.format("PASS [%s]: %s\n", label, tostring(a)))
    end
end

check("winner",          winnerA, winnerB)
check("step_count",      stepsA,  stepsB)
check("health_snapshot", healthSnapshot(unitsA), healthSnapshot(unitsB))

if passed then
    print("\nAll determinism tests passed.")
    os.exit(0)
else
    print("\nDeterminism test FAILED — simulation is non-deterministic.")
    os.exit(1)
end
