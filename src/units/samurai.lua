local BaseUnit = require('src.base_unit')

local Samurai = BaseUnit:extend()

function Samurai:new(row, col, owner, sprites)
    -- Samurai stats: melee fighter
    local stats = {
        health = 10,
        maxHealth = 10,
        damage = 1,
        attackSpeed = 1.1,
        moveSpeed = 1,    -- 1 cell per second
        attackRange = 0,  -- Melee (adjacent cells only)
        unitType = "samurai"
    }

    Samurai.super.new(self, row, col, owner, sprites, stats)

    -- Upgrade tracking fields
    self.damageFromAlliedDeaths = 0  -- Track cumulative damage bonus from ally deaths
    self.allyDeathsObserved = {}  -- Track which allies already counted

    -- Define upgrade tree (3 upgrades, can choose 2)
    self.upgradeTree = {
        -- Upgrade 1: Heal on kill
        {
            name = "Bloodthirst",
            description = "Heal 30% HP on enemy kill",
            onApply = function(unit)
                -- No immediate effect, handled in onKill()
            end
        },
        -- Upgrade 2: +1 damage per ally death in radius
        {
            name = "Vengeance",
            description = "+1 damage per ally death within 2 cells",
            onApply = function(unit)
                -- No immediate effect, handled in update() and getDamage()
            end
        },
        -- Upgrade 3: Enhanced isolation boost
        {
            name = "Lone Wolf",
            description = "Isolation damage boost +25% (75% total)",
            onApply = function(unit)
                -- No immediate effect, handled in getDamage()
            end
        }
    }
end

-- Check if Samurai is isolated (no friendly units within 2 cells)
function Samurai:isIsolated(grid)
    local allUnits = grid:getAllUnits()
    for _, unit in ipairs(allUnits) do
        if unit ~= self and unit.owner == self.owner and not unit.isDead then
            local distance = math.sqrt((unit.col - self.col)^2 + (unit.row - self.row)^2)
            if distance <= 2 then
                return false  -- Found a friendly nearby, not isolated
            end
        end
    end
    return true  -- No friendlies nearby, isolated
end

-- Passive: 50% more damage when isolated (75% with Lone Wolf upgrade)
function Samurai:getDamage(grid)
    local baseDamage = self.damage

    -- Apply isolation bonus
    if grid and self:isIsolated(grid) then
        if self:hasUpgrade(3) then
            baseDamage = baseDamage * 1.75  -- Lone Wolf: 75% boost
        else
            baseDamage = baseDamage * 2.0  -- Base: 100% boost when isolated
        end
    end

    -- Apply Vengeance damage bonus from ally deaths
    if self:hasUpgrade(2) then
        baseDamage = baseDamage + self.damageFromAlliedDeaths
    end

    return math.floor(baseDamage * (self.royalCommandBonus or 1))
end

-- Override update to track ally deaths for Vengeance upgrade
function Samurai:update(dt, grid)
    -- Check for dead allies within 2-cell radius (Vengeance upgrade)
    if self:hasUpgrade(2) and grid then
        local allUnits = grid:getAllUnits()
        for _, unit in ipairs(allUnits) do
            if unit ~= self and unit.owner == self.owner and unit.isDead then
                local distance = math.sqrt((unit.col - self.col)^2 + (unit.row - self.row)^2)
                if distance <= 2 then
                    -- Check if we've already counted this death
                    if not self.allyDeathsObserved[unit] then
                        self.allyDeathsObserved[unit] = true
                        self.damageFromAlliedDeaths = self.damageFromAlliedDeaths + 1
                        self:triggerBuffAnim()
                    end
                end
            end
        end
    end

    -- Call parent update for normal behavior
    Samurai.super.update(self, dt, grid)
end

function Samurai:resetCombatState()
    Samurai.super.resetCombatState(self)
    self.damageFromAlliedDeaths = 0
    self.allyDeathsObserved     = {}
end

-- Heal on kill (Bloodthirst upgrade)
function Samurai:onKill(target)
    -- Upgrade 1: Heal 30% HP on kill
    if self:hasUpgrade(1) then
        local healAmount = math.floor(self.maxHealth * 0.3)
        self.health = math.min(self.health + healAmount, self.maxHealth)
        self:triggerBuffAnim()
    end
end

-- Melee attack: apply damage (animation started by startMeleeAnimation in update())
function Samurai:attack(target, grid)
    Samurai.super.attack(self, target, grid)
end

return Samurai
