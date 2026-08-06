-- tests/balance_sim.lua
-- Run with: lua tests/balance_sim.lua [--quick | --full]   (from project root)
--
-- Runs symmetric, equal-budget P1-vs-P2 battle simulations across the ENTIRE
-- roster (units + costs are pulled live from src/unit_registry.lua, base stats
-- are harvested from each unit's constructor — nothing here can drift from the
-- game code):
--   1. Cost-curve regression (paper value: cost vs HP/DPS/range residuals)
--   2. All-unit matchups (every unit vs every other unit, mono vs mono)
--   3. Upgrade level & path sweeps
--   4. Buy-vs-upgrade economy (k upgraded units vs 2k/3k level-0, equal coins)
--   5. Archetype armies + random armies
--   6. Stat searches (health / damage / attack-speed nudges per unit)
--
-- After all simulations writes: tests/balance_report_TIMESTAMP.md
-- with per-unit win rates, imbalance flags, and concrete tweak suggestions.
--
-- Modes: --quick = fast smoke pass, default = balanced, --full = high sim counts.

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
        newShader    = function() return {} end,
        newQuad      = function() return {} end,
        setShader    = function() end,
        setScissor   = function() end,
        setColor     = function() end,
        setLineWidth = function() end,
        draw         = function() end,
        rectangle    = function() end,
        circle       = function() end,
        line         = function() end,
        polygon      = function() end,
        print        = function() end,
        printf       = function() end,
        setFont      = function() end,
        push         = function() end,
        pop          = function() end,
        translate    = function() end,
        scale        = function() end,
        rotate       = function() end,
        getWidth     = function() return 540 end,
        getHeight    = function() return 960 end,
    },
    filesystem = {
        read    = function() end,
        getInfo = function() return nil end,
    },
    window = { getMode = function() return 540, 960, {} end },
    timer  = { getTime = function() return 0 end },
    image  = { newImageData = function() return nil end },
    math   = { newRandomGenerator = function()
        return { random = math.random, setSeed = math.randomseed }
    end },
}
Fonts = { tiny = { getWidth = function() return 0 end, getHeight = function() return 0 end } }
---@diagnostic disable-next-line: lowercase-global
AudioManager = setmetatable({}, { __index = function() return function() end end })
-- Some units require the module directly instead of using the global —
-- pre-seed package.loaded so the real (love.audio-dependent) module never loads.
package.loaded['src.audio_manager'] = AudioManager

-- ── Tuning knobs ─────────────────────────────────────────────────────────────
local MODE = "default"
for _, a in ipairs(arg or {}) do
    if a == "--quick" then MODE = "quick" end
    if a == "--full"  then MODE = "full"  end
end

local BUDGET   = 18                  -- coins per army (full late-game budget)
-- Multi-budget: unit matrix is averaged across these sizes to capture early
-- (1v1/2v2), mid (3v4), and late (full board) game fights.
local BUDGETS  = { 6, 12, 18, 24 }

local N_SIMS_RANDOM, N_SIMS_MATCHUP, N_SIMS_UNIT, N_SIMS_STAT, N_SIMS_UPG
if MODE == "quick" then
    BUDGETS = { 12, 24 }
    N_SIMS_RANDOM, N_SIMS_MATCHUP, N_SIMS_UNIT, N_SIMS_STAT, N_SIMS_UPG = 40, 6, 2, 2, 3
elseif MODE == "full" then
    N_SIMS_RANDOM, N_SIMS_MATCHUP, N_SIMS_UNIT, N_SIMS_STAT, N_SIMS_UPG = 400, 40, 12, 10, 15
else
    N_SIMS_RANDOM, N_SIMS_MATCHUP, N_SIMS_UNIT, N_SIMS_STAT, N_SIMS_UPG = 200, 20, 5, 5, 8
end

local FIXED_DT        = 1 / 60
local MAX_STEPS       = 60 * 120
local STALEMATE_STEPS = 60 * 10   -- if the board fingerprint is unchanged for 10s → draw

-- Balance thresholds
local WIN_HIGH   = 0.62  -- flag if a unit/comp wins more than this
local WIN_LOW    = 0.38  -- flag if a unit/comp wins less than this
local TARGET_WIN = 0.50  -- ideal win rate

-- ── Load modules (single source of truth: the live registry) ────────────────
local UnitRegistry = require('src.unit_registry')
local Grid         = require('src.grid')

local UnitClasses = UnitRegistry.unitClasses
local UnitCosts   = {}   -- filtered to actual units (registry cost table also holds spells)
for t in pairs(UnitClasses) do
    UnitCosts[t] = UnitRegistry.unitCosts[t] or 3
end

-- Sprite stub covers every optional sprite field any unit constructor touches
local STUB_SPRITES = {
    front = {}, back = {}, dead = {},
    freeForm   = { front = {}, back = {}, dead = {} },  -- sinner
    directions = {},                                     -- directional units
}

-- ── Base stats harvested from live constructors ──────────────────────────────
local UnitBaseStats = {}
for t, UnitClass in pairs(UnitClasses) do
    local d = UnitClass(1, 1, 1, STUB_SPRITES)
    UnitBaseStats[t] = {
        health              = d.baseHealth,
        damage              = d.baseDamage,
        attackSpeed         = d.statAttackSpeed,
        moveSpeed           = d.baseMoveSpeed or d.moveSpeed or 0,
        attackRange         = d.attackRange or 0,
        healthPerLevel      = d.healthPerLevel,
        attackSpeedPerLevel = d.attackSpeedPerLevel,
    }
