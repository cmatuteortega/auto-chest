local BaseUnit  = require('src.base_unit')
local Constants = require('src.constants')

local Ninja = BaseUnit:extend()

local DASH_DURATION = 0.35  -- seconds to cross the board visually

-- ============================================================
-- Ninja — Castle Crew melee unit (4 coins)
-- Passive (Shadow Dash): every 7 combined hits (dealt + received),
-- dashes to the farthest enemy unit on the board and locks onto
-- them as the new target for up to 5 seconds.
-- ============================================================

function Ninja:new(row, col, owner, sprites)
    local stats = {
        health      = 11,
        maxHealth   = 11,
        damage      = 2,
        attackSpeed = 1.2,
        moveSpeed   = 1,
        attackRange = 0,
        unitType    = "ninja"
    }

    Ninja.super.new(self, row, col, owner, sprites, stats)

    self.hitSound = "slice.mp3"

    -- Energy / dash state
    self.energyCounter   = 0
    self.dashTarget      = nil
    self.dashTargetTimer = 0

    -- Dash visual tween (independent from normal cell-to-cell movement)
    self.isDashing    = false
    self.dashProgress = 0
    self.dashStartCol = col
    self.dashStartRow = row
    self.dashDestCol  = col
    self.dashDestRow  = row

    self.upgradeTree = {
        {
            name        = "Phantom Cut",
            description = "Enemies along the dash path take damage equal to Ninja's base damage",
            onApply     = function(_) end
        },
        {
            name        = "Chi Drain",
            description = "The dash removes 2 energy from every enemy dashed through",
            onApply     = function(_) end
        },
        {
            name        = "Smokescreen",
            description = "On landing, stuns all enemies within 1.5 cells for 0.8 seconds",
            onApply     = function(_) end
        },
    }
end

-- ============================================================
-- getEnergy: expose 0-7 hit counter as the energy bar.
-- ============================================================
function Ninja:getEnergy()
    return self.energyCounter, 7
end

-- ============================================================
-- findFarthestEnemy: greatest Euclidean distance; tie-break by
-- lower col then lower row for determinism.
-- ============================================================
function Ninja:findFarthestEnemy(grid)
    local allUnits = grid:getAllUnits()
    local farthest = nil
    local maxDist  = -1

    for _, unit in ipairs(allUnits) do
        if unit.owner ~= self.owner and not unit.isDead then
            local dx   = unit.col - self.col
            local dy   = unit.row - self.row
            local dist = math.sqrt(dx * dx + dy * dy)
            if dist > maxDist
               or (dist == maxDist and farthest
                   and (unit.col < farthest.col
                        or (unit.col == farthest.col and unit.row < farthest.row)))
            then
                maxDist  = dist
                farthest = unit
            end
        end
    end

    return farthest
end

-- ============================================================
-- Helpers for dash-path hit detection.
-- ============================================================
local function pointToSegmentDist(px, py, ax, ay, bx, by)
    local dx, dy = bx - ax, by - ay
    local lenSq  = dx * dx + dy * dy
    if lenSq == 0 then
        return math.sqrt((px - ax)^2 + (py - ay)^2)
    end
    local t  = math.max(0, math.min(1, ((px - ax) * dx + (py - ay) * dy) / lenSq))
    local qx = ax + t * dx
    local qy = ay + t * dy
    return math.sqrt((px - qx)^2 + (py - qy)^2)
end

function Ninja:getUnitsAlongDash(grid, destCol, destRow)
    local hit = {}
    for _, unit in ipairs(grid:getAllUnits()) do
        if unit.owner ~= self.owner and not unit.isDead then
            local d = pointToSegmentDist(
                unit.col, unit.row,
                self.col, self.row,
                destCol,  destRow)
            if d < 0.6 then
                table.insert(hit, unit)
            end
        end
    end
    return hit
end

