local BaseUnit  = require('src.base_unit')
local Constants = require('src.constants')

-- Draws one fire patch clipped to [clipTop, clipTop+clipH] in screen Y
local function drawFirePatch(patch, sprites, clipTop, clipH)
    local lg        = love.graphics
    local visualRow = Constants.toVisualRow(patch.row)
    local cx  = Constants.GRID_OFFSET_X + (patch.col - 1) * Constants.CELL_SIZE + Constants.CELL_SIZE / 2
    local cy  = Constants.GRID_OFFSET_Y + (visualRow - 1) * Constants.CELL_SIZE + Constants.CELL_SIZE / 2
    local alpha = math.min(1, patch.timer / 3) * 0.8 + 0.2
    local fireFrames = sprites and sprites.fireFrames

    lg.setScissor(cx - Constants.CELL_SIZE / 2, clipTop, Constants.CELL_SIZE, clipH)
    if fireFrames then
        local fps      = 8
        local elapsed  = 3 - patch.timer
        local frameIdx = math.floor(elapsed * fps) % #fireFrames + 1
        local img      = fireFrames[frameIdx]
        local sw, sh   = img:getWidth(), img:getHeight()
        local scale    = Constants.CELL_SIZE / sw
        lg.setColor(1, 1, 1, alpha)
        lg.draw(img, cx, cy, 0, scale, scale, sw / 2, sh / 2)
    else
        lg.setColor(1, 0.35, 0, alpha)
        lg.rectangle('fill', cx - Constants.CELL_SIZE / 2, cy - Constants.CELL_SIZE / 2, Constants.CELL_SIZE, Constants.CELL_SIZE)
    end
    lg.setScissor()
    lg.setColor(1, 1, 1, 1)
end

-- Cross offsets: center + 4 cardinal neighbours
local CROSS_OFFSETS = { {0,0}, {1,0}, {-1,0}, {0,1}, {0,-1} }

local Catapult = BaseUnit:extend()

function Catapult:new(row, col, owner, sprites)
    local stats = {
        health      = 12,
        maxHealth   = 12,
        damage      = 3,
        attackSpeed = 0,
        moveSpeed   = 0,
        attackRange = 0,
        unitType    = "catapult"
    }

    Catapult.super.new(self, row, col, owner, sprites, stats)

    self.isActionUnit   = true
    self.actionDuration = 0.6

    -- Active projectile: { startCol, startRow, targetCol, targetRow, progress, duration }
    self.projectile = nil
    -- Fire patches on the ground: { col, row, timer, damageTimer }
    self.firePatches = {}
    self.shotFired   = false

    self.upgradeTree = {
        {
            name        = "Ember Drain",
            description = "Fire ground also removes 1 energy per damage tick",
            onApply     = function(unit) end
        },
        {
            name        = "Scorched",
            description = "Enemies standing on fire cannot be healed",
            onApply     = function(unit) end
        },
        {
            name        = "Heavy Payload",
            description = "Initial blast damage increased to 5",
            onApply     = function(unit)
                unit.baseDamage = 5
                local multiplier = 1.3 ^ unit.level
                unit.damage = math.floor(unit.baseDamage * multiplier)
            end
        }
    }
end

function Catapult:resetCombatState()
    Catapult.super.resetCombatState(self)
    self.projectile  = nil
    self.firePatches = {}
    self.shotFired   = false
end

function Catapult:onBattleStart(grid)
    -- Fire 4 rows forward toward the enemy side
    local targetRow
    if self.owner == 1 then
        targetRow = math.max(1, self.row - 4)
    else
        targetRow = math.min(8, self.row + 4)
    end

    self.projectile = {
        startCol  = self.col,
        startRow  = self.row,
        targetCol = self.col,
        targetRow = targetRow,
        progress  = 0,
        duration  = self.actionDuration,
    }
    self.shotFired = true
end

-- Explode on landing: deal damage + plant fire patches in a cross
function Catapult:explodeShot(grid)
    local cx  = self.projectile.targetCol
    local cy  = self.projectile.targetRow
    local dmg = self:getDamage(grid)
    local allUnits = grid:getAllUnits()

    -- Damage all enemies in cross
    for _, offset in ipairs(CROSS_OFFSETS) do
        local tc = cx + offset[1]
        local tr = cy + offset[2]
        if grid:isValidCell(tc, tr) then
            for _, unit in ipairs(allUnits) do
                if unit.owner ~= self.owner and not unit.isDead
                   and unit.col == tc and unit.row == tr then
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

    -- Plant fire patches for the cross
    for _, offset in ipairs(CROSS_OFFSETS) do
        local tc = cx + offset[1]
        local tr = cy + offset[2]
        if grid:isValidCell(tc, tr) then
            table.insert(self.firePatches, {
                col         = tc,
                row         = tr,
                timer       = 5,
                damageTimer = 1,
            })
        end
    end
end