end

-- ── Roles (placement bands) ───────────────────────────────────────────────────
-- Derived from stats; explicit overrides for units whose role isn't stat-visible.
-- "tank" → front, "melee" → mid, "ranged"/"structure" → back.
local RoleOverrides = {
    knight = "tank",    -- 12 HP but it's the taunt anchor
    effigy = "melee",   -- aura totem wants mid board (bot_manager places it mid)
}

local UnitRole = {}
for t, s in pairs(UnitBaseStats) do
    if RoleOverrides[t] then
        UnitRole[t] = RoleOverrides[t]
    elseif s.moveSpeed == 0 then
        UnitRole[t] = "structure"
    elseif s.attackRange >= 2 then
        UnitRole[t] = "ranged"
    elseif s.health >= 13 then
        UnitRole[t] = "tank"
    else
        UnitRole[t] = "melee"
    end
end

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
    if ov.health then
        unit.health = ov.health; unit.maxHealth = ov.health; unit.baseHealth = ov.health
    end
    if ov.damage then
        unit.damage = ov.damage; unit.baseDamage = ov.damage
    end
    if ov.attackSpeed then
        unit.attackSpeed = ov.attackSpeed
        unit.baseAttackSpeed = ov.attackSpeed
        unit.statAttackSpeed = ov.attackSpeed
    end
    local lvl = level or 0
    if lvl > 0 then
        if upgradePath then
            for i = 1, math.min(lvl, #upgradePath) do unit:upgrade(upgradePath[i]) end
        else
            for i = 1, lvl do
                -- fall back to ability-less level-up when the tree is shorter
                if not unit:upgrade(i) then unit:upgrade() end
            end
        end
    end
    unit.homeCol = col
    unit.homeRow = row
    return unit
end

-- ── runBattle ─────────────────────────────────────────────────────────────────
-- Stalemate detection: passive-vs-passive boards (structures, out-of-range
-- standoffs) end as a draw once nothing has changed for STALEMATE_STEPS.
local function boardFingerprint(allUnits)
    local parts = {}
    for _, u in ipairs(allUnits) do
        parts[#parts+1] = string.format("%d:%s:%d:%d:%d",
            u.owner, u.unitType, u.col or 0, u.row or 0, u.isDead and -1 or u.health)
    end
    table.sort(parts)
    return table.concat(parts, "|")
end

local function runBattle(grid)
    local lastFP = nil
    for step = 1, MAX_STEPS do
        -- IncludingHidden matters: burrow/ninja leave the grid mid-battle but
        -- must keep updating and count as alive (mirrors game.lua's battle loop)
        local allUnits = grid:getAllUnitsIncludingHidden()
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
        if step % STALEMATE_STEPS == 0 then
            local fp = boardFingerprint(allUnits)
            if fp == lastFP then return 0, step, allUnits end
            lastFP = fp
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

-- Draw-aware win rate: a draw counts as half a win for each side, so
-- structure-vs-structure standoffs read as 50%, not 0%.
local function wrOf(res)
    return (res.p1Wins + 0.5 * res.draws) / res.totalSims
end

-- ── Grid placement helpers ────────────────────────────────────────────────────
-- P1 rows: 5-8 (row 8 = frontline closest to P2, row 5 = backline)
-- P2 rows: 1-4 (row 1 = frontline closest to P1, row 4 = backline)

local P1_FRONT = { {col=2,row=8},{col=3,row=8},{col=4,row=8},{col=1,row=8},{col=5,row=8} }
local P1_BACK  = { {col=2,row=6},{col=3,row=6},{col=4,row=6},{col=1,row=6},{col=5,row=6},
                   {col=2,row=5},{col=3,row=5},{col=4,row=5},{col=1,row=5},{col=5,row=5} }
local P1_MID   = { {col=2,row=7},{col=3,row=7},{col=4,row=7},{col=1,row=7},{col=5,row=7} }

local P2_FRONT = { {col=2,row=1},{col=3,row=1},{col=4,row=1},{col=1,row=1},{col=5,row=1} }
local P2_BACK  = { {col=2,row=3},{col=3,row=3},{col=4,row=3},{col=1,row=3},{col=5,row=3},
                   {col=2,row=4},{col=3,row=4},{col=4,row=4},{col=1,row=4},{col=5,row=4} }
local P2_MID   = { {col=2,row=2},{col=3,row=2},{col=4,row=2},{col=1,row=2},{col=5,row=2} }

-- ── Army builders ─────────────────────────────────────────────────────────────

-- Heuristic army: tanks front, melee mid, ranged + structures back.
-- unitList = list of {unitType, level, upgradePath}. owner = 1 or 2.
local function buildHeuristicArmy(unitList, owner)
    local front = owner == 1 and P1_FRONT or P2_FRONT
    local mid   = owner == 1 and P1_MID   or P2_MID
    local back  = owner == 1 and P1_BACK  or P2_BACK

    local tanks, melees, rangeds = {}, {}, {}
    for _, u in ipairs(unitList) do
        local role = UnitRole[u.unitType] or "melee"
        if role == "tank" then table.insert(tanks, u)
        elseif role == "ranged" or role == "structure" then table.insert(rangeds, u)
        else table.insert(melees, u) end
    end

    local army = {}
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
    -- Place ranged + structures in back (or mid overflow)
    for _, u in ipairs(rangeds) do
        if backIdx <= #back then
            local pos = back[backIdx]; backIdx = backIdx + 1
            table.insert(army, { unitType=u.unitType, col=pos.col, row=pos.row,
                                  level=u.level or 0, upgradePath=u.upgradePath })
        elseif midIdx <= #mid then
            local pos = mid[midIdx]; midIdx = midIdx + 1
            table.insert(army, { unitType=u.unitType, col=pos.col, row=pos.row,
                                  level=u.level or 0, upgradePath=u.upgradePath })
        end
    end
    return army
end

-- Random army: fill budget randomly, equal budget both sides.
local function buildRandomArmy(budget, owner, seed)
    math.randomseed(seed)
    local allTypes = {}
    for t in pairs(UnitCosts) do table.insert(allTypes, t) end
    table.sort(allTypes)

    local unitList = {}
    local remaining = budget
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
-- Each archetype is a unit list; buildHeuristicArmy handles placement.
-- Budget enforced at definition time (sum of UnitCosts ≈ 18).

local ARCHETYPES = {
    -- Boney swarm: 9x boney = 18
    boney_swarm = {
        { unitType="boney" }, { unitType="boney" }, { unitType="boney" },
        { unitType="boney" }, { unitType="boney" }, { unitType="boney" },
        { unitType="boney" }, { unitType="boney" }, { unitType="boney" },
    },
    -- Knight wall: 6x knight = 18
    knight_wall = {
        { unitType="knight" }, { unitType="knight" }, { unitType="knight" },
        { unitType="knight" }, { unitType="knight" }, { unitType="knight" },
    },
    -- Ranged squad: 9x marrow = 18
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
    -- Mixed: 2x knight(6) + 1x mage(4) + 2x boney(4) + 1x samurai(3) = 17
    classic_mixed = {
        { unitType="knight" },  { unitType="knight" },
        { unitType="mage" },
        { unitType="boney" },   { unitType="boney" },
        { unitType="samurai" },
    },
    -- Skeleton themed: 3x boney(6) + 2x clavicula(8) + 1x marrow(2) + 1x mend(3) = 19
    skeleton_team = {
        { unitType="boney" }, { unitType="boney" }, { unitType="boney" },
        { unitType="clavicula" }, { unitType="clavicula" },
        { unitType="marrow" },
    },
    -- Castle themed: 2x bull(8) + 1x humerus(5) + 1x marc(3) + 1x samurai(3) = 19
    castle_charge = {
        { unitType="bull" },    { unitType="bull" },
        { unitType="humerus" },
        { unitType="marc" },
        { unitType="samurai" },
    },
    -- Invulnerable core: 2x amalgam(8) + 2x mage(8) = 16
    amalgam_shield = {
        { unitType="amalgam" }, { unitType="amalgam" },
        { unitType="mage" },    { unitType="mage" },
    },
    -- Upgraded front: knight L2 x2 + boney L2 + samurai L1
    upgraded_front = {
        { unitType="knight",  level=2, upgradePath={1,2} },
        { unitType="knight",  level=2, upgradePath={1,2} },
        { unitType="boney",   level=2, upgradePath={2,3} },
        { unitType="samurai", level=1, upgradePath={1} },
    },
    -- Goblin pack: cart(4) + hook(4) + flint(3) + pouch(3) + barrel(3) = 17
    goblin_pack = {
        { unitType="cart" }, { unitType="hook" },
        { unitType="flint" }, { unitType="pouch" }, { unitType="barrel" },
    },
    -- Ninja strike: 3x ninja(12) + 3x boney(6) = 18
    ninja_strike = {
        { unitType="ninja" }, { unitType="ninja" }, { unitType="ninja" },
        { unitType="boney" }, { unitType="boney" }, { unitType="boney" },
    },
    -- Structure turtle: effigy(3) + 2x cannon(6) + catapult(2) + mason(4) + tomb(1) + marrow(2) = 18
    structure_turtle = {
        { unitType="effigy" }, { unitType="cannon" }, { unitType="cannon" },
        { unitType="catapult" }, { unitType="mason" }, { unitType="tomb" },
        { unitType="marrow" },
    },
}

-- ── Cost-curve regression ─────────────────────────────────────────────────────
-- Least-squares fit: cost ≈ w0 + w1·HP + w2·DPS + w3·range, fitted on units
-- with real auto-attack DPS (structures/passives excluded — their value is
-- ability-driven and unpriced by stats). Residual = actual − predicted:
-- negative → cheaper than its stats (strong on paper), positive → overpriced.
local function solveLinearSystem(A, b)
    local n = #b
    for i = 1, n do
        -- partial pivot
        local maxRow, maxVal = i, math.abs(A[i][i])
        for r = i+1, n do
            if math.abs(A[r][i]) > maxVal then maxRow, maxVal = r, math.abs(A[r][i]) end
        end
        if maxVal < 1e-12 then return nil end
        A[i], A[maxRow] = A[maxRow], A[i]
        b[i], b[maxRow] = b[maxRow], b[i]
        for r = i+1, n do
            local f = A[r][i] / A[i][i]
            for c = i, n do A[r][c] = A[r][c] - f * A[i][c] end
            b[r] = b[r] - f * b[i]
        end
    end
    local x = {}
    for i = n, 1, -1 do
        local s = b[i]
        for c = i+1, n do s = s - A[i][c] * x[c] end
        x[i] = s / A[i][i]
    end
    return x
end

local function computeCostCurve()
    local featureRows, targets, fitTypes = {}, {}, {}
    for t, s in pairs(UnitBaseStats) do
        local dps = s.damage * s.attackSpeed
        if dps > 0 then
            table.insert(featureRows, { 1, s.health, dps, s.attackRange })
            table.insert(targets, UnitCosts[t])
            table.insert(fitTypes, t)
        end
    end

    -- Normal equations: (XᵀX) w = Xᵀy
    local k = 4
    local XtX, Xty = {}, {}
    for i = 1, k do
        XtX[i] = {}
        for j = 1, k do XtX[i][j] = 0 end
        Xty[i] = 0
    end
    for r, row in ipairs(featureRows) do
        for i = 1, k do
            for j = 1, k do XtX[i][j] = XtX[i][j] + row[i] * row[j] end
            Xty[i] = Xty[i] + row[i] * targets[r]
        end
    end
    local w = solveLinearSystem(XtX, Xty)
    if not w then return nil end

    local results = {}
    for t, s in pairs(UnitBaseStats) do
        local dps = s.damage * s.attackSpeed
        local predicted = w[1] + w[2] * s.health + w[3] * dps + w[4] * s.attackRange
        results[t] = {
            dps       = dps,
            predicted = predicted,
            residual  = UnitCosts[t] - predicted,
            inFit     = dps > 0,
        }
    end
    return { weights = w, results = results }
end

-- ── computeUnitWinRates ───────────────────────────────────────────────────────
-- For each unit: mono-vs-each-other-unit matchups (all at level 0), averaged
-- across BUDGETS. Diagonal = mirror match (symmetry check).
local function computeUnitWinRates(nSims)
    local unitTypes = {}
    for t in pairs(UnitClasses) do table.insert(unitTypes, t) end
    table.sort(unitTypes)

    local matrix = {}
    for _, a in ipairs(unitTypes) do
        matrix[a] = {}
        for _, b in ipairs(unitTypes) do
            local totalWR, totalSteps, count = 0, 0, 0
            for _, budget in ipairs(BUDGETS) do
                if (UnitCosts[a] or 3) <= budget and (UnitCosts[b] or 3) <= budget then
                    local armyA = buildMonoArmy(a, budget, 1, 0, nil)
                    local armyB = buildMonoArmy(b, budget, 2, 0, nil)
                    local r = runMatchup(armyA, armyB, nSims)
                    totalWR    = totalWR    + wrOf(r)
                    totalSteps = totalSteps + r.totalSteps / r.totalSims
                    count = count + 1
                end
            end
            local n = math.max(count, 1)
            matrix[a][b] = { wr = totalWR / n, steps = totalSteps / n }
        end
        io.write(".") io.flush()
    end
    io.write("\n")

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
-- For each unit: mono mirror at levels 0-2, plus leveled-vs-L0 upgrade power.
local function computeLevelWinRates(nSims)
    local results = {}
    for unitType in pairs(UnitClasses) do
        results[unitType] = {}
        for level = 0, 2 do
            local armyP1 = buildMonoArmy(unitType, BUDGET, 1, level, nil)
            local armyP2 = buildMonoArmy(unitType, BUDGET, 2, level, nil)
            local r = runMatchup(armyP1, armyP2, nSims)
            if level == 0 then
                results[unitType][level] = { mirror_wr = wrOf(r) }
            else
                local armyL0 = buildMonoArmy(unitType, BUDGET, 2, 0, nil)
                local r2 = runMatchup(armyP1, armyL0, nSims)
                results[unitType][level] = {
                    mirror_wr = wrOf(r),
                    vs_l0_wr  = wrOf(r2),
                }
            end
        end
    end
    return results
end

-- ── computeBuyVsUpgrade ───────────────────────────────────────────────────────
-- The real draft decision: an upgrade costs the unit's base cost (game.lua),
-- so a level-1 unit costs exactly the same as two level-0 copies.
--   L1 test: 3 units at L1  vs  6 units at L0   (equal coins)
--   L2 test: 2 units at L2  vs  6 units at L0   (equal coins)
-- WR > 50% → upgrading beats buying bodies. Each 1-upgrade path is tested and
-- averaged; best path is also reported.
local function computeBuyVsUpgrade(nSims)
    local results = {}
    for unitType in pairs(UnitClasses) do
        local names = UpgradeNames[unitType] or {}
        local paths1 = {}
        for i = 1, math.min(3, #names) do table.insert(paths1, {i}) end
        if #paths1 == 0 then paths1 = { nil } end  -- ability-less level-up

        local function listOf(n, level, path)
            local l = {}
            for _ = 1, n do table.insert(l, { unitType=unitType, level=level, upgradePath=path }) end
            return l
        end

        -- L1: 3 upgraded vs 6 base
        local sum1, best1, best1Label, n1 = 0, -1, nil, 0
        for _, path in ipairs(paths1) do
            local armyA = buildHeuristicArmy(listOf(3, 1, path), 1)
            local armyB = buildHeuristicArmy(listOf(6, 0, nil), 2)
            local r  = runMatchup(armyA, armyB, nSims)
            local wr = wrOf(r)
            sum1 = sum1 + wr; n1 = n1 + 1
            if wr > best1 then
                best1 = wr
                best1Label = path and (names[path[1]] or ("U"..path[1])) or "level-only"
            end
        end

        -- L2: 2 upgraded (path {1,2}) vs 6 base
        local path2 = (#names >= 2) and {1,2} or nil
        local armyA2 = buildHeuristicArmy(listOf(2, 2, path2), 1)
        local armyB2 = buildHeuristicArmy(listOf(6, 0, nil), 2)
        local r2 = runMatchup(armyA2, armyB2, nSims)

        results[unitType] = {
            l1_avg   = sum1 / math.max(n1, 1),
            l1_best  = best1,
            l1_label = best1Label,
            l2_wr    = wrOf(r2),
        }
    end
    return results
end

-- ── computeUpgradePathWinRates ────────────────────────────────────────────────
-- For each unit: all 1- and 2-upgrade paths vs unupgraded mirror.
local ALL_PATHS_1 = {{1},{2},{3}}
local ALL_PATHS_2 = {{1,2},{1,3},{2,3}}

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

        local baseArmy = buildMonoArmy(unitType, BUDGET, 2, 0, nil)

        for _, path in ipairs(ALL_PATHS_1) do
            if names[path[1]] then
                local key = table.concat(path, "_")
                local army = buildMonoArmy(unitType, BUDGET, 1, 1, path)
                local r = runMatchup(army, baseArmy, nSims)
                results[unitType][key] = { wr = wrOf(r), steps = r.totalSteps / r.totalSims, label = pathLabel(path) }
            end
        end
        for _, path in ipairs(ALL_PATHS_2) do
            if names[path[1]] and names[path[2]] then
                local key = table.concat(path, "_")
                local army = buildMonoArmy(unitType, BUDGET, 1, 2, path)
                local r = runMatchup(army, baseArmy, nSims)
                results[unitType][key] = { wr = wrOf(r), steps = r.totalSteps / r.totalSims, label = pathLabel(path) }
            end
        end
        ::continue::
    end
    return results
end

-- ── computeArchetypeMatchups ──────────────────────────────────────────────────
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
                wr_a  = wrOf(r),
                wr_b  = 1 - wrOf(r),
                draws = r.draws  / r.totalSims,
                steps = r.totalSteps / r.totalSims,
            }
        end
    end
    return results, names
end

-- ── computeRandomMatchupWinRates ──────────────────────────────────────────────
-- Per-unit participation win rate from random vs random matches.
local function computeRandomMatchupWinRates(nSims)
    local unitStats = {}
    for t in pairs(UnitClasses) do
        unitStats[t] = { appeared=0, wonWith=0 }
    end
    local overallP1Wins = 0

    for sim = 1, nSims do
        local budget = BUDGETS[((sim - 1) % #BUDGETS) + 1]
        local armyP1 = buildRandomArmy(budget, 1, sim * 7919)
        local armyP2 = buildRandomArmy(budget, 2, sim * 6271 + 1)
        local r = runMatchup(armyP1, armyP2, 1)

        local winner = (r.p1Wins > 0) and 1 or (r.p2Wins > 0 and 2 or 0)
        if winner == 1 then overallP1Wins = overallP1Wins + 1 end

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
-- Per unit: health ±10/20%, damage ±1, attack speed ±0.05/±0.10 vs base mirror.
-- Attack speed matters most for tuning: damage values are tiny integers (mostly
-- 1), so ±1 damage is a ±100% swing while ±0.05 speed is a fine-grained nudge.
local function computeStatSearch(nSims)
    local results = {}

    for unitType, stats in pairs(UnitBaseStats) do
        results[unitType] = { health={}, damage={}, attackSpeed={} }

        -- Health search: ±10% and ±20% — small nudges, not drastic rewrites
        local bh = stats.health
        local healthVals = {
            math.max(1, math.floor(bh * 0.80)),
            math.max(1, math.floor(bh * 0.90)),
            bh,
            math.floor(bh * 1.10),
            math.floor(bh * 1.20),
        }
        local seen, uniqH = {}, {}
        for _, v in ipairs(healthVals) do
            if not seen[v] then seen[v]=true; table.insert(uniqH, v) end
        end

        local armyP2base = buildMonoArmy(unitType, BUDGET, 2, 0, nil)

        for _, v in ipairs(uniqH) do
            StatOverrides[unitType].health = v
            local armyP1 = buildMonoArmy(unitType, BUDGET, 1, 0, nil)
            local r = runMatchup(armyP1, armyP2base, nSims)
            StatOverrides[unitType].health = nil
            table.insert(results[unitType].health, {
                value = v, isBase = (v == bh),
                wr = wrOf(r), steps = r.totalSteps / r.totalSims,
            })
        end

        -- Damage search: ±1 only — one step at a time (units with 0 damage skip)
        local bd = stats.damage
        if bd > 0 then
            local damageVals = {}
            seen = {}
            for _, d in ipairs({ math.max(1, bd-1), bd, bd+1 }) do
                if not seen[d] then seen[d]=true; table.insert(damageVals, d) end
            end
            for _, v in ipairs(damageVals) do
                StatOverrides[unitType].damage = v
                local armyP1 = runMatchup(buildMonoArmy(unitType, BUDGET, 1, 0, nil), armyP2base, nSims)
                StatOverrides[unitType].damage = nil
                table.insert(results[unitType].damage, {
                    value = v, isBase = (v == bd),
                    wr = wrOf(armyP1), steps = armyP1.totalSteps / armyP1.totalSims,
                })
            end
        end

        -- Attack speed search: ±0.05 / ±0.10 (attackers only)
        local bs = stats.attackSpeed
        if bs > 0 then
            local spdVals = {}
            seen = {}
            for _, v in ipairs({ bs - 0.10, bs - 0.05, bs, bs + 0.05, bs + 0.10 }) do
                v = math.floor(v * 100 + 0.5) / 100
                if v >= 0.05 and not seen[v] then seen[v]=true; table.insert(spdVals, v) end
            end
            for _, v in ipairs(spdVals) do
                StatOverrides[unitType].attackSpeed = v
                local r = runMatchup(buildMonoArmy(unitType, BUDGET, 1, 0, nil), armyP2base, nSims)
                StatOverrides[unitType].attackSpeed = nil
                table.insert(results[unitType].attackSpeed, {
                    value = v, isBase = (math.abs(v - bs) < 0.001),
                    wr = wrOf(r), steps = r.totalSteps / r.totalSims,
                })
            end
        end
    end

    return results
end

-- ── Tweak suggestion engine ───────────────────────────────────────────────────
-- status: "balanced" | "overtuned" | "undertuned"
local function generateTweaks(overallWR, levelWR, upgradePathWR, randomWR, statSearch, buyVsUpgrade)
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
        if rwr > WIN_HIGH or rwr < WIN_LOW then
            table.insert(signals, string.format("random matchup win rate %.0f%%", rwr*100))
        end

        -- 3. Upgrade spike signal (fixed additive system: tune per-level gains)
        local lw = levelWR[unitType]
        if lw and lw[1] and lw[1].vs_l0_wr then
            local upgradeWR = lw[1].vs_l0_wr
            if upgradeWR > 0.80 then
                table.insert(signals, string.format("level 1 beats level 0 %.0f%% of the time (upgrades very powerful)", upgradeWR*100))
                table.insert(suggestions, string.format(
                    "Per-level gains look too strong — lower `stats.healthPerLevel` (now %d) or `stats.attackSpeedPerLevel` (now %.2f) for this unit.",
                    UnitBaseStats[unitType].healthPerLevel, UnitBaseStats[unitType].attackSpeedPerLevel))
            elseif upgradeWR < 0.55 then
                table.insert(signals, string.format("level 1 only beats level 0 %.0f%% (upgrades weak)", upgradeWR*100))
                table.insert(suggestions, "Upgrades feel underpowered — consider stronger ability effects at L1 or a higher `stats.healthPerLevel`.")
            end
        end

        -- 4. Buy-vs-upgrade economy signal
        local bvu = buyVsUpgrade[unitType]
        if bvu then
            if bvu.l1_avg > WIN_HIGH then
                table.insert(signals, string.format("upgrading beats buying bodies %.0f%% (equal coins)", bvu.l1_avg*100))
                table.insert(suggestions, "Upgrading dominates buying more copies — lower per-level gains or make copies stronger.")
            elseif bvu.l1_avg < WIN_LOW then
                table.insert(signals, string.format("upgrading loses to buying bodies %.0f%% (equal coins)", bvu.l1_avg*100))
                table.insert(suggestions, "Never worth upgrading vs buying more copies — raise `stats.healthPerLevel`/`stats.attackSpeedPerLevel` or strengthen L1 abilities.")
            end
        end

        -- 5. Stat search: suggest small nudges only when the unit is flagged.
        local ss = statSearch[unitType]
        local baseStats = UnitBaseStats[unitType]
        local unitIsImbalanced = (wr > WIN_HIGH or wr < WIN_LOW or rwr > WIN_HIGH or rwr < WIN_LOW)
        if ss and baseStats and unitIsImbalanced then
            local function bestValue(entries, baseVal)
                local best, bestDelta = baseVal, math.huge
                for _, entry in ipairs(entries or {}) do
                    local delta = math.abs(entry.wr - TARGET_WIN)
                    if delta < bestDelta then bestDelta = delta; best = entry.value end
                end
                return best
            end

            local bestH = bestValue(ss.health, baseStats.health)
            local healthDirOk = (wr > WIN_HIGH and bestH < baseStats.health)
                             or (wr < WIN_LOW  and bestH > baseStats.health)
            if bestH ~= baseStats.health and healthDirOk then
                local dir = bestH > baseStats.health and "increase" or "reduce"
                table.insert(suggestions, string.format(
                    "**Health**: %s base HP from %d → **%d** (~%.0f%% change)",
                    dir, baseStats.health, bestH,
                    math.abs(bestH - baseStats.health) / baseStats.health * 100))
            end

            -- Attack speed is the fine-grained DPS lever (damage steps are ±100%
            -- on 1-damage units) — prefer suggesting it over damage.
            local bestS = bestValue(ss.attackSpeed, baseStats.attackSpeed)
            local spdDirOk = (wr > WIN_HIGH and bestS < baseStats.attackSpeed)
                          or (wr < WIN_LOW  and bestS > baseStats.attackSpeed)
            if math.abs(bestS - baseStats.attackSpeed) > 0.001 and spdDirOk then
                local dir = bestS > baseStats.attackSpeed and "increase" or "reduce"
                table.insert(suggestions, string.format(
                    "**Attack speed**: %s from %.2f → **%.2f**",
                    dir, baseStats.attackSpeed, bestS))
            end

            local bestD = bestValue(ss.damage, baseStats.damage)
            local dmgDirOk = (wr > WIN_HIGH and bestD < baseStats.damage)
                          or (wr < WIN_LOW  and bestD > baseStats.damage)
            if bestD ~= baseStats.damage and dmgDirOk then
                local dir = bestD > baseStats.damage and "increase" or "reduce"
                table.insert(suggestions, string.format(
                    "**Damage**: %s base damage from %d → **%d** (coarse ±%.0f%% step — prefer attack speed if a smaller nudge is enough)",
                    dir, baseStats.damage, bestD,
                    math.abs(bestD - baseStats.damage) / baseStats.damage * 100))
            end
        end

        -- 6. Cost suggestion based on overall win rate
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

        -- 7. Best/worst upgrade path
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
                                   archetypeNames, randomP1WR, costCurve, buyVsUpgrade)
    local lines = {}
    local function w(s) table.insert(lines, s or "") end

    local ts = os.date("%Y-%m-%d %H:%M")

    w("# AutoChest Balance Report")
    w(string.format("> Generated: %s  |  Mode: %s  |  Budget: %d coins/player  |  Sims: random=%d, matchup=%d, unit=%d, stat=%d",
        ts, MODE, BUDGET, N_SIMS_RANDOM, N_SIMS_MATCHUP, N_SIMS_UNIT, N_SIMS_STAT))
    w("")
    w("---")
    w("")

    -- Roster sheet
    w("## Roster Sheet")
    w("")
    w("*Base stats harvested live from unit constructors; costs from unit_registry.*")
    w("")
    w("| Unit | Cost | HP | DMG | SPD | DPS | Range | Move | Role | HP/lvl | SPD/lvl | HP/coin | DPS/coin |")
    w("|------|------|----|----|-----|-----|-------|------|------|--------|---------|---------|----------|")
    local byCost = {}
    for _, t in ipairs(unitTypes) do table.insert(byCost, t) end
    table.sort(byCost, function(a, b)
        if UnitCosts[a] ~= UnitCosts[b] then return UnitCosts[a] < UnitCosts[b] end
        return a < b
    end)
    for _, t in ipairs(byCost) do
        local s = UnitBaseStats[t]
        local dps = s.damage * s.attackSpeed
        w(string.format("| **%s** | %d | %d | %d | %.2f | %.2f | %d | %.1f | %s | %d | %.2f | %.1f | %.2f |",
            t, UnitCosts[t], s.health, s.damage, s.attackSpeed, dps,
            s.attackRange, s.moveSpeed, UnitRole[t],
            s.healthPerLevel, s.attackSpeedPerLevel,
            s.health / UnitCosts[t], dps / UnitCosts[t]))
    end
    w("")

    -- Cost curve
    if costCurve then
        w("## Cost-Curve Fit (Paper Value)")
        w("")
        w(string.format("*Least-squares fit over auto-attacking units: `cost ≈ %.2f + %.3f·HP + %.2f·DPS + %.2f·range`.*",
            costCurve.weights[1], costCurve.weights[2], costCurve.weights[3], costCurve.weights[4]))
        w("*Residual = actual − predicted cost. **Negative → cheaper than its stats justify (strong on paper)**; positive → overpriced. Structures/passives (DPS 0) are shown but excluded from the fit — their value is ability-driven.*")
        w("")
        w("| Unit | Cost | Predicted | Residual | In fit |")
        w("|------|------|-----------|----------|--------|")
        local order = {}
        for _, t in ipairs(unitTypes) do table.insert(order, t) end
        table.sort(order, function(a, b)
            return costCurve.results[a].residual < costCurve.results[b].residual
        end)
        for _, t in ipairs(order) do
            local r = costCurve.results[t]
            local res = string.format("%+.2f", r.residual)
            if r.inFit and math.abs(r.residual) >= 0.8 then res = "**" .. res .. "**" end
            w(string.format("| **%s** | %d | %.2f | %s | %s |",
                t, UnitCosts[t], r.predicted, res, r.inFit and "yes" or "no (passive)"))
        end
        w("")
    end

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

    -- Unit vs unit matrix
    w("## Unit vs Unit Win Rate Matrix")
    w("")
    w("*Row = P1 unit type (mono army), Column = P2 unit type (mono army), value = P1 win rate (draws count 50/50).*")
    w("*Diagonal = mirror match, should be ~50%.*")
    w("")

    local headerCols = {}
    for _, b in ipairs(unitTypes) do
        table.insert(headerCols, b:sub(1,4))
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
    w("*P1 = leveled unit, P2 = same unit at level 0, same body count (upgrade is free here — pure power check).*")
    w("*>62% expected (upgrades should matter); ~50% = upgrades do nothing.*")
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

    -- Buy vs upgrade
    w("## Buy vs Upgrade (Equal Coins)")
    w("")
    w("*An upgrade costs the unit's base cost, so L1 = the price of two L0 copies.*")
    w("*L1 test: 3×L1 vs 6×L0. L2 test: 2×L2 vs 6×L0. WR = upgraded side's win rate.*")
    w("*~50% = healthy tension. >62% = upgrading dominates; <38% = never upgrade.*")
    w("")
    w("| Unit | 3×L1 vs 6×L0 (avg) | Best L1 path | 2×L2 vs 6×L0 |")
    w("|------|--------------------|--------------|--------------|")
    for _, unitType in ipairs(unitTypes) do
        local b = buyVsUpgrade[unitType]
        if b then
            local function fmt(v)
                local s = string.format("%.0f%%", v*100)
                if v > WIN_HIGH then s = "**"..s.."**" end
                if v < WIN_LOW  then s = "*"..s.."*" end
                return s
            end
            w(string.format("| **%s** | %s | %s (%.0f%%) | %s |",
                unitType, fmt(b.l1_avg), b.l1_label or "--", b.l1_best*100, fmt(b.l2_wr)))
        end
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
            local key  = na .. "_vs_" .. nb
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
        local s = UnitBaseStats[unitType]
        w(string.format("**Base stats**: HP=%d | DMG=%d | ATKSPD=%.2f | +%d HP/lvl | +%.2f SPD/lvl",
            s.health, s.damage, s.attackSpeed, s.healthPerLevel, s.attackSpeedPerLevel))
        w("")
        w(string.format("**Win rates**: overall=%.0f%% | random=%.0f%%",
            t.overallWR*100, t.randomWR*100))
        w("")
        if #t.signals > 0 then
            w("**Signals:**")
            for _, sig in ipairs(t.signals) do
                w("- " .. sig)
            end
            w("")
        end
        if #t.suggestions > 0 then
            w("**Suggested tweaks:**")
            for _, sug in ipairs(t.suggestions) do
                w("- " .. sug)
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
    w("- **Single source of truth**: unit classes + costs come from `src/unit_registry.lua`; base stats are read from live constructors. Spells are excluded (not simulated).")
    w("- **Equal budget**: both players receive the same coin budget per match.")
    w("- **Heuristic placement**: tanks → front, melee → mid, ranged + structures → back (effigy mid).")
    w("- **Unit vs unit matrix**: mono-army of each type vs every other type, averaged over budgets " .. table.concat(BUDGETS, "/") .. ".")
    w("- **Draws**: stalemates (board unchanged for 10s) end early and count as half a win for each side.")
    w("- **Buy vs upgrade**: an upgrade costs the unit's base cost (same as a second copy), so 3×L1 vs 6×L0 is coin-neutral.")
    w("- **Stat search**: ±10/20% health, ±1 damage, ±0.05/0.10 attack speed vs unmodified mirror.")
    w("- **Upgrade paths**: all 1- and 2-upgrade combinations vs unupgraded same unit.")
    w("- **Balance thresholds**: >62% = overtuned, <38% = undertuned.")
    w("- **Caveat**: the sim can't value setup-phase play, spells, or clever positioning — treat results as a screen, confirm with playtests/telemetry.")
    w("")

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

local nUnits = 0
for _ in pairs(UnitClasses) do nUnits = nUnits + 1 end

io.write(string.format("\nAutoChest Balance Sim | mode=%s | %d units | budget=%d | random=%d matchup=%d unit=%d stat=%d upg=%d\n\n",
    MODE, nUnits, BUDGET, N_SIMS_RANDOM, N_SIMS_MATCHUP, N_SIMS_UNIT, N_SIMS_STAT, N_SIMS_UPG))

local t0 = os.clock()
local function phase(label)
    io.write(string.format("[%6.1fs] %s\n", os.clock() - t0, label))
end

phase("0/7 Cost-curve regression...")
local costCurve = computeCostCurve()

phase("1/7 Unit vs unit matrix...")
local unitMatrix, overallWR, unitTypes = computeUnitWinRates(N_SIMS_UNIT)

phase("2/7 Upgrade level win rates...")
local levelWR = computeLevelWinRates(N_SIMS_UPG)

phase("3/7 Upgrade path win rates...")
local upgradePathWR = computeUpgradePathWinRates(N_SIMS_UPG)

phase("4/7 Buy vs upgrade economy...")
local buyVsUpgrade = computeBuyVsUpgrade(N_SIMS_UPG)

phase("5/7 Archetype matchups...")
local archetypeResults, archetypeNames = computeArchetypeMatchups(N_SIMS_MATCHUP)

phase("6/7 Random matchup participation rates...")
local randomUnitWR, randomP1WR = computeRandomMatchupWinRates(N_SIMS_RANDOM)

phase("7/7 Stat search (health/damage/attack speed)...")
local statSearch = computeStatSearch(N_SIMS_STAT)

phase("Generating tweak suggestions...")
local tweaks = generateTweaks(overallWR, levelWR, upgradePathWR, randomUnitWR, statSearch, buyVsUpgrade)

local timestamp = os.date("%Y%m%d_%H%M%S")
local reportPath = "tests/balance_report_" .. timestamp .. ".md"
phase(string.format("Writing report to %s...", reportPath))

local ok = writeMarkdownReport(reportPath, tweaks, unitMatrix, unitTypes,
    levelWR, upgradePathWR, archetypeResults, archetypeNames, randomP1WR,
    costCurve, buyVsUpgrade)

if ok then
    io.write(string.format("\nDone in %.1fs. Report written to: %s\n", os.clock() - t0, reportPath))
else
    io.write("\nERROR: failed to write report.\n")
    os.exit(1)
end

os.exit(0)
