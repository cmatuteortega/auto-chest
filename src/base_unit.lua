local Class = require('lib.classic')
local Constants = require('src.constants')
local Pathfinding = require('src.pathfinding')
local tween = require('lib.tween')

--[[
================================================================================
UPGRADE SYSTEM DOCUMENTATION (Clash Mini Style)
================================================================================

OVERVIEW:
---------
Each unit can be upgraded up to level 3 (from base level 0). Upgrades provide:
1. STAT BOOST: 1.5x multiplier to HP and damage per level (automatic for all units)
2. ABILITY UPGRADES: Units with upgrade trees get to choose special abilities

UPGRADE TREE STRUCTURE:
-----------------------
Units can define an upgradeTree with 3 upgrade options. Players can select
all 3 upgrades (at level 1, 2, and 3). Each upgrade has:
  - name: Short display name (e.g., "Fury")
  - description: Brief description for tooltip (e.g., "+50% ATKSPD below 50% HP")
  - onApply: Optional function called when upgrade is selected

EXAMPLE UPGRADE TREE (from Boney):
----------------------------------
self.upgradeTree = {
    {
        name = "Mend",
        description = "Heal 25% HP when reaching 50% HP",
        onApply = function(unit)
            -- Called once when upgrade is purchased
            -- For passive effects, check in update() or getDamage()
        end
    },
    {
        name = "Fury",
        description = "+50% ATKSPD when below 50% HP",
        onApply = function(unit)
            -- Dynamic effects should be checked each frame in update()
        end
    },
    {
        name = "Desperate",
        description = "3x damage (instead of 2x)",
        onApply = function(unit)
            -- Damage modifiers checked in getDamage()
        end
    }
}

KEY METHODS:
------------
- upgrade(upgradeIndex): Apply an upgrade. Pass nil to auto-select next available.
- hasUpgrade(index): Check if a specific upgrade (1, 2, or 3) is active.
- getNextAvailableUpgrade(): Returns first available upgrade index.

IMPLEMENTING UPGRADE EFFECTS:
-----------------------------
1. ONE-TIME EFFECTS: Put logic in onApply function
2. PASSIVE/CONDITIONAL EFFECTS: Check hasUpgrade() in relevant hooks:
   - getDamage(grid): For damage modifiers
   - update(dt, grid): For per-frame checks (HP thresholds, attack speed, etc.)
   - onKill(target): For kill-triggered effects
   - onBattleStart(grid): For battle start effects

STAT SCALING:
-------------
- Level 0: Base stats (e.g., 10 HP, 1 damage)
- Level 1: 1.5x stats (15 HP, 1 damage)
- Level 2: 2.25x stats (22 HP, 2 damage)
- Level 3: 3.375x stats (33 HP, 3 damage)

Note: damage uses math.floor, so low base damage may not increase until level 2.

UNITS WITHOUT UPGRADE TREES:
----------------------------
Units that don't define an upgradeTree will still get the stat multiplier
when upgraded, but won't have special abilities to choose from.

================================================================================
--]]

local BaseUnit = Class:extend()

