local BaseUnit = require('src.base_unit')
local BaseUnitRanged = require('src.base_unit_ranged')
local Constants = require('src.constants')
local tween = require('lib.tween')

local Pouch = BaseUnitRanged:extend()

function Pouch:new(row, col, owner, sprites)
    local stats = {
        health          = 9,
        maxHealth       = 9,
        damage          = 1,
        attackSpeed     = 0.8,
        moveSpeed       = 1,
        attackRange     = 4,
        projectileSpeed = 12,
        unitType        = "pouch"
    }

    Pouch.super.new(self, row, col, owner, sprites, stats)

    self.lastTarget         = nil
    self.uniqueTargetStreak = 0
    self.boulderArmed       = false
    self.firstHitTargets    = {}

    self.upgradeTree = {
        {
            name = "Pebble Drum",
            description = "First hit on each enemy deals +1 damage",
            onApply = function(unit) end
        },
        {
            name = "Quick Combo",
            description = "Boulder triggers after 2 different targets instead of 3",
            onApply = function(unit) end
        },
        {
            name = "Stunning Boulder",
            description = "Boulder stuns 2s and deals double damage",
            onApply = function(unit) end
        }
    }
end

function Pouch:getEnergy()
    local threshold = self:hasUpgrade(2) and 2 or 3
    if self.boulderArmed then
        return threshold, threshold
    end
    return self.uniqueTargetStreak, threshold
end

-- ============================================================
-- Passive: Rock & Roll target rotation
-- Prefer an in-range enemy that is NOT the previous target,
-- but only when an alternative exists. Falls back to the same
-- target when it's the only one in range.
-- Out-of-range fallback uses base nearest-enemy logic so
-- movement still approaches the closest threat.
-- ============================================================
function Pouch:findNearestEnemy(grid)
    local allUnits = grid:getAllUnits()

    local inRangeCount = 0
    local lastTargetInRange = false
    for _, unit in ipairs(allUnits) do
        if unit.owner ~= self.owner and not unit.isDead and self:isInAttackRange(unit) then
            inRangeCount = inRangeCount + 1
            if unit == self.lastTarget then
                lastTargetInRange = true
            end
        end
    end

    local excludeLastTarget = lastTargetInRange and inRangeCount >= 2

    local nearestEnemy = nil
    local shortestDistance = math.huge
    for _, unit in ipairs(allUnits) do
        if unit.owner ~= self.owner and not unit.isDead then
            if not (excludeLastTarget and unit == self.lastTarget) then
                local distance = math.sqrt((unit.col - self.col)^2 + (unit.row - self.row)^2)
                local isBetter = distance < shortestDistance
                if distance == shortestDistance and nearestEnemy then
                    isBetter = (unit.col < nearestEnemy.col) or
                               (unit.col == nearestEnemy.col and unit.row < nearestEnemy.row) or
                               (unit.col == nearestEnemy.col and unit.row == nearestEnemy.row
                                and unit.owner < nearestEnemy.owner)
                end
                if isBetter then
                    shortestDistance = distance
                    nearestEnemy = unit
                end
            end
        end
    end

    return nearestEnemy
end

-- ============================================================
-- attack(): track target rotation streak, arm boulder for next
-- throw when threshold reached, then delegate to base.
-- ============================================================
function Pouch:attack(target, grid)
    if not target or target.isDead then return end

    BaseUnitRanged.attack(self, target, grid)

    if self.boulderArmed then
        self.boulderArmed = false
    end

    if target ~= self.lastTarget then
        self.uniqueTargetStreak = self.uniqueTargetStreak + 1
    else
        self.uniqueTargetStreak = 0
    end

    local threshold = self:hasUpgrade(2) and 2 or 3
    if self.uniqueTargetStreak >= threshold then
        self.boulderArmed = true
        self.uniqueTargetStreak = 0
    end

    self.lastTarget = target

    -- Force the AI loop to re-acquire next tick so Rock & Roll picks a fresh
    -- target. Without this, base_unit.lua only calls findNearestEnemy when
    -- target is nil/dead, so Pouch would keep hammering the same enemy.
    self.target = nil
