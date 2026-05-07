local BaseUnit = require('src.base_unit')

local Loot = BaseUnit:extend()

function Loot:new(row, col, owner, sprites)
    local stats = {
        health      = 10,
        maxHealth   = 10,
        damage      = 0,
        attackSpeed = 0,
        moveSpeed   = 0,
        attackRange = 0,
        unitType    = "loot"
    }

    Loot.super.new(self, row, col, owner, sprites, stats)

    self.mimicTriggered = false
    self.pendingMimic   = false

    self.upgradeTree = {
        {
            name = "Reinforced Vault",
            description = "+6 max HP",
            onApply = function(unit)
                unit.baseHealth = unit.baseHealth + 6
                local multiplier = 1.3 ^ unit.level
                unit.maxHealth = math.floor(unit.baseHealth * multiplier)
                unit.health    = unit.maxHealth
            end
        },
        {
            name = "Greed",
            description = "Survival bonus +1 (3 coins); kill bonus to opponent +1 (2 coins)",
            onApply = function(unit) end
        },
        {
            name = "Mimic",
            description = "First time damaged: deal 4 damage and push adjacent enemies 1 cell",
            onApply = function(unit) end
        }
    }
end

-- Coin yield: read by game.lua at round-end. Bumps to 3/2 with Greed.
function Loot:getSurvivalBonus()
    return self:hasUpgrade(2) and 3 or 2
end

function Loot:getKillBonus()
    return self:hasUpgrade(2) and 2 or 1
end

-- Flag a mimic trigger; the actual AoE+push runs in update() where grid is available.
function Loot:takeDamage(amount, attacker, grid)
    Loot.super.takeDamage(self, amount, attacker, grid)
    if self:hasUpgrade(3) and not self.mimicTriggered and not self.isDead then
        self.pendingMimic = true
    end
end

-- Find adjacent (Manhattan=1) enemies, deal 4 damage, push 1 cell away from the chest.
-- Push skipped if destination is invalid or occupied; damage still applies.
function Loot:triggerMimic(grid)
    local allUnits = grid:getAllUnits()
    -- Collect first so we don't iterate while mutating cell positions
    local victims = {}
    for _, u in ipairs(allUnits) do
        if u.owner ~= self.owner and not u.isDead then
            local dc = u.col - self.col
            local dr = u.row - self.row
            if math.abs(dc) + math.abs(dr) == 1 then
                table.insert(victims, { unit = u, dc = dc, dr = dr })
            end
        end
    end

    for _, v in ipairs(victims) do
        local u  = v.unit
        local newCol = u.col + v.dc
        local newRow = u.row + v.dr

        if grid:isValidCell(newCol, newRow) then
            local cell = grid:getCell(newCol, newRow)
            if cell and not cell.occupied then
                -- Cancel any active tween cleanly
                if u.isMoving and u.targetCol and u.targetRow then
                    grid:freeReservation(u.targetCol, u.targetRow)
                end
                u.isMoving      = false
                u.tweenProgress = 1
                u.path          = nil

                grid:removeUnit(u.col, u.row)
                u.col       = newCol
                u.row       = newRow
                u.startCol  = newCol
                u.startRow  = newRow
                u.targetCol = nil
                u.targetRow = nil
                grid:placeUnit(newCol, newRow, u)
                u:invalidatePath()
            end
        end

        u:takeDamage(4)
        if u.isDead then
            grid:killUnit(u)
            self:onKill(u)
        end
    end
end

function Loot:update(dt, grid)
    -- Tick base animations (hit, attack-anim) without combat AI — structure pattern.
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

    if self.isDead then
        self.state = "dead"
        return
    end

    -- Mimic snap: triggered on first damage, runs once per round.
    if self.pendingMimic and not self.mimicTriggered then
        self.pendingMimic   = false
        self.mimicTriggered = true
        self:triggerMimic(grid)
        self:triggerBuffAnim()
    end
end

function Loot:resetCombatState()
    Loot.super.resetCombatState(self)
    self.mimicTriggered = false
    self.pendingMimic   = false
end

return Loot
