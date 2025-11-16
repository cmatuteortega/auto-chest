local Class = require('lib.classic')
local Constants = require('src.constants')

local Grid = Class:extend()

function Grid:new()
    self.cols = Constants.GRID_COLS
    self.rows = Constants.GRID_ROWS
    self.cellSize = Constants.CELL_SIZE
    self.offsetX = Constants.GRID_OFFSET_X
    self.offsetY = Constants.GRID_OFFSET_Y

    -- Grid data (2D array)
    self.cells = {}
    for row = 1, self.rows do
        self.cells[row] = {}
        for col = 1, self.cols do
            self.cells[row][col] = {
                row = row,
                col = col,
                occupied = false,
                unit = nil,
                owner = self:getOwner(row) -- 1 for player 1, 2 for player 2
            }
        end
    end

    -- Highlighted cell (for touch/mouse input)
    self.highlightedCell = nil
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
    -- Convert screen coordinates to grid coordinates
    local col = math.floor((x - self.offsetX) / self.cellSize) + 1
    local row = math.floor((y - self.offsetY) / self.cellSize) + 1

    if col >= 1 and col <= self.cols and row >= 1 and row <= self.rows then
        return col, row
    end

    return nil, nil
end

function Grid:gridToWorld(col, row)
    -- Convert grid coordinates to world coordinates (top-left of cell)
    local x = self.offsetX + (col - 1) * self.cellSize
    local y = self.offsetY + (row - 1) * self.cellSize
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

function Grid:canPlaceUnit(col, row, playerOwner)
    local cell = self:getCell(col, row)
    if not cell then
        return false
    end

    -- Check if cell is occupied
    if cell.occupied then
        return false
    end

    -- Check if cell belongs to the player
    if cell.owner ~= playerOwner then
        return false
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

function Grid:update(dt, mouseX, mouseY)
    -- Update highlighted cell based on mouse/touch position
    local col, row = self:worldToGrid(mouseX, mouseY)

    if col and row then
        self.highlightedCell = {col = col, row = row}
    else
        self.highlightedCell = nil
    end
end

function Grid:draw()
    local lg = love.graphics

    -- Draw grid background
    lg.setColor(Constants.COLORS.GRID_BG)
    lg.rectangle('fill', self.offsetX, self.offsetY,
                 Constants.GRID_WIDTH, Constants.GRID_HEIGHT)

    -- Draw cells with player zones
    for row = 1, self.rows do
        for col = 1, self.cols do
            local cell = self.cells[row][col]
            local x, y = self:gridToWorld(col, row)

            -- Color cells based on owner
            if cell.owner == 1 then
                lg.setColor(Constants.COLORS.PLAYER1_CELL)
            else
                lg.setColor(Constants.COLORS.PLAYER2_CELL)
            end
            lg.rectangle('fill', x, y, self.cellSize, self.cellSize)

            -- Draw grid lines
            lg.setColor(Constants.COLORS.GRID_LINE)
            lg.rectangle('line', x, y, self.cellSize, self.cellSize)
        end
    end

    -- Draw highlighted cell
    if self.highlightedCell then
        local x, y = self:gridToWorld(self.highlightedCell.col, self.highlightedCell.row)
        lg.setColor(Constants.COLORS.CELL_HIGHLIGHT)
        lg.rectangle('fill', x, y, self.cellSize, self.cellSize)

        -- Draw border
        lg.setColor(1, 1, 1, 0.5)
        lg.setLineWidth(2)
        lg.rectangle('line', x, y, self.cellSize, self.cellSize)
        lg.setLineWidth(1)
    end

    -- Draw center line between players
    lg.setColor(1, 1, 1, 0.3)
    lg.setLineWidth(2)
    local centerY = self.offsetY + (Constants.PLAYER2_ROWS * self.cellSize)
    lg.line(self.offsetX, centerY, self.offsetX + Constants.GRID_WIDTH, centerY)
    lg.setLineWidth(1)

    -- Draw units
    for row = 1, self.rows do
        for col = 1, self.cols do
            local cell = self.cells[row][col]
            if cell.unit then
                cell.unit:draw()
            end
        end
    end
end

return Grid
