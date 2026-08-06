local BaseUnit = require('src.base_unit')

local Tomb = BaseUnit:extend()

function Tomb:new(row, col, owner, sprites)
    local stats = {
        health = 15,
        maxHealth = 15,
        damage = 0,
        attackSpeed = 0,
        moveSpeed = 0,
        attackRange = 0,
        unitType = "tomb"
    }

    Tomb.super.new(self, row, col, owner, sprites, stats)

    -- Per-round state
    -- corpsePositions: set of "col,row" strings for cells that held a corpse
    -- We populate this each frame by scanning grid.corpses.
    self.corpsePositions   = {}
    -- Track which units have already received the burst heal for a given corpse key
    -- healedUnits[unitRef][corpseKey] = true
    self.healedUnits       = {}

    self.upgradeTree = {
        -- Upgrade 1: Overtime regen while standing on a corpse cell
        {
            name = "Rot",
            description = "Friendly units also regen 1 HP/s while on a corpse cell",
            onApply = function(unit) end
        },
        -- Upgrade 2: On Tomb death, grant friendly units +25% ATK SPD for 4s
        {
            name = "Martyrdom",
            description = "On death, friendly units gain +25% ATK SPD for 4s",
            onApply = function(unit) end
        },
        -- Upgrade 3: +5 base HP
        {
            name = "Reinforced",
            description = "+5 base HP",
            onApply = function(unit)
                -- upgrade() recalculates stats and heals to full right after onApply
                unit.baseHealth = unit.baseHealth + 5
            end
        }
    }
end

-- Martyrdom: apply ally ATK SPD buff synchronously while the dying Tomb is still on the grid.
function Tomb:onDeath(grid)
    if not self:hasUpgrade(2) then return end
    for _, u in ipairs(grid:getAllUnits()) do
        if u.owner == self.owner and not u.isDead and u ~= self then
            u.tombMartyrdombuffTimer = 4.0
            u:triggerBuffAnim()
        end
    end
end

function Tomb:update(dt, grid)
    -- Run base animation state (hit-anim, attack-anim) without combat AI.
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

    local allUnits = grid:getAllUnits()

    -- Step 1: Rebuild corpse position set from grid.corpses (fallen units, in death order).
    self.corpsePositions = {}
    for _, u in ipairs(grid.corpses) do
        local key = u.col .. "," .. u.row
        self.corpsePositions[key] = true
    end

    -- Step 2: Heal friendly units standing on a corpse cell.
    for _, u in ipairs(allUnits) do
        if u.owner == self.owner and not u.isDead and u ~= self then
            local key = u.col .. "," .. u.row
            if self.corpsePositions[key] then
                -- Burst heal: once per unit per corpse position
                if not self.healedUnits[u] then
                    self.healedUnits[u] = {}
                end
                if not self.healedUnits[u][key] then
                    self.healedUnits[u][key] = true
                    u.health = math.min(u.health + 2, u.maxHealth)
                    u:triggerBuffAnim()
                end
                -- Upgrade 1 (Rot): 1 HP/s while standing on a corpse cell
                if self:hasUpgrade(1) then
                    u.tombRegenAccum = (u.tombRegenAccum or 0) + dt
                    if u.tombRegenAccum >= 1.0 then
                        u.tombRegenAccum = u.tombRegenAccum - 1.0
                        u.health = math.min(u.health + 1, u.maxHealth)
                        u:triggerBuffAnim()
                    end
                end
            else
                -- Not on a corpse cell; reset regen accumulator
                u.tombRegenAccum = 0
            end
        end
    end
end

function Tomb:resetCombatState()
    Tomb.super.resetCombatState(self)
    self.corpsePositions  = {}
    self.healedUnits      = {}
end

return Tomb
