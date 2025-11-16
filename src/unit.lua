local Class = require('lib.classic')
local Constants = require('src.constants')
local Pathfinding = require('src.pathfinding')
local tween = require('lib.tween')

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

    -- Tween movement state
    self.isMoving = false
    self.tweenProgress = 0  -- 0 to 1
    self.tweenDuration = 1 / self.moveSpeed  -- seconds
    self.startCol = col
    self.startRow = row
    self.targetCol = nil
    self.targetRow = nil

    -- Attack animation state
    self.attackAnimProgress = 0
    self.attackAnimDuration = 0.15  -- Quick lunge animation
    self.attackTargetCol = nil
    self.attackTargetRow = nil

    -- Hit animation state
    self.hitAnimProgress = 0
    self.hitAnimDuration = 0.1  -- Quick hit reaction
    self.hitAnimIntensity = 0

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

    -- Calculate base position (with tween interpolation if moving)
    local drawCol, drawRow = self.col, self.row

    if self.isMoving and self.targetCol and self.targetRow then
        -- Use inOutQuad easing for smooth acceleration/deceleration
        local easedProgress = tween.easing.inOutQuad(self.tweenProgress, 0, 1, 1)

        local colDiff = self.targetCol - self.startCol
        local rowDiff = self.targetRow - self.startRow

        drawCol = self.startCol + colDiff * easedProgress
        drawRow = self.startRow + rowDiff * easedProgress
    end

    local x = Constants.GRID_OFFSET_X + (drawCol - 1) * Constants.CELL_SIZE
    local y = Constants.GRID_OFFSET_Y + (drawRow - 1) * Constants.CELL_SIZE

    -- Apply attack animation (lunge with outBack for punch effect)
    if self.attackAnimProgress < 1 and self.attackTargetCol and self.attackTargetRow then
        local targetX = Constants.GRID_OFFSET_X + (self.attackTargetCol - 1) * Constants.CELL_SIZE
        local targetY = Constants.GRID_OFFSET_Y + (self.attackTargetRow - 1) * Constants.CELL_SIZE

        -- Calculate lunge direction
        local dx = targetX - x
        local dy = targetY - y
        local distance = math.sqrt(dx * dx + dy * dy)

        if distance > 0 then
            -- Normalize direction
            dx = dx / distance
            dy = dy / distance

            -- Use outBack easing for overshoot punch effect
            local maxLunge = Constants.CELL_SIZE * 0.3
            local lungeAmount = tween.easing.outBack(self.attackAnimProgress, 0, maxLunge, 1, 1.7)
            x = x + dx * lungeAmount
            y = y + dy * lungeAmount
        end
    end

    -- Apply hit animation (elastic bounce for impact)
    if self.hitAnimProgress < 1 and self.hitAnimIntensity > 0 then
        -- Use inOutElastic for bouncy impact effect
        local shakeAmount = tween.easing.inOutElastic(self.hitAnimProgress, 0, self.hitAnimIntensity, 1)
        x = x + shakeAmount
    end

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

    -- Trigger hit animation
    self.hitAnimProgress = 0  -- Reset to start
    self.hitAnimIntensity = 4  -- Pixels to shake
end

function Unit:update(dt, grid)
    -- Update animations even when dead
    if self.attackAnimProgress < 1 and self.attackTargetCol and self.attackTargetRow then
        self.attackAnimProgress = self.attackAnimProgress + (dt / self.attackAnimDuration)
        if self.attackAnimProgress >= 1.0 then
            self.attackAnimProgress = 1
            self.attackTargetCol = nil
            self.attackTargetRow = nil
        end
    end

    if self.hitAnimProgress < 1 and self.hitAnimIntensity > 0 then
        self.hitAnimProgress = self.hitAnimProgress + (dt / self.hitAnimDuration)
        if self.hitAnimProgress >= 1.0 then
            self.hitAnimProgress = 1
            self.hitAnimIntensity = 0
        end
    end

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
        -- Trigger attack animation
        self.attackAnimProgress = 0  -- Reset to start
        self.attackTargetCol = target.col
        self.attackTargetRow = target.row

        -- Apply damage
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

-- Move along the current path (with tween animation)
function Unit:moveAlongPath(dt, grid)
    if not self.path or #self.path == 0 then return end

    if self.isMoving then
        -- Currently animating movement
        self.tweenProgress = self.tweenProgress + (dt / self.tweenDuration)

        if self.tweenProgress >= 1.0 then
            -- Tween complete - finalize movement
            self.tweenProgress = 1.0
            self.isMoving = false

            -- Update grid: move from old position to new position
            local oldCol, oldRow = self.col, self.row
            grid:removeUnit(oldCol, oldRow)
            grid:placeUnit(self.targetCol, self.targetRow, self)

            -- Free the reservation
            grid:freeReservation(self.targetCol, self.targetRow)

            -- Update unit position
            self.col = self.targetCol
            self.row = self.targetRow

            -- Remove completed waypoint
            table.remove(self.path, 1)
        end
    else
        -- Not currently moving - try to start next move
        local nextPos = self.path[1]

        -- Skip if next position is same as current
        if nextPos.col == self.col and nextPos.row == self.row then
            table.remove(self.path, 1)
            return
        end

        -- Check if destination cell will be available
        if grid:isCellAvailable(nextPos.col, nextPos.row) then
            -- Reserve the destination cell
            if grid:reserveCell(nextPos.col, nextPos.row) then
                -- Start tween animation
                self.isMoving = true
                self.tweenProgress = 0
                self.startCol = self.col
                self.startRow = self.row
                self.targetCol = nextPos.col
                self.targetRow = nextPos.row
            else
                -- Reservation failed, recalculate path
                self.path = nil
            end
        else
            -- Destination not available, recalculate path
            self.path = nil
        end
    end
end

return Unit
