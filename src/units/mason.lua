local BaseUnit  = require('src.base_unit')
local Constants = require('src.constants')

local Mason = BaseUnit:extend()

local ACTION_TRAVEL_CELLS = 4
local ACTION_ROCK_DMG     = 5
local ACTION_ROCK_BIG_DMG = 10
local ACTION_ROCK_STUN    = 2.0

local BASIC_TRAVEL_CARDINAL = 4
local BASIC_TRAVEL_DIAGONAL = 3
local ACTION_FLIGHT_PER_CELL = 0.18   -- 4-cell action rock: ~0.72s total
local BASIC_FLIGHT_PER_CELL  = 0.35   -- basic attacks fly slower for dramatic feel
local BREAK_DURATION         = 0.25

local ROCK_FPS  = 10
local BREAK_FPS = 8

local function sign(n) return (n > 0 and 1) or (n < 0 and -1) or 0 end

function Mason:new(row, col, owner, sprites)
    local stats = {
        health      = 20,
        maxHealth   = 20,
        damage      = 2,
        attackSpeed = 0.6,
        moveSpeed   = 1,
        attackRange = 0,   -- 8-cell adjacency; we throw rocks visually
        unitType    = "mason",
    }

    Mason.super.new(self, row, col, owner, sprites, stats)

    self.hitSound = "soft-hit.mp3"

    -- Mason's action rock launches at battle start (no windup) so it lines
    -- up with Bull's charge and Barrel's roll. actionDuration covers the
    -- full 4-cell roll so non-action units' AI is delayed until the rock
    -- finishes its run.
    self.isActionUnit   = true
    self.actionDuration = ACTION_TRAVEL_CELLS * ACTION_FLIGHT_PER_CELL

    self.rocks       = {}
    self.actionRock  = nil
    self.breakAnims  = {}
    self.pushedUnits = {}  -- units mid-slide; we restore their tweenDuration on slide end

    self.upgradeTree = {
        {
            name        = "Boulder Throw",
            description = "Battle-start rock deals 10 damage instead of 5",
            onApply     = function(unit) end,
        },
        {
            name        = "Concussive Toss",
            description = "Battle-start rock stuns every hit enemy for 2s",
            onApply     = function(unit) end,
        },
        {
            name        = "Rolling Stone",
            description = "Action rock pushes back hit enemies. Basic attacks roll 4 cells (3 diagonal), damaging + pushing each enemy on the way",
            onApply     = function(unit) end,
        },
    }
end

-- ============================================================
-- onBattleStart: launch the action rock immediately so its
-- timing matches Bull's charge and Barrel's roll. No windup.
-- ============================================================
function Mason:onBattleStart(grid)
    local dirRow = (self.owner == 1) and -1 or 1
    self.actionRock = self:spawnRock(self.col, self.row, 0, dirRow,
        ACTION_TRAVEL_CELLS, ACTION_FLIGHT_PER_CELL,
        function(r, g, c, ro) self:applyActionRockPayload(r, g, c, ro) end)
    if self.hitSound then AudioManager.playSFX(self.hitSound) end
end

-- ============================================================
-- spawnRock: build a rock projectile that walks N cells along
-- (dCol, dRow), applying a per-cell payload as it crosses each
-- cell. `payload` is a function (rock, cell) called once per cell
-- as the rock enters it.
-- ============================================================
function Mason:spawnRock(startCol, startRow, dCol, dRow, maxSteps, flightPerCell, payload)
    local steps = math.max(1, maxSteps)
    local rock = {
        startCol   = startCol,
        startRow   = startRow,
        dCol       = dCol,
        dRow       = dRow,
        steps      = steps,
        progress   = 0,
        duration   = steps * flightPerCell,
        animTime   = 0,
        nextStep   = 1,    -- which cell index to apply next (1..steps)
        hitTargets = {},   -- units already hit by this rock; never re-hit
        payload    = payload,
    }
    rock.endCol = startCol + dCol * steps
    rock.endRow = startRow + dRow * steps
    return rock
end

