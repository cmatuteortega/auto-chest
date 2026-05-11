-- Arrows spell effect: triggered at battle start by an Arrows spell card.
-- Drops arrows from the sky onto a 3x3 area centered on (col, row),
-- dealing 2 damage to each enemy unit (relative to spell.owner) caught.
--
-- 9 "damage" arrows (one per 3x3 cell) carry the damage payload and fire
-- at deterministic times. ~36 cosmetic arrows scatter around the footprint
-- for a denser rain. Each arrow falls vertically, lands, then fades out.
--
-- Determinism: arrow positions, rotations and spawn delays are derived from
-- a per-arrow integer seed (placementId + index) via a tiny LCG, so both
-- clients see identical visuals AND damage timing without depending on
-- math.random call order.

local Constants = require('src.constants')

local ArrowsSpell = {}
ArrowsSpell.__index = ArrowsSpell

-- 3x3 offsets in canonical (col, row). Damage arrow index i (1-9) maps here.
local OFFSETS = {
    {-1, -1}, {0, -1}, {1, -1},
    {-1,  0}, {0,  0}, {1,  0},
    {-1,  1}, {0,  1}, {1,  1},
}

local DAMAGE             = 2
local DAMAGE_STAGGER     = 0.04   -- seconds between successive damage arrows
local FALL_DURATION      = 0.40   -- seconds for an arrow to fall to ground
local FADE_DURATION      = 0.45   -- seconds to fade after impact
local COSMETIC_PER_CELL  = 4      -- 4 * 9 = 36 cosmetic arrows total
local COSMETIC_TIME_MAX  = 0.65   -- cosmetic spawn times spread over [0, this]
local CELLS_ABOVE_START  = 3      -- arrows start this many cell-heights above impact

-- Tiny deterministic PRNG: 32-bit LCG. Returns a float in [0, 1).
local function lcg(seed)
    seed = (seed * 1103515245 + 12345) % 2147483648
    return seed / 2147483648, seed
end

-- Pull n successive [0,1) floats from a seed; returns table of length n + final state.
local function nrand(seed, n)
    local out = {}
    for i = 1, n do
        local v
        v, seed = lcg(seed)
        out[i] = v
    end
    return out
end

local function cellCenterPx(col, row)
    local visualRow = Constants.toVisualRow(row)
    local x = Constants.GRID_OFFSET_X + (col - 1) * Constants.CELL_SIZE + Constants.CELL_SIZE / 2
    local y = Constants.GRID_OFFSET_Y + (visualRow - 1) * Constants.CELL_SIZE + Constants.CELL_SIZE / 2
    return x, y
end

