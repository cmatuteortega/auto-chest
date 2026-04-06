local BaseUnitRanged = require('src.base_unit_ranged')
local Constants      = require('src.constants')

local Marrow = BaseUnitRanged:extend()

function Marrow:new(row, col, owner, sprites)
    -- Marrow stats: ranged archer
    local stats = {
        health = 9,
        maxHealth = 9,
        damage = 1,
        attackSpeed = 1.05,      -- 1 attack per second
        moveSpeed = 1,        -- 1 cell per second
        attackRange = 3,      -- 3 cells range
        projectileSpeed = 0.2, -- Arrow flight time
        unitType = "marrow"
    }

    Marrow.super.new(self, row, col, owner, sprites, stats)

    -- Lance passive (fires at battle start)
    self.isActionUnit      = true
    self.actionDuration    = 0.6
    self.idleFrameDuration = 0.18  -- 4 frames × 0.18s = 0.72s cycle, matches boney's 3 × 0.24s
    self.lance          = nil

    -- Track damage boost timer for upgrade 2
    self.damageBoostTimer = 0

    -- Define upgrade tree (3 upgrades, can choose 2)
    self.upgradeTree = {
        -- Upgrade 1: +1 range
        {
            name = "Extended Range",
            description = "+1 attack range",
            onApply = function(unit)
                unit.attackRange = unit.attackRange + 1
            end
        },
        -- Upgrade 2: 2s damage boost on kill
        {
            name = "Momentum",
            description = "+50% damage for 2s after kill",
            onApply = function(unit)
                -- No immediate effect, handled in update() and getDamage()
            end
        },
        -- Upgrade 3: Multi-shot
        {
            name = "Volley",
            description = "Shoot two enemies within range",
            onApply = function(unit)
                -- No immediate effect, handled in attack()
            end
        }
    }
end

-- Lance passive: scan enemies in column, closest first
function Marrow:findColumnTargets(grid)
    local targets = {}
    local dir = (self.owner == 1) and -1 or 1
    local r   = self.row + dir
    while r >= 1 and r <= Constants.GRID_ROWS do
        local cell = grid:getCell(self.col, r)
        if cell and cell.unit and not cell.unit.isDead and cell.unit.owner ~= self.owner then
            table.insert(targets, cell.unit)
        end
        r = r + dir
    end
    return targets
end

function Marrow:onBattleStart(grid)
    local endRow = (self.owner == 1) and 1 or Constants.GRID_ROWS
    -- Store lance params; lance fires when windup animation completes
    self.pendingLance = {
        duration = self.actionDuration,
        startCol = self.col,
        startRow = self.row,
        endRow   = endRow,
        targets  = self:findColumnTargets(grid),
        damage   = 5,
    }
    self.lance              = nil
    self.actionAnimPlaying  = true
    self.actionAnimProgress = 0
    self.actionAnimDone     = false
end

-- Override getDamage to apply damage boost from upgrade 2
function Marrow:getDamage(grid)
    local mult = self.royalCommandBonus or 1
    if self:hasUpgrade(2) and self.damageBoostTimer > 0 then
        return math.floor(self.damage * 1.5 * mult)
    end
    return math.floor(self.damage * mult)
end

