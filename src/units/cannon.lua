local BaseUnit  = require('src.base_unit')
local Constants = require('src.constants')

local Cannon = BaseUnit:extend()

function Cannon:new(row, col, owner, sprites)
    local stats = {
        health      = 10,
        maxHealth   = 10,
        damage      = 3,
        attackSpeed = 0,
        moveSpeed   = 0,
        attackRange = 0,
        unitType    = "cannon"
    }

    Cannon.super.new(self, row, col, owner, sprites, stats)

    self.shootInterval = 2.0
    self.shootTimer    = self.shootInterval
    self.cannonball    = nil

    self.recoilDuration = 0.12
    self.recoilTimer    = 0
    self.recoilDir      = 1

    self.upgradeTree = {
        {
            name        = "Rapid Fire",
            description = "Fires every 1.4s instead of 2s",
            onApply     = function(unit)
                unit.shootInterval = 1.4
            end
        },
        {
            name        = "Piercing Shot",
            description = "Cannonballs pierce through the first enemy hit",
            onApply     = function(_) end
        },
        {
            name        = "Explosive Shell",
            description = "On hit, deals 1 damage to units in adjacent columns",
            onApply     = function(_) end
        }
    }
end

-- Energy bar fills as the shoot timer charges toward the next shot
function Cannon:getEnergy()
    local elapsed = self.shootInterval - self.shootTimer
    return elapsed, self.shootInterval
end

function Cannon:resetCombatState()
    Cannon.super.resetCombatState(self)
    self.shootTimer  = self.shootInterval
    self.cannonball  = nil
    self.recoilTimer = 0
end

function Cannon:onBattleStart()
    self.shootTimer  = self.shootInterval
    self.cannonball  = nil
    self.recoilTimer = 0
    self.barRevealed = true
end

function Cannon:fireCannonball()
    if self.isDead then return end
    local targetRow = self.owner == 1 and 1 or 8
    local dist = math.abs(targetRow - self.row)
    if dist == 0 then return end

    -- Recoil direction is opposite to firing direction in visual space
    local targetVR = Constants.toVisualRow(targetRow)
    local selfVR   = Constants.toVisualRow(self.row)
    self.recoilDir   = targetVR < selfVR and 1 or -1
    self.recoilTimer = self.recoilDuration

    self.cannonball = {
        col            = self.col,
        startRow       = self.row,
        targetRow      = targetRow,
        progress       = 0,
        duration       = dist / 4,
        lastCheckedRow = self.row,
    }
end

function Cannon:hitEnemiesAt(col, row, grid)
    local dmg      = self:getDamage(grid)
    local allUnits = grid:getAllUnits()
    local hitAny   = false

    for _, unit in ipairs(allUnits) do
        if unit.owner ~= self.owner and not unit.isDead
           and unit.col == col and unit.row == row then
            unit:takeDamage(dmg, self, grid)
            if unit.isDead then
                grid:killUnit(unit)
                self:onKill(unit)
            end
            hitAny = true
        end
    end

    -- Upgrade 3: also hit adjacent columns for 1 damage on impact
    if hitAny and self:hasUpgrade(3) then
        for _, unit in ipairs(allUnits) do
            if unit.owner ~= self.owner and not unit.isDead
               and math.abs(unit.col - col) == 1 and unit.row == row then
                unit:takeDamage(1, self, grid)
                if unit.isDead then
                    grid:killUnit(unit)
                    self:onKill(unit)
                end
            end
        end
    end

    return hitAny
end

