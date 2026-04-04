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

local Sinner = BaseUnit:extend()

local FORM_CHANGE_THRESHOLD_DEFAULT = 15
local FORM_CHANGE_THRESHOLD_UPGRADE = 10  -- upgrade 1: Early Release
local AOE_RADIUS = 2

function Sinner:new(row, col, owner, sprites)
    local stats = {
        health      = 18,
        maxHealth   = 18,
        damage      = 1,
        attackSpeed = 0.6,
        moveSpeed   = 0.8,
        attackRange = 0,
        unitType    = "sinner"
    }

    Sinner.super.new(self, row, col, owner, sprites, stats)

    -- Form state
    self.hitCounter        = 0
    self.isFree            = false
    self.formChangePending = false
    self.chainedSprites    = sprites
    self.freeSprites       = sprites and sprites.freeForm
    self.burstFlash        = nil

    self.upgradeTree = {
        {
            name        = "Early Release",
            description = "Form change triggers at 14 hits instead of 20",
            onApply     = function() end
        },
        {
            name        = "Mending Chains",
            description = "Heal 40% max HP when breaking free",
            onApply     = function() end
        },
        {
            name        = "Shattered Chains",
            description = "Stun all enemies within 2 cells for 0.5s when breaking free",
            onApply     = function() end
        },
    }
end

function Sinner:getEnergy()
    if self.isFree then return nil, nil end
    local threshold = self:hasUpgrade(1) and FORM_CHANGE_THRESHOLD_UPGRADE
                                         or  FORM_CHANGE_THRESHOLD_DEFAULT
    return self.hitCounter, threshold
end

function Sinner:checkFormChange()
    if self.isFree then return end
    local threshold = self:hasUpgrade(1) and FORM_CHANGE_THRESHOLD_UPGRADE
                                         or  FORM_CHANGE_THRESHOLD_DEFAULT
    if self.hitCounter >= threshold then
        self.hitCounter        = 0
        self.formChangePending = true
    end
end

function Sinner:takeDamage(amount)
    Sinner.super.takeDamage(self, amount)
    if self.isDead then return end
    self.hitCounter = self.hitCounter + 1
    self:checkFormChange()
end

function Sinner:attack(target, grid)
    if not target or target.isDead then return end
    if not self.isFree then
        self.hitCounter = self.hitCounter + 1
        self:checkFormChange()
    end
    Sinner.super.attack(self, target, grid)
end

function Sinner:doFormChange(grid)
    self.isFree      = true
    self.attackSpeed = 1.3
    self:triggerBuffAnim()
    self.stunTimer   = 0  -- clear any active stun on transformation
    if self.freeSprites then self.sprites = self.freeSprites end

    -- Mending Chains (upgrade 2): heal 40% max HP on form change
    if self:hasUpgrade(2) and not self._noHeal then
        local heal = math.floor(self.maxHealth * 0.4)
        self.health = math.min(self.health + heal, self.maxHealth)
        self:triggerBuffAnim()
    end

    -- Shattered Chains (upgrade 3): stun nearby enemies for 0.5s
    if self:hasUpgrade(3) then
        for _, unit in ipairs(grid:getAllUnits()) do
            if unit.owner ~= self.owner and not unit.isDead then
                local dx = unit.col - self.col
                local dy = unit.row - self.row
                if math.sqrt(dx * dx + dy * dy) <= AOE_RADIUS then
                    unit.stunTimer = math.max(unit.stunTimer, 0.5)
                end
            end
        end
    end

    self.burstFlash = { col = self.col, row = self.row, timer = 0.5 }
end

function Sinner:update(dt, grid)
    if self.formChangePending then
        self.formChangePending = false
        self:doFormChange(grid)
    end

    -- In free form, stun immunity: cancel any stun applied externally
    if self.isFree then self.stunTimer = 0 end

    if self.burstFlash then
        self.burstFlash.timer = self.burstFlash.timer - dt
        if self.burstFlash.timer <= 0 then self.burstFlash = nil end
    end

    Sinner.super.update(self, dt, grid)
end

function Sinner:resetCombatState()
    Sinner.super.resetCombatState(self)
    self.hitCounter        = 0
    self.isFree            = false
    self.formChangePending = false
    self.burstFlash        = nil
    self.attackSpeed       = self.baseAttackSpeed
    if self.chainedSprites then self.sprites = self.chainedSprites end
end

function Sinner:drawAttackVisuals()
    Sinner.super.drawAttackVisuals(self)

    if self.burstFlash then
        local flash = self.burstFlash
        drawPixelBurst(flash.col, flash.row, flash.timer, 0.5, 0.9, 0.3, 0.1)
    end
end

return Sinner