-- ============================================================
-- knockBack: shove a unit 1 cell along (dCol, dRow), tweening at
-- the same pace as the rock so the unit visually slides with it
-- rather than snapping instantly. Skip if destination is
-- occupied/reserved/off-board, or if the unit is already mid-tween.
-- ============================================================
function Mason:knockBack(unit, grid, dCol, dRow, duration)
    if dCol == 0 and dRow == 0 then return end
    if unit.isMoving then return end

    local destCol = unit.col + dCol
    local destRow = unit.row + dRow
    if destCol < 1 or destCol > grid.cols then return end
    if destRow < 1 or destRow > grid.rows then return end
    local cell = grid:getCell(destCol, destRow)
    if not cell or cell.occupied or cell.reserved then return end

    -- Reserve destination + set up the same tween fields the base movement
    -- system uses. self.col/row stay at the start cell until tweenProgress
    -- hits 1.0, at which point base_unit.lua's update completion path
    -- handles grid:removeUnit / grid:placeUnit / freeReservation.
    grid:reserveCell(destCol, destRow)
    unit.startCol      = unit.col
    unit.startRow      = unit.row
    unit.targetCol     = destCol
    unit.targetRow     = destRow
    unit.tweenProgress = 0
    unit.tweenDuration = duration
    unit.isMoving      = true
    unit.path          = { { col = destCol, row = destRow } }

    -- Track for tween-duration restore once the slide ends. Without this,
    -- the unit's subsequent normal moves would keep using the rock's pace.
    table.insert(self.pushedUnits, unit)
end

-- ============================================================
-- applyActionRockPayload: per-cell handler for the battle-start
-- rock. Damages, optionally stuns, optionally pushes.
-- ============================================================
function Mason:applyActionRockPayload(rock, grid, cellCol, cellRow)
    if not grid:isValidCell(cellCol, cellRow) then return end
    local cell = grid:getCell(cellCol, cellRow)
    if not (cell and cell.unit and not cell.unit.isDead and cell.unit.owner ~= self.owner) then
        return
    end

    local target = cell.unit
    if rock.hitTargets[target] then return end
    rock.hitTargets[target] = true

    -- Rolling Stone (upgrade 3) interrupts incoming Bull charges and Barrel
    -- rolls firing at the same battle-start tick.
    if self:hasUpgrade(3) then
        if target.isCharging then
            -- Bull mid-charge: cancel its charge tween + the pending stun
            -- it would have applied to its target. Bull will still take
            -- Mason's damage and get pushed back by the upgrade-3 push below
            -- (now that isMoving is false, knockBack works).
            target.isCharging       = false
            target.isMoving         = false
            target.tweenProgress    = 1
            target.chargeEnemy      = nil
            target.chargeTrail      = {}
            target.chargeTrailIndex = 0
        elseif target.isRolling then
            -- Barrel mid-roll: end the roll, cancel its crash payload, and
            -- trigger the transformation. Barrel does NOT take Mason's
            -- damage in this case — the rock just breaks the barrel open.
            target.isRolling     = false
            target.isMoving      = false
            target.tweenProgress = 1
            target.crashTarget   = nil
            target.tweenDuration = 1 / (target.moveSpeed or 1)
            if target.doCrash then target:doCrash(grid) end
            return
        end
    end

    local dmg = self:hasUpgrade(1) and ACTION_ROCK_BIG_DMG or ACTION_ROCK_DMG
    target:takeDamage(dmg, self, grid)

    if self:hasUpgrade(2) then
        target.stunTimer = math.max(target.stunTimer, ACTION_ROCK_STUN)
    end

    if self:hasUpgrade(3) and not target.isDead then
        self:knockBack(target, grid, rock.dCol, rock.dRow, ACTION_FLIGHT_PER_CELL)
    end

    if target.isDead then
        grid:killUnit(target)
        self:onKill(target)
    end
end

-- ============================================================
-- applyBasicRockPayload: per-cell handler for basic-attack rocks.
-- Without upgrade 3 the rock only fires payload at the final cell
-- (1-cell flight). With upgrade 3 the rock applies damage + push
-- to each enemy on the way.
-- ============================================================
function Mason:applyBasicRockPayload(rock, grid, cellCol, cellRow)
    if not grid:isValidCell(cellCol, cellRow) then return end
    local cell = grid:getCell(cellCol, cellRow)
    if not (cell and cell.unit and not cell.unit.isDead and cell.unit.owner ~= self.owner) then
        return
    end

    local target = cell.unit
    if rock.hitTargets[target] then return end
    rock.hitTargets[target] = true

    target:takeDamage(self.damage, self, grid)

    if self:hasUpgrade(3) and not target.isDead then
        self:knockBack(target, grid, rock.dCol, rock.dRow, BASIC_FLIGHT_PER_CELL)
    end

    if target.isDead then
        grid:killUnit(target)
        self:onKill(target)
    end
