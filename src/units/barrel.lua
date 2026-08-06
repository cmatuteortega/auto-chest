local BaseUnit = require('src.base_unit')

local Barrel = BaseUnit:extend()

local CRASH_DURATION = 0.6
local CRASH_DAMAGE   = 3

function Barrel:new(row, col, owner, sprites)
    local stats = {
        health      = 8,
        maxHealth   = 8,
        damage      = 1,
        attackSpeed = 0.65,
        moveSpeed   = 1,
        attackRange = 0,
        unitType    = "barrel"
    }

    Barrel.super.new(self, row, col, owner, sprites, stats)

    self.hitSound = "bite.mp3"

    -- ACTION move identification
    self.isActionUnit   = true
    self.actionDuration = CRASH_DURATION

    -- Sprite swap: pre-crash (barrel) and post-crash (free goblin)
    self.barrelSprites = sprites
    self.freeSprites   = sprites and sprites.freeForm

    -- Per-round crash state
    self.isRolling     = false
    self.rollTimer     = 0
    self.crashPending  = false
    self.crashTarget   = nil
    self.hasCrashed    = false

    self.upgradeTree = {
        {
            name        = "Concussion Crash",
            description = "Crash stuns the hit enemy for 1.5s",
            onApply     = function(unit) end
        },
        {
            name        = "Splinter Shot",
            description = "Crash also deals 1 damage to enemies in cardinally-adjacent cells",
            onApply     = function(unit) end
        },
        {
            name        = "Berserker Goblin",
            description = "If no enemy was hit by the crash, gain +50% attack speed",
            onApply     = function(unit) end
        },
    }
end

-- ============================================================
-- findCrashDest: scan forward until blocked by any unit (enemy
-- or friendly) or until off the board. Returns the destination
-- column/row plus the blocking unit (nil if reached end of board).
-- ============================================================
function Barrel:findCrashDest(grid)
    local dirRow  = (self.owner == 1) and -1 or 1
    local destCol = self.col
    local destRow = self.row
    local hitUnit = nil

    local i = 1
    while true do
        local checkRow = self.row + dirRow * i
        if checkRow < 1 or checkRow > grid.rows then
            break
        end
        local cell = grid:getCell(destCol, checkRow)
        if cell and cell.unit and not cell.unit.isDead then
            hitUnit = cell.unit
            break
        elseif grid:isRock(destCol, checkRow) then
            break  -- rock blocks the roll — stop before it, no hit unit
        else
            destRow = checkRow
        end
        i = i + 1
    end

    return destCol, destRow, hitUnit
end

-- ============================================================
-- onBattleStart: tween the barrel forward and set up the crash
-- payload to fire when the roll completes.
-- ============================================================
function Barrel:onBattleStart(grid)
    local destCol, destRow, hitUnit = self:findCrashDest(grid)

    self.crashTarget = hitUnit

    if destCol == self.col and destRow == self.row then
        -- No movement possible — crash next update tick at current position
        self.crashPending = true
        return
    end

    self.startCol      = self.col
    self.startRow      = self.row
    self.targetCol     = destCol
    self.targetRow     = destRow
    self.tweenProgress = 0
    self.tweenDuration = CRASH_DURATION
    self.isMoving      = true

    grid:removeUnit(self.col, self.row)
    self.col = destCol
    self.row = destRow
    grid:placeUnit(destCol, destRow, self)

    self.isRolling = true
    self.rollTimer = 0
end

-- ============================================================
-- doCrash: apply crash payload, swap sprite, optionally buff.
-- ============================================================
function Barrel:doCrash(grid)
    self.hasCrashed = true
    if self.freeSprites then
        self.sprites = self.freeSprites
    end

    local target = self.crashTarget
    local enemyHit = target and target.owner ~= self.owner and not target.isDead

    if enemyHit then
        target:takeDamage(CRASH_DAMAGE, self, grid)
        if self:hasUpgrade(1) then
            target.stunTimer = math.max(target.stunTimer, 1.5)
        end
        if target.isDead then
            grid:killUnit(target)
            self:onKill(target)
        end
    end

    -- Splinter Shot: 1 damage to cardinally-adjacent enemies of the crash point
    if self:hasUpgrade(2) then
        local cardinals = { {0, 1}, {0, -1}, {1, 0}, {-1, 0} }
        for _, d in ipairs(cardinals) do
            local cell = grid:getCell(self.col + d[1], self.row + d[2])
            -- Capture the unit: takeDamage can vacate the cell (e.g. Ninja dash)
            local victim = cell and cell.unit
            if victim and not victim.isDead and victim.owner ~= self.owner then
                victim:takeDamage(1, self, grid)
                if victim.isDead then
                    grid:killUnit(victim)
                    self:onKill(victim)
                end
            end
        end
    end

    -- Berserker Goblin: +50% attack speed if no enemy was hit by the crash
    if self:hasUpgrade(3) and not enemyHit then
        self.attackSpeed = self.attackSpeed * 1.5
        self:triggerBuffAnim()
    end

    self.crashTarget = nil
end

-- ============================================================
-- update: drive the roll tween, then resolve the crash. After
-- crashing, fall through to normal melee combat.
-- ============================================================
function Barrel:update(dt, grid)
    if self.crashPending then
        self.crashPending = false
        self:doCrash(grid)
    end

    if self.isRolling then
        self.rollTimer     = self.rollTimer + dt
        self.tweenProgress = math.min(self.rollTimer / CRASH_DURATION, 1)

        if self.rollTimer >= CRASH_DURATION then
            self.isRolling     = false
            self.isMoving      = false
            self.tweenProgress = 1
            -- Restore standard per-cell tween duration so post-crash movement
            -- matches the rest of the units (we overrode it for the roll).
            self.tweenDuration = 1 / self.moveSpeed
            self:doCrash(grid)
        end

        return  -- skip combat AI while rolling
    end

    Barrel.super.update(self, dt, grid)
end

-- ============================================================
-- resetCombatState: restore the intact barrel sprite and clear
-- per-round crash state so the action plays again next round.
-- ============================================================
function Barrel:resetCombatState()
    Barrel.super.resetCombatState(self)
    self.isRolling    = false
    self.rollTimer    = 0
    self.crashPending = false
    self.crashTarget  = nil
    self.hasCrashed   = false
    self.attackSpeed  = self.baseAttackSpeed
    self.tweenDuration = 1 / self.moveSpeed
    if self.barrelSprites then
        self.sprites = self.barrelSprites
    end
end

return Barrel
