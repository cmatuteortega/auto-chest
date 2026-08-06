local BaseUnit = require('src.base_unit')

local Clavicula = BaseUnit:extend()

function Clavicula:new(row, col, owner, sprites)
    local stats = {
        health      = 12,
        maxHealth   = 12,
        damage      = 2,
        attackSpeed = 0.75,
        moveSpeed   = 1,
        attackRange = 0,   -- melee
        unitType    = "clavicula"
    }

    Clavicula.super.new(self, row, col, owner, sprites, stats)

    self.hitSound = "slice.mp3"
    self.hitCounter      = 0
    self.spinFlag        = false   -- consumed in update() where grid is available
    self.killDamageBonus = 0       -- War Spoils: +1 damage per kill, resets each round

    self.upgradeTree = {
        {
            name        = "Bloodwhirl",
            description = "Whirlwind heals 50% of damage dealt instead of 30%",
            onApply     = function(_) end
        },
        {
            name        = "Frenzy",
            description = "Whirlwind triggers every 9 hits instead of 12",
            onApply     = function(_) end
        },
        {
            name        = "War Spoils",
            description = "On kill, gain +1 damage for the rest of the round (stacks)",
            onApply     = function(_) end
        },
    }
end

function Clavicula:getEnergy()
    local threshold = self:hasUpgrade(2) and 9 or 12
    return self.hitCounter, threshold
end

function Clavicula:getDamage()
    return math.floor((self.damage + self.killDamageBonus) * (self.royalCommandBonus or 1))
end

-- Track hits received toward Whirlwind
function Clavicula:takeDamage(amount, attacker, grid)
    Clavicula.super.takeDamage(self, amount, attacker, grid)

    if self.isDead then return end

    local threshold = self:hasUpgrade(2) and 9 or 12
    self.hitCounter = self.hitCounter + 1
    if self.hitCounter >= threshold then
        self.hitCounter = 0
        self.spinFlag   = true
    end
end

-- Track hits given toward Whirlwind
function Clavicula:attack(target, grid)
    Clavicula.super.attack(self, target, grid)

    local threshold = self:hasUpgrade(2) and 9 or 12
    self.hitCounter = self.hitCounter + 1
    if self.hitCounter >= threshold then
        self.hitCounter = 0
        self.spinFlag   = true
    end
end

function Clavicula:onKill(target)
    if self:hasUpgrade(3) then
        self.killDamageBonus = self.killDamageBonus + 1
        self:triggerBuffAnim()
    end
end

-- Spin: deal damage to all adjacent enemies, heal based on total damage dealt
function Clavicula:doSpin(grid)
    local dmg       = self:getDamage()
    local healTotal = 0

    for _, unit in ipairs(grid:getAllUnits()) do
        if unit.owner ~= self.owner and not unit.isDead then
            local dx = math.abs(unit.col - self.col)
            local dy = math.abs(unit.row - self.row)
            if dx <= 1 and dy <= 1 then
                unit:takeDamage(dmg, self, grid)
                AudioManager.playSFX("slice.mp3")
                if unit.isDead then
                    grid:killUnit(unit)
                    self:onKill(unit)
                end
                healTotal = healTotal + dmg
            end
        end
    end

    -- Heal: 30% of damage dealt (50% with upgrade 1)
    if healTotal > 0 then
        local healFraction = self:hasUpgrade(1) and 0.5 or 0.3
        local heal = math.max(1, math.floor(healTotal * healFraction))
        self.health = math.min(self.maxHealth, self.health + heal)
        self:triggerBuffAnim()
    end

end

function Clavicula:update(dt, grid)
    -- Consume spin flag before super (grid is needed here)
    if self.spinFlag then
        self.spinFlag = false
        self:doSpin(grid)
    end

    Clavicula.super.update(self, dt, grid)
end

function Clavicula:resetCombatState()
    Clavicula.super.resetCombatState(self)
    self.hitCounter      = 0
    self.spinFlag        = false
    self.killDamageBonus = 0
end


return Clavicula
