local BaseUnit = require('src.base_unit')

local Humerus = BaseUnit:extend()

function Humerus:new(row, col, owner, sprites)
    local stats = {
        health      = 22,
        maxHealth   = 22,
        damage      = 4,
        attackSpeed = 0.35,
        moveSpeed   = 1,
        attackRange = 0,
        unitType    = "humerus"
    }

    Humerus.super.new(self, row, col, owner, sprites, stats)

    self.hitCounter          = 0     -- counts attacks for Cleave (upgrade 3)
    self.royalCommandCleared = false -- true once bonuses are cleared on death

    self.upgradeTree = {
        {
            name        = "Bone Throne",
            description = "Heal 15% max HP after killing a foe",
            onApply     = function(unit) end
        },
        {
            name        = "Execute",
            description = "+100% damage to enemies below 30% HP",
            onApply     = function(unit) end
        },
        {
            name        = "Cleave",
            description = "Every 3rd hit also strikes units flanking the target",
            onApply     = function(unit) end
        }
    }
end

-- Royal Command passive: allies attacking the same target gain +20% ATK.
-- We set royalCommandBonus on qualifying allies each frame.
function Humerus:update(dt, grid)
    if self.isDead then
        -- Clear bonus from allies once on death so it doesn't linger
        if not self.royalCommandCleared then
            local allUnits = grid:getAllUnits()
            for _, unit in ipairs(allUnits) do
                if unit.owner == self.owner and unit ~= self then
                    unit.royalCommandBonus = 1.0
                end
            end
            self.royalCommandCleared = true
        end
        Humerus.super.update(self, dt, grid)
        return
    end

    local allUnits = grid:getAllUnits()
    for _, unit in ipairs(allUnits) do
        if unit.owner == self.owner and unit ~= self and not unit.isDead then
            if self.target and not self.target.isDead and unit.target == self.target then
                unit.royalCommandBonus = 1.2
            else
                unit.royalCommandBonus = 1.0
            end
        end
    end

    Humerus.super.update(self, dt, grid)
end

-- Execute: doubles damage against targets below 30% HP.
function Humerus:getDamage(grid)
    local dmg = self.damage
    if self:hasUpgrade(2) and self.target and not self.target.isDead then
        local hp = self.target.health / self.target.maxHealth
        if hp < 0.3 then
            dmg = dmg * 2
        end
    end
    return math.floor(dmg * (self.royalCommandBonus or 1))
end

-- Melee attack with optional Cleave on every 3rd hit.
-- Animation is started by startMeleeAnimation() in update(); damage fires here at 2/3 progress.
function Humerus:attack(target, grid)
    if not target or target.isDead then return end

    target:takeDamage(self:getDamage(grid))
    self.hitCounter = self.hitCounter + 1

    if target.isDead then
        local cell = grid:getCell(target.col, target.row)
        if cell then cell.occupied = false end
        self:onKill(target)
    end

    -- Cleave: also hit units to the left and right of the target
    if self:hasUpgrade(3) and self.hitCounter % 3 == 0 then
        local allUnits = grid:getAllUnits()
        for _, unit in ipairs(allUnits) do
            if unit.owner ~= self.owner and not unit.isDead and unit ~= target then
                local dc = math.abs(unit.col - target.col)
                local dr = math.abs(unit.row - target.row)
                if dr == 0 and dc == 1 then  -- flanking: same row, adjacent column
                    local cleaveDmg = self.damage
                    if self:hasUpgrade(2) then
                        local hp = unit.health / unit.maxHealth
                        if hp < 0.3 then cleaveDmg = cleaveDmg * 2 end
                    end
                    cleaveDmg = math.floor(cleaveDmg * (self.royalCommandBonus or 1))
                    unit:takeDamage(cleaveDmg)
                    if unit.isDead then
                        local deadCell = grid:getCell(unit.col, unit.row)
                        if deadCell then deadCell.occupied = false end
                        self:onKill(unit)
                    end
                end
            end
        end
    end
end

-- Bone Throne: heal 15% max HP on kill.
function Humerus:onKill(target)
    if self:hasUpgrade(1) then
        local heal = math.floor(self.maxHealth * 0.15)
        self.health = math.min(self.health + heal, self.maxHealth)
    end
end

function Humerus:resetCombatState()
    Humerus.super.resetCombatState(self)
    self.hitCounter          = 0
    self.royalCommandCleared = false
end

return Humerus
