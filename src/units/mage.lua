local BaseUnit        = require('src.base_unit')
local BaseUnitRanged  = require('src.base_unit_ranged')
local Constants       = require('src.constants')

local Mage = BaseUnitRanged:extend()

function Mage:new(row, col, owner, sprites)
    local stats = {
        health          = 11,
        maxHealth       = 11,
        damage          = 1,
        attackSpeed     = 0.65,
        moveSpeed       = 1,
        attackRange     = 3,
        projectileSpeed = 0.25,
        unitType        = "mage"
    }

    Mage.super.new(self, row, col, owner, sprites, stats)

    -- Hit counter: increments on attacks made and damage received
    self.hitCounter      = 0
    self.fireballPending = false  -- set in takeDamage (no grid access there)

    -- Active fireball: { startCol, startRow, targetCol, targetRow, progress, duration, damage }
    self.fireball  = nil

    -- Fire patches for Burning Ground upgrade: { col, row, timer, damageTimer }
    self.firePatches = {}

    -- Arcane Surge upgrade state
    self.arcaneTimer    = 0
    self.arcaneActive   = false
    self.preArcaneSpeed = nil

    self.upgradeTree = {
        {
            name        = "Burning Ground",
            description = "Fireball leaves fire dealing 1 dmg/sec for 4s",
            onApply     = function(unit) end
        },
        {
            name        = "Arcane Surge",
            description = "Casting fireball grants +50% ATK speed for 3s",
            onApply     = function(unit) end
        },
        {
            name        = "Big Boom",
            description = "Fireball radius increased to 3 tiles",
            onApply     = function(unit) end
        }
    }
end

function Mage:resetCombatState()
    Mage.super.resetCombatState(self)
    self.hitCounter      = 0
    self.fireballPending = false
    self.fireball        = nil
    self.firePatches     = {}
    self.arcaneTimer     = 0
    self.arcaneActive    = false
    self.preArcaneSpeed  = nil
end

-- Override takeDamage: track hits received, set pending flag (no grid here)
function Mage:takeDamage(amount)
    Mage.super.takeDamage(self, amount)
    if not self.isDead then
        self.hitCounter = self.hitCounter + 1
        if self.hitCounter >= 6 then
            self.hitCounter      = 0
            self.fireballPending = true
        end
    end
end

-- Override attack: track hits dealt, fire fireball if counter hits 6
function Mage:attack(target, grid)
    Mage.super.attack(self, target, grid)
    self.hitCounter = self.hitCounter + 1
    if self.hitCounter >= 6 then
        self.hitCounter = 0
        self:fireFireball(grid)
    end
end

-- Launch a fireball at the nearest enemy
function Mage:fireFireball(grid)
    if self.isDead then return end
    local target = self:findNearestEnemy(grid)
    if not target then return end

    self.fireball = {
        startCol  = self.col,
        startRow  = self.row,
        targetCol = target.col,
        targetRow = target.row,
        progress  = 0,
        duration  = 0.5,
        damage    = math.max(1, math.floor(self.damage * 3))
    }

    -- Arcane Surge: +50% attack speed for 3s
    if self:hasUpgrade(2) then
        if not self.arcaneActive then
            self.preArcaneSpeed = self.attackSpeed
            self.attackSpeed    = self.attackSpeed * 1.5
            self.arcaneActive   = true
        end
        self.arcaneTimer = 3
    end
end

-- Explode fireball: deal AoE damage, apply upgrades
function Mage:explodeFireball(grid)
    if not self.fireball then return end

    local radius   = self:hasUpgrade(3) and 3 or 2
    local cx, cy   = self.fireball.targetCol, self.fireball.targetRow
    local dmg      = self.fireball.damage
    local allUnits = grid:getAllUnits()

    for _, unit in ipairs(allUnits) do
        if unit.owner ~= self.owner and not unit.isDead then
            local dx   = unit.col - cx
            local dy   = unit.row - cy
            local dist = math.sqrt(dx * dx + dy * dy)
            if dist <= radius then
                unit:takeDamage(dmg)
                if unit.isDead then
                    local cell = grid:getCell(unit.col, unit.row)
                    if cell then cell.occupied = false end
                    self:onKill(unit)
                end
            end
        end
    end

    -- Burning Ground: leave fire patch at impact
    if self:hasUpgrade(1) then
        table.insert(self.firePatches, {
            col         = cx,
            row         = cy,
            timer       = 4,
            damageTimer = 1
        })
    end
