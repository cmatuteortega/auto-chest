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
1. STAT BOOST: 1.3x multiplier to HP and damage per level (automatic for all units)
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
- Level 1: 1.3x stats (13 HP, 1 damage)
- Level 2: 1.69x stats (16 HP, 1 damage)
- Level 3: 2.197x stats (21 HP, 2 damage)

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
    -- Buff animation
    self.buffAnimTimer    = 0

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
    self.attackAnimDuration = 0.45  -- 3 phases: windup / lunge / impact; scaled at fire time
    self.attackTargetCol = nil
    self.attackTargetRow = nil

    -- Deferred melee damage: integer tick countdown (0 = no pending attack)
    self.pendingAttackTarget = nil
    self.pendingAttackGrid   = nil
    self.pendingAttackDelay  = 0

    -- Deferred ranged shot: fired when attack animation completes
    self.pendingRangedTarget = nil
    self.pendingRangedGrid   = nil

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
    self.idleFrameDuration = 0.24          -- seconds/frame for idle cycling (default 2× walk)

    -- Battle-start one-shot action animation (used by action units like Marrow)
    self.actionAnimProgress = 0     -- 0..1, set by the unit's update(); drives frame index
    self.actionAnimPlaying  = false -- true while action is in flight
    self.actionAnimDone     = false -- latched true once animation finishes

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
-- prevAngle (optional) is used as a tiebreaker so 90° picks 45° or 135° based on
-- the incoming direction.  Pass already-converted visual-space angles for both.
function BaseUnit:getNearestStep(angle, availableSteps, prevAngle)
    prevAngle = prevAngle or self.prevFacingAngle
    local best, bestDist = availableSteps[1], 999
    for _, step in ipairs(availableSteps) do
        local d = math.abs(((angle - step + 180) % 360) - 180)
        local isBetter = d < bestDist
        if d == bestDist then
            local dPrev = math.abs(((prevAngle - step + 180) % 360) - 180)
            local dBest = math.abs(((prevAngle - best  + 180) % 360) - 180)
            isBetter = dPrev < dBest
        end
        if isBetter then best, bestDist = step, d end
    end
    return best
end