end

-- ============================================================
-- attack: override base melee. Enqueue a rock projectile (1 cell
-- flight by default; rolling 4/3 cells with upgrade 3) instead of
-- dealing instant damage.
-- ============================================================
function Mason:attack(target, grid)
    if not target or target.isDead then return end

    local dCol = sign(target.col - self.col)
    local dRow = sign(target.row - self.row)
    if dCol == 0 and dRow == 0 then return end

    local maxSteps
    if self:hasUpgrade(3) then
        local isDiagonal = (dCol ~= 0 and dRow ~= 0)
        maxSteps = isDiagonal and BASIC_TRAVEL_DIAGONAL or BASIC_TRAVEL_CARDINAL
    else
        maxSteps = 1
    end

    local rock = self:spawnRock(self.col, self.row, dCol, dRow, maxSteps, BASIC_FLIGHT_PER_CELL,
        function(r, g, c, ro) self:applyBasicRockPayload(r, g, c, ro) end)
    table.insert(self.rocks, rock)

    if self.hitSound then AudioManager.playSFX(self.hitSound) end
end

-- ============================================================
-- tickRock: advance one rock; apply payload to each cell as it's
-- crossed; queue break anim + return true when the rock finishes.
-- ============================================================
function Mason:tickRock(rock, dt, grid)
    rock.progress = rock.progress + (dt / rock.duration)
    rock.animTime = rock.animTime + dt
    if rock.progress > 1 then rock.progress = 1 end

    -- How many cells have we crossed? Cell `i` is reached when
    -- progress >= i / steps.
    while rock.nextStep <= rock.steps do
        local threshold = rock.nextStep / rock.steps
        if rock.progress >= threshold then
            local cellCol = rock.startCol + rock.dCol * rock.nextStep
            local cellRow = rock.startRow + rock.dRow * rock.nextStep
            if grid:isRock(cellCol, cellRow) then
                -- Terrain rock blocks the thrown rock — stop here, no damage.
                rock.progress = 1
                rock.endCol   = cellCol
                rock.endRow   = cellRow
                break
            end
            rock.payload(rock, grid, cellCol, cellRow)
            rock.nextStep = rock.nextStep + 1
        else
            break
        end
    end

    if rock.progress >= 1 then
        table.insert(self.breakAnims, {
            col   = rock.endCol,
            row   = rock.endRow,
            timer = BREAK_DURATION,
        })
        return true
    end
    return false
end

-- ============================================================
-- update: drive windup → action rock → basic rocks → break anims.
-- ============================================================
function Mason:update(dt, grid)
    -- Action rock
    if self.actionRock then
        if self:tickRock(self.actionRock, dt, grid) then
            self.actionRock = nil
        end
    end

    -- Basic-attack rocks
    for i = #self.rocks, 1, -1 do
        if self:tickRock(self.rocks[i], dt, grid) then
            table.remove(self.rocks, i)
        end
    end

    -- Restore tweenDuration on units we pushed once their slide ends. Without
    -- this, knockBack's rock-paced override would leak into the unit's
    -- subsequent normal moves (zoom across the board).
    for i = #self.pushedUnits, 1, -1 do
        local u = self.pushedUnits[i]
        if not u.isMoving then
            u.tweenDuration = 1 / (u.moveSpeed or 1)
            table.remove(self.pushedUnits, i)
        end
    end

    -- Break animations
    for i = #self.breakAnims, 1, -1 do
        local b = self.breakAnims[i]
        b.timer = b.timer - dt
        if b.timer <= 0 then
            table.remove(self.breakAnims, i)
        end
    end

    Mason.super.update(self, dt, grid)
end

-- ============================================================
-- drawRock: shared helper to render a rolling rock at its current
-- progress along its path.
-- ============================================================
local function rockScreenPos(rock)
    local startVR = Constants.toVisualRow(rock.startRow)
    local endVR   = Constants.toVisualRow(rock.endRow)
    local sx = Constants.GRID_OFFSET_X + (rock.startCol - 1) * Constants.CELL_SIZE + Constants.CELL_SIZE / 2
    local sy = Constants.GRID_OFFSET_Y + (startVR - 1)        * Constants.CELL_SIZE + Constants.CELL_SIZE / 2
    local ex = Constants.GRID_OFFSET_X + (rock.endCol - 1)   * Constants.CELL_SIZE + Constants.CELL_SIZE / 2
    local ey = Constants.GRID_OFFSET_Y + (endVR - 1)         * Constants.CELL_SIZE + Constants.CELL_SIZE / 2
    local t  = rock.progress
    return sx + (ex - sx) * t, sy + (ey - sy) * t