function BaseUnit:new(row, col, owner, sprites, stats)
    self.row = row
    self.col = col
    self.owner = owner  -- 1 or 2
    self.sprites = sprites

    -- Stats (passed from subclasses)
    self.health = stats.health or 10
    self.maxHealth = stats.maxHealth or 10
    self.damage = stats.damage or 1
    self.attackSpeed = stats.attackSpeed or 1  -- attacks per second
    self.moveSpeed = stats.moveSpeed or 1  -- cells per second
    self.attackRange = stats.attackRange or 0  -- 0 = melee
    self.unitType = stats.unitType or "unknown"

    -- Upgrade system (Clash Mini style - 3 upgrades, can choose all 3)
    self.level = 0  -- 0, 1, 2, or 3
    self.baseHealth = stats.health or 10
    self.baseDamage = stats.damage or 1
    self.baseAttackSpeed = stats.attackSpeed or 1

    -- Upgrade tree: each unit can have up to 3 upgrades, all can be selected
    self.activeUpgrades = {}  -- List of upgrade indices that have been selected (e.g., {1, 2})
    self.upgradeTree = {}  -- Defined in subclasses: {name, description, apply function}

    self.isDead = false

    -- Combat stats
    self.attackCooldown = 0

    -- Taunt system
    self.tauntedBy = nil  -- Reference to unit that taunted this unit
    self.tauntTimer = 0   -- Time remaining for taunt effect

    -- ACTION move system
    self.isActionUnit     = false  -- true for units with ACTION abilities
    self.actionDuration   = 0      -- seconds this unit's ACTION move takes
    self.actionDelayTimer = 0      -- delay before this unit starts acting (set by startBattle)
    -- Stun system
    self.stunTimer        = 0      -- seconds remaining stunned (cannot move or attack)

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

    -- Directional sprite animation system (gated by sprites.hasDirectionalSprites)
    self.hasDirectionalSprites = (sprites and sprites.hasDirectionalSprites) or false
    local defaultAngle = (owner == 1) and 180 or 0  -- P1 faces north (180°), P2 faces south (0°)
    self.facingAngle       = defaultAngle
    self.targetFacingAngle = defaultAngle
    self.prevFacingAngle   = defaultAngle  -- saved at move/attack start for 90°/270° tiebreaking
    self.turnSpeed         = 360           -- degrees/second; subclasses may override
    self.animState         = "idle"
    self.animFrameIndex    = 1
    self.animFrameTimer    = 0
    self.animFrameDuration = 0.12          -- seconds/frame; subclasses may override

    -- Visual
    self.sprite = self:getSprite()
end

function BaseUnit:getSprite()
    if self.isDead then
        return self.sprites.dead
    end
    -- Perspective-aware sprite selection:
    -- A unit whose owner matches the local player's perspective faces *away*
    -- (back sprite), and enemy units face *toward* (front sprite).
    -- This ensures the visual is correct both for P1 and the mirrored P2 view.
    local perspective = Constants.PERSPECTIVE or 1
    if self.owner == perspective then
        return self.sprites.back
    else
        return self.sprites.front
    end
end

-- Compute screen-space facing angle (CW from south=0°) for a movement delta.
-- dCol = targetCol - col (positive=right), dRow = targetRow - row (positive=down/south)
function BaseUnit:computeTargetAngle(dCol, dRow)
    if dCol == 0 and dRow == 0 then return self.facingAngle end
    local angle = math.atan2(-dCol, dRow) * (180 / math.pi)
    return angle % 360
end

-- Returns the nearest available angle step from availableSteps to the given angle.
-- Uses prevFacingAngle as tiebreaker so 90° picks 45° or 135° based on origin direction.
function BaseUnit:getNearestStep(angle, availableSteps)
    local best, bestDist = availableSteps[1], 999
    for _, step in ipairs(availableSteps) do
        local d = math.abs(((angle - step + 180) % 360) - 180)
        local isBetter = d < bestDist
        if d == bestDist then
            local dPrev = math.abs(((self.prevFacingAngle - step + 180) % 360) - 180)
            local dBest = math.abs(((self.prevFacingAngle - best  + 180) % 360) - 180)
            isBetter = dPrev < dBest
        end
        if isBetter then best, bestDist = step, d end
    end
    return best
end