function Catapult:update(dt, grid)
    -- Run base animations (hit, attack) without combat AI
    if self.attackAnimProgress < 1 and self.attackTargetCol and self.attackTargetRow then
        self.attackAnimProgress = self.attackAnimProgress + (dt / self.attackAnimDuration)
        if self.attackAnimProgress >= 1.0 then
            self.attackAnimProgress = 1
            self.attackTargetCol = nil
            self.attackTargetRow = nil
        end
    end
    if self.hitAnimProgress < 1 and self.hitAnimIntensity > 0 then
        self.hitAnimProgress = self.hitAnimProgress + (dt / self.hitAnimDuration)
        if self.hitAnimProgress >= 1.0 then
            self.hitAnimProgress = 1
            self.hitAnimIntensity = 0
        end
    end

    if self.isDead then
        self.state = "dead"
        return
    end

    -- Advance projectile flight
    if self.projectile then
        self.projectile.progress = self.projectile.progress + (dt / self.projectile.duration)
        if self.projectile.progress >= 1.0 then
            self:explodeShot(grid)
            self.projectile = nil
        end
    end

    -- Update fire patches
    local allUnits = grid:getAllUnits()

    -- Track which enemy units are currently on a patch (for Scorched upgrade)
    local onPatch = {}
    if self:hasUpgrade(2) then
        for _, patch in ipairs(self.firePatches) do
            for _, unit in ipairs(allUnits) do
                if unit.owner ~= self.owner and not unit.isDead
                   and unit.col == patch.col and unit.row == patch.row then
                    onPatch[unit] = true
                end
            end
        end
        -- Apply/clear _noHeal flag
        for _, unit in ipairs(allUnits) do
            if unit.owner ~= self.owner and not unit.isDead then
                unit._noHeal = onPatch[unit] or nil
            end
        end
    end

    for i = #self.firePatches, 1, -1 do
        local patch = self.firePatches[i]
        patch.timer       = patch.timer - dt
        patch.damageTimer = patch.damageTimer - dt

        if patch.damageTimer <= 0 then
            patch.damageTimer = 1
            for _, unit in ipairs(allUnits) do
                if unit.owner ~= self.owner and not unit.isDead
                   and unit.col == patch.col and unit.row == patch.row then
                    unit:takeDamage(1)
                    if self:hasUpgrade(1) and unit.hitCounter then
                        unit.hitCounter = math.max(0, unit.hitCounter - 1)
                    end
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
end

function Catapult:drawGroundEffects()
    for _, patch in ipairs(self.firePatches) do
        local visualRow = Constants.toVisualRow(patch.row)
        local cy    = Constants.GRID_OFFSET_Y + (visualRow - 1) * Constants.CELL_SIZE + Constants.CELL_SIZE / 2
        local topY  = cy - Constants.CELL_SIZE / 2
        drawFirePatch(patch, self.sprites, topY, Constants.CELL_SIZE * 3 / 4)
    end
end

function Catapult:drawAttackVisuals()
    -- Draw bottom quarter of fire patches on top of units
    for _, patch in ipairs(self.firePatches) do
        local visualRow = Constants.toVisualRow(patch.row)
        local cy      = Constants.GRID_OFFSET_Y + (visualRow - 1) * Constants.CELL_SIZE + Constants.CELL_SIZE / 2
        local bottomY = cy + Constants.CELL_SIZE / 4
        drawFirePatch(patch, self.sprites, bottomY, Constants.CELL_SIZE / 4)
    end

    if not self.projectile then return end

    local lg  = love.graphics
    local pb  = self.projectile
    local startVR  = Constants.toVisualRow(pb.startRow)
    local targetVR = Constants.toVisualRow(pb.targetRow)
    local sx = Constants.GRID_OFFSET_X + (pb.startCol - 1) * Constants.CELL_SIZE + Constants.CELL_SIZE / 2
    local sy = Constants.GRID_OFFSET_Y + (startVR  - 1)   * Constants.CELL_SIZE + Constants.CELL_SIZE / 2
    local ex = Constants.GRID_OFFSET_X + (pb.targetCol - 1) * Constants.CELL_SIZE + Constants.CELL_SIZE / 2
    local ey = Constants.GRID_OFFSET_Y + (targetVR - 1)   * Constants.CELL_SIZE + Constants.CELL_SIZE / 2

    local t  = pb.progress
    local cx = sx + (ex - sx) * t
    local cy = sy + (ey - sy) * t - math.sin(t * math.pi) * 16 * Constants.SCALE

    -- Base scale matches unit sprite scale (CELL_SIZE / 16 pixels)
    local baseScale  = math.max(1, math.floor(Constants.CELL_SIZE / 16))
    -- Parabolic size bump: peaks at t=0.5 with +50% size, smooth via sin curve
    local sizeScale  = baseScale * (1 + 0.5 * math.sin(t * math.pi))

    local img = self.sprites and self.sprites.catapultProjectile
    if img then
        local sw, sh = img:getWidth(), img:getHeight()
        local angle  = math.atan2(ey - sy, ex - sx) + (t - 0.5) * math.pi * 0.5
        lg.setColor(1, 1, 1, 1)
        lg.draw(img, cx, cy, angle, sizeScale, sizeScale, sw / 2, sh / 2)
    else
        -- Fallback: dark circle
        lg.setColor(0.3, 0.2, 0.1, 1)
        lg.circle('fill', cx, cy, sizeScale * 2)
        lg.setColor(1, 1, 1, 1)
    end
end

return Catapult
