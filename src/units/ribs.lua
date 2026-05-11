local BaseUnit    = require('src.base_unit')
local Constants   = require('src.constants')
local AudioManager = require('src.audio_manager')

-- Sprite-pixel burst: 12 particles fly outward (copied from migraine.lua)
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

local Ribs = BaseUnit:extend()

local LAST_STAND_DURATION = 3
local LAST_STAND_DURATION_LONG = 5
local TAUNT_RADIUS = 3
local DEATH_RATTLE_DAMAGE = 3
local DEATH_RATTLE_RADIUS = 2

function Ribs:new(row, col, owner, sprites)
    local stats = {
        health      = 16,
        maxHealth   = 16,
        damage      = 1,
        attackSpeed = 0.65,
        moveSpeed   = 1.0,
        attackRange = 0,
        unitType    = "ribs"
    }

    Ribs.super.new(self, row, col, owner, sprites, stats)

    self.hitSound = "mid-hit.mp3"

    self.inLastStand    = false
    self.lastStandUsed  = false
    self.lastStandTimer = 0
    self.explosionFlash = nil

    self.upgradeTree = {
        {
            name        = "Thorned Ribs",
            description = "Each hit received during last stand reflects half its damage back to the attacker",
            onApply     = function(unit) end
        },
        {
            name        = "Prolonged Agony",
            description = "Last stand duration extended from 3s to 5s",
            onApply     = function(unit) end
        },
        {
            name        = "Death Rattle",
            description = "On final death, deal 3 AoE damage to all enemies within 2 cells",
            onApply     = function(unit) end
        },
    }
end

function Ribs:applyLastStandTaunts(grid)
    if not grid then return end
    local duration = self:hasUpgrade(2) and LAST_STAND_DURATION_LONG or LAST_STAND_DURATION
    for _, unit in ipairs(grid:getAllUnits()) do
        if unit.owner ~= self.owner and not unit.isDead then
            local dx   = unit.col - self.col
            local dy   = unit.row - self.row
            local dist = math.sqrt(dx * dx + dy * dy)
            if dist <= TAUNT_RADIUS then
                unit.tauntedBy = self
                unit.tauntTimer = duration
            end
        end
    end
end

function Ribs:doDeathRattle(grid)
    for _, unit in ipairs(grid:getAllUnits()) do
        if unit.owner ~= self.owner and not unit.isDead then
            local dx   = unit.col - self.col
            local dy   = unit.row - self.row
            local dist = math.sqrt(dx * dx + dy * dy)
            if dist <= DEATH_RATTLE_RADIUS then
                unit:takeDamage(DEATH_RATTLE_DAMAGE, self, grid)
                if unit.isDead then
                    grid:killUnit(unit)
                end
            end
        end
    end
    self.explosionFlash = { col = self.col, row = self.row, timer = 0.4 }
    AudioManager.playSFX("fireball.mp3")
end

function Ribs:takeDamage(amount, attacker, grid)
    if self.inLastStand then
        -- Upgrade 1: Thorned Ribs — reflect half damage back to attacker
        if self:hasUpgrade(1) and attacker and not attacker.isDead then
            local reflectDmg = math.max(1, math.floor(amount / 2))
            attacker:takeDamage(reflectDmg, self, grid)
            if attacker.isDead and grid then
                grid:killUnit(attacker)
            end
        end
        -- Absorb the hit visually but don't die
        self.hitAnimProgress = 0
        self.hitAnimIntensity = 4 * Constants.SCALE
        return
    end

    if not self.lastStandUsed and self.health - amount <= 0 then
        -- Enter last stand instead of dying
        self.inLastStand   = true
        self.lastStandUsed = true
        self.health        = 0
        local duration     = self:hasUpgrade(2) and LAST_STAND_DURATION_LONG or LAST_STAND_DURATION
        self.lastStandTimer = duration
        self:applyLastStandTaunts(grid)
        self.hitAnimProgress  = 0
        self.hitAnimIntensity = 4 * Constants.SCALE
        return
    end

    Ribs.super.takeDamage(self, amount, attacker, grid)
end

function Ribs:getSprite()
    if self.inLastStand then
        return self.sprites.dead
    end
    return Ribs.super.getSprite(self)
end

function Ribs:update(dt, grid)
    if self.inLastStand then
        -- Advance explosion flash timer (Death Rattle visual lingers into final frame)
        if self.explosionFlash then
            self.explosionFlash.timer = self.explosionFlash.timer - dt
            if self.explosionFlash.timer <= 0 then
                self.explosionFlash = nil
            end
        end

        self.lastStandTimer = self.lastStandTimer - dt
        if self.lastStandTimer <= 0 then
            if self:hasUpgrade(3) then
                self:doDeathRattle(grid)
            end
            self.inLastStand = false
            self.isDead      = true
            grid:killUnit(self)
            return
        end

        -- Frozen during last stand: no movement or attacking
        return
    end

    Ribs.super.update(self, dt, grid)
end

function Ribs:drawAttackVisuals()
    if self.explosionFlash then
        local flash = self.explosionFlash
        drawPixelBurst(flash.col, flash.row, flash.timer, 0.4, 1, 0.95, 0.8)
    end
    Ribs.super.drawAttackVisuals(self)
end

function Ribs:resetCombatState()
    Ribs.super.resetCombatState(self)
    self.inLastStand    = false
    self.lastStandUsed  = false
    self.lastStandTimer = 0
    self.explosionFlash = nil
end

return Ribs