-- Returns the directional sprite image and trimBottom for the current animation state.
function BaseUnit:getDirectionalSprite()
    if self.isDead then
        return self.sprites.dead, self.sprites.deadTrimBottom or 0
    end

    local d = self.sprites.directional
    local stateKey = self.animState == "attack" and "hit" or self.animState
    local availableSteps = (self.animState == "idle") and {0, 180} or {0, 45, 135, 180, 225, 315}
    local step = self:getNearestStep(self.facingAngle, availableSteps)

    local stateData = d[stateKey]
    local dirData   = stateData and stateData[step]
    if not dirData and step ~= 0 then
        dirData = stateData and stateData[0]
    end

    -- Last resort: legacy sprite
    if not dirData then
        local sprite = self:getSprite()
        local spriteKey = self.isDead and "dead"
            or (self.owner == (Constants.PERSPECTIVE or 1) and "back" or "front")
        return sprite, self.sprites[spriteKey .. "TrimBottom"] or 0
    end

    local frameIdx = math.min(self.animFrameIndex, #dirData.frames)
    return dirData.frames[frameIdx], dirData.trimBottom[frameIdx]
end

-- Visual-only update: smooth rotation and animation frame cycling.
-- Called every frame for all game states (NOT in the fixed-timestep battle loop).
function BaseUnit:updateVisuals(dt, gameState)
    if not self.hasDirectionalSprites then return end
    if self.isDead then return end

    -- 1. Smooth rotation toward targetFacingAngle (shortest arc)
    local delta = self.targetFacingAngle - self.facingAngle
    delta = ((delta + 180) % 360) - 180
    local maxStep = self.turnSpeed * dt
    if math.abs(delta) <= maxStep then
        self.facingAngle = self.targetFacingAngle
    else
        self.facingAngle = self.facingAngle + maxStep * (delta > 0 and 1 or -1)
    end

    -- 2. Determine animState
    local prevState = self.animState
    if self.attackAnimProgress < 1 and self.attackTargetCol then
        self.animState = "attack"
    elseif self.isMoving then
        self.animState = "walk"
    elseif gameState == "setup" then
        self.animState = "idle"
    else
        self.animState = "walk"  -- freeze on last walk frame during battle pauses
    end

    if self.animState ~= prevState then
        self.animFrameIndex = 1
        self.animFrameTimer = 0
    end

    -- 3. Advance frame index
    if self.animState == "attack" then
        -- Map attackAnimProgress (0→1) to frame index
        local d = self.sprites.directional
        local step = self:getNearestStep(self.facingAngle, {0, 45, 135, 180, 225, 315})
        local dirData = (d.hit and d.hit[step]) or (d.hit and d.hit[0])
        local count = dirData and #dirData.frames or 1
        self.animFrameIndex = math.min(count, math.floor(self.attackAnimProgress * count) + 1)
    else
        -- Cycle idle/walk frames via timer (only when actually moving for walk)
        local shouldCycle = (self.animState == "idle") or self.isMoving
        if shouldCycle then
            self.animFrameTimer = self.animFrameTimer + dt
            if self.animFrameTimer >= self.animFrameDuration then
                self.animFrameTimer = self.animFrameTimer - self.animFrameDuration
                local d = self.sprites.directional
                local steps = (self.animState == "idle") and {0, 180} or {0, 45, 135, 180, 225, 315}
                local step = self:getNearestStep(self.facingAngle, steps)
                local stateData = d[self.animState]
                local dirData = (stateData and stateData[step]) or (stateData and stateData[0])
                local count = dirData and #dirData.frames or 1
                self.animFrameIndex = (self.animFrameIndex % count) + 1
            end
        end
    end
end

function BaseUnit:draw()
    local lg = love.graphics

    -- If being dragged, use drag position
    local x, y
    if self.dragX and self.dragY then
        x = self.dragX
        y = self.dragY
    else
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

        -- Apply perspective: convert canonical row to visual (screen) row
        local visualRow = Constants.toVisualRow(drawRow)
        x = Constants.GRID_OFFSET_X + (drawCol - 1) * Constants.CELL_SIZE
        y = Constants.GRID_OFFSET_Y + (visualRow - 1) * Constants.CELL_SIZE
    end

    -- Apply attack animation (lunge with outBack for punch effect)
    if self.attackAnimProgress < 1 and self.attackTargetCol and self.attackTargetRow then
        local visualTargetRow = Constants.toVisualRow(self.attackTargetRow)
        local targetX = Constants.GRID_OFFSET_X + (self.attackTargetCol - 1) * Constants.CELL_SIZE
        local targetY = Constants.GRID_OFFSET_Y + (visualTargetRow - 1) * Constants.CELL_SIZE

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

    -- Get current sprite and trimBottom
    local sprite, trimBottom
    if self.hasDirectionalSprites then
        sprite, trimBottom = self:getDirectionalSprite()
    else
        sprite = self:getSprite()
        local spriteKey
        if self.isDead then
            spriteKey = "dead"
        elseif self.owner == (Constants.PERSPECTIVE or 1) then
            spriteKey = "back"
        else
            spriteKey = "front"
        end
        trimBottom = self.sprites[spriteKey .. "TrimBottom"] or 0
    end

    -- Draw sprite centered in cell
    lg.setColor(1, 1, 1, 1)

    -- Get sprite dimensions (supports variable height sprites: 16xH)
    local spriteWidth = sprite:getWidth()
    local spriteHeight = sprite:getHeight()

    -- Scale based on width (assuming 16px width) - use integer scale for crisp pixels
    local scale = math.floor(Constants.CELL_SIZE / 16)

    -- Ensure scale is at least 1 to prevent invisible sprites
    scale = math.max(1, scale)
    local BOTTOM_MARGIN = 3  -- sprite pixels; keep visual baseline consistent across units

    -- Center horizontally, anchor visual bottom 3 sprite-pixels above tile floor
    -- (allows taller sprites to overflow upward naturally)
    -- Use floor to ensure pixel-perfect positioning
    local offsetX = math.floor((Constants.CELL_SIZE - spriteWidth * scale) / 2)
    local offsetY = math.floor(Constants.CELL_SIZE - (spriteHeight - trimBottom + BOTTOM_MARGIN) * scale)

    lg.draw(sprite, math.floor(x + offsetX), math.floor(y + offsetY), 0, scale, scale)

    -- Draw health bar if damaged (scaled)
    if self.health < self.maxHealth and not self.isDead then
        local barPadding = 4 * Constants.SCALE
        local barHeight = 3 * Constants.SCALE
        local barWidth = Constants.CELL_SIZE - barPadding
        local barX = x + (barPadding / 2)
        local barY = y + Constants.CELL_SIZE - barHeight - (barPadding / 2)

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

    -- Draw level asterisks under health bar (if level > 0)
    if self.level > 0 and not self.isDead then
        lg.setFont(Fonts.tiny)
        lg.setColor(1, 1, 1, 1)  -- White color for stars
        local stars = string.rep("*", self.level)
        local starWidth = Fonts.tiny:getWidth(stars)
        local starX = x + (Constants.CELL_SIZE - starWidth) / 2
        local starY = y + Constants.CELL_SIZE - (12 * Constants.SCALE)
        lg.print(stars, starX, starY)
    end

    -- Let subclasses draw additional things (like arrows)
    self:drawAttackVisuals()

    -- Draw taunt indicator if taunted (scaled)
    if self.tauntedBy and not self.tauntedBy.isDead and self.tauntTimer > 0 then
        -- Draw exclamation mark above unit
        lg.setColor(1, 0.8, 0, 1)  -- Yellow/orange color

        local centerX = x + Constants.CELL_SIZE / 2
        local iconY = y - (8 * Constants.SCALE)  -- Above the unit

        -- Draw exclamation mark (simple shape, scaled)
        -- Vertical line
        lg.setLineWidth(2 * Constants.SCALE)
        lg.line(centerX, iconY, centerX, iconY + (6 * Constants.SCALE))
        -- Dot at bottom
        lg.circle('fill', centerX, iconY + (8 * Constants.SCALE), 1.5 * Constants.SCALE)
        lg.setLineWidth(1)
    end
end

-- Override this in subclasses for custom attack visuals
function BaseUnit:drawAttackVisuals()
    -- Base implementation does nothing
end

function BaseUnit:takeDamage(amount)
    self.health = self.health - amount
    if self.health <= 0 then
        self.health = 0
        self.isDead = true
    end

    -- Trigger hit animation (scaled)
    self.hitAnimProgress = 0  -- Reset to start
    self.hitAnimIntensity = 4 * Constants.SCALE  -- Pixels to shake (scaled)
end

-- Hook: Get damage amount (can be overridden for conditional damage)
function BaseUnit:getDamage(grid)
    return math.floor(self.damage * (self.royalCommandBonus or 1))
end

-- Hook: Called when this unit kills an enemy
function BaseUnit:onKill(target)
    -- Override in subclasses for kill-triggered abilities
end

-- Hook: Called when battle starts
function BaseUnit:onBattleStart(grid)
    -- Override in subclasses for battle start abilities
end

-- Upgrade unit with specific upgrade choice (Clash Mini style)
-- upgradeIndex: 1, 2, or 3 (which upgrade to apply)
function BaseUnit:upgrade(upgradeIndex)
    if self.level >= 3 then
        return false  -- Already max level
    end

    -- Check if this unit has an upgrade tree
    local hasUpgradeTree = self.upgradeTree and #self.upgradeTree > 0

    if hasUpgradeTree then
        -- New Clash Mini style upgrade system
        -- Default to first available upgrade if not specified
        if not upgradeIndex then
            upgradeIndex = self:getNextAvailableUpgrade()
        end

        -- Validate upgrade index
        if not upgradeIndex or upgradeIndex < 1 or upgradeIndex > 3 then
            return false
        end

        -- Check if upgrade is already active
        for _, activeIdx in ipairs(self.activeUpgrades) do
            if activeIdx == upgradeIndex then
                return false  -- Already purchased
            end
        end

        -- Check if we have this upgrade defined
        if not self.upgradeTree[upgradeIndex] then
            return false
        end

        -- Apply the upgrade
        self.level = self.level + 1
        table.insert(self.activeUpgrades, upgradeIndex)

        -- Call the upgrade's apply function if it exists
        local upgrade = self.upgradeTree[upgradeIndex]
        if upgrade.onApply then
            upgrade.onApply(self)
        end
    else
        -- Units without upgrade trees just level up
        self.level = self.level + 1
    end

    -- Always apply stat multiplier on upgrade (for all units)
    local multiplier = 1.5 ^ self.level
    self.maxHealth = math.floor(self.baseHealth * multiplier)
    self.damage = math.floor(self.baseDamage * multiplier)

    -- Heal to new max health when upgrading
    self.health = self.maxHealth

    return true
end

-- Get the next available upgrade (used for drag-to-upgrade auto-selection)
function BaseUnit:getNextAvailableUpgrade()
    for i = 1, 3 do
        local alreadyActive = false
        for _, activeIdx in ipairs(self.activeUpgrades) do
            if activeIdx == i then
                alreadyActive = true
                break
            end
        end
        if not alreadyActive and self.upgradeTree[i] then
            return i
        end
    end
    return nil
end

-- Check if a specific upgrade is active
function BaseUnit:hasUpgrade(upgradeIndex)
    for _, activeIdx in ipairs(self.activeUpgrades) do
        if activeIdx == upgradeIndex then
            return true
        end
    end
    return false
end

function BaseUnit:resetCombatState()
    self.health             = self.maxHealth
    self.isDead             = false
    self.state              = "idle"
    self.target             = nil
    self.path               = nil
    self.moveTimer          = 0
    self.attackCooldown     = 0
    self.tauntedBy          = nil
    self.tauntTimer         = 0
    self.stunTimer          = 0
    self.actionDelayTimer   = 0
    self.isMoving           = false
    self.startCol           = self.col
    self.startRow           = self.row
    self.targetCol          = nil
    self.targetRow          = nil
    self.attackAnimProgress = 1
    self.attackTargetCol    = nil
    self.attackTargetRow    = nil

    -- Reset directional sprite fields
    if self.hasDirectionalSprites then
        local defaultAngle = (self.owner == 1) and 180 or 0
        self.facingAngle       = defaultAngle
        self.targetFacingAngle = defaultAngle
        self.prevFacingAngle   = defaultAngle
        self.animState         = "idle"
        self.animFrameIndex    = 1
        self.animFrameTimer    = 0
    end
end

function BaseUnit:update(dt, grid)
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

    -- Wait for ACTION moves to resolve before acting
    if self.actionDelayTimer > 0 then
        self.actionDelayTimer = self.actionDelayTimer - dt
        return
    end

    -- Cannot move or attack while stunned
    if self.stunTimer > 0 then
        self.stunTimer = self.stunTimer - dt
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

    -- Update taunt timer
    if self.tauntTimer > 0 then
        self.tauntTimer = self.tauntTimer - dt
        if self.tauntTimer <= 0 then
            self.tauntedBy = nil  -- Taunt expired
        end
    end

    -- TAUNT OVERRIDE: If taunted, always target the taunter (highest priority)
    if self.tauntedBy and not self.tauntedBy.isDead and self.tauntTimer > 0 then
        if self.target ~= self.tauntedBy then
            self.target = self.tauntedBy
            self.path = nil  -- Recalculate path to taunter
        end
    else
        -- Find or validate target (normal behavior)
        if not self.target or self.target.isDead then
            self.target = self:findNearestEnemy(grid)
            self.path = nil
        end
    end

    -- No enemies left, go idle
    if not self.target then
        self.state = "idle"
        return
    end

    -- Check if target is in attack range
    local inRange = self:isInAttackRange(self.target)

    if inRange and not self.isMoving then
        -- Target in range and we're stationary, attack!
        self.state = "attacking"
        self.path = nil

        if self.attackCooldown <= 0 then
            if self.hasDirectionalSprites and self.target then
                self.prevFacingAngle   = self.facingAngle
                self.targetFacingAngle = self:computeTargetAngle(
                    self.target.col - self.col, self.target.row - self.row)
            end
            self:attack(self.target, grid)
            self.attackCooldown = 1 / self.attackSpeed
        end
    else
        -- Target out of range, or we're still moving - move toward it
        self.state = "moving"

        -- Check if any enemy has come within attack range while moving
        -- But only attack if we're not currently tweening between cells
        local enemyInRange = self:findEnemyInRange(grid)
        if enemyInRange and not self.isMoving then
            -- Found an enemy in attack range and we're stationary! Switch to attacking
            self.target = enemyInRange
            self.state = "attacking"
            self.path = nil

            if self.attackCooldown <= 0 then
                if self.hasDirectionalSprites and self.target then
                    self.prevFacingAngle   = self.facingAngle
                    self.targetFacingAngle = self:computeTargetAngle(
                        self.target.col - self.col, self.target.row - self.row)
                end
                self:attack(self.target, grid)
                self.attackCooldown = 1 / self.attackSpeed
            end
        else
            -- Generate new path if we don't have one
            if not self.path or #self.path == 0 then
                -- Find best goal cell based on attack range
                local goalCol, goalRow = self:findGoalNearTarget(grid, self.target)
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
end

-- Find the goal position near target (override in subclasses for ranged behavior)
function BaseUnit:findGoalNearTarget(grid, target)
    if not target then return nil, nil end

    -- Default: find adjacent cell (for melee units)
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
function BaseUnit:findNearestEnemy(grid)
    local allUnits = grid:getAllUnits()
    local nearestEnemy = nil
    local shortestDistance = math.huge

    for _, unit in ipairs(allUnits) do
        if unit.owner ~= self.owner and not unit.isDead then
            local distance = math.sqrt((unit.col - self.col)^2 + (unit.row - self.row)^2)
            -- Primary: closest enemy. Tie-break: lower col → lower row → lower owner.
            -- Explicit tie-breaking keeps target selection deterministic even when
            -- multiple equidistant enemies exist.
            local isBetter = distance < shortestDistance
            if distance == shortestDistance and nearestEnemy then
                isBetter = (unit.col < nearestEnemy.col) or
                           (unit.col == nearestEnemy.col and unit.row < nearestEnemy.row) or
                           (unit.col == nearestEnemy.col and unit.row == nearestEnemy.row
                            and unit.owner < nearestEnemy.owner)
            end
            if isBetter then
                shortestDistance = distance
                nearestEnemy = unit
            end
        end
    end

    return nearestEnemy
end

-- Find any enemy unit within attack range
function BaseUnit:findEnemyInRange(grid)
    local allUnits = grid:getAllUnits()

    for _, unit in ipairs(allUnits) do
        if unit.owner ~= self.owner and not unit.isDead then
            if self:isInAttackRange(unit) then
                return unit
            end
        end
    end

    return nil
end

-- Check if target is in attack range (override in subclasses for different ranges)
-- Note: Ranged units can attack over obstacles - no line-of-sight check
function BaseUnit:isInAttackRange(target)
    if not target then return false end

    local colDiff = math.abs(self.col - target.col)
    local rowDiff = math.abs(self.row - target.row)

    if self.attackRange == 0 then
        -- Melee range: 8 surrounding cells (adjacent only)
        return colDiff <= 1 and rowDiff <= 1 and not (colDiff == 0 and rowDiff == 0)
    else
        -- Ranged: check Manhattan distance (ignores obstacles between attacker and target)
        local distance = colDiff + rowDiff
        return distance > 0 and distance <= self.attackRange
    end
end

-- Attack the target (abstract method - override in subclasses)
function BaseUnit:attack(target, grid)
    -- Base implementation - subclasses should override this
    error("BaseUnit:attack() must be overridden in subclass")
end

-- Move along the current path (with tween animation)
function BaseUnit:moveAlongPath(dt, grid)
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

                -- Update facing angle for directional sprites
                if self.hasDirectionalSprites then
                    self.prevFacingAngle   = self.facingAngle
                    self.targetFacingAngle = self:computeTargetAngle(
                        nextPos.col - self.col, nextPos.row - self.row)
                end
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

return BaseUnit
