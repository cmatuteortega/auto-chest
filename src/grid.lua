local Class = require('lib.classic')
local Constants = require('src.constants')
local BaseUnit = require('src.base_unit')

local Grid = Class:extend()

function Grid:new()
    self:refreshDimensions()

    -- Grid data (2D array)
    self.cells = {}
    for row = 1, self.rows do
        self.cells[row] = {}
        for col = 1, self.cols do
            self.cells[row][col] = {
                row = row,
                col = col,
                occupied = false,
                reserved = false,  -- For units currently moving to this cell
                unit = nil,
                owner = self:getOwner(row) -- 1 for player 1, 2 for player 2
            }
        end
    end

    -- Highlighted cell (for touch/mouse input)
    self.highlightedCell = nil

    -- Death registry: dead units by death order. Tomb / Samurai / future death anim read this.
    self.corpses = {}

    -- Ground effects (e.g. Migraine fire patches). Owned by Grid so they outlive their source unit.
    self.firePatches = {}
end

-- Refresh grid dimensions from Constants (called on resize)
function Grid:refreshDimensions()
    self.cols = Constants.GRID_COLS
    self.rows = Constants.GRID_ROWS
    self.cellSize = Constants.CELL_SIZE
    self.offsetX = Constants.GRID_OFFSET_X
    self.offsetY = Constants.GRID_OFFSET_Y
end

function Grid:getOwner(row)
    -- Top half (rows 1-6) belongs to player 2
    -- Bottom half (rows 7-12) belongs to player 1
    if row <= Constants.PLAYER2_ROWS then
        return 2
    else
        return 1
    end
end

function Grid:worldToGrid(x, y)
    -- Convert screen coordinates to canonical grid coordinates.
    -- When perspective == 2 the board is visually flipped, so we invert the row.
    local col = math.floor((x - self.offsetX) / self.cellSize) + 1
    local visualRow = math.floor((y - self.offsetY) / self.cellSize) + 1

    if col >= 1 and col <= self.cols and visualRow >= 1 and visualRow <= self.rows then
        local canonicalRow = Constants.toVisualRow(visualRow)  -- toVisualRow is its own inverse
        return col, canonicalRow
    end

    return nil, nil
end

function Grid:gridToWorld(col, row)
    -- Convert canonical grid coordinates to screen coordinates (top-left of cell).
    -- Applies perspective flip so the correct player always sees themselves at the bottom.
    local visualRow = Constants.toVisualRow(row)
    local x = self.offsetX + (col - 1) * self.cellSize
    local y = self.offsetY + (visualRow - 1) * self.cellSize
    return x, y
end

function Grid:getCellCenter(col, row)
    -- Get the center point of a cell
    local x, y = self:gridToWorld(col, row)
    return x + self.cellSize / 2, y + self.cellSize / 2
end

function Grid:isValidCell(col, row)
    return col >= 1 and col <= self.cols and row >= 1 and row <= self.rows
end

function Grid:getCell(col, row)
    if self:isValidCell(col, row) then
        return self.cells[row][col]
    end
    return nil
end

function Grid:canPlaceUnit(col, row, zoneOwner)
    local cell = self:getCell(col, row)
    if not cell then
        return false
    end

    -- Check if cell is occupied
    if cell.occupied then
        return false
    end

    -- Enforce zone restriction: P1 owns bottom half (rows > rows/2), P2 owns top half
    if zoneOwner then
        local half = self.rows / 2
        if zoneOwner == 1 and row <= half then return false end
        if zoneOwner == 2 and row >  half then return false end
    end

    return true
end

function Grid:placeUnit(col, row, unit)
    local cell = self:getCell(col, row)
    if cell and not cell.occupied then
        cell.occupied = true
        cell.unit = unit
        return true
    end
    return false
end

function Grid:removeUnit(col, row)
    local cell = self:getCell(col, row)
    if cell then
        cell.occupied = false
        local unit = cell.unit
        cell.unit = nil
        return unit
    end
    return nil
end

-- Atomically move a unit from one cell to another
-- Returns true if successful, false if the target cell is occupied or invalid
function Grid:moveUnit(oldCol, oldRow, newCol, newRow, unit)
    -- Validate both cells
    local oldCell = self:getCell(oldCol, oldRow)
    local newCell = self:getCell(newCol, newRow)

    if not oldCell or not newCell then
        return false
    end

    -- Check if target cell is available
    if newCell.occupied then
        return false
    end

    -- Atomic move: remove from old, place in new
    oldCell.occupied = false
    oldCell.unit = nil

    newCell.occupied = true
    newCell.unit = unit

    return true
