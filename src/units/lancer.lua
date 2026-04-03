local BaseUnitRanged = require('src.base_unit_ranged')
local Constants      = require('src.constants')

local Lancer = BaseUnitRanged:extend()

function Lancer:new(row, col, owner, sprites)
    local stats = {
        health          = 8,
        maxHealth       = 8,
        damage          = 2,
        attackSpeed     = 0.8,
        moveSpeed       = 1,
        attackRange     = 3,
        projectileSpeed = 0.2,
        unitType        = "lancer"
    }

    Lancer.super.new(self, row, col, owner, sprites, stats)

    -- ACTION move: lance fires at battle start
    self.isActionUnit   = true
    self.actionDuration = 0.6   -- seconds for lance to cross the board

    -- Lance projectile state (nil between rounds)
    self.lance          = nil

    -- Blood Rush (upgrade 3) timer
    self.bloodRushTimer = 0

    self.upgradeTree = {
        {
            name        = "Heavy Lance",
            description = "Lance deals 10 damage instead of 5",
            onApply     = function(unit) end
        },
        {
            name        = "Piercing Lance",
            description = "Lance pierces first enemy and hits second in column",
            onApply     = function(unit) end
        },
        {
            name        = "Blood Rush",
            description = "+25% attack speed for 3s after killing an enemy",
            onApply     = function(unit) end
        },
    }
end

-- Scan enemies in the Lancer's column in firing direction, closest first.
function Lancer:findColumnTargets(grid)
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

function Lancer:onBattleStart(grid)
    local endRow = (self.owner == 1) and 1 or Constants.GRID_ROWS
    self.lance = {
        progress = 0,
        duration = self.actionDuration,
        startCol = self.col,
        startRow = self.row,
        endRow   = endRow,
        targets  = self:findColumnTargets(grid),
        hitIndex = 1,
        damage   = self:hasUpgrade(1) and 10 or 5,
        done     = false,
    }
end

function Lancer:update(dt, grid)
    -- Phase 1: lance animation and hit resolution
    if self.lance and not self.lance.done then
        local lance = self.lance
        lance.progress = lance.progress + (dt / lance.duration)

        -- Apply damage at the proportional progress when the tip crosses each target's row
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

            if self:hasUpgrade(2) then
                lance.hitIndex = lance.hitIndex + 1
            else
                -- No pierce: stop after first hit
                lance.done     = true
                lance.progress = 1
                break
            end
        end

        if lance.progress >= 1 then lance.done = true end
        return  -- skip normal combat AI while lance is in flight
    end

    -- Phase 2: Blood Rush countdown
    if self.bloodRushTimer > 0 then
        self.bloodRushTimer = self.bloodRushTimer - dt
        if self.bloodRushTimer <= 0 then
            self.bloodRushTimer = 0
            self.attackSpeed    = self.baseAttackSpeed
        end
    end

    -- Phase 3: normal ranged combat
    -- self.arrows is handled entirely by BaseUnitRanged.update, so calling super is correct.
    Lancer.super.update(self, dt, grid)
end

function Lancer:onKill(target)
    if self:hasUpgrade(3) then
        self.bloodRushTimer = 3
        self.attackSpeed    = self.baseAttackSpeed * 1.25
        self:triggerBuffAnim()
    end
end

function Lancer:getDamage(grid)
    return math.floor(self.damage * (self.royalCommandBonus or 1))
end

function Lancer:resetCombatState()
    Lancer.super.resetCombatState(self)
    self.lance          = nil
    self.bloodRushTimer = 0
    self.attackSpeed    = self.baseAttackSpeed
end

-- Draw the bone-spear lance plus normal arrows.
function Lancer:drawAttackVisuals()
    Lancer.super.drawAttackVisuals(self)   -- draws self.arrows

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

return Lancer