-- ============================================================
-- triggerDash: grid position snaps to destination instantly;
-- visual slides across via a separate tween in getDrawPos/update.
-- Upgrade effects are applied before the move (enemies are still
-- at their original positions).
-- ============================================================
function Ninja:triggerDash(grid)
    local farthest = self:findFarthestEnemy(grid)
    if not farthest then return end

    local destCol, destRow = self:findGoalNearTarget(grid, farthest)
    if not destCol then return end

    -- Collect enemies along the path before moving
    local dashedUnits = self:getUnitsAlongDash(grid, destCol, destRow)

    -- Apply path-based upgrade effects
    for _, enemy in ipairs(dashedUnits) do
        -- Upgrade 1 — Phantom Cut: deal damage to enemies along the path
        if self:hasUpgrade(1) then
            enemy:takeDamage(self:getDamage(), self, grid)
            if enemy.isDead then
                grid:killUnit(enemy)
                self:onKill(enemy)
            end
        end
        -- Upgrade 2 — Chi Drain: remove 2 energy from each enemy
        if self:hasUpgrade(2) and enemy.energyCounter then
            enemy.energyCounter = math.max(0, enemy.energyCounter - 2)
        end
    end

    -- Record current position as the visual start of the tween
    self.dashStartCol = self.col
    self.dashStartRow = self.row

    -- Snap the logical grid position to the destination
    grid:hideUnit(self)
    self.col = destCol
    self.row = destRow
    grid:unhideUnit(self)
    grid:placeUnit(destCol, destRow, self)

    -- Cancel any pending pathfinding
    self.path       = nil
    self.isMoving   = false
    self.tweenProgress = 1

    -- Begin visual tween
    self.dashDestCol  = destCol
    self.dashDestRow  = destRow
    self.dashProgress = 0
    self.isDashing    = true

    -- Upgrade 3 — Smokescreen: stun enemies within 1.5 cells of the landing spot
    if self:hasUpgrade(3) then
        for _, unit in ipairs(grid:getAllUnits()) do
            if unit.owner ~= self.owner and not unit.isDead then
                local dx   = unit.col - destCol
                local dy   = unit.row - destRow
                if math.sqrt(dx * dx + dy * dy) <= 1.5 then
                    unit.stunTimer = math.max(unit.stunTimer, 0.8)
                end
            end
        end
    end

    -- Lock onto the farthest enemy
    self.dashTarget      = farthest
    self.dashTargetTimer = 5

    -- Reset hit counter
    self.energyCounter = 0

    self:triggerBuffAnim()
end

-- ============================================================
-- getDrawPos: use fractional col/row interpolation during the
-- dash tween. toVisualRow is linear so fractional rows are fine.
-- ============================================================
function Ninja:getDrawPos()
    if self.isDashing then
        local t    = self.dashProgress
        local ease = t < 0.5 and (2 * t * t) or (-1 + (4 - 2 * t) * t)
        local drawCol   = self.dashStartCol + (self.dashDestCol - self.dashStartCol) * ease
        local drawRow   = self.dashStartRow + (self.dashDestRow - self.dashStartRow) * ease
        local visualRow = Constants.toVisualRow(drawRow)
        local x = Constants.GRID_OFFSET_X + (drawCol - 1) * Constants.CELL_SIZE
        local y = Constants.GRID_OFFSET_Y + (visualRow - 1) * Constants.CELL_SIZE
        return x, y
    end
    return Ninja.super.getDrawPos(self)
end

-- ============================================================
-- findNearestEnemy: honour the post-dash target lock.
-- ============================================================
function Ninja:findNearestEnemy(grid)
    if self.dashTarget and self.dashTargetTimer > 0 and not self.dashTarget.isDead then
        return self.dashTarget
    end
    self.dashTarget = nil
    return Ninja.super.findNearestEnemy(self, grid)
end

-- ============================================================
-- attack: count hits given toward the energy counter.
-- ============================================================
function Ninja:attack(target, grid)
    Ninja.super.attack(self, target, grid)

    self.energyCounter = self.energyCounter + 1
    if self.energyCounter >= 7 then
        self:triggerDash(grid)
    end
end

-- ============================================================
-- takeDamage: count hits received toward the energy counter.
-- ============================================================
function Ninja:takeDamage(amount, attacker, grid)
    Ninja.super.takeDamage(self, amount, attacker, grid)

    if self.isDead then return end

    self.energyCounter = self.energyCounter + 1
    if self.energyCounter >= 7 then
        self:triggerDash(grid)
    end
end

-- ============================================================
-- update: advance the dash tween; block normal combat while
-- the tween is in flight.
-- ============================================================
function Ninja:update(dt, grid)
    if self.isDashing then
        self.dashProgress = math.min(1, self.dashProgress + dt / DASH_DURATION)
        if self.dashProgress >= 1 then
            self.isDashing = false
        end
        return
    end

    if self.dashTargetTimer > 0 then
        self.dashTargetTimer = self.dashTargetTimer - dt
        if self.dashTargetTimer <= 0 then
            self.dashTargetTimer = 0
            self.dashTarget      = nil
        end
    end

    Ninja.super.update(self, dt, grid)
end

-- ============================================================
-- resetCombatState: clear per-round dash state.
-- ============================================================
function Ninja:resetCombatState()
    Ninja.super.resetCombatState(self)
    self.energyCounter   = 0
    self.dashTarget      = nil
    self.dashTargetTimer = 0
    self.isDashing       = false
    self.dashProgress    = 0
end

return Ninja