-- Override update to handle lance phase then normal combat
function Marrow:update(dt, grid)
    -- Windup animation; fires lance when complete
    if self.actionAnimPlaying and not self.actionAnimDone then
        self.actionAnimProgress = math.min(1, self.actionAnimProgress + dt / self.actionDuration)
        if self.actionAnimProgress >= 1 then
            self.actionAnimDone    = true
            self.actionAnimPlaying = false
            if self.pendingLance then
                local p = self.pendingLance
                self.lance = {
                    progress = 0,
                    duration = p.duration,
                    startCol = p.startCol,
                    startRow = p.startRow,
                    endRow   = p.endRow,
                    targets  = p.targets,
                    hitIndex = 1,
                    damage   = p.damage,
                    done     = false,
                }
                self.pendingLance = nil
            end
        end
        return  -- skip normal combat AI during windup
    end

    -- Lance travel and hit resolution
    if self.lance and not self.lance.done then
        local lance = self.lance
        lance.progress = lance.progress + (dt / lance.duration)

        local totalRows = math.abs(lance.endRow - lance.startRow)
        while lance.hitIndex <= #lance.targets do
            local target      = lance.targets[lance.hitIndex]
            local targetDist  = math.abs(target.row - lance.startRow)
            local hitProgress = (totalRows > 0) and (targetDist / totalRows) or 1

            if lance.progress < hitProgress then break end

            if not target.isDead then
                target:takeDamage(lance.damage)
                if target.isDead then
                    local cell = grid:getCell(target.col, target.row)
                    if cell then cell.occupied = false end
                    for _, u in ipairs(grid:getAllUnits()) do
                        if not u.isDead then u.path = nil end
                    end
                    self:onKill(target)
                end
            end

            -- No pierce: stop after first hit
            lance.done     = true
            lance.progress = 1
            break
        end

        if lance.progress >= 1 then lance.done = true end
        return  -- skip normal combat AI while lance is in flight
    end

    if self.damageBoostTimer > 0 then
        self.damageBoostTimer = self.damageBoostTimer - dt
    end

    Marrow.super.update(self, dt, grid)
end

function Marrow:onKill(target)
    -- Upgrade 2: 2s damage boost
    if self:hasUpgrade(2) then
        self.damageBoostTimer = 2
        self:triggerBuffAnim()
    end
end

function Marrow:resetCombatState()
    Marrow.super.resetCombatState(self)
    self.lance            = nil
    self.pendingLance     = nil
    self.damageBoostTimer = 0
end

-- Override attack for multi-shot (upgrade 3)
function Marrow:attack(target, grid)
    if target and not target.isDead then
        -- First projectile: always to the primary target
        local projectile = self:createProjectile(target, grid)
        table.insert(self.arrows, projectile)

        -- Upgrade 3: Second arrow to nearby enemy
        if self:hasUpgrade(3) then
            local secondTarget = self:findSecondTarget(grid, target)
            if secondTarget and not secondTarget.isDead then
                local projectile2 = self:createProjectile(secondTarget, grid)
                table.insert(self.arrows, projectile2)
            end
        end
    end
end

-- Draw lance visual (same as Clavicula)
function Marrow:drawAttackVisuals()
    Marrow.super.drawAttackVisuals(self)  -- draws arrows

    if not self.lance or self.lance.done then return end

    local lg    = love.graphics
    local lance = self.lance

    local startVR = Constants.toVisualRow(lance.startRow)
    local endVR   = Constants.toVisualRow(lance.endRow)
    local cx      = Constants.GRID_OFFSET_X + (lance.startCol - 1) * Constants.CELL_SIZE + Constants.CELL_SIZE / 2
    local startY  = Constants.GRID_OFFSET_Y + (startVR - 1) * Constants.CELL_SIZE + Constants.CELL_SIZE / 2
    local endY    = Constants.GRID_OFFSET_Y + (endVR   - 1) * Constants.CELL_SIZE + Constants.CELL_SIZE / 2
    local tipY    = startY + (endY - startY) * lance.progress

    local dir         = (startY > endY) and -1 or 1
    local lanceSprite = self.sprites and self.sprites.lance

    if lanceSprite then
        local sw    = lanceSprite:getWidth()
        local sh    = lanceSprite:getHeight()
        local angle = (dir == -1) and (-math.pi / 2) or (math.pi / 2)
        local scale = Constants.SCALE * 3

        lg.setColor(1, 1, 1, 1)
        lg.draw(lanceSprite, cx, tipY, angle, scale, scale, sw / 2, sh / 2)
    end

    lg.setColor(1, 1, 1, 1)
end

-- Helper function to find second target for multi-shot
function Marrow:findSecondTarget(grid, primaryTarget)
    local allUnits = grid:getAllUnits()
    local closest = nil
    local closestDist = math.huge

    for _, unit in ipairs(allUnits) do
        if unit.owner ~= self.owner and
           not unit.isDead and
           unit ~= primaryTarget and
           self:isInAttackRange(unit) then
            local dist = math.sqrt((unit.col - self.col)^2 + (unit.row - self.row)^2)
            if dist < closestDist then
                closest = unit
                closestDist = dist
            end
        end
    end

    return closest
end

return Marrow
