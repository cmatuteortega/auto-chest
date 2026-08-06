local BaseUnit = require('src.base_unit')

local Cart = BaseUnit:extend()

local WHIPLASH_DAMAGE = 1
local PLATING_HP_BONUS = 5

function Cart:new(row, col, owner, sprites)
    local stats = {
        health      = 14,
        maxHealth   = 14,
        damage      = 1,
        attackSpeed = 0.9,
        moveSpeed   = 2,
        attackRange = 0,
        unitType    = "cart"
    }

    Cart.super.new(self, row, col, owner, sprites, stats)

    self.hitSound = "soft-hit.mp3"

    -- Pothole tracking: enemies that have already been knocked back this round
    self.knockedBackAttackers = {}

    -- Whiplash cell-entry detection
    self.prevCol = col
    self.prevRow = row

    self.upgradeTree = {
        {
            name        = "Pothole",
            description = "First time each enemy melees Cart, knock them back 1 cell",
            onApply     = function(unit) end
        },
        {
            name        = "Whiplash",
            description = "Each cell Cart enters deals 1 damage to adjacent enemies",
            onApply     = function(unit) end
        },
        {
            name        = "Reinforced Plating",
            description = "+5 max HP",
            onApply     = function(unit)
                unit.maxHealth = unit.maxHealth + PLATING_HP_BONUS
                unit.health    = unit.health    + PLATING_HP_BONUS
            end
        },
    }
end

-- ============================================================
-- takeDamage: Pothole upgrade — knock back the FIRST melee enemy
-- to hit Cart this round, once per attacker. Ranged hits and AoE
-- pass attacker == nil and never trigger knockback.
-- ============================================================
function Cart:takeDamage(amount, attacker, grid)
    if self:hasUpgrade(1)
       and attacker
       and grid
       and not attacker.isDead
       and attacker.owner ~= self.owner
       and not self.knockedBackAttackers[attacker]
    then
        local colDiff = math.abs(attacker.col - self.col)
        local rowDiff = math.abs(attacker.row - self.row)
        if colDiff <= 1 and rowDiff <= 1 and (colDiff + rowDiff) > 0 then
            self.knockedBackAttackers[attacker] = true
            self:knockBackAttacker(attacker, grid)
        end
    end

    Cart.super.takeDamage(self, amount, attacker, grid)
end

-- ============================================================
-- knockBackAttacker: shove the attacker 1 cell directly away from Cart
-- along the line of approach. Owner-agnostic — works whether the
-- attacker is in front of, behind, or beside Cart. Skips if the
-- destination is occupied or off-board.
-- ============================================================
local function sign(n) return (n > 0 and 1) or (n < 0 and -1) or 0 end

function Cart:knockBackAttacker(attacker, grid)
    local kCol = sign(attacker.col - self.col)
    local kRow = sign(attacker.row - self.row)
    if kCol == 0 and kRow == 0 then return end

    local destCol = attacker.col + kCol
    local destRow = attacker.row + kRow
    if destRow < 1 or destRow > grid.rows then return end
    if destCol < 1 or destCol > grid.cols then return end

    local destCell = grid:getCell(destCol, destRow)
    if not destCell or destCell.occupied then return end

    grid:removeUnit(attacker.col, attacker.row)
    attacker.col = destCol
    attacker.row = destRow
    grid:placeUnit(destCol, destRow, attacker)
end

-- ============================================================
-- update: Whiplash upgrade — when Cart enters a new cell, deal 1
-- damage to enemies in the 4 cardinally-adjacent cells.
-- ============================================================
function Cart:update(dt, grid)
    Cart.super.update(self, dt, grid)

    if self:hasUpgrade(2) then
        if self.col ~= self.prevCol or self.row ~= self.prevRow then
            self:applyWhiplash(grid)
        end
    end

    self.prevCol = self.col
    self.prevRow = self.row
end

function Cart:applyWhiplash(grid)
    local cardinals = { {0, 1}, {0, -1}, {1, 0}, {-1, 0} }
    for _, d in ipairs(cardinals) do
        local cell = grid:getCell(self.col + d[1], self.row + d[2])
        -- Capture the unit: takeDamage can vacate the cell (e.g. Ninja dash)
        local victim = cell and cell.unit
        if victim and not victim.isDead and victim.owner ~= self.owner then
            victim:takeDamage(WHIPLASH_DAMAGE, self, grid)
            if victim.isDead then
                grid:killUnit(victim)
                self:onKill(victim)
            end
        end
    end
end

-- ============================================================
-- resetCombatState: clear per-round Pothole tracking and sync
-- Whiplash position trackers to the home cell.
-- ============================================================
function Cart:resetCombatState()
    Cart.super.resetCombatState(self)
    self.knockedBackAttackers = {}
    self.prevCol = self.col
    self.prevRow = self.row
end

return Cart
