local BaseUnit  = require('src.base_unit')
local Constants = require('src.constants')

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
        lg.setShader(BaseUnit.getPaletteShader())
        lg.draw(img, cx, cy, 0, scale, scale, sw / 2, sh / 2)
        lg.setShader()
    else
        lg.setColor(1, 0.35, 0, alpha)
        lg.rectangle('fill', cx - Constants.CELL_SIZE / 2, cy - Constants.CELL_SIZE / 2, Constants.CELL_SIZE, Constants.CELL_SIZE)
    end
    lg.setScissor()
    lg.setColor(1, 1, 1, 1)
end

local Bull = BaseUnit:extend()

function Bull:new(row, col, owner, sprites)
    local stats = {
        health      = 13,
        maxHealth   = 13,
        damage      = 2,
        attackSpeed = 0.65,
        moveSpeed   = 1,
        attackRange = 0,
        unitType    = "bull"
    }

    Bull.super.new(self, row, col, owner, sprites, stats)

    -- ACTION move identification
    self.isActionUnit   = true
    self.actionDuration = 0.5  -- charge animation takes 0.5s

    -- Per-round charge state
    self.isCharging      = false
    self.chargeTimer     = 0
    self.chargeDuration  = 0.5
    self.chargeEnemy     = nil
    self.chargeTrail     = {}  -- cells traversed during charge (for Blazing Trail)
    self.ragingBullTimer = 0

    -- Fire patches left by Blazing Trail: { col, row, timer, damageTimer }
    self.firePatches = {}

    self.upgradeTree = {
        {
            name        = "Unstoppable",
            description = "Charge knocks the enemy to the tile behind them",
            onApply     = function(unit) end
        },
        {
            name        = "Blazing Trail",
            description = "Charge leaves fire on every traversed cell, the landing cell, and the hit enemy's cell for 3s",
            onApply     = function(unit) end
        },
        {
            name        = "Trampling Hooves",
            description = "Charge stuns 1s longer",
            onApply     = function(unit) end
        },
    }
end

-- ============================================================
-- findChargeDest: scan forward up to 4 tiles.
-- Returns (destCol, destRow, hitEnemy, trail).
-- Stops before first enemy or friendly/dead unit; stops at wall.
-- ============================================================
function Bull:findChargeDest(grid)
    local dirRow  = (self.owner == 1) and -1 or 1
    local destCol = self.col
    local destRow = self.row
    local hitEnemy = nil
    local trail = {}

    for i = 1, 4 do
        local checkRow = self.row + dirRow * i
        if checkRow < 1 or checkRow > grid.rows then break end

        local cell = grid:getCell(destCol, checkRow)
        if cell then
            if cell.unit and not cell.unit.isDead and cell.unit.owner ~= self.owner then
                hitEnemy = cell.unit  -- stop before this enemy
                break
            elseif cell.unit then
                break  -- friendly (or dead) blocking — stop here
            else
                table.insert(trail, { col = destCol, row = checkRow })
                destRow = checkRow  -- empty — advance landing spot
            end
        end
    end

    return destCol, destRow, hitEnemy, trail
end

-- ============================================================
-- onBattleStart: compute charge destination, update grid
-- position immediately, and set up the tween animation.
-- ============================================================
function Bull:onBattleStart(grid)
    local destCol, destRow, enemy, trail = self:findChargeDest(grid)

    -- No movement possible (already at wall or blocked on first tile)
    if destCol == self.col and destRow == self.row then
        return
    end

    -- Set up tween animation using the existing draw system
    self.startCol      = self.col
    self.startRow      = self.row
    self.targetCol     = destCol
    self.targetRow     = destRow
    self.tweenProgress = 0
    self.tweenDuration = self.chargeDuration
    self.isMoving      = true

    -- Update logical grid position immediately so AI sees correct placement
    grid:removeUnit(self.col, self.row)
    self.col = destCol
    self.row = destRow
    grid:placeUnit(destCol, destRow, self)

    self.isCharging       = true
    self.chargeTimer      = 0
    self.chargeEnemy      = enemy
    self.chargeTrail      = trail
    self.chargeTrailIndex = 0  -- how many trail cells have been planted so far
end

