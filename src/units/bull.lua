local BaseUnit = require('src.base_unit')

local Bull = BaseUnit:extend()

function Bull:new(row, col, owner, sprites)
    local stats = {
        health      = 13,
        maxHealth   = 13,
        damage      = 2,
        attackSpeed = 0.65,
        moveSpeed   = 1,
        attackRange = 0,
        unitType    = "bull"
    }

    Bull.super.new(self, row, col, owner, sprites, stats)

    -- ACTION move identification
    self.isActionUnit   = true
    self.actionDuration = 0.5  -- charge animation takes 0.5s

    -- Per-round charge state
    self.isCharging      = false
    self.chargeTimer     = 0
    self.chargeDuration  = 0.5
    self.chargeEnemy     = nil
    self.ragingBullTimer = 0

    self.upgradeTree = {
        {
            name        = "Unstoppable",
            description = "Charge knocks the enemy to the tile behind them",
            onApply     = function(unit) end
        },
        {
            name        = "Raging Bull",
            description = "+30% ATK speed for 5s after charge ends",
            onApply     = function(unit) end
        },
        {
            name        = "Trampling Hooves",
            description = "Charge deals more damage and stuns 1s longer",
            onApply     = function(unit) end
        },
    }
end

-- ============================================================
-- findChargeDest: scan forward up to 4 tiles.
-- Returns (destCol, destRow, hitEnemy).
-- Stops before first enemy or friendly/dead unit; stops at wall.
-- ============================================================
function Bull:findChargeDest(grid)
    local dirRow  = (self.owner == 1) and -1 or 1
    local destCol = self.col
    local destRow = self.row
    local hitEnemy = nil

    for i = 1, 4 do
        local checkRow = self.row + dirRow * i
        if checkRow < 1 or checkRow > grid.rows then break end

        local cell = grid:getCell(destCol, checkRow)
        if cell then
            if cell.unit and not cell.unit.isDead and cell.unit.owner ~= self.owner then
                hitEnemy = cell.unit  -- stop before this enemy
                break
            elseif cell.unit then
                break  -- friendly (or dead) blocking — stop here
            else
                destRow = checkRow  -- empty — advance landing spot
            end
        end
    end

    return destCol, destRow, hitEnemy
end

-- ============================================================
-- onBattleStart: compute charge destination, update grid
-- position immediately, and set up the tween animation.
-- ============================================================
function Bull:onBattleStart(grid)
    local destCol, destRow, enemy = self:findChargeDest(grid)

    -- No movement possible (already at wall or blocked on first tile)
    if destCol == self.col and destRow == self.row then
        return
    end

    -- Set up tween animation using the existing draw system
    self.startCol      = self.col
    self.startRow      = self.row
    self.targetCol     = destCol
    self.targetRow     = destRow
    self.tweenProgress = 0
    self.tweenDuration = self.chargeDuration
    self.isMoving      = true

    -- Update logical grid position immediately so AI sees correct placement
    grid:removeUnit(self.col, self.row)
    self.col = destCol
    self.row = destRow
    grid:placeUnit(destCol, destRow, self)

    self.isCharging  = true
    self.chargeTimer = 0
    self.chargeEnemy = enemy
end

-- ============================================================
-- update: handle charge animation, then normal combat.
-- ============================================================
function Bull:update(dt, grid)
    if self.isCharging then
        self.chargeTimer   = self.chargeTimer + dt
        self.tweenProgress = math.min(self.chargeTimer / self.chargeDuration, 1)

        if self.chargeTimer >= self.chargeDuration then
            self.isCharging    = false
            self.isMoving      = false
            self.tweenProgress = 1

            local enemy = self.chargeEnemy
            if enemy and not enemy.isDead then
                -- Apply stun
                local stunDur = self:hasUpgrade(3) and 3 or 2
                enemy.stunTimer = stunDur

                -- Apply charge damage
                local chargeDmg = self:hasUpgrade(3)
                    and math.floor(self.damage * 2.5)
                    or  math.floor(self.damage * 1.5)
                enemy:takeDamage(chargeDmg)

                if enemy.isDead then
                    local cell = grid:getCell(enemy.col, enemy.row)
                    if cell then cell.occupied = false end
                    self:onKill(enemy)
                end

                -- Unstoppable: knock enemy to tile behind them
                if self:hasUpgrade(1) and not enemy.isDead then
                    local dirRow = (self.owner == 1) and -1 or 1
                    local kbRow  = enemy.row + dirRow
                    if kbRow >= 1 and kbRow <= grid.rows then
                        local kbCell = grid:getCell(enemy.col, kbRow)
                        if kbCell and not kbCell.occupied then
                            grid:removeUnit(enemy.col, enemy.row)
                            enemy.row = kbRow
                            grid:placeUnit(enemy.col, kbRow, enemy)
                        end
                    end
                end
            end

            -- Raging Bull: start attack speed buff
            if self:hasUpgrade(2) then
                self.ragingBullTimer = 5
            end
        end

        return  -- skip normal combat during charge
    end

    -- Raging Bull: manage attack speed buff
    if self:hasUpgrade(2) then
        if self.ragingBullTimer > 0 then
            self.ragingBullTimer = self.ragingBullTimer - dt
            self.attackSpeed = self.baseAttackSpeed * 1.3
            if self.ragingBullTimer <= 0 then
                self.attackSpeed = self.baseAttackSpeed
            end
        end
    end

    Bull.super.update(self, dt, grid)
end

-- ============================================================
-- attack: melee lunge + damage.
-- ============================================================
function Bull:attack(target, grid)
    if not target or target.isDead then return end

    self.attackAnimProgress = 0
    self.attackTargetCol    = target.col
    self.attackTargetRow    = target.row

    target:takeDamage(self:getDamage(grid))

    if target.isDead then
        local cell = grid:getCell(target.col, target.row)
        if cell then cell.occupied = false end
        self:onKill(target)
    end
end

-- ============================================================
-- resetCombatState: reset per-round charge state.
-- ============================================================
function Bull:resetCombatState()
    Bull.super.resetCombatState(self)
    self.isCharging      = false
    self.chargeTimer     = 0
    self.chargeEnemy     = nil
    self.ragingBullTimer = 0
    self.attackSpeed     = self.baseAttackSpeed
end

return Bull
