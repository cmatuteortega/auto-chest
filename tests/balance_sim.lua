-- tests/balance_sim.lua
-- Run with: lua tests/balance_sim.lua  (from project root)
--
-- Runs symmetric, equal-budget P1-vs-P2 battle simulations across:
--   1. Random armies (both sides identical budget, random composition)
--   2. Heuristic armies (ranged in back, tanks in front, various archetypes)
--   3. All-unit matchups (every unit vs every other unit, mono vs mono)
--   4. Upgrade path sweeps (best path per unit)
--   5. Stat searches (health/damage ranges per unit)
--
-- After all simulations writes: tests/balance_report_TIMESTAMP.md
-- with per-unit win rates, imbalance flags, and concrete tweak suggestions.

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
    filesystem = {
        read    = function() end,
        getInfo = function() return nil end,
    },
    window = { getMode = function() return 540, 960, {} end },
    timer  = { getTime = function() return 0 end },
    image  = { newImageData = function() return nil end },
}
Fonts = { tiny = { getWidth = function() return 0 end, getHeight = function() return 0 end } }

-- ── Tuning knobs ─────────────────────────────────────────────────────────────
local BUDGET         = 18    -- coins per army (full late-game budget)
-- Multi-budget: unit matrix and random matchups are averaged across these sizes
-- to capture early (1v1/2v2), mid (3v4), and late (full board) game fights.
local BUDGETS        = {6, 12, 18, 24}
local N_SIMS_RANDOM  = 200   -- random matchup simulations
local N_SIMS_MATCHUP = 40    -- per named-matchup simulations
local N_SIMS_UNIT    = 30    -- per unit isolation simulations
local N_SIMS_STAT    = 20    -- per stat-search value simulations
local FIXED_DT       = 1 / 60
local MAX_STEPS      = 60 * 120

-- Balance thresholds
local WIN_HIGH  = 0.62  -- flag if a unit/comp wins more than this
local WIN_LOW   = 0.38  -- flag if a unit/comp wins less than this
local TARGET_WIN = 0.50 -- ideal win rate

-- ── Unit metadata ─────────────────────────────────────────────────────────────
-- cost mirrors UnitRegistry.unitCosts
local UnitCosts = {
    boney=2, marrow=2, samurai=3, knight=3,
    marc=3,  bull=4,  mage=4,   amalgam=4, humerus=5, clavicula=4,
    bonk=3,  tomb=3,
}

-- Role: "tank" = high-hp melee, "melee" = standard melee, "ranged" = ranged attacker
-- Used by the heuristic army builder to place units correctly.
local UnitRole = {
    knight    = "tank",
    bull      = "tank",
    humerus   = "tank",
    amalgam   = "tank",
    boney     = "melee",
    samurai   = "melee",
    marrow    = "ranged",
    marc      = "ranged",
    mage      = "ranged",
    clavicula = "ranged",
    bonk      = "melee",
    tomb      = "support",
}

-- Base stats for tweak suggestions (mirrors unit constructors)
local UnitBaseStats = {
    knight    = { health=12, damage=1,  attackSpeed=1.00 },
    boney     = { health=7,  damage=1,  attackSpeed=1.00 },
    samurai   = { health=10, damage=1,  attackSpeed=1.10 },
    marrow    = { health=9,  damage=1,  attackSpeed=0.85 },
    marc      = { health=10, damage=1,  attackSpeed=0.75 },
    bull      = { health=13, damage=2,  attackSpeed=0.65 },
    mage      = { health=9,  damage=1,  attackSpeed=0.55 },
    amalgam   = { health=13, damage=3,  attackSpeed=0.45 },
    humerus   = { health=22, damage=4,  attackSpeed=0.35 },
    clavicula = { health=9,  damage=1,  attackSpeed=0.65 },
    bonk      = { health=11, damage=1,  attackSpeed=0.70 },
    tomb      = { health=15, damage=0,  attackSpeed=0.00 },
}

-- ── Load modules ─────────────────────────────────────────────────────────────
local Grid = require('src.grid')

local UnitClasses = {
    boney     = require('src.units.boney'),
    marrow    = require('src.units.marrow'),
    samurai   = require('src.units.samurai'),
    knight    = require('src.units.knight'),
    marc      = require('src.units.marc'),
    bull      = require('src.units.bull'),
    mage      = require('src.units.mage'),
    amalgam   = require('src.units.amalgam'),
    humerus   = require('src.units.humerus'),
    clavicula = require('src.units.clavicula'),
    bonk      = require('src.units.bonk'),
    tomb      = require('src.units.tomb'),
}

local STUB_SPRITES = { front = {}, back = {}, dead = {} }

-- ── Upgrade names ─────────────────────────────────────────────────────────────
local UpgradeNames = {}
for unitType, UnitClass in pairs(UnitClasses) do
    local dummy = UnitClass(1, 1, 1, STUB_SPRITES)
    UpgradeNames[unitType] = {}
    for i, u in ipairs(dummy.upgradeTree or {}) do
        UpgradeNames[unitType][i] = u.name or ("U"..i)
    end
end

-- ── StatOverrides (used by stat search) ──────────────────────────────────────
local StatOverrides = {}
for t in pairs(UnitClasses) do StatOverrides[t] = {} end

