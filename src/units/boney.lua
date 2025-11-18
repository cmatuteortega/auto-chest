local BaseUnit = require('src.base_unit')

local Boney = BaseUnit:extend()

function Boney:new(row, col, owner, sprites)
    -- Boney stats: melee fighter
    local stats = {
        health = 10,
        maxHealth = 10,
        damage = 1,
        attackSpeed = 1,  -- 1 attack per second
        moveSpeed = 1,    -- 1 cell per second
        attackRange = 0,  -- Melee (adjacent cells only)
        unitType = "boney"
    }

    Boney.super.new(self, row, col, owner, sprites, stats)

    -- Boney-specific upgrade flags
    self.hasHealed = false  -- Track if one-time heal has been used
    self.wasAboveHalfHealth = true  -- Track HP threshold crossing

    -- Define upgrade tree (3 upgrades, can choose 2)
    self.upgradeTree = {
        -- Upgrade 1: One-time heal when reaching 50% HP
        {
            name = "Mend",
            description = "Heal 25% HP when reaching 50% HP",
            onApply = function(unit)
                -- No immediate effect, just enables the passive
            end
        },
        -- Upgrade 2: Attack speed boost under 50% HP
        {
            name = "Fury",
            description = "+50% ATKSPD when below 50% HP",
            onApply = function(unit)
                -- Dynamic effect, applied in update()
            end
        },
        -- Upgrade 3: Increased damage under 50% HP
        {
            name = "Desperate",
            description = "3x damage (instead of 2x)",
            onApply = function(unit)
                -- Dynamic effect, applied in getDamage()
            end
        }
    }
end

-- Passive: Double damage when below 50% HP (or 3x with Desperation upgrade)
function Boney:getDamage(grid)
    if self.health < self.maxHealth * 0.5 then
        -- Check if Desperation upgrade (upgrade 3) is active
        if self:hasUpgrade(3) then
            return self.damage * 3  -- Desperation: 3x damage
        else
            return self.damage * 2  -- Base passive: 2x damage
        end
    end
    return self.damage
end


-- Override update to handle upgrades that need to check state each frame
function Boney:update(dt, grid)
    -- Handle Bone Mending upgrade (heal once at 50% HP threshold)
    if self:hasUpgrade(1) and not self.hasHealed and not self.isDead then
        local belowHalf = self.health < self.maxHealth * 0.5

        -- Check if we just crossed the 50% threshold
        if self.wasAboveHalfHealth and belowHalf then
            -- Trigger one-time heal
            local healAmount = math.floor(self.maxHealth * 0.25)
            self.health = math.min(self.health + healAmount, self.maxHealth)
            self.hasHealed = true
        end

        -- Update threshold tracker
        self.wasAboveHalfHealth = not belowHalf
    end

    -- Handle Fury upgrade (attack speed boost under 50% HP)
    if self:hasUpgrade(2) and not self.isDead then
        if self.health < self.maxHealth * 0.5 then
            -- Apply 50% attack speed boost
            self.attackSpeed = self.baseAttackSpeed * 1.5
        else
            -- Reset to base attack speed
            self.attackSpeed = self.baseAttackSpeed
        end
    end

    -- Call parent update to handle normal AI behavior
    Boney.super.update(self, dt, grid)
end

-- Melee attack: lunge toward target and apply damage
function Boney:attack(target, grid)
    if target and not target.isDead then
        -- Trigger attack animation (lunge)
        self.attackAnimProgress = 0  -- Reset to start
        self.attackTargetCol = target.col
        self.attackTargetRow = target.row

        -- Apply damage (use getDamage() for passive abilities, pass grid)
        target:takeDamage(self:getDamage(grid))

        -- If target died, mark cell as unoccupied but keep unit visible
        if target.isDead then
            local cell = grid:getCell(target.col, target.row)
            if cell then
                cell.occupied = false  -- Allow movement through this cell
                -- Keep cell.unit so the dead sprite remains visible
            end

            -- Trigger onKill hook for passive abilities
            self:onKill(target)
        end
    end
end

return Boney
