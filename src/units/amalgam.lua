local BaseUnit  = require('src.base_unit')
local Constants = require('src.constants')

local Amalgam = BaseUnit:extend()

local INVULN_DURATION  = 1    -- seconds of invulnerability after surviving a lethal hit
local INVULN_COOLDOWN  = 10   -- default cooldown before the passive can trigger again
local INVULN_COOLDOWN_RELENTLESS = 6  -- cooldown with upgrade 3

function Amalgam:new(row, col, owner, sprites)
    local stats = {
        health      = 16,
        maxHealth   = 16,
        damage      = 3,
        attackSpeed = 0.45,
        moveSpeed   = 1,
        attackRange = 0,
        unitType    = "amalgam"
    }

    Amalgam.super.new(self, row, col, owner, sprites, stats)

    -- Invulnerability state
    self.invulnTimer    = 0   -- active invulnerability countdown (seconds)
    self.invulnCooldown = 0   -- cooldown until passive can trigger again

    -- Corpse Explosion: flag consumed in update() (no grid in takeDamage)
    self.corpseExplosionPending = false

    self.upgradeTree = {
        {
            name        = "Bone Armor",
            description = "Permanently reduces all incoming damage by 15%",
            onApply     = function() end
        },
        {
            name        = "Corpse Explosion",
            description = "Triggering invulnerability deals AoE damage around self",
            onApply     = function() end
        },
        {
            name        = "Relentless",
            description = "Invulnerability cooldown reduced from 10s to 6s",
            onApply     = function() end
        }
    }
end

function Amalgam:resetCombatState()
    Amalgam.super.resetCombatState(self)
    self.invulnTimer            = 0
    self.invulnCooldown         = 0
    self.corpseExplosionPending = false
end

function Amalgam:takeDamage(amount)
    if self.isDead then return end

    -- Invulnerable: ignore all damage
    if self.invulnTimer > 0 then return end

    -- Bone Armor: 15% damage reduction (minimum 1)
    if self:hasUpgrade(1) then
        amount = math.max(1, math.floor(amount * 0.85))
    end

    -- Unholy Resilience: a single hit cannot reduce health below 1
    if self.health - amount <= 0 and self.health > 1 then
        self.health = 1
        -- Trigger hit animation manually (not calling super)
        self.hitAnimProgress  = 0
        self.hitAnimIntensity = 4 * Constants.SCALE

        -- Activate invulnerability if cooldown has expired
        if self.invulnCooldown <= 0 then
            self.invulnTimer    = INVULN_DURATION
            local cd            = self:hasUpgrade(3) and INVULN_COOLDOWN_RELENTLESS or INVULN_COOLDOWN
            self.invulnCooldown = cd

            -- Corpse Explosion triggers on invuln activation
            if self:hasUpgrade(2) then
                self.corpseExplosionPending = true
            end
        end
    else
        -- Normal damage
        Amalgam.super.takeDamage(self, amount)
    end
end

-- AoE burst when invulnerability triggers (upgrade 2)
function Amalgam:doCorpseExplosion(grid)
    local radius   = 2
    local dmg      = math.max(1, math.floor(self.damage * 2))
    local allUnits = grid:getAllUnits()

    for _, unit in ipairs(allUnits) do
        if unit.owner ~= self.owner and not unit.isDead then
            local dx   = unit.col - self.col
            local dy   = unit.row - self.row
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
end

function Amalgam:update(dt, grid)
    -- Tick invulnerability
    if self.invulnTimer > 0 then
        self.invulnTimer = self.invulnTimer - dt
        if self.invulnTimer < 0 then self.invulnTimer = 0 end
    end

    -- Tick passive cooldown
    if self.invulnCooldown > 0 then
        self.invulnCooldown = self.invulnCooldown - dt
        if self.invulnCooldown < 0 then self.invulnCooldown = 0 end
    end

    -- Consume Corpse Explosion flag (now we have grid access)
    if self.corpseExplosionPending then
        self.corpseExplosionPending = false
        self:doCorpseExplosion(grid)
    end

    Amalgam.super.update(self, dt, grid)
end

function Amalgam:drawAttackVisuals()
    local lg = love.graphics
    -- Invulnerability aura
    if self.invulnTimer > 0 then
        local visualRow = Constants.toVisualRow(self.row)
        local px = Constants.GRID_OFFSET_X + (self.col - 1) * Constants.CELL_SIZE
        local py = Constants.GRID_OFFSET_Y + (visualRow - 1) * Constants.CELL_SIZE

        -- Pulsing outer glow
        local t     = love.timer.getTime()
        local pulse = math.abs(math.sin(t * 8)) * 0.25 + 0.45

        -- Outer halo
        local pad = 2 * Constants.SCALE
        local inner = Constants.CELL_SIZE - 2 * Constants.SCALE
        lg.setColor(0.6, 0.85, 1, pulse * 0.4)
        lg.rectangle('fill', px - pad, py - pad, Constants.CELL_SIZE + 2 * pad, Constants.CELL_SIZE + 2 * pad)

        -- Sharp border
        lg.setColor(0.75, 0.95, 1, pulse)
        lg.setLineWidth(2 * Constants.SCALE)
        lg.rectangle('line', px + Constants.SCALE, py + Constants.SCALE, inner, inner)

        lg.setLineWidth(1)
        lg.setColor(1, 1, 1, 1)
    end
end

return Amalgam
