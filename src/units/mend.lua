local BaseUnitRanged = require('src.base_unit_ranged')

local Mend = BaseUnitRanged:extend()

-- ============================================================
-- Mend — Calcium Clan ranged healer (3 coins)
-- Passive (Mending Pulse): every 6 hits given or received,
-- heals the lowest HP ally (can be self) for 2 HP.
-- ============================================================

function Mend:new(row, col, owner, sprites)
    local stats = {
        health          = 8,
        maxHealth       = 8,
        damage          = 1,
        attackSpeed     = 0.8,
        moveSpeed       = 1,
        attackRange     = 3,
        projectileSpeed = 0.2,
        unitType        = "mend"
    }

    Mend.super.new(self, row, col, owner, sprites, stats)

    self.hitSound = "poof.mp3"

    -- Hit counter (given + received); triggers heal at 6
    self.hitCounter = 0

    -- Active attack-speed buffs applied to healed allies:
    -- each entry: { unit = u, timer = 2.0, baseSpeed = originalSpeed }
    self.healBuffs = {}

    self.upgradeTree = {
        {
            name        = "Mending Touch",
            description = "Heal amount increased to 3 HP",
            onApply     = function(unit) end
        },
        {
            name        = "Invigorating Pulse",
            description = "Healed ally gains +15% attack speed for 2s",
            onApply     = function(unit) end
        },
        {
            name        = "Double Dose",
            description = "Heal the two lowest HP allies",
            onApply     = function(unit) end
        }
    }
end

-- ── Energy bar display ────────────────────────────────────────
function Mend:getEnergy()
    return self.hitCounter, 6
end

-- ── Heal helper ───────────────────────────────────────────────
-- Finds the N lowest HP allies and heals each for healAmt.
-- Tie-break: lower col → lower row (deterministic).
local function sortedAlliesByHP(self, grid)
    local allies = {}
    for _, unit in ipairs(grid:getAllUnits()) do
        if unit.owner == self.owner and not unit.isDead then
            table.insert(allies, unit)
        end
    end
    table.sort(allies, function(a, b)
        local ra = a.health / a.maxHealth
        local rb = b.health / b.maxHealth
        if ra ~= rb then return ra < rb end
        if a.col ~= b.col then return a.col < b.col end
        return a.row < b.row
    end)
    return allies
end

function Mend:triggerHeal(grid)
    local healAmt = self:hasUpgrade(1) and 3 or 2
    local count   = self:hasUpgrade(3) and 2 or 1
    local allies  = sortedAlliesByHP(self, grid)

    for i = 1, math.min(count, #allies) do
        local target = allies[i]
        target.health = math.min(target.maxHealth, target.health + healAmt)

        -- Upgrade 2: +15% attack speed for 2s on healed unit
        if self:hasUpgrade(2) then
            -- Remove any existing buff on this unit first (no stacking)
            for j = #self.healBuffs, 1, -1 do
                if self.healBuffs[j].unit == target then
                    -- Revert before refreshing
                    target.attackSpeed = self.healBuffs[j].baseSpeed
                    table.remove(self.healBuffs, j)
                end
            end
            local base = target.attackSpeed
            target.attackSpeed = base * 1.15
            table.insert(self.healBuffs, { unit = target, timer = 2.0, baseSpeed = base })
        end
    end

    self:triggerBuffAnim()
end

-- ── Hit counter tracking ──────────────────────────────────────
function Mend:takeDamage(amount)
    Mend.super.takeDamage(self, amount)
    if not self.isDead then
        self.hitCounter = self.hitCounter + 1
        -- Note: grid not available here; heal deferred to attack() or update()
        -- Store pending flag, resolved in next attack or update tick
        if self.hitCounter >= 6 then
            self.hitCounter   = 0
            self.healPending  = true
        end
    end
end

function Mend:attack(target, grid)
    Mend.super.attack(self, target, grid)
    self.hitCounter = self.hitCounter + 1
    if self.hitCounter >= 6 then
        self.hitCounter = 0
        self:triggerHeal(grid)
    end
    -- Resolve a pending heal (triggered by takeDamage) now that we have grid
    if self.healPending then
        self.healPending = false
        self:triggerHeal(grid)
    end
end

-- ── Update ────────────────────────────────────────────────────
function Mend:update(dt, grid)
    -- Tick attack-speed buffs (Upgrade 2)
    for i = #self.healBuffs, 1, -1 do
        local buff = self.healBuffs[i]
        buff.timer = buff.timer - dt
        if buff.timer <= 0 or buff.unit.isDead then
            -- Revert speed only if the unit is still alive
            if not buff.unit.isDead then
                buff.unit.attackSpeed = buff.baseSpeed
            end
            table.remove(self.healBuffs, i)
        end
    end

    -- Resolve pending heal in update (fallback when no attack fires)
    if self.healPending and grid then
        self.healPending = false
        self:triggerHeal(grid)
    end

    Mend.super.update(self, dt, grid)
end

-- ── Reset ─────────────────────────────────────────────────────
function Mend:resetCombatState()
    Mend.super.resetCombatState(self)
    self.hitCounter  = 0
    self.healPending = false
    -- Revert any lingering speed buffs
    for _, buff in ipairs(self.healBuffs) do
        if not buff.unit.isDead then
            buff.unit.attackSpeed = buff.baseSpeed
        end
    end
    self.healBuffs = {}
end

return Mend
