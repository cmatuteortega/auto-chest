-- Quake spell effect.
-- Instantly creates a 3x3 seismic zone centred on the target cell.  Each cell
-- in the zone shakes and applies 50% move-slow + 20% attack-slow to any unit
-- standing on it for the 5-second duration.  Patches are owned by Grid and
-- rendered the same way as fire patches (3/4 behind units, 1/4 in front).

local Constants = require('src.constants')

local QuakeSpell = {}
QuakeSpell.__index = QuakeSpell

local QUAKE_DURATION = 5.0

-- Shake constants for both the ground animation and affected units.
local SHAKE_FREQ_X  = 30
local SHAKE_FREQ_Y  = 25
local SHAKE_AMP_X   = 2
local SHAKE_AMP_Y   = 1

-- Slow parameters fed into BaseUnit:applySlow(duration, atkMult, moveMult).
-- Duration is kept short so the slow expires quickly when a unit walks off.
local SLOW_REFRESH  = 0.3
local SLOW_ATK_MULT = 0.8
local SLOW_MOV_MULT = 0.5

local function drawQuakePatchClipped(patch, clipTop, clipH)
    local lg        = love.graphics
    local visualRow = Constants.toVisualRow(patch.row)
    local cx = Constants.GRID_OFFSET_X + (patch.col - 1) * Constants.CELL_SIZE + Constants.CELL_SIZE / 2
    local cy = Constants.GRID_OFFSET_Y + (visualRow - 1) * Constants.CELL_SIZE + Constants.CELL_SIZE / 2

    -- Fade out in the last 30% of lifetime, otherwise hold near-full opacity.
    local life  = patch.lifetime or QUAKE_DURATION
    local alpha = math.min(1, patch.timer / (life * 0.3)) * 0.85 + 0.15

    -- Positional shake for the ground animation itself.
    local t      = patch.shakeTime
    local shakeX = math.sin(t * SHAKE_FREQ_X) * SHAKE_AMP_X
    local shakeY = math.cos(t * SHAKE_FREQ_Y) * SHAKE_AMP_Y

    local frames = patch.sprites and patch.sprites.frames

    lg.setScissor(
        cx - Constants.CELL_SIZE / 2,
        clipTop + (Constants.cameraShiftY or 0),
        Constants.CELL_SIZE,
        clipH
    )
    if frames and #frames > 0 then
        local frameIdx = math.floor(t * 8) % #frames + 1
        local img      = frames[frameIdx]
        local sw, sh   = img:getWidth(), img:getHeight()
        local scale    = Constants.CELL_SIZE / sw
        lg.setColor(1, 1, 1, alpha)
        lg.draw(img, math.floor(cx + shakeX), math.floor(cy + shakeY), 0, scale, scale, sw / 2, sh / 2)
    else
        lg.setColor(0.6, 0.4, 0.1, alpha)
        lg.rectangle('fill', cx - Constants.CELL_SIZE / 2, cy - Constants.CELL_SIZE / 2, Constants.CELL_SIZE, Constants.CELL_SIZE)
    end
    lg.setScissor()
    lg.setColor(1, 1, 1, 1)
end

local function quakePatchDraw(patch, clipMode)
    local visualRow = Constants.toVisualRow(patch.row)
    local cy = Constants.GRID_OFFSET_Y + (visualRow - 1) * Constants.CELL_SIZE + Constants.CELL_SIZE / 2
    if clipMode == "top" then
        drawQuakePatchClipped(patch, cy - Constants.CELL_SIZE / 2, Constants.CELL_SIZE * 3 / 4)
    else
        drawQuakePatchClipped(patch, cy + Constants.CELL_SIZE / 4, Constants.CELL_SIZE / 4)
    end
end

function QuakeSpell.new(targetCol, targetRow, owner, grid, sprites, placementId)
    local self = setmetatable({}, QuakeSpell)
    self.spellType   = "quake"
    self.placementId = placementId or 0
    self.isDone      = true   -- no projectile phase; patches handle everything

    for dc = -1, 1 do
        for dr = -1, 1 do
            local col = targetCol + dc
            local row = targetRow + dr
            if col >= 1 and col <= 5 and row >= 1 and row <= 8 then
                table.insert(grid.quakePatches, {
                    col       = col,
                    row       = row,
                    owner     = owner,
                    timer     = QUAKE_DURATION,
                    lifetime  = QUAKE_DURATION,
                    shakeTime = 0,
                    sprites   = sprites,
                    draw      = quakePatchDraw,
                    slowRefresh  = SLOW_REFRESH,
                    slowAtkMult  = SLOW_ATK_MULT,
                    slowMovMult  = SLOW_MOV_MULT,
                    shakeFreqX   = SHAKE_FREQ_X,
                    shakeFreqY   = SHAKE_FREQ_Y,
                    shakeAmpX    = SHAKE_AMP_X,
                    shakeAmpY    = SHAKE_AMP_Y,
                })
            end
        end
    end

    return self
end

function QuakeSpell:update(dt) end
function QuakeSpell:draw() end

return QuakeSpell
