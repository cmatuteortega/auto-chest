-- Sigil spell effect (Calcium Clan).
-- Inscribes a 3×3 healing zone for 5 seconds. Allied units standing on it
-- heal 2 HP every second and receive the heal overlay animation.
-- The 48×48 ground sprite rotates gently and is drawn BEFORE units via
-- grid.sigilPatches (same pattern as quake patches).

local Constants  = require('src.constants')
local BaseUnit   = require('src.base_unit')

local SIGIL_DURATION = 10.0
local HEAL_INTERVAL  = 2.0
local HEAL_AMOUNT    = 2
local FADE_IN_TIME   = 0.5
local FADE_OUT_TIME  = 0.5
local HEAL_FPS       = 14
local HEAL_DURATION  = 21 / HEAL_FPS   -- 1.5 s, matches Mend

local lg = love.graphics

-- ── Ground sprite draw function (called by Grid:drawSigilPatches) ──────────
local function sigilPatchDraw(patch)
    local img = patch.sprites and patch.sprites.sigilSprite
    if not img then return end

    local visualRow = Constants.toVisualRow(patch.row)
    local cx = Constants.GRID_OFFSET_X + (patch.col - 1) * Constants.CELL_SIZE + Constants.CELL_SIZE / 2
    local cy = Constants.GRID_OFFSET_Y + (visualRow - 1) * Constants.CELL_SIZE + Constants.CELL_SIZE / 2

    -- Fade in during first FADE_IN_TIME seconds, fade out during last FADE_OUT_TIME seconds.
    local life = patch.lifetime or SIGIL_DURATION
    local alpha
    if patch.timer > life - FADE_IN_TIME then
        alpha = (life - patch.timer) / FADE_IN_TIME
    elseif patch.timer < FADE_OUT_TIME then
        alpha = patch.timer / FADE_OUT_TIME
    else
        alpha = 1.0
    end
    alpha = math.max(0, math.min(1, alpha)) * 0.9

    local sw = img:getWidth()   -- 48
    local scale = (3 * Constants.CELL_SIZE) / sw

    lg.setColor(1, 1, 1, alpha)
    lg.draw(img, math.floor(cx), math.floor(cy), patch.rotation or 0, scale, scale, sw / 2, img:getHeight() / 2)
    lg.setColor(1, 1, 1, 1)
end

-- ── Sigil effect class ──────────────────────────────────────────────────────
local SigilSpell = {}
SigilSpell.__index = SigilSpell

function SigilSpell.new(col, row, owner, grid, sprites, placementId)
    local self = setmetatable({}, SigilSpell)
    self.col         = col
    self.row         = row
    self.owner       = owner
    self.sprites     = sprites
    self.placementId = placementId or 0
    self.elapsed     = 0
    self.healTimer   = 0
    self.healAnims   = {}   -- { unit, elapsed }
    self.complete    = false

    -- Register the ground patch with the grid so it is drawn before units.
    table.insert(grid.sigilPatches, {
        col           = col,
        row           = row,
        owner         = owner,
        timer    = SIGIL_DURATION,
        lifetime = SIGIL_DURATION,
        rotation      = 0,
        rotationSpeed = 0.25,
        sprites       = sprites,
        draw          = sigilPatchDraw,
    })

    return self
end

function SigilSpell:update(dt, grid)
    if self.complete then return end

    self.elapsed   = self.elapsed + dt
    self.healTimer = self.healTimer + dt

    -- Tick existing heal animations; remove finished ones.
    for i = #self.healAnims, 1, -1 do
        local anim = self.healAnims[i]
        anim.elapsed = anim.elapsed + dt
        if anim.elapsed >= HEAL_DURATION then
            table.remove(self.healAnims, i)
        end
    end

    -- Apply a heal proc once per second.
    if self.healTimer >= HEAL_INTERVAL then
        self.healTimer = self.healTimer - HEAL_INTERVAL
        for _, unit in ipairs(grid:getAllUnits()) do
            if not unit.isDead and unit.owner == self.owner then
                if math.abs(unit.col - self.col) <= 1 and math.abs(unit.row - self.row) <= 1 then
                    unit.health = math.min(unit.maxHealth, unit.health + HEAL_AMOUNT)
                    table.insert(self.healAnims, { unit = unit, elapsed = 0 })
                end
            end
        end
    end

    if self.elapsed >= SIGIL_DURATION then
        self.complete = true
    end
end

-- Draw heal overlay animations above all units (called by game.lua after grid:draw).
function SigilSpell:draw()
    local frames = self.sprites and self.sprites.healFrames
    if not frames or #frames == 0 or #self.healAnims == 0 then return end

    for _, anim in ipairs(self.healAnims) do
        local u = anim.unit
        if not u.isDead then
            local x, y = u:getDrawPos()
            x = x + Constants.CELL_SIZE / 2
            y = y + Constants.CELL_SIZE / 2

            local frameIdx = math.min(#frames, math.floor(anim.elapsed * HEAL_FPS) + 1)
            local img = frames[frameIdx]
            local sw, sh = img:getWidth(), img:getHeight()
            local scale = Constants.SCALE * 3

            lg.setColor(1, 1, 1, 1)
            lg.setShader(BaseUnit.getPaletteShader())
            lg.draw(img, x, y, 0, scale, scale, sw / 2, sh / 2)
            lg.setShader()
        end
    end
    lg.setColor(1, 1, 1, 1)
end

return SigilSpell