-- ── createUnit ────────────────────────────────────────────────────────────────
local function createUnit(unitType, row, col, owner, level, upgradePath)
    local unit = UnitClasses[unitType](row, col, owner, STUB_SPRITES)
    local ov = StatOverrides[unitType] or {}
    if ov.health      then unit.health=ov.health; unit.maxHealth=ov.health; unit.baseHealth=ov.health end
    if ov.damage      then unit.damage=ov.damage; unit.baseDamage=ov.damage end
    if ov.attackSpeed then unit.attackSpeed=ov.attackSpeed; unit.baseAttackSpeed=ov.attackSpeed end
    local lvl = level or 0
    if lvl > 0 then
        if upgradePath then
            for i = 1, math.min(lvl, #upgradePath) do unit:upgrade(upgradePath[i]) end
        else
            for i = 1, lvl do unit:upgrade(i) end
        end
    end
    unit.homeCol = col
    unit.homeRow = row
    return unit
end

-- ── runBattle ─────────────────────────────────────────────────────────────────
local function runBattle(grid)
    for step = 1, MAX_STEPS do
        local allUnits = grid:getAllUnits()
        for _, unit in ipairs(allUnits) do unit:update(FIXED_DT, grid) end
        local p1, p2 = 0, 0
        for _, unit in ipairs(allUnits) do
            if not unit.isDead then
                if unit.owner == 1 then p1=p1+1 else p2=p2+1 end
            end
        end
        if p1 == 0 or p2 == 0 then
            return (p1 > 0 and 1 or 2), step, allUnits
        end
    end
    return 0, MAX_STEPS, grid:getAllUnits()
end

-- ── runMatchup ────────────────────────────────────────────────────────────────
-- armyP1: list of {unitType, col, row, level, upgradePath}  (rows 5-8)
-- armyP2: list of {unitType, col, row, level, upgradePath}  (rows 1-4)
-- Returns { p1Wins, p2Wins, draws, totalSteps, totalSims }
local function runMatchup(armyP1, armyP2, nSims)
    local res = { p1Wins=0, p2Wins=0, draws=0, totalSteps=0, totalSims=nSims }
    for sim = 1, nSims do
        local seed = sim * 1013 + 37
        local grid = Grid()
        for _, e in ipairs(armyP1) do
            grid:placeUnit(e.col, e.row, createUnit(e.unitType, e.row, e.col, 1, e.level, e.upgradePath))
        end
        for _, e in ipairs(armyP2) do
            grid:placeUnit(e.col, e.row, createUnit(e.unitType, e.row, e.col, 2, e.level, e.upgradePath))
        end
        math.randomseed(seed)
        for _, u in ipairs(grid:getAllUnits()) do u:onBattleStart(grid) end
        math.randomseed(seed)
        local winner, steps = runBattle(grid)
        res.totalSteps = res.totalSteps + steps
        if winner == 1 then res.p1Wins = res.p1Wins + 1
        elseif winner == 2 then res.p2Wins = res.p2Wins + 1
        else res.draws = res.draws + 1 end
    end
    return res
end

-- ── Grid placement helpers ────────────────────────────────────────────────────
-- P1 rows: 5-8 (row 8 = frontline closest to P2, row 5 = backline)
-- P2 rows: 1-4 (row 1 = frontline closest to P1, row 4 = backline)
-- Front row for P1 = row 8. Back row for P1 = row 5.
-- Front row for P2 = row 1. Back row for P2 = row 4.

local P1_FRONT = { {col=2,row=8},{col=3,row=8},{col=4,row=8},{col=1,row=8},{col=5,row=8} }
local P1_BACK  = { {col=2,row=6},{col=3,row=6},{col=4,row=6},{col=1,row=6},{col=5,row=6},
                   {col=2,row=5},{col=3,row=5},{col=4,row=5},{col=1,row=5},{col=5,row=5} }
local P1_MID   = { {col=2,row=7},{col=3,row=7},{col=4,row=7},{col=1,row=7},{col=5,row=7} }

local P2_FRONT = { {col=2,row=1},{col=3,row=1},{col=4,row=1},{col=1,row=1},{col=5,row=1} }
local P2_BACK  = { {col=2,row=3},{col=3,row=3},{col=4,row=3},{col=1,row=3},{col=5,row=3},
                   {col=2,row=4},{col=3,row=4},{col=4,row=4},{col=1,row=4},{col=5,row=4} }
local P2_MID   = { {col=2,row=2},{col=3,row=2},{col=4,row=2},{col=1,row=2},{col=5,row=2} }

-- ── Army builders ─────────────────────────────────────────────────────────────

-- Heuristic army: tanks go front, ranged go back, melee fill middle.
-- unitList = list of {unitType, level, upgradePath}. owner = 1 or 2.
local function buildHeuristicArmy(unitList, owner)
    local front = owner == 1 and P1_FRONT or P2_FRONT
    local mid   = owner == 1 and P1_MID   or P2_MID
    local back  = owner == 1 and P1_BACK  or P2_BACK

    local tanks   = {}
    local melees  = {}
    local rangeds = {}
    for _, u in ipairs(unitList) do
        local role = UnitRole[u.unitType] or "melee"
        if role == "tank"   then table.insert(tanks, u)
        elseif role == "ranged" then table.insert(rangeds, u)
        else table.insert(melees, u) end
    end

    local army = {}
    -- Walk tank slots, then mid for melee, then back for ranged
    local frontIdx, midIdx, backIdx = 1, 1, 1

    -- Place tanks in front
    for _, u in ipairs(tanks) do
        if frontIdx > #front then break end
        local pos = front[frontIdx]; frontIdx = frontIdx + 1
        table.insert(army, { unitType=u.unitType, col=pos.col, row=pos.row,
                              level=u.level or 0, upgradePath=u.upgradePath })
    end
    -- Place melee in mid (or front overflow)
    for _, u in ipairs(melees) do
        if midIdx <= #mid then
            local pos = mid[midIdx]; midIdx = midIdx + 1
            table.insert(army, { unitType=u.unitType, col=pos.col, row=pos.row,
                                  level=u.level or 0, upgradePath=u.upgradePath })
        elseif frontIdx <= #front then
            local pos = front[frontIdx]; frontIdx = frontIdx + 1
            table.insert(army, { unitType=u.unitType, col=pos.col, row=pos.row,
                                  level=u.level or 0, upgradePath=u.upgradePath })
        end
    end
    -- Place ranged in back
    for _, u in ipairs(rangeds) do
        if backIdx <= #back then
            local pos = back[backIdx]; backIdx = backIdx + 1
            table.insert(army, { unitType=u.unitType, col=pos.col, row=pos.row,
                                  level=u.level or 0, upgradePath=u.upgradePath })
        end
    end
    return army
end

-- Random army: fill budget randomly, equal budget both sides.
-- seed is used for unit-type selection, owner determines row zone.
local function buildRandomArmy(budget, owner, seed)
    math.randomseed(seed)
    local allTypes = {}
    for t in pairs(UnitCosts) do table.insert(allTypes, t) end
    table.sort(allTypes)

    local unitList = {}
    local remaining = budget
    -- Try to place units until budget runs out (max 15 attempts to avoid infinite loop)
    local attempts = 0
    while remaining > 0 and attempts < 30 do
        attempts = attempts + 1
        local affordable = {}
        for _, t in ipairs(allTypes) do
            if UnitCosts[t] <= remaining then table.insert(affordable, t) end
        end
        if #affordable == 0 then break end
        local pick = affordable[math.random(#affordable)]
        table.insert(unitList, { unitType=pick, level=0 })
        remaining = remaining - UnitCosts[pick]
    end
    return buildHeuristicArmy(unitList, owner)
end

-- Mono army: all one unit type, budget-capped, heuristic placement.
local function buildMonoArmy(unitType, budget, owner, level, upgradePath)
    local cost = UnitCosts[unitType] or 3
    local unitList = {}
    local remaining = budget
    while remaining >= cost do
        table.insert(unitList, { unitType=unitType, level=level or 0, upgradePath=upgradePath })
        remaining = remaining - cost
    end
    return buildHeuristicArmy(unitList, owner)
end

-- ── Archetype armies ──────────────────────────────────────────────────────────
-- Each archetype is defined as a unit list; buildHeuristicArmy handles placement.
-- Budget is enforced at definition time (sum of UnitCosts).

local ARCHETYPES = {
    -- Boney swarm: 9x boney = 18 coins (cost 2 each)
    boney_swarm = {
        { unitType="boney" }, { unitType="boney" }, { unitType="boney" },
        { unitType="boney" }, { unitType="boney" }, { unitType="boney" },
        { unitType="boney" }, { unitType="boney" }, { unitType="boney" },
    },
    -- Castle rush: 6x knight = 18 coins
    knight_wall = {
        { unitType="knight" }, { unitType="knight" }, { unitType="knight" },
        { unitType="knight" }, { unitType="knight" }, { unitType="knight" },
    },
    -- Ranged squad: 9x marrow = 18 coins (cost 2 each)
    marrow_squad = {
        { unitType="marrow" }, { unitType="marrow" }, { unitType="marrow" },
        { unitType="marrow" }, { unitType="marrow" }, { unitType="marrow" },
        { unitType="marrow" }, { unitType="marrow" }, { unitType="marrow" },
    },
    -- Tanky front + ranged back: 2x humerus(10) + 2x marc(6) + 1x boney(2) = 18
    tank_ranged = {
        { unitType="humerus" }, { unitType="humerus" },
        { unitType="marc" },    { unitType="marc" },
        { unitType="boney" },
    },
    -- Mixed: 2x knight(6) + 1x mage(4) + 2x boney(6) + 1x samurai(3) = 19 (~budget)
    classic_mixed = {
        { unitType="knight" },  { unitType="knight" },
        { unitType="mage" },
        { unitType="boney" },   { unitType="boney" },
        { unitType="samurai" },
    },
    -- Skeleton themed: 3x boney(9) + 2x clavicula(6) + 1x marrow(2) = 17 (~budget)
    skeleton_team = {
        { unitType="boney" }, { unitType="boney" }, { unitType="boney" },
        { unitType="clavicula" }, { unitType="clavicula" },
        { unitType="marrow" },
    },
    -- Castle themed: 2x bull(8) + 1x humerus(5) + 1x marc(3) + 1x samurai(3) = 19 (~budget)
    castle_charge = {
        { unitType="bull" },    { unitType="bull" },
        { unitType="humerus" },
        { unitType="marc" },
        { unitType="samurai" },
    },
    -- Invulnerable core: 2x amalgam(8) + 2x mage(8) = 16 (~budget)
    amalgam_shield = {
        { unitType="amalgam" }, { unitType="amalgam" },
        { unitType="mage" },    { unitType="mage" },
    },
    -- Upgraded front: knight L2 (guardian+ironwill) + boney L2 + samurai L1
    upgraded_front = {
        { unitType="knight",  level=2, upgradePath={1,2} },
        { unitType="knight",  level=2, upgradePath={1,2} },
        { unitType="boney",   level=2, upgradePath={2,3} },
        { unitType="samurai", level=1, upgradePath={1} },
    },
}

-- ── computeUnitWinRates ───────────────────────────────────────────────────────
-- For each unit: runs mono-vs-each-other-unit matchups (all at level 0) and
-- mono-vs-mirror (same unit on both sides for symmetry check).
-- Returns { [unitType] = { vsUnit = {wr, steps}, overall = wr } }
local function computeUnitWinRates(nSims)
    local unitTypes = {}
    for t in pairs(UnitClasses) do table.insert(unitTypes, t) end
    table.sort(unitTypes)

    -- matrix[a][b] = win rate of mono-a vs mono-b averaged across BUDGETS
    local matrix = {}
    for _, a in ipairs(unitTypes) do
        matrix[a] = {}
        for _, b in ipairs(unitTypes) do
            local totalWR, totalSteps, count = 0, 0, 0
            for _, budget in ipairs(BUDGETS) do
                -- Skip if either unit can't afford even one at this budget
                if (UnitCosts[a] or 3) <= budget and (UnitCosts[b] or 3) <= budget then
                    local armyA = buildMonoArmy(a, budget, 1, 0, nil)
                    local armyB = buildMonoArmy(b, budget, 2, 0, nil)
                    local r = runMatchup(armyA, armyB, nSims)
                    totalWR    = totalWR    + r.p1Wins / r.totalSims
                    totalSteps = totalSteps + r.totalSteps / r.totalSims
                    count = count + 1
                end
            end
            local n = math.max(count, 1)
            matrix[a][b] = { wr = totalWR / n, steps = totalSteps / n }
        end
    end

    -- Compute overall win rate per unit (average across all opponents)
    local overallWR = {}
    for _, a in ipairs(unitTypes) do
        local total = 0
        for _, b in ipairs(unitTypes) do
            total = total + matrix[a][b].wr
        end
        overallWR[a] = total / #unitTypes
    end

    return matrix, overallWR, unitTypes
end

-- ── computeLevelWinRates ──────────────────────────────────────────────────────
-- For each unit: runs mono-vs-mirror at levels 0, 1, 2 (mirror uses same level).
-- Returns { [unitType] = { [0]=wr, [1]=wr, [2]=wr } }
local function computeLevelWinRates(nSims)
    local results = {}
    for unitType in pairs(UnitClasses) do
        results[unitType] = {}
        for level = 0, 2 do
            local armyP1 = buildMonoArmy(unitType, BUDGET, 1, level, nil)
            local armyP2 = buildMonoArmy(unitType, BUDGET, 2, level, nil)
            local r = runMatchup(armyP1, armyP2, nSims)
            -- Store win rate of L(level) vs unupgraded (L0)
            if level == 0 then
                -- vs same level: should be ~50%
                results[unitType][level] = { mirror_wr = r.p1Wins / r.totalSims }
            else
                -- vs level 0 opponent to measure upgrade power
                local armyL0 = buildMonoArmy(unitType, BUDGET, 2, 0, nil)
                local r2 = runMatchup(armyP1, armyL0, nSims)
                results[unitType][level] = {
                    mirror_wr = r.p1Wins / r.totalSims,
                    vs_l0_wr  = r2.p1Wins / r2.totalSims,
                }
            end
        end
    end
    return results
end

-- ── computeUpgradePathWinRates ────────────────────────────────────────────────
-- For select units: tests all 1- and 2-upgrade paths vs unupgraded mirror.
-- Returns { [unitType] = { [{pathkey}] = { wr, steps, label } } }
local ALL_PATHS_1  = {{1},{2},{3}}
local ALL_PATHS_2  = {{1,2},{1,3},{2,3}}

local function computeUpgradePathWinRates(nSims)
    local results = {}
    for unitType in pairs(UnitClasses) do
        results[unitType] = {}
        local names = UpgradeNames[unitType] or {}
        if #names == 0 then goto continue end

        local function pathLabel(path)
            local parts = {}
            for _, idx in ipairs(path) do
                table.insert(parts, names[idx] or ("U"..idx))
            end
            return table.concat(parts, "+")
        end

        -- Baseline: L0 vs L0 mirror
        local baseArmy = buildMonoArmy(unitType, BUDGET, 2, 0, nil)

        for _, path in ipairs(ALL_PATHS_1) do
            if names[path[1]] then  -- skip if upgrade doesn't exist
                local key = table.concat(path, "_")
                local army = buildMonoArmy(unitType, BUDGET, 1, 1, path)
                local r = runMatchup(army, baseArmy, nSims)
                results[unitType][key] = {
                    wr    = r.p1Wins / r.totalSims,
                    steps = r.totalSteps / r.totalSims,
                    label = pathLabel(path),
                }
            end
        end
        for _, path in ipairs(ALL_PATHS_2) do
            if names[path[1]] and names[path[2]] then
                local key = table.concat(path, "_")
                local army = buildMonoArmy(unitType, BUDGET, 1, 2, path)
                local r = runMatchup(army, baseArmy, nSims)
                results[unitType][key] = {
                    wr    = r.p1Wins / r.totalSims,
                    steps = r.totalSteps / r.totalSims,
                    label = pathLabel(path),
                }
            end
        end
        ::continue::
    end
    return results
end

-- ── computeArchetypeMatchups ──────────────────────────────────────────────────
-- Runs every archetype vs every other archetype (symmetric: also mirror match).
-- Returns { [nameA_vs_nameB] = { wr_a, steps } }
local function computeArchetypeMatchups(nSims)
    local names = {}
    for n in pairs(ARCHETYPES) do table.insert(names, n) end
    table.sort(names)

    local results = {}
    for i = 1, #names do
        for j = i, #names do
            local na, nb = names[i], names[j]
            local armyA_p1 = buildHeuristicArmy(ARCHETYPES[na], 1)
            local armyB_p2 = buildHeuristicArmy(ARCHETYPES[nb], 2)
            local r = runMatchup(armyA_p1, armyB_p2, nSims)
            local key = na .. "_vs_" .. nb
            results[key] = {
                nameA = na, nameB = nb,
                wr_a  = r.p1Wins / r.totalSims,
                wr_b  = r.p2Wins / r.totalSims,
                draws = r.draws  / r.totalSims,
                steps = r.totalSteps / r.totalSims,
            }
        end
    end
    return results, names
end

-- ── computeRandomMatchupWinRates ──────────────────────────────────────────────
-- Per-unit participation win rate from random vs random matches.
-- Tracks each unit type's win rate when it appears in the winning army.
-- Returns { [unitType] = { appeared, wonWith, winRate } }
local function computeRandomMatchupWinRates(nSims)
    local unitStats = {}
    for t in pairs(UnitClasses) do
        unitStats[t] = { appeared=0, wonWith=0 }
    end
    local overallP1Wins = 0

    for sim = 1, nSims do
        -- Cycle through BUDGETS so we cover early/mid/late game army sizes
        local budget = BUDGETS[((sim - 1) % #BUDGETS) + 1]
        -- Different seeds for P1 and P2 so they get different compositions
        local armyP1 = buildRandomArmy(budget, 1, sim * 7919)
        local armyP2 = buildRandomArmy(budget, 2, sim * 6271 + 1)
        local r = runMatchup(armyP1, armyP2, 1)

        local winner = (r.p1Wins > 0) and 1 or (r.p2Wins > 0 and 2 or 0)
        if winner == 1 then overallP1Wins = overallP1Wins + 1 end

        -- Track unit appearances
        for _, e in ipairs(armyP1) do
            unitStats[e.unitType].appeared = unitStats[e.unitType].appeared + 1
            if winner == 1 then
                unitStats[e.unitType].wonWith = unitStats[e.unitType].wonWith + 1
            end
        end
        for _, e in ipairs(armyP2) do
            unitStats[e.unitType].appeared = unitStats[e.unitType].appeared + 1
            if winner == 2 then
                unitStats[e.unitType].wonWith = unitStats[e.unitType].wonWith + 1
            end
        end
    end

    for _, s in pairs(unitStats) do
        s.winRate = s.appeared > 0 and (s.wonWith / s.appeared) or 0.5
    end
    return unitStats, overallP1Wins / nSims
end

-- ── computeStatSearch ────────────────────────────────────────────────────────
-- For each unit: search health and damage ranges vs its own mirror.
-- Returns { [unitType] = { health=[{v,wr}], damage=[{v,wr}] } }
local function computeStatSearch(nSims)
    local results = {}
    local base = UnitBaseStats

    for unitType, stats in pairs(base) do
        results[unitType] = { health={}, damage={} }

        -- Health search: ±25% and ±50% of base
        local bh = stats.health
        -- Health search: ±10% and ±20% only — small nudges, not drastic rewrites
        local healthVals = {
            math.max(1, math.floor(bh * 0.80)),
            math.max(1, math.floor(bh * 0.90)),
            bh,
            math.floor(bh * 1.10),
            math.floor(bh * 1.20),
        }
        -- Remove duplicates
        local seen = {}
        local uniqH = {}
        for _, v in ipairs(healthVals) do
            if not seen[v] then seen[v]=true; table.insert(uniqH, v) end
        end

        for _, v in ipairs(uniqH) do
            -- P1 gets the tested health value; P2 uses base stats (no override)
            StatOverrides[unitType].health = v
            local armyP1 = buildMonoArmy(unitType, BUDGET, 1, 0, nil)
            StatOverrides[unitType].health = nil
            local armyP2base = buildMonoArmy(unitType, BUDGET, 2, 0, nil)

            -- For stat search: P1 = tested stat, P2 = base stat (no override)
            local r = runMatchup(armyP1, armyP2base, nSims)
            table.insert(results[unitType].health, {
                value = v,
                isBase = (v == bh),
                wr    = r.p1Wins / r.totalSims,
                steps = r.totalSteps / r.totalSims,
            })
        end

        -- Damage search: ±1 only — one step at a time
        local bd = stats.damage
        local damageVals = {}
        seen = {}
        for _, d in ipairs({ math.max(1, bd-1), bd, bd+1 }) do
            if not seen[d] then seen[d]=true; table.insert(damageVals, d) end
        end
        -- Build P2 army once at base stats (no override)
        local armyP2baseDmg = buildMonoArmy(unitType, BUDGET, 2, 0, nil)
        for _, v in ipairs(damageVals) do
            StatOverrides[unitType].damage = v
            local armyP1 = buildMonoArmy(unitType, BUDGET, 1, 0, nil)
            StatOverrides[unitType].damage = nil
            local r = runMatchup(armyP1, armyP2baseDmg, nSims)
            table.insert(results[unitType].damage, {
                value = v,
                isBase = (v == bd),
                wr    = r.p1Wins / r.totalSims,
                steps = r.totalSteps / r.totalSims,
            })
        end
    end

    return results
end

-- ── Tweak suggestion engine ───────────────────────────────────────────────────
-- Given all simulation results, generates concrete suggestions per unit.
-- Returns { [unitType] = { status, suggestions=[] } }
-- status: "balanced" | "overtuned" | "undertuned"
local function generateTweaks(overallWR, levelWR, upgradePathWR, randomWR, statSearch)
    local tweaks = {}

    local unitTypes = {}
    for t in pairs(UnitClasses) do table.insert(unitTypes, t) end
    table.sort(unitTypes)

    for _, unitType in ipairs(unitTypes) do
        local suggestions = {}
        local signals = {}

        -- 1. Overall win rate signal
        local wr = overallWR[unitType] or 0.5
        if wr > WIN_HIGH then
            table.insert(signals, string.format("overall win rate %.0f%% (above %.0f%% threshold)", wr*100, WIN_HIGH*100))
        elseif wr < WIN_LOW then
            table.insert(signals, string.format("overall win rate %.0f%% (below %.0f%% threshold)", wr*100, WIN_LOW*100))
        end

        -- 2. Random matchup signal
        local rwr = randomWR[unitType] and randomWR[unitType].winRate or 0.5
        if rwr > WIN_HIGH then
            table.insert(signals, string.format("random matchup win rate %.0f%%", rwr*100))
        elseif rwr < WIN_LOW then
            table.insert(signals, string.format("random matchup win rate %.0f%%", rwr*100))
        end

        -- 3. Upgrade spike signal: if L1 vs L0 > 80%, upgrades are too powerful
        local lw = levelWR[unitType]
        if lw and lw[1] and lw[1].vs_l0_wr then
            local upgradeWR = lw[1].vs_l0_wr
            if upgradeWR > 0.80 then
                table.insert(signals, string.format("level 1 beats level 0 %.0f%% of the time (upgrades very powerful)", upgradeWR*100))
                table.insert(suggestions, "Consider reducing the 1.3× upgrade stat multiplier for this unit, or making upgrades cost more coins.")
            elseif upgradeWR < 0.55 then
                table.insert(signals, string.format("level 1 only beats level 0 %.0f%% (upgrades weak)", upgradeWR*100))
                table.insert(suggestions, "Upgrades feel underpowered — consider stronger ability effects at L1.")
            end
        end

        -- 4. Stat search: suggest small nudges only when unit is flagged as imbalanced.
        -- Only emit a suggestion when the best candidate differs from base AND
        -- the unit's overall or random win rate is outside the balanced range.
        local ss = statSearch[unitType]
        local baseStats = UnitBaseStats[unitType]
        local unitIsImbalanced = (wr > WIN_HIGH or wr < WIN_LOW or rwr > WIN_HIGH or rwr < WIN_LOW)
        if ss and baseStats and unitIsImbalanced then
            -- Health: pick the candidate closest to TARGET_WIN win rate.
            -- Only suggest if it differs from base (the search range is already ±20%).
            local bestH, bestHDelta = baseStats.health, math.huge
            for _, entry in ipairs(ss.health) do
                local delta = math.abs(entry.wr - TARGET_WIN)
                if delta < bestHDelta then
                    bestHDelta = delta
                    bestH = entry.value
                end
            end
            -- Only emit if the suggestion actually moves in the right direction
            -- (overtuned → reduce, undertuned → increase) and differs from base.
            local healthDirOk = (wr > WIN_HIGH and bestH < baseStats.health)
                             or (wr < WIN_LOW  and bestH > baseStats.health)
            if bestH ~= baseStats.health and healthDirOk then
                local dir = bestH > baseStats.health and "increase" or "reduce"
                table.insert(suggestions, string.format(
                    "**Health**: %s base HP from %d → **%d** (~%.0f%% change)",
                    dir, baseStats.health, bestH,
                    math.abs(bestH - baseStats.health) / baseStats.health * 100))
            end

            -- Damage: same logic — only fire when direction matches imbalance.
            local bestD, bestDDelta = baseStats.damage, math.huge
            for _, entry in ipairs(ss.damage) do
                local delta = math.abs(entry.wr - TARGET_WIN)
                if delta < bestDDelta then
                    bestDDelta = delta
                    bestD = entry.value
                end
            end
            local dmgDirOk = (wr > WIN_HIGH and bestD < baseStats.damage)
                          or (wr < WIN_LOW  and bestD > baseStats.damage)
            if bestD ~= baseStats.damage and dmgDirOk then
                local dir = bestD > baseStats.damage and "increase" or "reduce"
                table.insert(suggestions, string.format(
                    "**Damage**: %s base damage from %d → **%d**",
                    dir, baseStats.damage, bestD))
            end
        end

        -- 5. Cost suggestion based on overall win rate
        local currentCost = UnitCosts[unitType] or 3
        if wr > WIN_HIGH + 0.10 then
            table.insert(suggestions, string.format(
                "**Cost**: raise from %d → **%d** coins (unit wins too frequently for its price)",
                currentCost, currentCost + 1))
        elseif wr < WIN_LOW - 0.10 then
            table.insert(suggestions, string.format(
                "**Cost**: lower from %d → **%d** coins (unit rarely wins, too expensive for what it offers)",
                currentCost, math.max(1, currentCost - 1)))
        end

        -- 6. Best upgrade path suggestion
        local pathStats = upgradePathWR[unitType]
        if pathStats then
            local bestPath, bestPathWR = nil, -1
            local worstPath, worstPathWR = nil, math.huge
            for _, s in pairs(pathStats) do
                if s.wr > bestPathWR  then bestPathWR  = s.wr;  bestPath  = s.label end
                if s.wr < worstPathWR then worstPathWR = s.wr;  worstPath = s.label end
            end
            if bestPath and bestPathWR > WIN_HIGH then
                table.insert(suggestions, string.format(
                    "**Upgrades**: path `%s` wins %.0f%% vs L0 — consider nerfing one of these abilities.",
                    bestPath, bestPathWR * 100))
            end
            if worstPath and worstPathWR < WIN_LOW then
                table.insert(suggestions, string.format(
                    "**Upgrades**: path `%s` only wins %.0f%% vs L0 — consider buffing one of these abilities.",
                    worstPath, worstPathWR * 100))
            end
        end

        -- Determine status
        local status = "balanced"
        if wr > WIN_HIGH or rwr > WIN_HIGH then
            status = "overtuned"
        elseif wr < WIN_LOW or rwr < WIN_LOW then
            status = "undertuned"
        end
        if #suggestions == 0 and status ~= "balanced" then
            if status == "overtuned" then
                table.insert(suggestions, "Unit is performing above average. Review passive ability strength.")
            else
                table.insert(suggestions, "Unit is underperforming. Review whether passive triggers reliably.")
            end
        end

        tweaks[unitType] = {
            status      = status,
            overallWR   = wr,
            randomWR    = rwr,
            signals     = signals,
            suggestions = suggestions,
        }
    end
    return tweaks
end

-- ── Markdown report writer ────────────────────────────────────────────────────
local function writeMarkdownReport(path, tweaks, unitMatrix, unitTypes,
                                   levelWR, upgradePathWR, archetypeResults,
                                   archetypeNames, randomP1WR)
    local lines = {}
    local function w(s) table.insert(lines, s or "") end

    -- Timestamp
    local ts = os.date("%Y-%m-%d %H:%M")

    w("# AutoChest Balance Report")
    w(string.format("> Generated: %s  |  Budget: %d coins/player  |  Sims: random=%d, matchup=%d, unit=%d",
        ts, BUDGET, N_SIMS_RANDOM, N_SIMS_MATCHUP, N_SIMS_UNIT))
    w("")
    w("---")
    w("")

    -- Summary table
    w("## Summary: Unit Balance Status")
    w("")
    w("| Unit | Cost | Overall WR | Random WR | Status |")
    w("|------|------|-----------|-----------|--------|")
    for _, unitType in ipairs(unitTypes) do
        local t = tweaks[unitType]
        local statusEmoji = t.status == "balanced" and "✅ balanced"
                         or t.status == "overtuned" and "🔴 overtuned"
                         or "🔵 undertuned"
        w(string.format("| **%s** | %d | %.0f%% | %.0f%% | %s |",
            unitType, UnitCosts[unitType] or 3,
            t.overallWR * 100, t.randomWR * 100, statusEmoji))
    end
    w("")

    -- Random matchup overview
    w("## Random Matchup Overview")
    w(string.format("Ran %d random symmetric matches (each side same budget, different random composition).", N_SIMS_RANDOM))
    w(string.format("P1 overall win rate in random matches: **%.0f%%** (expected ~50%%)", randomP1WR * 100))
    w("")

    -- Per-unit vs all matchup matrix
    w("## Unit vs Unit Win Rate Matrix")
    w("")
    w("*Row = P1 unit type (mono army), Column = P2 unit type (mono army), value = P1 win rate.*")
    w("*Diagonal = mirror match (same unit both sides), should be ~50%.*")
    w("")

    -- Header
    local headerCols = {}
    for _, b in ipairs(unitTypes) do
        table.insert(headerCols, b:sub(1,4))  -- abbreviate
    end
    w("| P1 \\ P2 | " .. table.concat(headerCols, " | ") .. " |")
    local sepCols = {}
    for _ in ipairs(unitTypes) do table.insert(sepCols, "---") end
    w("|---------|" .. table.concat(sepCols, "|") .. "|")

    for _, a in ipairs(unitTypes) do
        local row = { string.format("**%s**", a) }
        for _, b in ipairs(unitTypes) do
            local entry = unitMatrix[a] and unitMatrix[a][b]
            if entry then
                local wr = entry.wr
                local cell = string.format("%.0f%%", wr * 100)
                if wr > WIN_HIGH then cell = "**" .. cell .. "**" end
                if wr < WIN_LOW  then cell = "*"  .. cell .. "*"  end
                table.insert(row, cell)
            else
                table.insert(row, "--")
            end
        end
        w("| " .. table.concat(row, " | ") .. " |")
    end
    w("")

    -- Upgrade power table
    w("## Upgrade Power (Leveled vs Unleveled Mirror)")
    w("")
    w("*P1 = leveled unit, P2 = same unit at level 0. Win rate shows upgrade impact.*")
    w("*>62% = upgrades too powerful; <38% = upgrades too weak.*")
    w("")
    w("| Unit | L1 vs L0 | L2 vs L0 | L1 mirror | L2 mirror |")
    w("|------|----------|----------|-----------|-----------|")
    for _, unitType in ipairs(unitTypes) do
        local lw = levelWR[unitType]
        local l1v0 = lw and lw[1] and lw[1].vs_l0_wr
        local l2v0 = lw and lw[2] and lw[2].vs_l0_wr
        local l1m  = lw and lw[1] and lw[1].mirror_wr
        local l2m  = lw and lw[2] and lw[2].mirror_wr
        local function fmtWR(v)
            if not v then return "--" end
            local s = string.format("%.0f%%", v*100)
            if v > WIN_HIGH then s = "**"..s.."**" end
            if v < WIN_LOW  then s = "*"..s.."*" end
            return s
        end
        w(string.format("| **%s** | %s | %s | %s | %s |",
            unitType, fmtWR(l1v0), fmtWR(l2v0), fmtWR(l1m), fmtWR(l2m)))
    end
    w("")

    -- Upgrade path comparison
    w("## Upgrade Path Win Rates (vs Unupgraded Mirror)")
    w("")
    w("*Each path tested as P1 (upgraded) vs P2 (level 0 same unit). Win rate measures path power.*")
    w("")
    for _, unitType in ipairs(unitTypes) do
        local pathStats = upgradePathWR[unitType]
        if not pathStats or not next(pathStats) then goto nextUnit end
        w(string.format("### %s", unitType))
        w("")
        w("| Path | Win Rate | Avg Steps |")
        w("|------|----------|-----------|")
        -- Sort paths by win rate desc
        local pathList = {}
        for _, s in pairs(pathStats) do table.insert(pathList, s) end
        table.sort(pathList, function(a, b) return a.wr > b.wr end)
        for _, s in ipairs(pathList) do
            local wrStr = string.format("%.0f%%", s.wr*100)
            if s.wr > WIN_HIGH then wrStr = "**"..wrStr.."** 🔴" end
            if s.wr < WIN_LOW  then wrStr = "*"..wrStr.."* 🔵" end
            w(string.format("| %s | %s | %d |", s.label, wrStr, math.floor(s.steps)))
        end
        w("")
        ::nextUnit::
    end

    -- Archetype matchups
    w("## Archetype Matchup Matrix")
    w("")
    w("*Each archetype runs against every other archetype. Values show P1 (row) win rate.*")
    w("")
    w("| P1 \\ P2 | " .. table.concat(archetypeNames, " | ") .. " |")
    local asep = {}
    for _ in ipairs(archetypeNames) do table.insert(asep, "---") end
    w("|---------|" .. table.concat(asep, "|") .. "|")
    for _, na in ipairs(archetypeNames) do
        local row = { string.format("**%s**", na) }
        for _, nb in ipairs(archetypeNames) do
            local key = na .. "_vs_" .. nb
            local rkey = nb .. "_vs_" .. na
            if na == nb then
                table.insert(row, "--")
            elseif archetypeResults[key] then
                local wr = archetypeResults[key].wr_a
                local cell = string.format("%.0f%%", wr*100)
                if wr > WIN_HIGH then cell = "**"..cell.."**" end
                if wr < WIN_LOW  then cell = "*"..cell.."*" end
                table.insert(row, cell)
            elseif archetypeResults[rkey] then
                -- We ran nb vs na, so P1=nb; flip to get na's win rate = 1 - wr_b
                local wr = 1 - archetypeResults[rkey].wr_a
                local cell = string.format("%.0f%%", wr*100)
                if wr > WIN_HIGH then cell = "**"..cell.."**" end
                if wr < WIN_LOW  then cell = "*"..cell.."*" end
                table.insert(row, cell)
            else
                table.insert(row, "--")
            end
        end
        w("| " .. table.concat(row, " | ") .. " |")
    end
    w("")

    -- Per-unit tweak recommendations
    w("## Per-Unit Tweak Recommendations")
    w("")
    for _, unitType in ipairs(unitTypes) do
        local t = tweaks[unitType]
        local statusBadge = t.status == "balanced" and "✅"
                         or t.status == "overtuned" and "🔴"
                         or "🔵"
        w(string.format("### %s %s `cost: %d`", statusBadge, unitType, UnitCosts[unitType] or 3))
        w("")
        w(string.format("**Base stats**: HP=%d | DMG=%d | ATKSPD=%.2f",
            UnitBaseStats[unitType].health,
            UnitBaseStats[unitType].damage,
            UnitBaseStats[unitType].attackSpeed))
        w("")
        w(string.format("**Win rates**: overall=%.0f%% | random=%.0f%%",
            t.overallWR*100, t.randomWR*100))
        w("")
        if #t.signals > 0 then
            w("**Signals:**")
            for _, s in ipairs(t.signals) do
                w("- " .. s)
            end
            w("")
        end
        if #t.suggestions > 0 then
            w("**Suggested tweaks:**")
            for _, s in ipairs(t.suggestions) do
                w("- " .. s)
            end
        else
            w("No tweaks suggested — unit appears balanced.")
        end
        w("")
    end

    -- Methodology note
    w("---")
    w("")
    w("## Methodology")
    w("")
    w("- **Equal budget**: both players receive the same coin budget per match.")
    w("- **Heuristic placement**: tanks → front row, melee → mid row, ranged → back row.")
    w("- **Unit vs unit matrix**: mono-army of each type vs mono-army of every other type, same budget.")
    w("- **Random matches**: both sides compose randomly from all affordable units.")
    w("- **Archetype matches**: hand-crafted strategic compositions (swarm, wall, tank+ranged, etc.).")
    w("- **Stat search**: each unit tested at ±25%/±50% health and ±1/±2 damage vs its own unmodified mirror.")
    w("- **Upgrade paths**: all 1- and 2-upgrade combinations tested vs unupgraded same unit.")
    w("- **Balance thresholds**: >62% = overtuned, <38% = undertuned.")
    w("")

    -- Write file
    local f = io.open(path, "w")
    if not f then
        io.stderr:write("ERROR: could not write to " .. path .. "\n")
        return false
    end
    f:write(table.concat(lines, "\n"))
    f:write("\n")
    f:close()
    return true
end

-- ── Main ──────────────────────────────────────────────────────────────────────

io.write(string.format("\nAutoChest Balance Sim | budget=%d | random=%d matchup=%d unit=%d stat=%d\n\n",
    BUDGET, N_SIMS_RANDOM, N_SIMS_MATCHUP, N_SIMS_UNIT, N_SIMS_STAT))

io.write("1/6 Unit vs unit matrix...\n")
local unitMatrix, overallWR, unitTypes = computeUnitWinRates(N_SIMS_UNIT)

io.write("2/6 Upgrade level win rates...\n")
local levelWR = computeLevelWinRates(N_SIMS_UNIT)

io.write("3/6 Upgrade path win rates...\n")
local upgradePathWR = computeUpgradePathWinRates(N_SIMS_UNIT)

io.write("4/6 Archetype matchups...\n")
local archetypeResults, archetypeNames = computeArchetypeMatchups(N_SIMS_MATCHUP)

io.write("5/6 Random matchup participation rates...\n")
local randomUnitWR, randomP1WR = computeRandomMatchupWinRates(N_SIMS_RANDOM)

io.write("6/6 Stat search (health and damage ranges)...\n")
local statSearch = computeStatSearch(N_SIMS_STAT)

io.write("Generating tweak suggestions...\n")
local tweaks = generateTweaks(overallWR, levelWR, upgradePathWR, randomUnitWR, statSearch)

-- Write report
local timestamp = os.date("%Y%m%d_%H%M%S")
local reportPath = "tests/balance_report_" .. timestamp .. ".md"
io.write(string.format("Writing report to %s...\n", reportPath))

local ok = writeMarkdownReport(reportPath, tweaks, unitMatrix, unitTypes,
    levelWR, upgradePathWR, archetypeResults, archetypeNames, randomP1WR)

if ok then
    io.write(string.format("\nDone. Report written to: %s\n", reportPath))
else
    io.write("\nERROR: failed to write report.\n")
    os.exit(1)
end

os.exit(0)
