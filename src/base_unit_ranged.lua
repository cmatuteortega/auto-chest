local BaseUnit = require('src.base_unit')
local Constants = require('src.constants')
local tween = require('lib.tween')

--[[
================================================================================
RANGED UNIT EXTENSION
================================================================================

This class extends BaseUnit to provide ranged attack behavior with projectiles.
See BaseUnit for full upgrade system documentation.

RANGED-SPECIFIC FEATURES:
-------------------------
- Projectile system with flight time
- Can attack over obstacles (no line-of-sight required)
- Stops moving when within attackRange (doesn't need to be adjacent)
- Damage applied when projectile reaches target, not instantly

RANGED STATS:
-------------
- attackRange: Manhattan distance for attacks (default 3 for most ranged units)
- projectileSpeed: Flight time in seconds (default 0.2)
- baseProjectileSpeed: Stored for upgrades that modify projectile speed

UPGRADE CONSIDERATIONS FOR RANGED UNITS:
----------------------------------------
When implementing upgrades for ranged units, consider:

1. PROJECTILE SPEED: Modify self.projectileSpeed in update() based on hasUpgrade()
2. ATTACK RANGE: Can be modified via onApply or checked dynamically
3. DAMAGE: Override getDamage() - projectile captures damage at fire time
4. ON-HIT EFFECTS: Projectile stores shooter reference, onKill() is called properly
5. MULTI-SHOT: Override createProjectile() or attack() for multiple projectiles

EXAMPLE RANGED UPGRADE TREE:
----------------------------
self.upgradeTree = {
    {
        name = "Piercing",
        description = "Arrows deal +1 damage",
        onApply = function(unit)
            unit.damage = unit.damage + 1
        end
    },
    {
        name = "Swift",
        description = "+50% attack speed",
        onApply = function(unit)
            -- Check in update() for dynamic effects
        end
    },
    {
        name = "Sniper",
        description = "+2 attack range",
        onApply = function(unit)
            unit.attackRange = unit.attackRange + 2
        end
    }
}

KEY OVERRIDABLE METHODS:
------------------------
- createProjectile(target, grid): Customize projectile properties
- drawProjectile(projectile): Custom projectile visuals
- findGoalNearTarget(grid, target): Movement behavior (already optimized for ranged)

================================================================================
--]]

local BaseUnitRanged = BaseUnit:extend()

function BaseUnitRanged:new(row, col, owner, sprites, stats)
    -- Call parent constructor
    BaseUnitRanged.super.new(self, row, col, owner, sprites, stats)

    -- Ranged unit specific properties
    self.arrows = {}  -- Array of active projectiles
    self.projectileSpeed = stats.projectileSpeed or 0.2  -- Flight time in seconds
    self.baseProjectileSpeed = stats.projectileSpeed or 0.2  -- Store base for upgrades
end

-- Override: Ranged units stop when within attack range (don't need to be adjacent)
-- Note: Can target enemies even with obstacles between them (projectiles fly over)
function BaseUnitRanged:findGoalNearTarget(grid, target)
    if not target then return nil, nil end

    -- If already in range, don't move (can shoot over obstacles)
    if self:isInAttackRange(target) then
        return self.col, self.row
    end

    -- Find a position within attack range of the target
    local targetDistance = self.attackRange

    -- Calculate direction vector from target to us
    local dx = self.col - target.col
    local dy = self.row - target.row
    local currentDistance = math.sqrt(dx * dx + dy * dy)

    if currentDistance == 0 then
        -- We're on top of the target somehow, move to any adjacent cell
        return BaseUnit.findGoalNearTarget(self, grid, target)
    end

    -- Normalize direction
    dx = dx / currentDistance
    dy = dy / currentDistance

    -- Try positions at attackRange distance from target
    local attempts = {
        -- Ideal position at exactly attackRange
        {
            col = math.floor(target.col + dx * targetDistance + 0.5),
            row = math.floor(target.row + dy * targetDistance + 0.5)
        },
        -- Closer positions if ideal is blocked
        {
            col = math.floor(target.col + dx * (targetDistance - 1) + 0.5),
            row = math.floor(target.row + dy * (targetDistance - 1) + 0.5)
        },
        -- Try positions around the target at range
        {col = target.col + targetDistance, row = target.row},
        {col = target.col - targetDistance, row = target.row},
        {col = target.col, row = target.row + targetDistance},
        {col = target.col, row = target.row - targetDistance},
    }

    -- Find first valid empty position
    for _, pos in ipairs(attempts) do
        if grid:isValidCell(pos.col, pos.row) then
            local cell = grid:getCell(pos.col, pos.row)
            -- Check if cell is empty or is our current position
            if not cell.occupied or (pos.col == self.col and pos.row == self.row) then
                -- Verify this position is within attack range
                local dist = math.abs(pos.col - target.col) + math.abs(pos.row - target.row)
                if dist <= self.attackRange and dist > 0 then
                    return pos.col, pos.row
                end
            end
        end
    end

    -- Fallback: use base implementation (adjacent)
    return BaseUnit.findGoalNearTarget(self, grid, target)
end

-- Ranged attack: shoot projectile at target
-- Note: Projectiles fly over obstacles - no line-of-sight required
function BaseUnitRanged:attack(target, grid)
    if target and not target.isDead then
        -- Create projectile (flies directly to target, ignoring obstacles)
        local projectile = self:createProjectile(target, grid)
        table.insert(self.arrows, projectile)

        -- Note: Damage is applied when projectile reaches target, not instantly
    end
end

-- Create a projectile (can be overridden for custom projectile properties)
function BaseUnitRanged:createProjectile(target, grid)
    -- Units only attack when stationary, so use current position
    return {
        startCol = self.col,
        startRow = self.row,
        targetCol = target.col,
        targetRow = target.row,
        progress = 0,
        duration = self.projectileSpeed,
        target = target,
        damage = self:getDamage(grid),  -- Use getDamage() for passive abilities
        shooter = self  -- Reference to unit that shot this projectile (for onKill callback)
    }
end

-- Override update to handle projectile animations
function BaseUnitRanged:update(dt, grid)
    -- Update projectiles
    for i = #self.arrows, 1, -1 do
        local projectile = self.arrows[i]
        projectile.progress = projectile.progress + (dt / projectile.duration)

        if projectile.progress >= 1.0 then
            -- Projectile reached target, apply damage
            if projectile.target and not projectile.target.isDead then
                projectile.target:takeDamage(projectile.damage)

                -- If target died, mark cell as unoccupied and trigger onKill
                if projectile.target.isDead then
                    local cell = grid:getCell(projectile.target.col, projectile.target.row)
                    if cell then
                        cell.occupied = false
                    end

                    -- Trigger onKill hook for passive abilities
                    if projectile.shooter then
                        projectile.shooter:onKill(projectile.target)
                    end
                end
            end

            -- Remove projectile
            table.remove(self.arrows, i)
        end
    end

    -- Call parent update for movement and AI
    BaseUnit.update(self, dt, grid)
end

-- Override draw to render projectiles
function BaseUnitRanged:drawAttackVisuals()
    -- Draw all active projectiles
    for _, projectile in ipairs(self.arrows) do
        self:drawProjectile(projectile)
    end
end

-- Draw a single projectile (override this in subclasses for custom visuals)
function BaseUnitRanged:drawProjectile(projectile)
    local lg = love.graphics

    -- Use easing for smooth projectile flight
    local easedProgress = tween.easing.linear(projectile.progress, 0, 1, 1)

    -- Calculate projectile position
    local startX = Constants.GRID_OFFSET_X + (projectile.startCol - 1) * Constants.CELL_SIZE + Constants.CELL_SIZE / 2
    local startY = Constants.GRID_OFFSET_Y + (projectile.startRow - 1) * Constants.CELL_SIZE + Constants.CELL_SIZE / 2
    local endX = Constants.GRID_OFFSET_X + (projectile.targetCol - 1) * Constants.CELL_SIZE + Constants.CELL_SIZE / 2
    local endY = Constants.GRID_OFFSET_Y + (projectile.targetRow - 1) * Constants.CELL_SIZE + Constants.CELL_SIZE / 2

    local currentX = startX + (endX - startX) * easedProgress
    local currentY = startY + (endY - startY) * easedProgress

    -- Default projectile: arrow shape (scaled)
    lg.setColor(0.8, 0.6, 0.3, 1)  -- Brown/tan color
    lg.setLineWidth(2 * Constants.SCALE)

    -- Arrow shaft
    local dx = endX - startX
    local dy = endY - startY
    local angle = math.atan2(dy, dx)

    -- Draw line from start toward current position (scaled)
    local arrowLength = 12 * Constants.SCALE
    local backX = currentX - math.cos(angle) * arrowLength
    local backY = currentY - math.sin(angle) * arrowLength

    lg.line(backX, backY, currentX, currentY)

    -- Draw arrowhead (simple triangle, scaled)
    local headSize = 6 * Constants.SCALE
    local perpAngle1 = angle + math.pi * 0.75
    local perpAngle2 = angle - math.pi * 0.75

    local tip1X = currentX + math.cos(perpAngle1) * headSize
    local tip1Y = currentY + math.sin(perpAngle1) * headSize
    local tip2X = currentX + math.cos(perpAngle2) * headSize
    local tip2Y = currentY + math.sin(perpAngle2) * headSize

    lg.polygon('fill', currentX, currentY, tip1X, tip1Y, tip2X, tip2Y)

    lg.setLineWidth(1)
end

return BaseUnitRanged