-- ============================================================
-- update: handle charge animation, then normal combat.
-- ============================================================
function Bull:update(dt, grid)
    if self.isCharging then
        self.chargeTimer   = self.chargeTimer + dt
        self.tweenProgress = math.min(self.chargeTimer / self.chargeDuration, 1)

        -- Blazing Trail: plant trail cells progressively as bull passes through them
        if self:hasUpgrade(2) and #self.chargeTrail > 0 then
            local t = self.chargeTimer / self.chargeDuration
            local totalCells = #self.chargeTrail
            -- Each trail cell triggers at its proportional position along the path
            while self.chargeTrailIndex < totalCells do
                local nextIdx = self.chargeTrailIndex + 1
                local threshold = nextIdx / (totalCells + 1)  -- +1 reserves t=1 for landing
                if t >= threshold then
                    local c = self.chargeTrail[nextIdx]
                    if grid:isValidCell(c.col, c.row) then
                        -- Earlier cells get a shorter timer so they fade out first
                        local trailTimer = 3 - (totalCells - nextIdx) * 0.4
                        table.insert(self.firePatches, {
                            col = c.col, row = c.row, timer = trailTimer, damageTimer = 1
                        })
                    end
                    self.chargeTrailIndex = nextIdx
                else
                    break
                end
            end
        end

        if self.chargeTimer >= self.chargeDuration then
            self.isCharging    = false
            self.isMoving      = false
            self.tweenProgress = 1

            local enemy = self.chargeEnemy
            if enemy and not enemy.isDead then
                -- Apply stun
                local stunDur = self:hasUpgrade(3) and 3 or 2
                enemy.stunTimer = stunDur

                -- Apply charge damage (base only, no upgrade bonus)
                local chargeDmg = math.floor(self.damage * 1.5)
                enemy:takeDamage(chargeDmg)

                if enemy.isDead then
                    local cell = grid:getCell(enemy.col, enemy.row)
                    if cell then cell.occupied = false end
                    self:onKill(enemy)
                end

                -- Unstoppable: knock enemy to tile behind them
                if self:hasUpgrade(1) and not enemy.isDead then
                    local dirRow = (self.owner == 1) and -1 or 1
                    local kbRow  = enemy.row + dirRow
                    if kbRow >= 1 and kbRow <= grid.rows then
                        local kbCell = grid:getCell(enemy.col, kbRow)
                        if kbCell and not kbCell.occupied then
                            grid:removeUnit(enemy.col, enemy.row)
                            enemy.row = kbRow
                            grid:placeUnit(enemy.col, kbRow, enemy)
                        end
                    end
                end
            end

            -- Blazing Trail: plant landing cell + enemy cell at end of charge
            -- (trail cells were planted progressively during the charge)
            if self:hasUpgrade(2) then
                local landingAndEnemy = { { col = self.col, row = self.row } }
                if enemy then
                    table.insert(landingAndEnemy, { col = enemy.col, row = enemy.row })
                end
                for _, c in ipairs(landingAndEnemy) do
                    if grid:isValidCell(c.col, c.row) then
                        table.insert(self.firePatches, {
                            col = c.col, row = c.row, timer = 3, damageTimer = 1
                        })
                    end
                end
            end
        end

        return  -- skip normal combat during charge
    end

    -- Tick fire patches
    local allUnits = grid:getAllUnits()
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

    Bull.super.update(self, dt, grid)
end

-- ============================================================
-- attack: melee lunge + damage.
-- ============================================================
function Bull:attack(target, grid)
    Bull.super.attack(self, target, grid)
end

function Bull:drawGroundEffects()
    for _, patch in ipairs(self.firePatches) do
        local visualRow = Constants.toVisualRow(patch.row)
        local cy    = Constants.GRID_OFFSET_Y + (visualRow - 1) * Constants.CELL_SIZE + Constants.CELL_SIZE / 2
        local topY  = cy - Constants.CELL_SIZE / 2
        drawFirePatch(patch, self.sprites, topY, Constants.CELL_SIZE * 3 / 4)
    end
end

function Bull:drawAttackVisuals()
    for _, patch in ipairs(self.firePatches) do
        local visualRow = Constants.toVisualRow(patch.row)
        local cy      = Constants.GRID_OFFSET_Y + (visualRow - 1) * Constants.CELL_SIZE + Constants.CELL_SIZE / 2
        local bottomY = cy + Constants.CELL_SIZE / 4
        drawFirePatch(patch, self.sprites, bottomY, Constants.CELL_SIZE / 4)
    end
end

-- ============================================================
-- resetCombatState: reset per-round charge state.
-- ============================================================
function Bull:resetCombatState()
    Bull.super.resetCombatState(self)
    self.isCharging      = false
    self.chargeTimer     = 0
    self.chargeEnemy     = nil
    self.chargeTrail      = {}
    self.chargeTrailIndex = 0
    self.ragingBullTimer  = 0
    self.firePatches     = {}
    self.attackSpeed     = self.baseAttackSpeed
end

return Bull