end

function Mason:drawRock(rock)
    local lg     = love.graphics
    local frames = self.sprites and self.sprites.rockFrames
    if not frames or #frames == 0 then return end

    local cx, cy   = rockScreenPos(rock)
    local frameIdx = math.floor(rock.animTime * ROCK_FPS) % #frames + 1
    local img      = frames[frameIdx]
    local sw, sh   = img:getWidth(), img:getHeight()
    local scale    = Constants.CELL_SIZE / 16

    lg.setColor(1, 1, 1, 1)
    lg.setShader(BaseUnit.getPaletteShader())
    lg.draw(img, cx, cy, 0, scale, scale, sw / 2, sh / 2)
    lg.setShader()
    lg.setColor(1, 1, 1, 1)
end

-- A rock that travels "up the screen" (toward the top of the visible board)
-- should render BEHIND Mason during the part of its arc that overlaps him.
-- We resolve direction in visual space so it works regardless of perspective.
local function rockGoesNorthVisual(rock)
    local startVR = Constants.toVisualRow(rock.startRow)
    local nextVR  = Constants.toVisualRow(rock.startRow + rock.dRow)
    return nextVR < startVR
end

-- ============================================================
-- drawAttackVisuals: rocks travelling DOWN the screen render in
-- front of units (drawn AFTER the unit sprite).
-- ============================================================
function Mason:drawAttackVisuals()
    Mason.super.drawAttackVisuals(self)

    if self.actionRock and not rockGoesNorthVisual(self.actionRock) then
        self:drawRock(self.actionRock)
    end
    for _, rock in ipairs(self.rocks) do
        if not rockGoesNorthVisual(rock) then
            self:drawRock(rock)
        end
    end
end

-- ============================================================
-- drawAttackVisualsBelow: rocks travelling UP the screen render
-- behind units (drawn BEFORE the unit sprite). Without this, a
-- rock thrown north visually covers Mason's head at launch.
-- ============================================================
function Mason:drawAttackVisualsBelow()
    Mason.super.drawAttackVisualsBelow(self)

    if self.actionRock and rockGoesNorthVisual(self.actionRock) then
        self:drawRock(self.actionRock)
    end
    for _, rock in ipairs(self.rocks) do
        if rockGoesNorthVisual(rock) then
            self:drawRock(rock)
        end
    end
end

-- ============================================================
-- drawGroundEffects: break animations rendered under any unit
-- standing on the impact cell.
-- ============================================================
function Mason:drawGroundEffects()
    local frames = self.sprites and self.sprites.rockBreakFrames
    if not frames or #frames == 0 then return end

    local lg = love.graphics
    for _, b in ipairs(self.breakAnims) do
        local visualRow = Constants.toVisualRow(b.row)
        local cx = Constants.GRID_OFFSET_X + (b.col - 1)   * Constants.CELL_SIZE + Constants.CELL_SIZE / 2
        local cy = Constants.GRID_OFFSET_Y + (visualRow - 1) * Constants.CELL_SIZE + Constants.CELL_SIZE / 2

        local elapsed  = BREAK_DURATION - b.timer
        local frameIdx = math.floor(elapsed * BREAK_FPS) + 1
        if frameIdx > #frames then frameIdx = #frames end
        local img      = frames[frameIdx]
        local sw, sh   = img:getWidth(), img:getHeight()
        local scale    = Constants.CELL_SIZE / 16

        lg.setColor(1, 1, 1, 1)
        lg.setShader(BaseUnit.getPaletteShader())
        lg.draw(img, cx, cy, 0, scale, scale, sw / 2, sh / 2)
        lg.setShader()
    end
    lg.setColor(1, 1, 1, 1)
end

-- ============================================================
-- resetCombatState: clear per-round rock + break + windup state.
-- ============================================================
function Mason:resetCombatState()
    Mason.super.resetCombatState(self)
    self.rocks       = {}
    self.actionRock  = nil
    self.breakAnims  = {}
    self.pushedUnits = {}
end

return Mason
