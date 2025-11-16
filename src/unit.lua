local Class = require('lib.classic')
local Constants = require('src.constants')
local Pathfinding = require('src.pathfinding')

local Unit = Class:extend()

function Unit:new(row, col, owner, sprites)
    self.row = row
    self.col = col
    self.owner = owner  -- 1 or 2
    self.sprites = sprites

    -- Stats
    self.health = 10
    self.maxHealth = 10
    self.damage = 1
    self.isDead = false

    -- Combat stats
    self.attackSpeed = 1  -- attacks per second
    self.attackCooldown = 0
    self.moveSpeed = 1  -- cells per second
    self.attackRange = 0  -- 0 = melee (adjacent cells only)

    -- AI state
    self.target = nil
    self.state = "idle"  -- idle, moving, attacking, dead
    self.path = nil
    self.moveTimer = 0

    -- Visual
    self.sprite = self:getSprite()
end

function Unit:getSprite()
    if self.isDead then
        return self.sprites.dead
    elseif self.owner == 1 then
        -- Player 1 units show back sprite (facing up/away)
        return self.sprites.back
    else
        -- Player 2 units show front sprite (facing down/toward player)
        return self.sprites.front
    end
end

function Unit:draw()
    local lg = love.graphics

    -- Always use grid position (no interpolation)
    local x = Constants.GRID_OFFSET_X + (self.col - 1) * Constants.CELL_SIZE
    local y = Constants.GRID_OFFSET_Y + (self.row - 1) * Constants.CELL_SIZE

    -- Get current sprite
    local sprite = self:getSprite()

    -- Draw sprite centered in cell
    lg.setColor(1, 1, 1, 1)

    -- Scale sprite to fit cell (16x16 sprite -> 32x32 cell = 2x scale)
    local scale = Constants.CELL_SIZE / 16
    local offsetX = (Constants.CELL_SIZE - 16 * scale) / 2
    local offsetY = (Constants.CELL_SIZE - 16 * scale) / 2

    lg.draw(sprite, x + offsetX, y + offsetY, 0, scale, scale)

    -- Draw health bar if damaged
    if self.health < self.maxHealth and not self.isDead then
        local barWidth = Constants.CELL_SIZE - 4
        local barHeight = 3
        local barX = x + 2
        local barY = y + Constants.CELL_SIZE - barHeight - 2

        -- Background
        lg.setColor(0.3, 0.3, 0.3, 1)
        lg.rectangle('fill', barX, barY, barWidth, barHeight)

        -- Health (green for player 1, red for player 2)
        local healthPercent = self.health / self.maxHealth
        if self.owner == 1 then
            lg.setColor(0.2, 0.8, 0.2, 1)  -- Green for player 1
        else
            lg.setColor(0.8, 0.2, 0.2, 1)  -- Red for player 2
        end
        lg.rectangle('fill', barX, barY, barWidth * healthPercent, barHeight)
    end
end

function Unit:takeDamage(amount)
    self.health = self.health - amount
    if self.health <= 0 then
        self.health = 0
        self.isDead = true
    end
end