end

function Mage:update(dt, grid)
    -- Consume pending fireball flag (set from takeDamage which has no grid)
    if self.fireballPending then
        self.fireballPending = false
        self:fireFireball(grid)
    end

    -- Arcane Surge timer
    if self.arcaneActive then
        self.arcaneTimer = self.arcaneTimer - dt
        if self.arcaneTimer <= 0 then
            self.attackSpeed    = self.preArcaneSpeed
            self.arcaneActive   = false
            self.preArcaneSpeed = nil
        end
    end

    -- Fire patches (Burning Ground)
    for i = #self.firePatches, 1, -1 do
        local patch  = self.firePatches[i]
        patch.timer       = patch.timer - dt
        patch.damageTimer = patch.damageTimer - dt

        -- Deal 1 damage per second to enemies on this tile
        if patch.damageTimer <= 0 then
            patch.damageTimer = 1
            local allUnits = grid:getAllUnits()
            for _, unit in ipairs(allUnits) do
                if unit.owner ~= self.owner and not unit.isDead
                   and unit.col == patch.col and unit.row == patch.row then
                    unit:takeDamage(1)
                    if unit.isDead then
                        local cell = grid:getCell(unit.col, unit.row)
                        if cell then cell.occupied = false end
                        self:onKill(unit)
                    end
                end
            end
        end

        if patch.timer <= 0 then
            table.remove(self.firePatches, i)
        end
    end

    -- Advance fireball flight
    if self.fireball then
        self.fireball.progress = self.fireball.progress + (dt / self.fireball.duration)
        if self.fireball.progress >= 1.0 then
            self:explodeFireball(grid)
            self.fireball = nil
        end
    end

    -- Call parent: handles regular arrows + movement + attacking
    Mage.super.update(self, dt, grid)
end

function Mage:drawAttackVisuals()
    -- Draw regular arrows via parent
    Mage.super.drawAttackVisuals(self)

    local lg = love.graphics

    -- Draw fire patches
    for _, patch in ipairs(self.firePatches) do
        local visualRow = Constants.toVisualRow(patch.row)
        local px = Constants.GRID_OFFSET_X + (patch.col - 1) * Constants.CELL_SIZE
        local py = Constants.GRID_OFFSET_Y + (visualRow - 1) * Constants.CELL_SIZE
        local alpha = math.min(1, patch.timer / 4) * 0.5 + 0.2  -- fade as timer expires
        lg.setColor(1, 0.35, 0, alpha)
        lg.rectangle('fill', px, py, Constants.CELL_SIZE, Constants.CELL_SIZE)
    end

    -- Draw active fireball
    if self.fireball then
        local fb       = self.fireball
        local startVR  = Constants.toVisualRow(fb.startRow)
        local targetVR = Constants.toVisualRow(fb.targetRow)
        local sx = Constants.GRID_OFFSET_X + (fb.startCol - 1) * Constants.CELL_SIZE + Constants.CELL_SIZE / 2
        local sy = Constants.GRID_OFFSET_Y + (startVR - 1)     * Constants.CELL_SIZE + Constants.CELL_SIZE / 2
        local ex = Constants.GRID_OFFSET_X + (fb.targetCol - 1) * Constants.CELL_SIZE + Constants.CELL_SIZE / 2
        local ey = Constants.GRID_OFFSET_Y + (targetVR - 1)     * Constants.CELL_SIZE + Constants.CELL_SIZE / 2

        local t  = fb.progress
        local cx = sx + (ex - sx) * t
        local cy = sy + (ey - sy) * t - math.sin(t * math.pi) * 12 * Constants.SCALE  -- slight arc

        -- Glow halo
        lg.setColor(1, 0.5, 0.1, 0.35)
        lg.circle('fill', cx, cy, 10 * Constants.SCALE)
        -- Core
        lg.setColor(1, 0.85, 0.2, 1)
        lg.circle('fill', cx, cy, 5 * Constants.SCALE)
    end

    lg.setColor(1, 1, 1, 1)
end

return Mage
