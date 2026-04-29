-- Reusable one-shot explosion animation, played at a grid cell.
-- Renders the 7-frame `assets/particles/explosion` sequence at unit-sprite scale
-- (CELL_SIZE / 16, matching fire patches and unit sprites pixel-for-pixel).
--
-- Usage:
--   self.explosions = self.explosions or {}
--   table.insert(self.explosions, ExplosionAnim.new(col, row))
--   ExplosionAnim.tick(self.explosions, dt)              -- in :update
--   ExplosionAnim.drawAll(self.explosions, sprites)      -- in :drawAttackVisuals
-- where `sprites` is the unit's sprite table containing `explosionFrames`
-- (assigned by UnitRegistry.finalizeSprites to every unit).

local Constants = require('src.constants')
local BaseUnit  = require('src.base_unit')

local ExplosionAnim = {}
ExplosionAnim.__index = ExplosionAnim

local DURATION = 0.50  -- seconds — matches FireballSpell explosion duration
local FPS      = 14

function ExplosionAnim.new(col, row)
    return setmetatable({
        col     = col,
        row     = row,
        elapsed = 0,
    }, ExplosionAnim)
end

function ExplosionAnim:isComplete()
    return self.elapsed >= DURATION
end

function ExplosionAnim:draw(frames)
    if not frames or #frames == 0 then return end
    local lg = love.graphics
    local frameIdx = math.floor(self.elapsed * FPS) + 1
    if frameIdx > #frames then frameIdx = #frames end
    local img = frames[frameIdx]
    local sw, sh = img:getWidth(), img:getHeight()
    local scale = Constants.CELL_SIZE / 16
    local visualRow = Constants.toVisualRow(self.row)
    local cx = Constants.GRID_OFFSET_X + (self.col - 1) * Constants.CELL_SIZE + Constants.CELL_SIZE / 2
    local cy = Constants.GRID_OFFSET_Y + (visualRow - 1) * Constants.CELL_SIZE + Constants.CELL_SIZE / 2
    lg.setColor(1, 1, 1, 1)
    lg.setShader(BaseUnit.getPaletteShader())
    lg.draw(img, cx, cy, 0, scale, scale, sw / 2, sh / 2)
    lg.setShader()
    lg.setColor(1, 1, 1, 1)
end

-- Convenience: tick a list of active explosions and prune completed ones.
function ExplosionAnim.tick(list, dt)
    for i = #list, 1, -1 do
        local e = list[i]
        e.elapsed = e.elapsed + dt
        if e:isComplete() then table.remove(list, i) end
    end
end

-- Convenience: draw all active explosions in `list` using `sprites.explosionFrames`.
function ExplosionAnim.drawAll(list, sprites)
    local frames = sprites and sprites.explosionFrames
    if not frames then return end
    for _, e in ipairs(list) do
        e:draw(frames)
    end
end

return ExplosionAnim