end

-- ============================================================
-- createProjectile(): tag boulder + first-hit flags so the
-- projectile carries upgrade context to its impact frame.
-- ============================================================
function Pouch:createProjectile(target, grid)
    local proj = BaseUnitRanged.createProjectile(self, target, grid)
    proj.isBoulder  = self.boulderArmed or false
    proj.isFirstHit = self:hasUpgrade(1) and not self.firstHitTargets[target] or false
    return proj
end

-- ============================================================
-- onProjectileHit(): apply damage with Pebble Drum bonus and
-- Stunning Boulder doubling, plus stun on boulder hits.
-- ============================================================
function Pouch:onProjectileHit(projectile, grid)
    if not (projectile.target and not projectile.target.isDead) then return end

    local damage = projectile.damage
    if projectile.isFirstHit then
        damage = damage + 1
    end
    if projectile.isBoulder and self:hasUpgrade(3) then
        damage = damage * 2
    end

    projectile.target:takeDamage(damage, self, grid)
    self.firstHitTargets[projectile.target] = true

    if projectile.isBoulder and not projectile.target.isDead then
        local stunDuration = self:hasUpgrade(3) and 2.0 or 1.0
        projectile.target.stunTimer = math.max(projectile.target.stunTimer, stunDuration)
    end

    if projectile.target.isDead then
        grid:killUnit(projectile.target)
        if projectile.shooter then
            projectile.shooter:onKill(projectile.target)
        end
    end
end

-- ============================================================
-- drawProjectile(): tumbling rock with a small parabolic arc.
-- Reuses the catapult projectile sprite. Boulder shots are
-- visibly larger.
-- ============================================================
function Pouch:drawProjectile(projectile)
    local lg = love.graphics
    local img = self.sprites and self.sprites.catapultProjectile

    local easedProgress = tween.easing.linear(projectile.progress, 0, 1, 1)

    local startVisualRow  = Constants.toVisualRow(projectile.startRow)
    local targetVisualRow = Constants.toVisualRow(projectile.targetRow)
    local startX = Constants.GRID_OFFSET_X + (projectile.startCol - 1) * Constants.CELL_SIZE + Constants.CELL_SIZE / 2
    local startY = Constants.GRID_OFFSET_Y + (startVisualRow - 1)  * Constants.CELL_SIZE + Constants.CELL_SIZE / 2
    local endX   = Constants.GRID_OFFSET_X + (projectile.targetCol - 1) * Constants.CELL_SIZE + Constants.CELL_SIZE / 2
    local endY   = Constants.GRID_OFFSET_Y + (targetVisualRow - 1) * Constants.CELL_SIZE + Constants.CELL_SIZE / 2

    local currentX = startX + (endX - startX) * easedProgress
    local currentY = startY + (endY - startY) * easedProgress

    local arcHeight = 14 * Constants.SCALE
    currentY = currentY - math.sin(easedProgress * math.pi) * arcHeight

    local rotation = easedProgress * math.pi * 4

    if img then
        local sw    = img:getWidth()
        local sh    = img:getHeight()
        local scale = Constants.SCALE * (projectile.isBoulder and 4.5 or 3)
        lg.setColor(1, 1, 1, 1)
        lg.setShader(BaseUnit.getPaletteShader())
        lg.draw(img, currentX, currentY, rotation, scale, scale, sw / 2, sh / 2)
        lg.setShader()
    else
        lg.setColor(0.5, 0.4, 0.3, 1)
        local size = (projectile.isBoulder and 6 or 4) * Constants.SCALE
        lg.circle('fill', currentX, currentY, size)
    end

    lg.setColor(1, 1, 1, 1)
end

-- ============================================================
-- resetCombatState(): clear per-round rotation/combo state.
-- ============================================================
function Pouch:resetCombatState()
    Pouch.super.resetCombatState(self)
    self.lastTarget         = nil
    self.uniqueTargetStreak = 0
    self.boulderArmed       = false
    self.firstHitTargets    = {}
end

return Pouch
