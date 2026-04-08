local BaseUnit = require('src.base_unit')
local BaseUnitRanged = require('src.base_unit_ranged')
local Constants = require('src.constants')

local Marc = BaseUnitRanged:extend()

function Marc:new(row, col, owner, sprites)
    local stats = {
        health          = 10,
        maxHealth       = 10,
        damage          = 1,
        attackSpeed     = 0.75,
        moveSpeed       = 1,
        attackRange     = 6,
        projectileSpeed = 0.3,
        unitType        = "marc"
    }

    Marc.super.new(self, row, col, owner, sprites, stats)

    self.attackCount   = 0
    self.currentTarget = nil

    self.upgradeTree = {
        {
            name = "Headshot",
            description = "+50% damage to enemies above 80% HP",
            onApply = function(unit) end
        },
        {
            name = "Piercing Arrow",
            description = "Every 3rd attack pierces all enemies in a line",
            onApply = function(unit) end
        },
        {
            name = "Eagle Eye",
            description = "+2 attack range",
            onApply = function(unit)
                unit.attackRange = unit.attackRange + 2
            end
        }
    }
end

-- ============================================================
-- Passive: Sniper Focus
-- If enemies are within attack range, target the furthest one.
-- Otherwise fall back to nearest (for movement approach).
-- ============================================================
function Marc:findNearestEnemy(grid)
    local allUnits = grid:getAllUnits()

    -- Check if any enemy is already in range
    local hasEnemyInRange = false
    for _, unit in ipairs(allUnits) do
        if unit.owner ~= self.owner and not unit.isDead and self:isInAttackRange(unit) then
            hasEnemyInRange = true
            break
        end
    end

    if hasEnemyInRange then
        -- Sniper Focus: pick the furthest in-range enemy
        local furthestEnemy = nil
        local greatestDistance = -1

        for _, unit in ipairs(allUnits) do
            if unit.owner ~= self.owner and not unit.isDead and self:isInAttackRange(unit) then
                local dist = math.sqrt((unit.col - self.col)^2 + (unit.row - self.row)^2)
                local isBetter = dist > greatestDistance
                if dist == greatestDistance and furthestEnemy then
                    isBetter = (unit.col > furthestEnemy.col) or
                               (unit.col == furthestEnemy.col and unit.row > furthestEnemy.row) or
                               (unit.col == furthestEnemy.col and unit.row == furthestEnemy.row
                                and unit.owner > furthestEnemy.owner)
                end
                if isBetter then
                    greatestDistance = dist
                    furthestEnemy = unit
                end
            end
        end

        return furthestEnemy
    end

    return BaseUnit.findNearestEnemy(self, grid)
end

-- Also override findEnemyInRange (called while moving) so mid-movement
-- opportunistic attacks also respect Sniper Focus.
function Marc:findEnemyInRange(grid)
    local allUnits = grid:getAllUnits()
    for _, unit in ipairs(allUnits) do
        if unit.owner ~= self.owner and not unit.isDead and self:isInAttackRange(unit) then
            return self:findNearestEnemy(grid)
        end
    end
    return nil
end

-- ============================================================
-- Upgrade 1: Headshot
-- +50% damage to enemies above 80% HP.
-- self.currentTarget is set in attack() before createProjectile.
-- ============================================================
function Marc:getDamage(grid)
    local dmg = self.damage

    if self:hasUpgrade(1) and self.currentTarget and not self.currentTarget.isDead then
        local hpPercent = self.currentTarget.health / self.currentTarget.maxHealth
        if hpPercent > 0.8 then
            -- math.max ensures at least +1 even when base damage is 1
            dmg = math.max(math.floor(dmg * 1.5), dmg + 1)
        end
    end

    return math.floor(dmg * (self.royalCommandBonus or 1))
end

-- ============================================================
-- Upgrade 2: Piercing Arrow helper
-- Walks from Marc through primaryTarget along the line,
-- collecting all living enemies within the grid.
-- ============================================================
function Marc:findPierceTargets(primaryTarget, grid)
    local targets = {}
    local dCol = primaryTarget.col - self.col
    local dRow = primaryTarget.row - self.row
    local steps = math.max(math.abs(dCol), math.abs(dRow))
    if steps == 0 then return targets end

    for s = 1, Constants.GRID_COLS + Constants.GRID_ROWS do
        local checkCol = self.col + math.floor(dCol * s / steps + 0.5)
        local checkRow = self.row + math.floor(dRow * s / steps + 0.5)
        if not grid:isValidCell(checkCol, checkRow) then break end
        local cell = grid:getCell(checkCol, checkRow)
        if cell and cell.unit and not cell.unit.isDead and cell.unit.owner ~= self.owner then
            table.insert(targets, cell.unit)
        end
    end

    return targets
end

-- ============================================================
-- attack(): set currentTarget for getDamage, track attackCount
-- for Piercing Arrow, then fire the projectile.
-- ============================================================
function Marc:attack(target, grid)
    if not target or target.isDead then return end

    self.attackCount = self.attackCount + 1
    self.currentTarget = target

    local projectile = self:createProjectile(target, grid)

    if self:hasUpgrade(2) and self.attackCount % 3 == 0 then
        projectile.piercing = true
        projectile.pierceTargets = self:findPierceTargets(target, grid)
    end

    self.currentTarget = nil
    table.insert(self.arrows, projectile)
    AudioManager.playSFX("bow.mp3", 0.3)
end

-- ============================================================
-- update(): fully replaces BaseUnitRanged:update.
-- Handles standard + piercing projectiles, then calls
-- BaseUnit.update directly to avoid double arrow processing.
-- ============================================================
function Marc:update(dt, grid)
    for i = #self.arrows, 1, -1 do
        local projectile = self.arrows[i]
        projectile.progress = projectile.progress + (dt / projectile.duration)

        if projectile.progress >= 1.0 then
            if projectile.piercing and projectile.pierceTargets then
                for _, pierceTarget in ipairs(projectile.pierceTargets) do
                    if not pierceTarget.isDead then
                        pierceTarget:takeDamage(projectile.damage)
                        if pierceTarget.isDead then
                            local cell = grid:getCell(pierceTarget.col, pierceTarget.row)
                            if cell then cell.occupied = false end
                            self:onKill(pierceTarget)
                        end
                    end
                end
            else
                if projectile.target and not projectile.target.isDead then
                    projectile.target:takeDamage(projectile.damage)
                    if projectile.target.isDead then
                        local cell = grid:getCell(projectile.target.col, projectile.target.row)
                        if cell then cell.occupied = false end
                        self:onKill(projectile.target)
                    end
                end
            end

            table.remove(self.arrows, i)
        end
    end

    -- Call grandparent directly (BaseUnit) to skip BaseUnitRanged's arrow loop
    BaseUnit.update(self, dt, grid)
end

-- ============================================================
-- resetCombatState(): reset Marc-specific per-round state
-- ============================================================
function Marc:resetCombatState()
    Marc.super.resetCombatState(self)
    self.attackCount   = 0
    self.currentTarget = nil
end

return Marc