function Cannon:update(dt, grid)
    -- Drive base animations without invoking combat AI
    if self.attackAnimProgress < 1 and self.attackTargetCol and self.attackTargetRow then
        self.attackAnimProgress = self.attackAnimProgress + dt / self.attackAnimDuration
        if self.attackAnimProgress >= 1.0 then
            self.attackAnimProgress = 1
            self.attackTargetCol    = nil
            self.attackTargetRow    = nil
        end
    end
    if self.hitAnimProgress < 1 and self.hitAnimIntensity > 0 then
        self.hitAnimProgress = self.hitAnimProgress + dt / self.hitAnimDuration
        if self.hitAnimProgress >= 1.0 then
            self.hitAnimProgress  = 1
            self.hitAnimIntensity = 0
        end
    end

    if self.recoilTimer > 0 then
        self.recoilTimer = math.max(0, self.recoilTimer - dt)
    end

    if self.isDead then
        self.state = "dead"
        return
    end

    -- Shoot timer: fire when charged, one cannonball in flight at a time
    self.shootTimer = self.shootTimer - dt
    if self.shootTimer <= 0 then
        self.shootTimer = self.shootInterval
        if not self.cannonball then
            self:fireCannonball()
        end
    end

    -- Advance cannonball and check each newly entered row
    if self.cannonball then
        local cb   = self.cannonball
        cb.progress = cb.progress + dt / cb.duration

        local t          = math.min(cb.progress, 1.0)
        local currentRow = math.floor(cb.startRow + (cb.targetRow - cb.startRow) * t + 0.5)
        local step       = cb.targetRow > cb.startRow and 1 or -1

        if currentRow ~= cb.lastCheckedRow then
            local r = cb.lastCheckedRow + step
            while r ~= currentRow + step do
                -- Rock spell blocks cannonballs just like other projectiles
                if grid:isRock(cb.col, r) then
                    self.cannonball = nil
                    break
                end
                local hit = self:hitEnemiesAt(cb.col, r, grid)
                if hit and not self:hasUpgrade(2) then
                    self.cannonball = nil
                    break
                end
                r = r + step
            end
            if self.cannonball then
                self.cannonball.lastCheckedRow = currentRow
            end
        end

        if self.cannonball and self.cannonball.progress >= 1.0 then
            self.cannonball = nil
        end
    end
end

-- Recoil pop: briefly nudge the sprite opposite to the firing direction
function Cannon:draw()
    if self.recoilTimer > 0 then
        local progress = 1 - (self.recoilTimer / self.recoilDuration)
        local offsetY  = math.sin(progress * math.pi) * 3 * Constants.SCALE * self.recoilDir
        love.graphics.push()
        love.graphics.translate(0, offsetY)
        Cannon.super.draw(self)
        love.graphics.pop()
    else
        Cannon.super.draw(self)
    end
end

-- Shared cannonball draw logic used by both draw hooks below
local function drawCannonball(cb, sprites)
    local lg       = love.graphics
    local startVR  = Constants.toVisualRow(cb.startRow)
    local targetVR = Constants.toVisualRow(cb.targetRow)

    local sx = Constants.GRID_OFFSET_X + (cb.col - 1) * Constants.CELL_SIZE + Constants.CELL_SIZE / 2
    local sy = Constants.GRID_OFFSET_Y + (startVR  - 1) * Constants.CELL_SIZE + Constants.CELL_SIZE / 2
    local ey = Constants.GRID_OFFSET_Y + (targetVR - 1) * Constants.CELL_SIZE + Constants.CELL_SIZE / 2
    local cy = sy + (ey - sy) * cb.progress

    local baseScale = math.max(1, math.floor(Constants.CELL_SIZE / 16))
    local img       = sprites and sprites.catapultProjectile

    if img then
        local sw, sh = img:getWidth(), img:getHeight()
        lg.setColor(1, 1, 1, 1)
        lg.setShader(BaseUnit.getPaletteShader())
        lg.draw(img, sx, cy, 0, baseScale, baseScale, sw / 2, sh / 2)
        lg.setShader()
    else
        lg.setColor(0.3, 0.2, 0.1, 1)
        lg.circle('fill', sx, cy, baseScale * 3)
        lg.setColor(1, 1, 1, 1)
    end
end

-- Cannonball going UP the screen (away from viewer) → draw behind the sprite
function Cannon:drawAttackVisualsBelow()
    if not self.cannonball then return end
    local startVR  = Constants.toVisualRow(self.cannonball.startRow)
    local targetVR = Constants.toVisualRow(self.cannonball.targetRow)
    if startVR > targetVR then
        drawCannonball(self.cannonball, self.sprites)
    end
end

-- Cannonball going DOWN the screen (toward viewer) → draw in front of the sprite
function Cannon:drawAttackVisuals()
    if not self.cannonball then return end
    local startVR  = Constants.toVisualRow(self.cannonball.startRow)
    local targetVR = Constants.toVisualRow(self.cannonball.targetRow)
    if startVR <= targetVR then
        drawCannonball(self.cannonball, self.sprites)
    end
end

return Cannon
