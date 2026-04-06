local BaseUnit  = require('src.base_unit')
local Constants = require('src.constants')

local Burrow = BaseUnit:extend()

-- ============================================================
-- Burrow — Calcium Clan melee unit (3 coins)
-- Passive (Subterranean Dash): at battle start, burrows underground
-- and reappears 1s later at the mirrored row on the far side of the
-- field (same column). Emerges at the nearest free cell if occupied.
-- ============================================================

function Burrow:new(row, col, owner, sprites)
    local stats = {
        health      = 8,
        maxHealth   = 8,
        damage      = 1,
        attackSpeed = 0.75,
        moveSpeed   = 1,
        attackRange = 0,
        unitType    = "burrow"
    }

    Burrow.super.new(self, row, col, owner, sprites, stats)

    self.actionDuration = 2.0   -- seconds underground before emerging

    -- Per-round burrow state
    self.isBurrowing  = false
    self.burrowTimer  = 0

    -- Upgrade 3 (Adrenaline Surge) timer
    self.surgeTimer = 0

    self.upgradeTree = {
        {
            name        = "Counter Strike",
            description = "Each hit removes 1 hit counter from the target (Mage, Migraine, etc.)",
            onApply     = function(unit) end
        },
        {
            name        = "Ground Burst",
            description = "Emerging from the ground deals 2 damage in a 1.5-cell radius and stuns enemies for 0.8s",
            onApply     = function(unit) end
        },
        {
            name        = "Adrenaline Surge",
            description = "+30% attack speed for 3s after emerging from burrow",
            onApply     = function(unit) end
        },
    }
end

-- ============================================================
-- findNearestFree: spiral outward from (col, row) to find a
-- free cell. Returns (col, row) if the cell itself is free.
-- ============================================================
local function findNearestFree(grid, col, row)
    local cell = grid:getCell(col, row)
    if cell and not cell.occupied then
        return col, row
    end
    for r = 1, 3 do
        for dc = -r, r do
            for dr = -r, r do
                if math.abs(dc) == r or math.abs(dr) == r then
                    local nc = col + dc
                    local nr = row + dr
                    if nc >= 1 and nc <= Constants.GRID_COLS
                       and nr >= 1 and nr <= Constants.GRID_ROWS then
                        local c = grid:getCell(nc, nr)
                        if c and not c.occupied then
                            return nc, nr
                        end
                    end
                end
            end
        end
    end
    return col, row  -- fallback: stay (will be handled gracefully)
end

-- ============================================================
-- onBattleStart: remove from grid, compute mirror destination,
-- place unit there immediately (logically), begin 1s hide timer.
-- ============================================================
function Burrow:onBattleStart(grid)
    local mirroredRow = Constants.GRID_ROWS + 1 - self.row
    local destCol, destRow = findNearestFree(grid, self.col, mirroredRow)

    -- Move logically to destination immediately (same as Bull pattern)
    grid:removeUnit(self.col, self.row)
    self.col = destCol
    self.row = destRow
    grid:placeUnit(destCol, destRow, self)

    -- Begin underground hide timer
    self.isBurrowing = true
    self.burrowTimer = 0
end

-- ============================================================
-- update: tick burrow timer; on emerge apply upgrades 2 & 3,
-- then run normal melee combat.
-- ============================================================
function Burrow:update(dt, grid)
    if self.isBurrowing then
        self.burrowTimer = self.burrowTimer + dt

        if self.burrowTimer >= self.actionDuration then
            self.isBurrowing = false
            self.burrowTimer = 0

            -- Upgrade 2 (Ground Burst): AoE damage + stun on emergence
            if self:hasUpgrade(2) then
                local allUnits = grid:getAllUnits()
                for _, unit in ipairs(allUnits) do
                    if unit.owner ~= self.owner and not unit.isDead then
                        local dx = unit.col - self.col
                        local dy = unit.row - self.row
                        local dist = math.sqrt(dx * dx + dy * dy)
                        if dist <= 1.5 then
                            unit:takeDamage(2)
                            unit.stunTimer = 0.8
                        end
                    end
                end
            end

            -- Upgrade 3 (Adrenaline Surge): +30% ATK speed for 3s
            if self:hasUpgrade(3) then
                self.surgeTimer  = 3
                self.attackSpeed = self.baseAttackSpeed * 1.3
                self:triggerBuffAnim()
            end
        end

        return  -- skip normal combat while underground
    end

    -- Adrenaline Surge cooldown
    if self.surgeTimer > 0 then
        self.surgeTimer = self.surgeTimer - dt
        if self.surgeTimer <= 0 then
            self.surgeTimer  = 0
            self.attackSpeed = self.baseAttackSpeed
        end
    end

    Burrow.super.update(self, dt, grid)
end

-- ============================================================
-- attack: melee hit + Upgrade 1 counter drain.
-- ============================================================
function Burrow:attack(target, grid)
    Burrow.super.attack(self, target, grid)

    -- Upgrade 1 (Counter Strike): remove 1 hit counter from target
    if self:hasUpgrade(1) then
        target.hitCounter = math.max(0, (target.hitCounter or 0) - 1)
    end
end

-- ============================================================
-- draw: hide while underground.
-- ============================================================
function Burrow:draw()
    if self.isBurrowing then return end
    Burrow.super.draw(self)
end

-- ============================================================
-- resetCombatState: clear per-round burrow and surge state.
-- ============================================================
function Burrow:resetCombatState()
    Burrow.super.resetCombatState(self)
    self.isBurrowing  = false
    self.burrowTimer  = 0
    self.surgeTimer   = 0
    self.attackSpeed  = self.baseAttackSpeed
end

return Burrow
