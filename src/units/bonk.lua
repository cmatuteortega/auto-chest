local BaseUnit = require('src.base_unit')

local Bonk = BaseUnit:extend()

function Bonk:new(row, col, owner, sprites)
    local stats = {
        health      = 11,
        maxHealth   = 11,
        damage      = 1,
        attackSpeed = 0.7,
        moveSpeed   = 1,
        attackRange = 0,
        unitType    = "bonk"
    }

    Bonk.super.new(self, row, col, owner, sprites, stats)

    self.hitCount = 0  -- tracks hits toward Power Strike threshold

    self.upgradeTree = {
        { name = "Brute Force",   description = "Power Strike triggers every 4th hit instead of 3rd, but stuns the target for 1.5s", onApply = function(unit) end },
        { name = "Cleave",        description = "Power Strike also hits units in adjacent side columns, applying all other active upgrades",  onApply = function(unit) end },
        { name = "Counter Crush", description = "Every hit removes 1 counter from enemy units with hit-counter mechanics",            onApply = function(unit) end },
    }
end

function Bonk:getEnergy()
    local threshold = self:hasUpgrade(1) and 4 or 3
    return self.hitCount, threshold
end

function Bonk:attack(target, grid)
    self.hitCount = self.hitCount + 1

    local threshold = self:hasUpgrade(1) and 4 or 3
    local isPowerStrike = false
    if self.hitCount >= threshold then
        self.hitCount = 0
        isPowerStrike = true
    end

    local dmg = isPowerStrike and (self.damage * 3) or self.damage

    -- Stun on Power Strike (Brute Force)
    if isPowerStrike and self:hasUpgrade(1) then
        target.stunTimer = 1.5
    end

    -- Deal damage to primary target
    target:takeDamage(dmg)
    AudioManager.playSFX(isPowerStrike and "big-hit.mp3" or "mid-hit.mp3")

    -- Cleave: hit adjacent side columns on Power Strike
    if isPowerStrike and self:hasUpgrade(2) then
        for _, u in ipairs(grid:getAllUnits()) do
            if u ~= target and not u.isDead
                and u.owner == target.owner
                and u.row == target.row
                and math.abs(u.col - target.col) == 1
            then
                u:takeDamage(dmg)
                AudioManager.playSFX("big-hit.mp3")
                -- Brute Force stun also applies to cleaved targets
                if self:hasUpgrade(1) then
                    u.stunTimer = 1.5
                end
                -- Counter Crush also applies to cleaved targets
                if self:hasUpgrade(3) then
                    u.hitCounter = math.max(0, (u.hitCounter or 0) - 1)
                end
            end
        end
    end

    -- Counter Crush: remove 1 hitCounter from primary target on every hit
    if self:hasUpgrade(3) then
        target.hitCounter = math.max(0, (target.hitCounter or 0) - 1)
    end
end

function Bonk:resetCombatState()
    Bonk.super.resetCombatState(self)
    self.hitCount = 0
end

return Bonk