end

-- Reserve a cell for a unit that's moving to it
function Grid:reserveCell(col, row)
    local cell = self:getCell(col, row)
    if cell and not cell.occupied and not cell.reserved then
        cell.reserved = true
        return true
    end
    return false
end

-- Free a cell reservation
function Grid:freeReservation(col, row)
    local cell = self:getCell(col, row)
    if cell then
        cell.reserved = false
    end
end

-- Check if a cell is available (not occupied and not reserved)
function Grid:isCellAvailable(col, row)
    local cell = self:getCell(col, row)
    if not cell then return false end
    return not cell.occupied and not cell.reserved
end

-- Centralized death: removes a unit from the grid, fires its onDeath hook,
-- frees movement reservations, records the corpse, and invalidates cached paths.
-- Idempotent — safe to call multiple times for the same unit.
function Grid:killUnit(unit)
    if unit._deathProcessed then return end
    unit._deathProcessed = true

    if unit.onDeath then unit:onDeath(self) end

    local cell = self:getCell(unit.col, unit.row)
    if cell and cell.unit == unit then
        cell.occupied = false
        cell.unit = nil
    end

    if unit.isMoving and unit.targetCol and unit.targetRow then
        self:freeReservation(unit.targetCol, unit.targetRow)
    end

    -- Snapshot the death position so the corpse animation plays at the cell where the unit
    -- fell, not wherever the (still-referenced) unit object happens to be later.
    unit.deathCol      = unit.col
    unit.deathRow      = unit.row
    unit.deathAnimTime = 0

    table.insert(self.corpses, unit)

    for _, u in ipairs(self:getAllUnits()) do u.path = nil end
end

-- Advance death-animation timers on every corpse. Cosmetic only; uses real dt.
function Grid:tickDeathAnims(dt)
    for _, corpse in ipairs(self.corpses) do
        corpse.deathAnimTime = (corpse.deathAnimTime or 0) + dt
    end
end

-- Tick fire patches (Migraine Cursed Ground residue). Called from the battle update loop
-- after the live-unit pass so freshly-emitted patches don't tick twice on their first frame.
function Grid:tickFirePatches(dt)
    for i = #self.firePatches, 1, -1 do
        local patch = self.firePatches[i]
        patch.timer       = patch.timer - dt
        patch.damageTimer = patch.damageTimer - dt

        if patch.damageTimer <= 0 then
            patch.damageTimer = patch.damageTimer + 1
            for _, unit in ipairs(self:getAllUnits()) do
                if unit.owner ~= patch.owner and not unit.isDead
                   and unit.col == patch.col and unit.row == patch.row then
                    unit:takeDamage(1)
                    if unit.isDead then
                        self:killUnit(unit)
                    end
                end
            end
        end

        if patch.timer <= 0 then
            table.remove(self.firePatches, i)
        end
    end
end

function Grid:getAllUnits()
    local units = {}
    for row = 1, self.rows do
        for col = 1, self.cols do
            local cell = self.cells[row][col]
            if cell.unit then
                table.insert(units, cell.unit)
            end
        end
    end
    return units
end

-- Find a unit by type and owner (for upgrade system)
function Grid:findUnitByTypeAndOwner(unitType, owner)
    for row = 1, self.rows do
        for col = 1, self.cols do
            local cell = self.cells[row][col]
            if cell.unit and cell.unit.unitType == unitType and cell.unit.owner == owner and not cell.unit.isDead then
                return cell.unit
            end
        end
    end
    return nil
end

-- Get the unit at a specific cell (returns nil if no unit)
function Grid:getUnitAtCell(col, row)
    local cell = self:getCell(col, row)
    if cell then
        return cell.unit
    end
    return nil
end

function Grid:update()
    -- Refresh dimensions in case window was resized
    self:refreshDimensions()
end

