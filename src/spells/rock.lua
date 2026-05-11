-- Rock spell effect.
-- Spawns an indestructible boulder at the target cell at battle start (before onBattleStart),
-- blocking pathfinding and projectiles for the entire round.
-- Any unit occupying the cell is displaced to the nearest free orthogonal neighbor.
-- After a punchy pop-up animation the spell marks itself complete; the grid owns the rock from then on.

local Constants = require('src.constants')

local RockSpell = {}
RockSpell.__index = RockSpell

local POP_DURATION = 0.30

local function interruptAction(unit)
    unit.actionAnimPlaying = false
    unit.actionAnimDone    = true
    unit.pendingTaunt      = nil   -- Knight
    unit.isCharging        = false -- Bull
    unit.isRolling         = false -- Barrel
    unit.crashPending      = false -- Barrel
end

local function displaceUnit(unit, grid)
    local neighbors = {
        {col = unit.col - 1, row = unit.row},
        {col = unit.col + 1, row = unit.row},
        {col = unit.col,     row = unit.row - 1},
        {col = unit.col,     row = unit.row + 1},
    }
    table.sort(neighbors, function(a, b)
        if a.col ~= b.col then return a.col < b.col end
        return a.row < b.row
    end)

    for _, n in ipairs(neighbors) do
        if grid:isValidCell(n.col, n.row) then
            local cell = grid:getCell(n.col, n.row)
            if not cell.occupied then
                grid:removeUnit(unit.col, unit.row)
                unit.col = n.col
                unit.row = n.row
                grid:placeUnit(n.col, n.row, unit)
                interruptAction(unit)
                return
            end
        end
    end
    -- No free neighbor found — unit stays, rock still spawns on top.
end

function RockSpell.new(targetCol, targetRow, owner, grid, sprite, placementId)
    local self = setmetatable({}, RockSpell)
    self.spellType   = "rock"
    self.targetCol   = targetCol
    self.targetRow   = targetRow
    self.owner       = owner
    self.sprite      = sprite
    self.placementId = placementId or 0
    self.elapsed     = 0
    self.complete    = false

    -- Displace any unit at the target cell before placing the rock.
    local existing = grid:getUnitAtCell(targetCol, targetRow)
    if existing and not existing.isDead then
        displaceUnit(existing, grid)
    end
    -- Also handle hidden units (e.g. Burrow underground).
    for _, u in ipairs(grid.hiddenUnits or {}) do
        if u.col == targetCol and u.row == targetRow then
            displaceUnit(u, grid)
        end
    end

    self.rockEntry = grid:placeRock(targetCol, targetRow, sprite)
    return self
end

function RockSpell:update(dt, grid) -- luacheck: ignore grid
    self.elapsed = self.elapsed + dt
    if self.elapsed >= POP_DURATION then
        self.complete = true
        if self.rockEntry then
            self.rockEntry.animating = false
            self.rockEntry = nil
        end
    end
end

function RockSpell:draw()
    -- Only draw during the pop animation; after that Grid:draw() handles it inline.
    if not (self.rockEntry and self.rockEntry.animating) then return end
    local img = self.sprite
    if not img then return end

    local t = math.min(self.elapsed / POP_DURATION, 1)
    local popScale = 1 + 0.4 * math.exp(-t * 12) * math.cos(t * math.pi * 5)
    if t == 0 then popScale = 0 end

    local visualRow = Constants.toVisualRow(self.targetRow)
    local x  = Constants.GRID_OFFSET_X + (self.targetCol - 1) * Constants.CELL_SIZE
    local y  = Constants.GRID_OFFSET_Y + (visualRow - 1) * Constants.CELL_SIZE
    local sw, sh    = img:getWidth(), img:getHeight()
    local baseScale = math.max(1, math.floor(Constants.CELL_SIZE / 16))
    local offX = math.floor((Constants.CELL_SIZE - sw * baseScale) / 2)
    local offY = math.floor(Constants.CELL_SIZE - (sh + 3) * baseScale)
    -- Scale from the sprite's bottom-centre so it pops upward from the ground.
    local drawX = math.floor(x + offX) + sw * baseScale / 2
    local drawY = math.floor(y + offY) + sh * baseScale
    local s = baseScale * popScale

    love.graphics.setColor(1, 1, 1, 1)
    love.graphics.draw(img, drawX, drawY, 0, s, s, sw / 2, sh)
end

return RockSpell
