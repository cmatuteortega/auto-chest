local BaseUnit  = require('src.base_unit')
local Constants = require('src.constants')

local Hook = BaseUnit:extend()

local HOOK_THROW_SPEED = 6   -- cells/sec outgoing
local HOOK_DRAG_SPEED  = 5   -- cells/sec drag
local HIT_THRESHOLD = 9
local STRING_R, STRING_G, STRING_B = 195/255, 163/255, 138/255  -- #c3a38a

function Hook:new(row, col, owner, sprites)
    local stats = {
        health      = 14,
        maxHealth   = 14,
        damage      = 2,
        attackSpeed = 0.75,
        moveSpeed   = 1,
        attackRange = 0,
        unitType    = "hook"
    }
    Hook.super.new(self, row, col, owner, sprites, stats)

    self.hitSound = "soft-hit.mp3"

    self.hitCounter     = 0
    self.hookProjectile = nil
    self.draggedUnit    = nil
    self.pushedUnits    = {}

    self.upgradeTree = {
        {
            name        = "Snare",
            description = "Dragged unit is stunned for 1.5s on arrival",
            onApply     = function(unit) end,
        },
        {
            name        = "Slam",
            description = "Arrival slams the landing cell, dealing damage to adjacent enemies",
            onApply     = function(unit) end,
        },
        {
            name        = "Eager Hook",
            description = "Hook charges in 6 hits instead of 9",
            onApply     = function(unit) end,
        },
    }
end

function Hook:getEnergy()
    local threshold = self:hasUpgrade(3) and 6 or HIT_THRESHOLD
    return self.hitCounter, threshold
end

function Hook:resetCombatState()
    Hook.super.resetCombatState(self)
    self.hitCounter     = 0
    self.hookProjectile = nil
    self.draggedUnit    = nil
    self.pushedUnits    = {}
end

-- ============================================================
-- Farthest-enemy search (deterministic tie-break)
-- ============================================================
function Hook:findFarthestEnemy(grid)
    local allUnits = grid:getAllUnits()
    local farthest = nil
    local maxDist  = -1

    for _, unit in ipairs(allUnits) do
        if unit.owner ~= self.owner and not unit.isDead then
            local dist    = math.sqrt((unit.col - self.col)^2 + (unit.row - self.row)^2)
            local isBetter = dist > maxDist
            if dist == maxDist and farthest then
                isBetter = (unit.col > farthest.col)
                    or (unit.col == farthest.col and unit.row > farthest.row)
                    or (unit.col == farthest.col and unit.row == farthest.row
                        and unit.owner > farthest.owner)
            end
            if isBetter then
                maxDist  = dist
                farthest = unit
            end
        end
    end

    return farthest
end