function Grid:draw(draggedUnit, hideOwner)
    local lg = love.graphics

    -- Reset color state to ensure no tinting
    lg.setColor(1, 1, 1, 1)

    -- Draw grid background
    lg.setColor(Constants.COLORS.GRID_BG)
    lg.rectangle('fill', self.offsetX, self.offsetY,
                 Constants.GRID_WIDTH, Constants.GRID_HEIGHT)

    -- Draw cells with chess pattern
    for row = 1, self.rows do
        for col = 1, self.cols do
            local x, y = self:gridToWorld(col, row)

            -- Chess pattern: use visual row so the pattern stays stable when flipped
            local visualRow = Constants.toVisualRow(row)
            if (visualRow + col) % 2 == 0 then
                lg.setColor(Constants.COLORS.CHESS_LIGHT)
            else
                lg.setColor(Constants.COLORS.CHESS_DARK)
            end
            lg.rectangle('fill', x, y, self.cellSize, self.cellSize)
        end
    end

    -- Draw center line between players (scaled).
    -- The divider sits between PLAYER2_ROWS and PLAYER2_ROWS+1 in canonical coords.
    -- After perspective flip this is still the geometric centre of the grid.
    lg.setColor(1, 1, 1, 0.3)
    lg.setLineWidth(2 * Constants.SCALE)
    local centerY = self.offsetY + (Constants.PLAYER2_ROWS * self.cellSize)
    lg.line(self.offsetX, centerY, self.offsetX + Constants.GRID_WIDTH, centerY)
    lg.setLineWidth(1)

    -- Determine row iteration order: draw far rows first, near rows last
    -- P1 (perspective 1): row 1 is far (top), row 8 is near (bottom) → iterate 1→8
    -- P2 (perspective 2): row 8 is far (top), row 1 is near (bottom) → iterate 8→1
    local rowStart, rowEnd, rowStep
    if Constants.PERSPECTIVE == 2 then
        rowStart, rowEnd, rowStep = self.rows, 1, -1
    else
        rowStart, rowEnd, rowStep = 1, self.rows, 1
    end

    -- Draw ground effects (fire patches etc.) before any units
    for row = rowStart, rowEnd, rowStep do
        for col = 1, self.cols do
            local cell = self.cells[row][col]
            if cell.unit then
                cell.unit:drawGroundEffects()
            end
        end
    end

    -- Grid-owned ground effects (Migraine fire patches): top portion clipped above units
    self:drawFirePatches("top")

    -- Interleave death animations with alive units row by row (far → near). Each row's
    -- corpse anims are drawn before its alive units, so a near-row death animation that
    -- extends upward correctly occludes units in farther rows from the camera POV.
    for row = rowStart, rowEnd, rowStep do
        self:drawCorpsesInRow(row, hideOwner)
        for col = 1, self.cols do
            local cell = self.cells[row][col]
            if cell.unit and cell.unit ~= draggedUnit and not cell.unit.isDead then
                if not (hideOwner and cell.unit.owner == hideOwner) then
                    cell.unit:draw()
                end
            end
        end
    end

    -- Grid-owned ground effects: bottom portion clipped over units' feet
    self:drawFirePatches("bottom")
end

-- Render fire patches owned by Grid. Called twice per frame: once with "top" before units
-- (covers upper 3/4 of cell, behind units stepping through) and once with "bottom" after
-- units (lower 1/4 overlays unit feet, matching the original Migraine-owned look).
function Grid:drawFirePatches(clipMode)
    for _, patch in ipairs(self.firePatches) do
        if patch.draw then patch:draw(clipMode) end
    end
end

local DEATH_FPS = 12

-- Draw the generic death animation for any corpse on the given canonical row.
-- Called from the row-by-row alive-unit loop so corpses inherit the same depth ordering
-- (far rows drawn first, near rows on top) and a near-row death animation properly
-- occludes farther units. The sprite vanishes once the one-shot completes; the corpse
-- stays in grid.corpses for game-state queries (Tomb heal cells, Samurai vengeance).
function Grid:drawCorpsesInRow(row, hideOwner)
    local frames = self.deathFrames
    if not frames or #frames == 0 then return end

    local lg      = love.graphics
    local nFrames = #frames
    local sample  = frames[1]
    local sw, sh  = sample:getWidth(), sample:getHeight()
    local scale   = math.max(1, math.floor(Constants.CELL_SIZE / 16))
    local drawW   = sw * scale
    local drawH   = sh * scale
    local offsetX = math.floor((Constants.CELL_SIZE - drawW) / 2)
    local offsetY = math.floor(Constants.CELL_SIZE - drawH)

    for _, corpse in ipairs(self.corpses) do
        local cRow = corpse.deathRow or corpse.row
        if cRow == row and not (hideOwner and corpse.owner == hideOwner) then
            local frameIdx = math.floor((corpse.deathAnimTime or 0) * DEATH_FPS) + 1
            if frameIdx <= nFrames then
                local img  = frames[frameIdx]
                local x, y = self:gridToWorld(corpse.deathCol or corpse.col, cRow)
                lg.setColor(1, 1, 1, 1)
                lg.setShader(BaseUnit.getPaletteShader())
                lg.draw(img, math.floor(x + offsetX), math.floor(y + offsetY), 0, scale, scale)
                lg.setShader()
            end
        end
    end
end

return Grid