function Unit:update(dt, grid)
    -- Dead units don't act
    if self.isDead then
        self.state = "dead"
        return
    end

    -- Update attack cooldown
    if self.attackCooldown > 0 then
        self.attackCooldown = self.attackCooldown - dt
    end

    -- Update movement timer
    if self.moveTimer > 0 then
        self.moveTimer = self.moveTimer - dt
    end

    -- Find or validate target
    if not self.target or self.target.isDead then
        self.target = self:findNearestEnemy(grid)
        self.path = nil
    end

    -- No enemies left, go idle
    if not self.target then
        self.state = "idle"
        return
    end

    -- Check if target is in attack range (adjacent cells for melee)
    local inRange = self:isInAttackRange(self.target)

    if inRange then
        -- Target in range, attack!
        self.state = "attacking"
        self.path = nil

        if self.attackCooldown <= 0 then
            self:attack(self.target, grid)
            self.attackCooldown = 1 / self.attackSpeed
        end
    else
        -- Target out of range, move toward it
        self.state = "moving"

        -- Generate new path if we don't have one
        if not self.path or #self.path == 0 then
            -- Find best adjacent cell to target (not the target's cell itself)
            local goalCol, goalRow = self:findAdjacentGoal(grid, self.target)
            if goalCol and goalRow then
                self.path = Pathfinding.findPath(grid, self.col, self.row, goalCol, goalRow, self.owner)
            end
        end

        -- Move along path if we have one
        if self.path and #self.path > 0 then
            self:moveAlongPath(dt, grid)
        else
            -- No valid path found, clear path to retry next frame
            self.path = nil
        end
    end
end

-- Find the best adjacent cell to move to near the target
function Unit:findAdjacentGoal(grid, target)
    if not target then return nil, nil end

    -- Get all cells adjacent to target (8 directions)
    local adjacentCells = {
        {col = target.col - 1, row = target.row},     -- left
        {col = target.col + 1, row = target.row},     -- right
        {col = target.col, row = target.row - 1},     -- up
        {col = target.col, row = target.row + 1},     -- down
        {col = target.col - 1, row = target.row - 1}, -- up-left
        {col = target.col + 1, row = target.row - 1}, -- up-right
        {col = target.col - 1, row = target.row + 1}, -- down-left
        {col = target.col + 1, row = target.row + 1}, -- down-right
    }

    -- Find the closest empty adjacent cell
    local bestCol, bestRow = nil, nil
    local shortestDistance = math.huge

    for _, cell in ipairs(adjacentCells) do
        if grid:isValidCell(cell.col, cell.row) then
            local gridCell = grid:getCell(cell.col, cell.row)
            -- Check if cell is empty or is our current position
            if not gridCell.occupied or (cell.col == self.col and cell.row == self.row) then
                local distance = math.sqrt((cell.col - self.col)^2 + (cell.row - self.row)^2)
                if distance < shortestDistance then
                    shortestDistance = distance
                    bestCol = cell.col
                    bestRow = cell.row
                end
            end
        end
    end

    return bestCol, bestRow
end

-- Find the nearest enemy unit
function Unit:findNearestEnemy(grid)
    local allUnits = grid:getAllUnits()
    local nearestEnemy = nil
    local shortestDistance = math.huge

    for _, unit in ipairs(allUnits) do
        if unit.owner ~= self.owner and not unit.isDead then
            local distance = math.sqrt((unit.col - self.col)^2 + (unit.row - self.row)^2)
            if distance < shortestDistance then
                shortestDistance = distance
                nearestEnemy = unit
            end
        end
    end

    return nearestEnemy
end

-- Check if target is in attack range (adjacent cells for melee)
function Unit:isInAttackRange(target)
    if not target then return false end

    local colDiff = math.abs(self.col - target.col)
    local rowDiff = math.abs(self.row - target.row)

    -- Melee range: 8 surrounding cells
    return colDiff <= 1 and rowDiff <= 1 and not (colDiff == 0 and rowDiff == 0)
end

-- Attack the target
function Unit:attack(target, grid)
    if target and not target.isDead then
        target:takeDamage(self.damage)

        -- If target died, mark cell as unoccupied but keep unit visible
        if target.isDead then
            local cell = grid:getCell(target.col, target.row)
            if cell then
                cell.occupied = false  -- Allow movement through this cell
                -- Keep cell.unit so the dead sprite remains visible
            end
        end
    end
end

-- Move along the current path (discrete grid-to-grid movement)
function Unit:moveAlongPath(dt, grid)
    if not self.path or #self.path == 0 then return end

    -- Wait for movement cooldown before moving to next cell
    if self.moveTimer > 0 then return end

    local nextPos = self.path[1]

    -- Skip if next position is the same as current position
    if nextPos.col == self.col and nextPos.row == self.row then
        table.remove(self.path, 1)
        return
    end

    -- Try to move to next cell atomically
    local oldCol, oldRow = self.col, self.row
    local success = grid:moveUnit(oldCol, oldRow, nextPos.col, nextPos.row, self)

    if success then
        -- Move succeeded, update unit position (snap to grid)
        self.col = nextPos.col
        self.row = nextPos.row

        -- Remove this waypoint from path
        table.remove(self.path, 1)

        -- Set movement cooldown (1 cell per second)
        self.moveTimer = 1 / self.moveSpeed
    else
        -- Move failed (cell occupied), recalculate path
        self.path = nil
    end
end

return Unit
