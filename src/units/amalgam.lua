local BaseUnit  = require('src.base_unit')
local Constants = require('src.constants')

-- Sprite-pixel burst: 12 particles fly outward, sized to one sprite pixel (CELL_SIZE/16)
local function drawPixelBurst(col, row, timer, duration, r, g, b)
    local lg      = love.graphics
    local t       = timer / duration
    local vr      = Constants.toVisualRow(row)
    local cx      = Constants.GRID_OFFSET_X + (col - 1) * Constants.CELL_SIZE + Constants.CELL_SIZE / 2
    local cy      = Constants.GRID_OFFSET_Y + (vr   - 1) * Constants.CELL_SIZE + Constants.CELL_SIZE / 2
    local ps      = math.max(1, math.floor(Constants.CELL_SIZE / 16))
    local maxDist = Constants.CELL_SIZE * 1.2
    local expand  = 1 - t
    for i = 0, 11 do
        local angle   = (i / 12) * math.pi * 2
        local isOuter = (i % 2 == 0)
        local dist    = maxDist * expand * (isOuter and 1.0 or 0.55)
        local px      = math.floor(cx + math.cos(angle) * dist - ps / 2)
        local py      = math.floor(cy + math.sin(angle) * dist - ps / 2)
        lg.setColor(r, g, b, t * (isOuter and 1.0 or 0.7))
        lg.rectangle('fill', px, py, ps, ps)
    end
    lg.setColor(1, 1, 1, 1)
end

local Amalgam = BaseUnit:extend()

local INVULN_DURATION  = 1    -- seconds of invulnerability after surviving a lethal hit
local INVULN_COOLDOWN  = 7    -- default cooldown before the passive can trigger again
local INVULN_COOLDOWN_RELENTLESS = 6  -- cooldown with upgrade 3

function Amalgam:new(row, col, owner, sprites)
    local stats = {
        health      = 13,
        maxHealth   = 13,
        damage      = 3,
        attackSpeed = 0.45,
        moveSpeed   = 1,
        attackRange = 0,
        unitType    = "amalgam"
    }

    Amalgam.super.new(self, row, col, owner, sprites, stats)

    self.hitSound = "bite.mp3"

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

-- Standard melee attack: apply damage (animation started by startMeleeAnimation in update())
function Amalgam:attack(target, grid)
    Amalgam.super.attack(self, target, grid)
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
    if not (self.invulnTimer > 0) then return end
    drawPixelBurst(self.col, self.row, self.invulnTimer, INVULN_DURATION, 0.6, 0.9, 1)
end

return Amalgam
