local BaseUnit = require('src.base_unit')

local Boney = BaseUnit:extend()

function Boney:new(row, col, owner, sprites)
    -- Boney stats: melee fighter
    local stats = {
        health = 7,
        maxHealth = 7,
        damage = 1,
        attackSpeed = 1,  -- 1 attack per second
        moveSpeed = 1,    -- 1 cell per second
        attackRange = 0,  -- Melee (adjacent cells only)
        unitType = "boney"
    }

    Boney.super.new(self, row, col, owner, sprites, stats)

    self.hitSound = "slice.mp3"

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
    local mult = self.royalCommandBonus or 1
    if self.health < self.maxHealth * 0.5 then
        if self:hasUpgrade(3) then
            return math.floor(self.damage * 3 * mult)
        else
            return math.floor(self.damage * 2 * mult)
        end
    end
    return math.floor(self.damage * mult)
end


-- Override update to handle upgrades that need to check state each frame
function Boney:update(dt, grid)
    -- Handle Bone Mending upgrade (heal once at 50% HP threshold)
    if self:hasUpgrade(1) and not self.hasHealed and not self.isDead then
        local belowHalf = self.health < self.maxHealth * 0.5

        -- Check if we just crossed the 50% threshold
        if self.wasAboveHalfHealth and belowHalf then
            -- Trigger one-time heal
            if not self._noHeal then
                local healAmount = math.floor(self.maxHealth * 0.25)
                self.health = math.min(self.health + healAmount, self.maxHealth)
                self:triggerBuffAnim()
            end
            self.hasHealed = true
        end

        -- Update threshold tracker
        self.wasAboveHalfHealth = not belowHalf
    end

    -- Handle Fury upgrade (attack speed boost under 50% HP)
    if self:hasUpgrade(2) and not self.isDead then
        if self.health < self.maxHealth * 0.5 then
            -- Apply 50% attack speed boost
            if self.attackSpeed ~= self.baseAttackSpeed * 1.5 then
                self:triggerBuffAnim()
            end
            self.attackSpeed = self.baseAttackSpeed * 1.5
        else
            -- Reset to base attack speed
            self.attackSpeed = self.baseAttackSpeed
        end
    end

    -- Call parent update to handle normal AI behavior
    Boney.super.update(self, dt, grid)
end

function Boney:resetCombatState()
    Boney.super.resetCombatState(self)
    self.hasHealed          = false
    self.wasAboveHalfHealth = true
end

-- Melee attack: apply damage (animation started by startMeleeAnimation in update())
function Boney:attack(target, grid)
    Boney.super.attack(self, target, grid)
end

return Boney