-- ============================================================
-- Nearest free cell to Hook (excluding Hook's own cell)
-- ============================================================
function Hook:findDragDest(grid)
    local candidates = {}

    for dc = -2, 2 do
        for dr = -2, 2 do
            if dc ~= 0 or dr ~= 0 then
                local tc = self.col + dc
                local tr = self.row + dr
                if grid:isValidCell(tc, tr) then
                    local cell = grid:getCell(tc, tr)
                    if not cell.occupied and not cell.reserved then
                        local distToHook = math.sqrt(dc * dc + dr * dr)
                        table.insert(candidates, { col = tc, row = tr, dist = distToHook })
                    end
                end
            end
        end
    end

    if #candidates == 0 then return nil, nil end

    table.sort(candidates, function(a, b)
        if a.dist ~= b.dist then return a.dist < b.dist end
        if a.col  ~= b.col  then return a.col  < b.col  end
        return a.row < b.row
    end)

    return candidates[1].col, candidates[1].row
end

-- ============================================================
-- Launch the hook projectile
-- ============================================================
function Hook:throwHook(target, grid)
    local dCol = target.col - self.col
    local dRow = target.row - self.row
    local dist = math.sqrt(dCol * dCol + dRow * dRow)
    if dist == 0 then return end

    self.hookProjectile = {
        phase     = "outgoing",
        startCol  = self.col,
        startRow  = self.row,
        targetCol = target.col,
        targetRow = target.row,
        progress  = 0,
        duration  = dist / HOOK_THROW_SPEED,
        target    = target,
    }
end

-- ============================================================
-- Hook arrives at target — begin drag
-- ============================================================
function Hook:onHookGrab(grid)
    local proj   = self.hookProjectile
    local target = proj.target

    if not target or target.isDead then
        self.hookProjectile = nil
        return
    end

    local destCol, destRow = self:findDragDest(grid)
    if not destCol then
        self.hookProjectile = nil
        return
    end

    -- Cancel any in-flight tween on the target so we can re-use the fields
    if target.isMoving then
        if target.targetCol and target.targetRow then
            grid:freeReservation(target.targetCol, target.targetRow)
        end
        target.isMoving      = false
        target.tweenProgress = 0
        target.path          = nil
    end

    -- Compute drag duration proportional to travel distance
    local dc      = destCol - target.col
    local dr      = destRow - target.row
    local dragDist = math.sqrt(dc * dc + dr * dr)
    local dragDur  = math.max(0.25, dragDist / HOOK_DRAG_SPEED)

    -- Reserve destination and start tween (same pattern as Mason:knockBack)
    grid:reserveCell(destCol, destRow)
    target.startCol      = target.col
    target.startRow      = target.row
    target.targetCol     = destCol
    target.targetRow     = destRow
    target.tweenProgress = 0
    target.tweenDuration = dragDur
    target.isMoving      = true
    target.path          = { { col = destCol, row = destRow } }

    table.insert(self.pushedUnits, target)

    -- Switch to returning phase
    self.hookProjectile = {
        phase       = "returning",
        draggedUnit = target,
        destCol     = destCol,
        destRow     = destRow,
    }
    self.draggedUnit = target
end

-- ============================================================
-- Drag complete — apply upgrade effects, re-target
-- ============================================================
function Hook:onDragComplete(grid)
    local target = self.draggedUnit
    self.hookProjectile = nil
    self.draggedUnit    = nil

    if not target or target.isDead then return end

    local landCol = target.col
    local landRow = target.row

    -- Upgrade 1: Snare
    if self:hasUpgrade(1) then
        target.stunTimer = math.max(target.stunTimer, 1.5)
    end

    -- Upgrade 2: Slam — damage all enemies within Chebyshev 1 (excluding dragged unit)
    if self:hasUpgrade(2) then
        local dmg      = self:getDamage(grid)
        local allUnits = grid:getAllUnits()
        for _, unit in ipairs(allUnits) do
            if unit ~= target and unit.owner ~= self.owner and not unit.isDead then
                local dx = math.abs(unit.col - landCol)
                local dy = math.abs(unit.row - landRow)
                if dx <= 1 and dy <= 1 then
                    unit:takeDamage(dmg, self, grid)
                    if unit.isDead then
                        grid:killUnit(unit)
                        self:onKill(unit)
                    end
                end
            end
        end
    end

    -- Re-target the dragged unit
    self.target = target
    self:invalidatePath()
end

-- ============================================================
-- Hit-counter triggers
-- ============================================================
function Hook:checkHookTrigger(grid)
    if self.hookProjectile then return end
    local threshold = self:hasUpgrade(3) and 6 or HIT_THRESHOLD
    if self.hitCounter >= threshold then
        self.hitCounter = 0
        local farthest  = self:findFarthestEnemy(grid)
        if farthest then
            self:throwHook(farthest, grid)
        end
    end
end

function Hook:attack(target, grid)
    Hook.super.attack(self, target, grid)
    self.hitCounter = self.hitCounter + 1
    self:checkHookTrigger(grid)
end

function Hook:takeDamage(amount, attacker, grid)
    Hook.super.takeDamage(self, amount, attacker, grid)
    if not self.isDead then
        self.hitCounter = self.hitCounter + 1
        self:checkHookTrigger(grid)
    end
end

-- ============================================================
-- Update
-- ============================================================
function Hook:update(dt, grid)
    if self.hookProjectile then
        local proj = self.hookProjectile

        if proj.phase == "outgoing" then
            proj.progress = proj.progress + dt / proj.duration
            if proj.progress >= 1 then
                proj.progress = 1
                self:onHookGrab(grid)
            end

        elseif proj.phase == "returning" then
            local dragged = proj.draggedUnit
            if not dragged or not dragged.isMoving or dragged.isDead then
                self:onDragComplete(grid)
            end
        end
    end

    -- Restore normal tweenDuration for dragged units once their slide ends
    for i = #self.pushedUnits, 1, -1 do
        local u = self.pushedUnits[i]
        if not u.isMoving then
            u.tweenDuration = 1 / (u.moveSpeed or 1)
            table.remove(self.pushedUnits, i)
        end
    end

    Hook.super.update(self, dt, grid)
end

-- ============================================================
-- Draw — hook sprite + string
-- ============================================================
local function cellCenter(col, row)
    local vr = Constants.toVisualRow(row)
    local x  = Constants.GRID_OFFSET_X + (col - 1) * Constants.CELL_SIZE + Constants.CELL_SIZE / 2
    local y  = Constants.GRID_OFFSET_Y + (vr   - 1) * Constants.CELL_SIZE + Constants.CELL_SIZE / 2
    return x, y
end

function Hook:drawHookVisuals()
    local proj = self.hookProjectile
    if not proj then return end

    local lg    = love.graphics
    local hx, hy = cellCenter(self.col, self.row)
    local headX, headY

    if proj.phase == "outgoing" then
        local sx, sy = cellCenter(proj.startCol, proj.startRow)
        local ex, ey = cellCenter(proj.targetCol, proj.targetRow)
        headX = sx + (ex - sx) * proj.progress
        headY = sy + (ey - sy) * proj.progress

    elseif proj.phase == "returning" then
        local dragged = proj.draggedUnit
        if dragged and not dragged.isDead then
            local dx, dy = dragged:getDrawPos()
            headX = dx + Constants.CELL_SIZE / 2
            headY = dy + Constants.CELL_SIZE / 2
        end
    end

    if not headX then return end

    -- String
    lg.setColor(STRING_R, STRING_G, STRING_B, 1)
    lg.setLineWidth(3 * Constants.SCALE)
    lg.line(hx, hy, headX, headY)
    lg.setLineWidth(1)

    -- Hook head
    local hookSprite = self.sprites and self.sprites.hookSprite
    -- +π/2 so the sprite's top edge points toward the hook head
    local angle = math.atan2(headY - hy, headX - hx) + math.pi / 2
    if hookSprite then
        local sw, sh = hookSprite:getWidth(), hookSprite:getHeight()
        local scale  = math.floor(Constants.CELL_SIZE / 16)
        lg.setColor(1, 1, 1, 1)
        lg.setShader(BaseUnit.getPaletteShader())
        lg.draw(hookSprite, headX, headY, angle, scale, scale, sw / 2, sh / 2)
        lg.setShader()
    else
        lg.setColor(STRING_R, STRING_G, STRING_B, 1)
        lg.circle('fill', headX, headY, 4 * Constants.SCALE)
    end

    lg.setColor(1, 1, 1, 1)
end

function Hook:drawAttackVisuals()
    self:drawHookVisuals()
end

return Hook
