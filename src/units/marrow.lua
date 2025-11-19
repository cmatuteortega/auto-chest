local BaseUnitRanged = require('src.base_unit_ranged')

local Marrow = BaseUnitRanged:extend()

function Marrow:new(row, col, owner, sprites)
    -- Marrow stats: ranged archer
    local stats = {
        health = 8,
        maxHealth = 7,
        damage = 1,
        attackSpeed = 0.7,      -- 1 attack per second
        moveSpeed = 1,        -- 1 cell per second
        attackRange = 3,      -- 3 cells range
        projectileSpeed = 0.2, -- Arrow flight time
        unitType = "marrow"
    }

    Marrow.super.new(self, row, col, owner, sprites, stats)

    -- Track damage boost timer for upgrade 2
    self.damageBoostTimer = 0

    -- Define upgrade tree (3 upgrades, can choose 2)
    self.upgradeTree = {
        -- Upgrade 1: +1 range
        {
            name = "Extended Range",
            description = "+1 attack range",
            onApply = function(unit)
                unit.attackRange = unit.attackRange + 1
            end
        },
        -- Upgrade 2: 2s damage boost on kill
        {
            name = "Momentum",
            description = "+50% damage for 2s after kill",
            onApply = function(unit)
                -- No immediate effect, handled in update() and getDamage()
            end
        },
        -- Upgrade 3: Multi-shot
        {
            name = "Volley",
            description = "Shoot two enemies within range",
            onApply = function(unit)
                -- No immediate effect, handled in attack()
            end
        }
    }
end

-- Override getDamage to apply damage boost from upgrade 2
function Marrow:getDamage(grid)
    if self:hasUpgrade(2) and self.damageBoostTimer > 0 then
        return math.floor(self.damage * 1.5)
    end
    return self.damage
end

-- Override update to decrement damage boost timer
function Marrow:update(dt, grid)
    if self.damageBoostTimer > 0 then
        self.damageBoostTimer = self.damageBoostTimer - dt
    end

    -- Call parent update for normal behavior
    Marrow.super.update(self, dt, grid)
end

-- Passive: Gain attack speed on kill
function Marrow:onKill(target)
    -- Increase attack speed by 0.2 per kill (stacks permanently for the battle)
    self.attackSpeed = self.attackSpeed + 0.2

    -- Upgrade 2: 2s damage boost
    if self:hasUpgrade(2) then
        self.damageBoostTimer = 2
    end
end

-- Override attack for multi-shot (upgrade 3)
function Marrow:attack(target, grid)
    if target and not target.isDead then
        -- First projectile: always to the primary target
        local projectile = self:createProjectile(target, grid)
        table.insert(self.arrows, projectile)

        -- Upgrade 3: Second arrow to nearby enemy
        if self:hasUpgrade(3) then
            local secondTarget = self:findSecondTarget(grid, target)
            if secondTarget and not secondTarget.isDead then
                local projectile2 = self:createProjectile(secondTarget, grid)
                table.insert(self.arrows, projectile2)
            end
        end
    end
end

-- Helper function to find second target for multi-shot
function Marrow:findSecondTarget(grid, primaryTarget)
    local allUnits = grid:getAllUnits()
    local closest = nil
    local closestDist = math.huge

    for _, unit in ipairs(allUnits) do
        if unit.owner ~= self.owner and
           not unit.isDead and
           unit ~= primaryTarget and
           self:isInAttackRange(unit) then
            local dist = math.sqrt((unit.col - self.col)^2 + (unit.row - self.row)^2)
            if dist < closestDist then
                closest = unit
                closestDist = dist
            end
        end
    end

    return closest
end

return Marrow
