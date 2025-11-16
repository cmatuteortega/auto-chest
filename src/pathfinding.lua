-- A* Pathfinding for grid-based movement
local Pathfinding = {}

-- Calculate Manhattan distance between two grid positions
local function manhattanDistance(col1, row1, col2, row2)
    return math.abs(col1 - col2) + math.abs(row1 - row2)
end

-- Reconstruct path from came_from table
local function reconstructPath(cameFrom, current)
    local path = {current}
    while cameFrom[current.row .. "," .. current.col] do
        current = cameFrom[current.row .. "," .. current.col]
        table.insert(path, 1, current)
    end
    return path
end

-- Find path from start to goal using A* algorithm
-- Returns array of {col, row} positions, or nil if no path found
function Pathfinding.findPath(grid, startCol, startRow, goalCol, goalRow, unitOwner)
    -- Start and goal are same
    if startCol == goalCol and startRow == goalRow then
        return {}
    end

    -- Goal is invalid
    if not grid:isValidCell(goalCol, goalRow) then
        return nil
    end

    local openSet = {{col = startCol, row = startRow}}
    local cameFrom = {}
    local gScore = {}
    local fScore = {}

    local startKey = startRow .. "," .. startCol
    gScore[startKey] = 0
    fScore[startKey] = manhattanDistance(startCol, startRow, goalCol, goalRow)

    while #openSet > 0 do
        -- Find node in openSet with lowest fScore
        local current
        local currentIndex
        local lowestFScore = math.huge

        for i, node in ipairs(openSet) do
            local key = node.row .. "," .. node.col
            if fScore[key] < lowestFScore then
                lowestFScore = fScore[key]
                current = node
                currentIndex = i
            end
        end

        -- Reached goal
        if current.col == goalCol and current.row == goalRow then
            local path = reconstructPath(cameFrom, current)
            -- Remove first position (current position)
            table.remove(path, 1)
            return path
        end

        -- Remove current from openSet
        table.remove(openSet, currentIndex)

        -- Check all neighbors (4 directions only - no diagonal movement)
        local neighbors = {
            {col = current.col - 1, row = current.row},     -- left
            {col = current.col + 1, row = current.row},     -- right
            {col = current.col, row = current.row - 1},     -- up
            {col = current.col, row = current.row + 1},     -- down
        }

        for _, neighbor in ipairs(neighbors) do
            if grid:isValidCell(neighbor.col, neighbor.row) then
                local cell = grid:getCell(neighbor.col, neighbor.row)

                -- Can only move through empty cells
                local canMove = not cell.occupied

                if canMove then
                    local currentKey = current.row .. "," .. current.col
                    local neighborKey = neighbor.row .. "," .. neighbor.col

                    -- All movement costs 1 (only 4-directional, no diagonals)
                    local moveCost = 1
                    local tentativeGScore = gScore[currentKey] + moveCost

                    if not gScore[neighborKey] or tentativeGScore < gScore[neighborKey] then
                        cameFrom[neighborKey] = current
                        gScore[neighborKey] = tentativeGScore
                        fScore[neighborKey] = tentativeGScore + manhattanDistance(neighbor.col, neighbor.row, goalCol, goalRow)

                        -- Add to openSet if not already there
                        local inOpenSet = false
                        for _, node in ipairs(openSet) do
                            if node.col == neighbor.col and node.row == neighbor.row then
                                inOpenSet = true
                                break
                            end
                        end

                        if not inOpenSet then
                            table.insert(openSet, {col = neighbor.col, row = neighbor.row})
                        end
                    end
                end
            end
        end
    end

    -- No path found
    return nil
end

return Pathfinding
