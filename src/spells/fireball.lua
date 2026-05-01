-- Fireball spell effect.
-- A flaming projectile arcs in from above and slightly to the side, animated through
-- 4 flight frames, hits the target cell, plays a 7-frame explosion, applies 5 damage to
-- enemies on the cell, then drops a 4-second fire patch onto Grid.firePatches that ticks
-- 1 dmg/s to enemies (using the same Grid:tickFirePatches pipeline Migraine uses).

local Constants     = require('src.constants')
local BaseUnit      = require('src.base_unit')
local ExplosionAnim = require('src.explosion_anim')

local FireballSpell = {}
FireballSpell.__index = FireballSpell

local DAMAGE          = 5
local FLIGHT_DURATION = 0.55
local FLIGHT_FPS      = 14
local FIRE_PATCH_LIFE = 4     -- seconds
local FIRE_PATCH_DAMAGE_TICK = 1     -- 1s between ticks (Grid handles)
local START_OFFSET_CELLS_X = -2      -- start position offset from target (cells)
local START_OFFSET_CELLS_Y = -4      -- start above (cells)

local function cellCenterPx(col, row)
    local visualRow = Constants.toVisualRow(row)
    local x = Constants.GRID_OFFSET_X + (col - 1) * Constants.CELL_SIZE + Constants.CELL_SIZE / 2
    local y = Constants.GRID_OFFSET_Y + (visualRow - 1) * Constants.CELL_SIZE + Constants.CELL_SIZE / 2
    return x, y
end

-- Patch render closure used by Grid:drawFirePatches. Mirrors the migraine/catapult shape
-- but parametrised to FIRE_PATCH_LIFE so the alpha ramp matches our 4s lifetime.
local function drawFirePatchClipped(patch, sprites, clipTop, clipH)
    local lg        = love.graphics
    local visualRow = Constants.toVisualRow(patch.row)
    local cx  = Constants.GRID_OFFSET_X + (patch.col - 1) * Constants.CELL_SIZE + Constants.CELL_SIZE / 2
    local cy  = Constants.GRID_OFFSET_Y + (visualRow - 1) * Constants.CELL_SIZE + Constants.CELL_SIZE / 2
    local life = patch.lifetime or FIRE_PATCH_LIFE
    local alpha = math.min(1, patch.timer / (life * 0.5)) * 0.8 + 0.2
    local fireFrames = sprites and sprites.fireFrames

    lg.setScissor(cx - Constants.CELL_SIZE / 2, clipTop + (Constants.cameraShiftY or 0), Constants.CELL_SIZE, clipH)
    if fireFrames then
        local fps      = 8
        local elapsed  = life - patch.timer
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

local function firePatchDraw(patch, clipMode)
    local visualRow = Constants.toVisualRow(patch.row)
    local cy = Constants.GRID_OFFSET_Y + (visualRow - 1) * Constants.CELL_SIZE + Constants.CELL_SIZE / 2
    if clipMode == "top" then
        drawFirePatchClipped(patch, patch.sprites, cy - Constants.CELL_SIZE / 2, Constants.CELL_SIZE * 3 / 4)
    else
        drawFirePatchClipped(patch, patch.sprites, cy + Constants.CELL_SIZE / 4, Constants.CELL_SIZE / 4)
    end
end

function FireballSpell.new(targetCol, targetRow, owner, grid, sprites, placementId)
    local self = setmetatable({}, FireballSpell)
    self.spellType   = "fireball"
    self.targetCol   = targetCol
    self.targetRow   = targetRow
    self.owner       = owner
    self.grid        = grid
    self.sprites     = sprites or {}
    self.placementId = placementId or 0

    self.elapsed   = 0
    self.phase     = "flight"   -- "flight" → "explosion" → "done"
    self.complete  = false
    self.exploded  = false

    -- Endpoint and start positions in screen pixels
    local endX, endY = cellCenterPx(targetCol, targetRow)
    self.endX, self.endY = endX, endY
    self.startX = endX + START_OFFSET_CELLS_X * Constants.CELL_SIZE
    self.startY = endY + START_OFFSET_CELLS_Y * Constants.CELL_SIZE

    return self
end

local function applyDamageAtCell(grid, col, row, ownerOfSpell)
    if not grid:isValidCell(col, row) then return end
    local victims = {}
    for _, u in ipairs(grid:getAllUnits()) do
        if u.owner ~= ownerOfSpell and not u.isDead and u.col == col and u.row == row then
            table.insert(victims, u)
        end
    end
    table.sort(victims, function(a, b)
        if a.col ~= b.col then return a.col < b.col end
        if a.row ~= b.row then return a.row < b.row end
        return a.owner < b.owner
    end)
    for _, u in ipairs(victims) do
        u:takeDamage(DAMAGE)
        if u.isDead then grid:killUnit(u) end
    end
end

function FireballSpell:_onImpact()
    if self.exploded then return end
    self.exploded = true
    AudioManager.playSFX("fireball.mp3")
    applyDamageAtCell(self.grid, self.targetCol, self.targetRow, self.owner)

    -- Spawn the shared explosion animation at the impact cell.
    self.explosion = ExplosionAnim.new(self.targetCol, self.targetRow)

    -- Drop a fire patch onto Grid.firePatches so it persists past this spell's lifetime.
    if self.grid:isValidCell(self.targetCol, self.targetRow) then
        table.insert(self.grid.firePatches, {
            col         = self.targetCol,
            row         = self.targetRow,
            owner       = self.owner,
            timer       = FIRE_PATCH_LIFE,
            lifetime    = FIRE_PATCH_LIFE,
            damageTimer = FIRE_PATCH_DAMAGE_TICK,
            sprites     = { fireFrames = self.sprites.fireFrames },
            draw        = firePatchDraw,
        })
    end
end

function FireballSpell:update(dt, grid)
    self.elapsed = self.elapsed + dt
    if self.phase == "flight" then
        if self.elapsed >= FLIGHT_DURATION then
            self:_onImpact()
            self.phase   = "explosion"
            self.elapsed = 0
        end
    elseif self.phase == "explosion" then
        if self.explosion then
            self.explosion.elapsed = self.explosion.elapsed + dt
            if self.explosion:isComplete() then
                self.phase    = "done"
                self.complete = true
            end
        else
            self.phase    = "done"
            self.complete = true
        end
    end
end

function FireballSpell:draw()
    local lg = love.graphics
    if self.phase == "flight" then
        local frames = self.sprites.flightFrames
        if not frames or #frames == 0 then return end
        local t = self.elapsed / FLIGHT_DURATION
        if t > 1 then t = 1 end
        -- Linear path with a slight downward arc bias for visual weight.
        local x = self.startX + (self.endX - self.startX) * t
        local y = self.startY + (self.endY - self.startY) * t
        local angle = math.atan2(self.endY - self.startY, self.endX - self.startX)
        local frameIdx = math.floor(self.elapsed * FLIGHT_FPS) % #frames + 1
        local img = frames[frameIdx]
        local sw, sh = img:getWidth(), img:getHeight()
        local scale = Constants.CELL_SIZE / 16
        lg.setColor(1, 1, 1, 1)
        lg.setShader(BaseUnit.getPaletteShader())
        lg.draw(img, x, y, angle, scale, scale, sw / 2, sh / 2)
        lg.setShader()
    elseif self.phase == "explosion" and self.explosion then
        self.explosion:draw(self.sprites.explosionFrames)
    end
    lg.setColor(1, 1, 1, 1)
end

return FireballSpell