-- Convert a canonical facing angle to the local player's visual screen space.
-- facingAngle is stored canonically (row 1 = top), but P2's grid is rendered
-- row-flipped.  The flip negates the N/S component of direction while leaving
-- E/W unchanged, which is a specular reflection: θ_visual = (180 - θ) mod 360.
--   canonical 0°  (south) → visual 180° (north on P2's screen)  ✓
--   canonical 90° (east)  → visual 90°  (east unchanged)         ✓
--   canonical 45°         → visual 135°                          ✓
--   canonical 315°        → visual 225°                          ✓
function BaseUnit:visualAngle(a)
    if (Constants.PERSPECTIVE or 1) == 2 then
        return (180 - a + 360) % 360
    end
    return a
end

-- Returns the directional sprite image, trimBottom, and trimTop for the current animation state.
function BaseUnit:getDirectionalSprite()
    if self.isDead then
        return self.sprites.dead, self.sprites.deadTrimBottom or 0, self.sprites.deadTrimTop or 0
    end

    local d = self.sprites.directional

    -- Action animation: one-shot battle-start sequence
    if self.animState == "action" and d.action then
        local step = self:getNearestStep(self:visualAngle(self.facingAngle), {0, 180},
                                         self:visualAngle(self.prevFacingAngle))
        local dirData = d.action[step] or d.action[0]
        if dirData then
            local idx = math.min(self.animFrameIndex, #dirData.frames)
            return dirData.frames[idx], dirData.trimBottom[idx], dirData.trimTop[idx]
        end
    end

    -- Idle override: use action/idle sprites during setup before action fires
    if self.animState == "idle" and not self.actionAnimDone and d.actionIdleOverride then
        local step = self:getNearestStep(self:visualAngle(self.facingAngle), {0, 180},
                                         self:visualAngle(self.prevFacingAngle))
        local dirData = d.actionIdleOverride[step] or d.actionIdleOverride[0]
        if dirData then
            local idx = math.min(self.animFrameIndex, #dirData.frames)
            return dirData.frames[idx], dirData.trimBottom[idx], dirData.trimTop[idx]
        end
    end

    local stateKey = self.animState == "attack" and "hit" or self.animState
    local availableSteps = (self.animState == "idle") and {0, 180} or {0, 45, 135, 180, 225, 315}
    local step = self:getNearestStep(self:visualAngle(self.facingAngle), availableSteps,
                                     self:visualAngle(self.prevFacingAngle))

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
        return sprite, self.sprites[spriteKey .. "TrimBottom"] or 0, self.sprites[spriteKey .. "TrimTop"] or 0
    end

    local frameIdx = math.min(self.animFrameIndex, #dirData.frames)
    return dirData.frames[frameIdx], dirData.trimBottom[frameIdx], dirData.trimTop[frameIdx]
end

-- Visual-only update: smooth rotation and animation frame cycling.
-- Called every frame for all game states (NOT in the fixed-timestep battle loop).
function BaseUnit:updateVisuals(dt, gameState)
    if not self.hasDirectionalSprites then return end
    if self.isDead then return end

    -- Continuously track the current target so the unit faces it between attacks.
    -- Only when stationary and not mid-attack (those set prevFacingAngle intentionally).
    if self.target and not self.target.isDead and not self.isMoving
       and not (self.attackAnimProgress < 1 and self.attackTargetCol) then
        self.targetFacingAngle = self:computeTargetAngle(
            self.target.col - self.col, self.target.row - self.row)
    end

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
    if self.actionAnimPlaying and not self.actionAnimDone then
        self.animState = "action"
    elseif not self.actionAnimDone and self.sprites.directional and self.sprites.directional.action then
        self.animState = "idle"   -- hold action-idle pose until windup begins
    elseif self.attackAnimProgress < 1 and self.attackTargetCol then
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
    if self.animState == "action" then
        -- Progress-driven one-shot: map actionAnimProgress (0..1) to frame index
        local d = self.sprites.directional
        local step = self:getNearestStep(self:visualAngle(self.facingAngle), {0, 180},
                                         self:visualAngle(self.prevFacingAngle))
        local dirData = d.action and (d.action[step] or d.action[0])
        local count = dirData and #dirData.frames or 1
        self.animFrameIndex = math.min(count, math.floor(self.actionAnimProgress * count) + 1)
    elseif self.animState == "attack" then
        -- 3-phase attack: windup (0→⅓) / lunge (⅓→⅔) / impact (⅔→1)
        -- frame 1 = windup, frame 2 = lunge, frame 3 = impact
        local d = self.sprites.directional
        local step = self:getNearestStep(self:visualAngle(self.facingAngle),
                                         {0, 45, 135, 180, 225, 315},
                                         self:visualAngle(self.prevFacingAngle))
        local dirData = (d.hit and d.hit[step]) or (d.hit and d.hit[0])
        local count = dirData and #dirData.frames or 1
        local p = self.attackAnimProgress
        if count >= 3 then
            if p < 1/3 then
                self.animFrameIndex = 1
            elseif p < 2/3 then
                self.animFrameIndex = 2
            else
                self.animFrameIndex = 3
            end
        else
            self.animFrameIndex = math.min(count, math.floor(p * count) + 1)
        end
    else
        -- Cycle idle/walk frames via timer (only when actually moving for walk)
        -- Idle uses a slower cadence than walk for a more relaxed breathing feel
        local frameDur = (self.animState == "idle") and self.idleFrameDuration or self.animFrameDuration
        local shouldCycle = (self.animState == "idle") or self.isMoving
        if shouldCycle then
            self.animFrameTimer = self.animFrameTimer + dt
            if self.animFrameTimer >= frameDur then
                self.animFrameTimer = self.animFrameTimer - frameDur
                local d = self.sprites.directional
                local steps = (self.animState == "idle") and {0, 180} or {0, 45, 135, 180, 225, 315}
                local step = self:getNearestStep(self:visualAngle(self.facingAngle), steps,
                                                 self:visualAngle(self.prevFacingAngle))
                local stateData = d[self.animState]
                local dirData = (stateData and stateData[step]) or (stateData and stateData[0])
                local count = dirData and #dirData.frames or 1
                self.animFrameIndex = (self.animFrameIndex % count) + 1
            end
        end
    end
end

local BUFF_ANIM_FPS      = 8
local BUFF_ANIM_FRAMES   = 6
local BUFF_ANIM_DURATION = BUFF_ANIM_FRAMES / BUFF_ANIM_FPS  -- 0.75s

function BaseUnit:triggerBuffAnim()
    self.buffAnimTimer = BUFF_ANIM_DURATION
end

-- Returns the interpolated cell top-left (x, y) in screen pixels, accounting for
-- movement tween. Does not include drag offset (dragged units are drawn separately).
function BaseUnit:getDrawPos()
    local drawCol, drawRow = self.col, self.row

    if self.isMoving and self.targetCol and self.targetRow then
        local easedProgress = tween.easing.inOutQuad(self.tweenProgress, 0, 1, 1)
        drawCol = self.startCol + (self.targetCol - self.startCol) * easedProgress
        drawRow = self.startRow + (self.targetRow - self.startRow) * easedProgress
    end

    local visualRow = Constants.toVisualRow(drawRow)
    local x = Constants.GRID_OFFSET_X + (drawCol - 1) * Constants.CELL_SIZE
    local y = Constants.GRID_OFFSET_Y + (visualRow - 1) * Constants.CELL_SIZE
    return x, y
end

function BaseUnit:draw()
    local lg = love.graphics

    -- If being dragged, use drag position
    local x, y
    if self.dragX and self.dragY then
        x = self.dragX
        y = self.dragY
    else
        x, y = self:getDrawPos()
    end

    -- Apply attack animation (lunge with outBack for punch effect) — melee only
    if self.attackRange == 0 and self.attackAnimProgress < 1 and self.attackTargetCol and self.attackTargetRow then
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

            -- Use outBack easing for overshoot punch effect.
            -- Lunge only starts after the windup phase (first 1/3 of progress).
            local lungeProgress = math.max(0, (self.attackAnimProgress - 1/3) / (2/3))
            local maxLunge = Constants.CELL_SIZE * 0.3
            local lungeAmount = tween.easing.outBack(lungeProgress, 0, maxLunge, 1, 1.7)
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

    -- Get current sprite, trimBottom, and trimTop
    local sprite, trimBottom, trimTop
    if self.hasDirectionalSprites then
        sprite, trimBottom, trimTop = self:getDirectionalSprite()
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
        trimTop    = self.sprites[spriteKey .. "TrimTop"]    or 0
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

    -- Bars above the sprite: anchor to the unit's visible top (same reference as stun particles)
    if not self.isDead then
        local barPadding = 4 * Constants.SCALE
        local barHeight  = 3 * Constants.SCALE
        local barGap     = math.floor(1 * Constants.SCALE)
        local barWidth   = Constants.CELL_SIZE - barPadding
        local barX       = x + (barPadding / 2)
        local visibleTopY = y + offsetY + trimTop * scale

        -- Energy bar sits directly above the sprite top
        local hasEnergy = false
        if self.getEnergy then
            local curr, max = self:getEnergy()
            if curr and max and max > 0 then
                hasEnergy = true
                local energyBarY = visibleTopY - barHeight - barGap
                local pct = math.min(curr / max, 1)
                lg.setColor(0.4, 0.75, 1.0, 1)
                lg.rectangle('fill', barX, energyBarY, barWidth * pct, barHeight)
            end
        end

        -- Health bar sits above the energy bar (or directly above sprite if no energy bar)
        if self.health < self.maxHealth then
            local energyOffset = hasEnergy and (barHeight + barGap) or 0
            local hpBarY = visibleTopY - barHeight - barGap - energyOffset

            lg.setColor(0.3, 0.3, 0.3, 1)
            lg.rectangle('fill', barX, hpBarY, barWidth, barHeight)

            local healthPercent = self.health / self.maxHealth
            if self.owner == (Constants.PERSPECTIVE or 1) then
                lg.setColor(0.2, 0.8, 0.2, 1)
            else
                lg.setColor(0.8, 0.2, 0.2, 1)
            end
            lg.rectangle('fill', barX, hpBarY, barWidth * healthPercent, barHeight)
        end
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

    -- Draw taunt indicator if taunted
    if self.tauntedBy and not self.tauntedBy.isDead and self.tauntTimer > 0 then
        local tauntImg = self.sprites and self.sprites.tauntImg
        if tauntImg then
            local sw, sh      = tauntImg:getWidth(), tauntImg:getHeight()
            local cx          = x + Constants.CELL_SIZE / 2
            local visTopY     = y + offsetY + trimTop * scale
            lg.setColor(1, 1, 1, 1)
            lg.draw(tauntImg, cx, visTopY, 0, scale, scale, sw / 2, sh)
        end
    end

    -- Draw stun particles above the unit's head
    if self.stunTimer > 0 then
        local stunFrames = self.sprites and self.sprites.stunFrames
        if stunFrames then
            local frameIdx   = math.floor(love.timer.getTime() * 6) % #stunFrames + 1
            local img        = stunFrames[frameIdx]
            local sw, sh     = img:getWidth(), img:getHeight()
            local cx             = x + Constants.CELL_SIZE / 2
            local visibleTopY    = y + offsetY + trimTop * scale
            lg.setColor(1, 1, 1, 1)
            -- origin at bottom-center of stun sprite → sits flush on the unit's first visible pixel
            lg.draw(img, cx, visibleTopY, 0, scale, scale, sw / 2, sh)
        end
    end

    -- Draw buff "up" animation to the left of the unit
    if self.buffAnimTimer > 0 then
        local upFrames = self.sprites and self.sprites.upFrames
        if upFrames then
            local elapsed  = BUFF_ANIM_DURATION - self.buffAnimTimer
            local frameIdx = math.min(#upFrames, math.floor(elapsed * BUFF_ANIM_FPS) + 1)
            local img      = upFrames[frameIdx]
            local sw, sh   = img:getWidth(), img:getHeight()
            local cx = x - sw * scale / 2
            local cy = y + offsetY + (spriteHeight - trimTop - trimBottom) * scale / 2 + trimTop * scale
            lg.setColor(1, 1, 1, 1)
            lg.draw(img, cx, cy, 0, scale, scale, sw / 2, sh / 2)
        end
    end
end

-- Override this in subclasses for ground-level effects drawn before units
function BaseUnit:drawGroundEffects()
    -- Base implementation does nothing
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
    local multiplier = 1.3 ^ self.level
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
    self.buffAnimTimer      = 0
    self.actionDelayTimer   = 0
    self.isMoving           = false
    self.startCol           = self.col
    self.startRow           = self.row
    self.targetCol          = nil
    self.targetRow          = nil
    self.attackAnimProgress  = 1
    self.attackTargetCol     = nil
    self.attackTargetRow     = nil
    self.pendingAttackTarget = nil
    self.pendingAttackGrid   = nil
    self.pendingAttackDelay  = 0

    self.tombMartyrdombuffTimer = nil
    self._noHeal                = nil

    -- Reset action animation state
    self.actionAnimProgress = 0
    self.actionAnimPlaying  = false
    self.actionAnimDone     = false

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
            -- Fire ranged projectile at animation end (deferred from attack trigger)
            if self.pendingRangedTarget and not self.isDead then
                self:attack(self.pendingRangedTarget, self.pendingRangedGrid)
                self.pendingRangedTarget = nil
                self.pendingRangedGrid   = nil
            end
        end
    end

    -- Fire deferred melee damage via integer tick countdown (immune to FP drift).
    -- pendingAttackDelay is set once in startMeleeAnimation() using integer math;
    -- decrementing an integer is bit-exact on every platform, unlike float comparisons.
    if self.pendingAttackDelay > 0 then
        self.pendingAttackDelay = self.pendingAttackDelay - 1
        if self.pendingAttackDelay == 0 and self.pendingAttackTarget then
            if not self.isDead then
                self:attack(self.pendingAttackTarget, self.pendingAttackGrid)
            end
            self.pendingAttackTarget = nil
            self.pendingAttackGrid   = nil
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

    -- Tomb Martyrdom buff: +25% ATK SPD for a duration
    if self.tombMartyrdombuffTimer and self.tombMartyrdombuffTimer > 0 then
        self.tombMartyrdombuffTimer = self.tombMartyrdombuffTimer - dt
        self.attackSpeed = self.baseAttackSpeed * 1.25
        if self.tombMartyrdombuffTimer <= 0 then
            self.tombMartyrdombuffTimer = nil
            self.attackSpeed = self.baseAttackSpeed
        end
    end

    -- Wait for ACTION moves to resolve before acting
    if self.actionDelayTimer > 0 then
        self.actionDelayTimer = self.actionDelayTimer - dt
        return
    end

    -- Buff animation timer
    if self.buffAnimTimer > 0 then
        self.buffAnimTimer = math.max(0, self.buffAnimTimer - dt)
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
            if self.attackRange == 0 then
                self:startMeleeAnimation(self.target, grid)
            else
                -- Ranged: start windup animation; projectile fires when animation completes
                if self.hasDirectionalSprites then
                    self.attackAnimProgress  = 0
                    self.attackTargetCol     = self.target.col
                    self.attackTargetRow     = self.target.row
                    self.attackAnimDuration  = math.min(0.45, 1 / self.attackSpeed)
                    self.pendingRangedTarget = self.target
                    self.pendingRangedGrid   = grid
                else
                    -- No directional sprites: fire immediately (no animation to wait for)
                    self:attack(self.target, grid)
                end
            end
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
                if self.attackRange == 0 then
                    self:startMeleeAnimation(self.target, grid)
                else
                    -- Ranged: fire projectile immediately; also trigger hit_* windup sprites
                    if self.hasDirectionalSprites then
                        self.attackAnimProgress = 0
                        self.attackTargetCol    = self.target.col
                        self.attackTargetRow    = self.target.row
                        self.attackAnimDuration = math.min(0.45, 1 / self.attackSpeed)
                    end
                    self:attack(self.target, grid)
                end
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
            if (not gridCell.occupied and not gridCell.reserved) or (cell.col == self.col and cell.row == self.row) then
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

-- Default melee attack: apply damage and handle kill.
-- Ranged units override this via BaseUnitRanged to fire a projectile instead.
-- Melee subclasses may override to add extra effects (e.g. Humerus cleave).
function BaseUnit:attack(target, grid)
    if not target or target.isDead then return end
    target:takeDamage(self:getDamage(grid))
    if target.isDead then
        local cell = grid:getCell(target.col, target.row)
        if cell then
            cell.occupied = false
            cell.unit = nil
        end
        -- Free reservation if target died mid-movement (stale reserved flag would block pathfinding)
        if target.isMoving and target.targetCol and target.targetRow then
            grid:freeReservation(target.targetCol, target.targetRow)
        end
        -- Invalidate all cached paths so units recompute around the freed cell next frame
        local allUnits = grid:getAllUnits()
        for _, u in ipairs(allUnits) do
            if not u.isDead then u.path = nil end
        end
        self:onKill(target)
    end
end

-- Start the lunge animation and queue deferred melee damage.
-- Damage fires after pendingAttackDelay ticks (≈ 2/3 of the animation).
-- The delay is computed with integer arithmetic to guarantee bit-exact results
-- on every platform — floating-point comparisons (e.g. progress >= 2/3) can
-- fire one tick early or late on different Android FPUs, causing desync.
--
-- Math: totalTicks = round(animDuration * 60), delay = round(totalTicks * 2/3)
-- attackSpeed=1 → animDuration=0.45 → totalTicks=27 → delay=18 ticks  ✓
-- attackSpeed=1.5 → same animDuration (min clamp) → same delay=18 ticks ✓
local _FIXED_DT = 1/60
function BaseUnit:startMeleeAnimation(target, grid)
    self.attackAnimDuration  = math.min(0.45, 1 / self.attackSpeed)
    self.attackAnimProgress  = 0
    self.attackTargetCol     = target.col
    self.attackTargetRow     = target.row
    self.pendingAttackTarget = target
    self.pendingAttackGrid   = grid
    local totalTicks        = math.floor(self.attackAnimDuration / _FIXED_DT + 0.5)
    self.pendingAttackDelay = math.max(1, math.floor(totalTicks * 2 / 3 + 0.5))
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