function ArrowsSpell.new(targetCol, targetRow, owner, grid, sprites, placementId)
    local self = setmetatable({}, ArrowsSpell)
    self.spellType   = "arrows"
    self.targetCol   = targetCol
    self.targetRow   = targetRow
    self.owner       = owner
    self.placementId = placementId or 0
    self.elapsed     = 0
    self.complete    = false
    self.arrows      = {}
    self.sprite      = sprites and sprites.arrow or nil  -- src/assets/particles/arrow.png

    -- Damage arrows: deterministic order (column-major within row, top-to-bottom).
    for i, off in ipairs(OFFSETS) do
        local dc, dr = off[1], off[2]
        local col, row = targetCol + dc, targetRow + dr
        local impactX, impactY = cellCenterPx(col, row)
        local rolls = nrand(self.placementId * 1009 + i * 31, 2)
        local rotation = (rolls[1] - 0.5) * 0.6
        local jitterX  = (rolls[2] - 0.5) * 4 * Constants.SCALE  -- tiny pixel jitter
        table.insert(self.arrows, {
            isDamage     = true,
            cellCol      = col,
            cellRow      = row,
            impactX      = impactX + jitterX,
            impactY      = impactY,
            startY       = impactY - CELLS_ABOVE_START * Constants.CELL_SIZE,
            spawnTime    = (i - 1) * DAMAGE_STAGGER,
            fallDuration = FALL_DURATION,
            fadeDuration = FADE_DURATION,
            rotation     = rotation,
            hit          = false,
            applied      = false,  -- damage applied flag
        })
    end

    -- Cosmetic arrows: scatter within and slightly past the 3x3 footprint.
    for cellIdx, off in ipairs(OFFSETS) do
        local dc, dr = off[1], off[2]
        local col, row = targetCol + dc, targetRow + dr
        local cx, cy = cellCenterPx(col, row)
        for k = 1, COSMETIC_PER_CELL do
            local rolls = nrand(self.placementId * 7919 + cellIdx * 257 + k, 4)
            local jitterX = (rolls[1] - 0.5) * Constants.CELL_SIZE * 0.9
            local jitterY = (rolls[2] - 0.5) * Constants.CELL_SIZE * 0.9
            local rotation = (rolls[3] - 0.5) * 0.8
            local spawnTime = rolls[4] * COSMETIC_TIME_MAX
            table.insert(self.arrows, {
                isDamage     = false,
                cellCol      = col,
                cellRow      = row,
                impactX      = cx + jitterX,
                impactY      = cy + jitterY,
                startY       = cy + jitterY - CELLS_ABOVE_START * Constants.CELL_SIZE,
                spawnTime    = spawnTime,
                fallDuration = FALL_DURATION + (rolls[3] - 0.5) * 0.08,
                fadeDuration = FADE_DURATION,
                rotation     = rotation,
                hit          = false,
                applied      = true,  -- never applies damage
            })
        end
    end

    return self
end

-- Apply 2 damage to enemy units on (col, row). Iterates units deterministically.
local function applyDamageAtCell(grid, col, row, ownerOfSpell)
    if not grid:isValidCell(col, row) then return end
    local allUnits = grid:getAllUnits()
    -- Sort for deterministic application order (col, row, owner).
    local victims = {}
    for _, u in ipairs(allUnits) do
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
        u:takeDamage(DAMAGE, nil, grid)
        if u.isDead then
            grid:killUnit(u)
        end
    end
end

function ArrowsSpell:update(dt, grid)
    self.elapsed = self.elapsed + dt

    local stillActive = false
    for _, a in ipairs(self.arrows) do
        local t = self.elapsed - a.spawnTime
        if t >= 0 then
            if not a.hit and t >= a.fallDuration then
                a.hit = true
                if a.isDamage and not a.applied then
                    a.applied = true
                    applyDamageAtCell(grid, a.cellCol, a.cellRow, self.owner)
                end
            end
            if a.hit then
                local fadeT = (t - a.fallDuration) / a.fadeDuration
                if fadeT < 1 then stillActive = true end
            else
                stillActive = true
            end
        else
            stillActive = true  -- not yet spawned
        end
    end

    if not stillActive then
        self.complete = true
    end
end

function ArrowsSpell:draw()
    if not self.sprite then return end
    local lg = love.graphics
    local sw = self.sprite:getWidth()
    local sh = self.sprite:getHeight()
    local scale = Constants.SCALE * 3

    for _, a in ipairs(self.arrows) do
        local t = self.elapsed - a.spawnTime
        if t >= 0 then
            local x, y, alpha
            if not a.hit then
                local p = math.min(1, t / a.fallDuration)
                x = a.impactX
                y = a.startY + (a.impactY - a.startY) * p
                alpha = 1
            else
                local fadeT = (t - a.fallDuration) / a.fadeDuration
                if fadeT >= 1 then
                    alpha = 0
                else
                    alpha = 1 - fadeT
                end
                x = a.impactX
                y = a.impactY
            end
            if alpha > 0 then
                -- Rotate +pi/2 so arrow.png (right-pointing) faces straight down.
                local angle = math.pi / 2 + a.rotation
                lg.setColor(1, 1, 1, alpha)
                lg.draw(self.sprite, x, y, angle, scale, scale, sw / 2, sh / 2)
            end
        end
    end
    lg.setColor(1, 1, 1, 1)
end

return ArrowsSpell
