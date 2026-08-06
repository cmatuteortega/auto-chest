local BaseUnit    = require('src.base_unit')
local Constants   = require('src.constants')
local AudioManager = require('src.audio_manager')

local Effigy = BaseUnit:extend()

local WARD_RADIUS          = 1
local WARD_RADIUS_EXPANDED = 2
local FUNERAL_PYRE_DAMAGE  = 4
local FUNERAL_PYRE_RADIUS  = 2

function Effigy:new(row, col, owner, sprites)
    local stats = {
        health      = 22,
        maxHealth   = 22,
        damage      = 0,
        attackSpeed = 0,
        moveSpeed   = 0,
        attackRange = 0,
        unitType    = "effigy"
    }

    Effigy.super.new(self, row, col, owner, sprites, stats)

    self.shieldedAllies = {}

    self.upgradeTree = {
        {
            name        = "Shared Burden",
            description = "Absorbed damage is reduced by 30% (Effigy takes 70% of each redirected hit)",
            onApply     = function(unit) end
        },
        {
            name        = "Funeral Pyre",
            description = "On death, deals 4 AoE damage to all enemies within 2 cells",
            onApply     = function(unit) end
        },
        {
            name        = "Unbreakable Ward",
            description = "+8 max HP and ward radius expands to 2 cells",
            onApply     = function(unit)
                -- upgrade() recalculates stats and heals to full right after onApply
                unit.baseHealth = unit.baseHealth + 8
            end
        },
    }
end

function Effigy:_wardRadius()
    return self:hasUpgrade(3) and WARD_RADIUS_EXPANDED or WARD_RADIUS
end

function Effigy:_updateShieldedAllies(grid)
    -- Clear old shield references
    for _, ally in ipairs(self.shieldedAllies) do
        if ally.shieldedBy == self then
            ally.shieldedBy = nil
        end
    end
    self.shieldedAllies = {}

    if self.isDead then return end

    local radius = self:_wardRadius()
    for _, unit in ipairs(grid:getAllUnits()) do
        if unit.owner == self.owner
            and unit ~= self
            and not unit.isDead
            and unit.unitType ~= "effigy"   -- prevent Effigy↔Effigy redirect loops
        then
            local dx = math.abs(unit.col - self.col)
            local dy = math.abs(unit.row - self.row)
            if dx <= radius and dy <= radius then
                unit.shieldedBy = self
                table.insert(self.shieldedAllies, unit)
            end
        end
    end
end

function Effigy:onBattleStart(grid)
    -- Clear stale references from the previous round
    for _, ally in ipairs(self.shieldedAllies) do
        if ally.shieldedBy == self then
            ally.shieldedBy = nil
        end
    end
    self.shieldedAllies = {}
    self:_updateShieldedAllies(grid)
end

function Effigy:update(dt, grid)
    -- Advance hit animation (no combat AI for immobile structure)
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

    self:_updateShieldedAllies(grid)
end

function Effigy:takeDamage(amount, attacker, grid)
    -- Upgrade 1 (Shared Burden): reduce redirected damage by 30%
    if self:hasUpgrade(1) then
        amount = math.max(1, math.floor(amount * 0.7))
    end
    Effigy.super.takeDamage(self, amount, attacker, grid)
    -- When damage is redirected from an ally, attack() checks isDead on the ally
    -- (not Effigy), so killUnit would never be called for us. Self-trigger it so
    -- the death animation plays and the grid cell is freed correctly.
    if self.isDead and grid then
        grid:killUnit(self)
    end
end

function Effigy:onDeath(grid)
    if not self:hasUpgrade(2) then return end
    -- Funeral Pyre: burst damage to nearby enemies
    for _, unit in ipairs(grid:getAllUnits()) do
        if unit.owner ~= self.owner and not unit.isDead then
            local dx   = unit.col - self.col
            local dy   = unit.row - self.row
            local dist = math.sqrt(dx * dx + dy * dy)
            if dist <= FUNERAL_PYRE_RADIUS then
                unit:takeDamage(FUNERAL_PYRE_DAMAGE, self, grid)
                if unit.isDead then
                    grid:killUnit(unit)
                end
            end
        end
    end
    AudioManager.playSFX("fireball.mp3")
end

function Effigy:resetCombatState()
    -- Release shielded allies before the base reset clears isDead/state
    for _, ally in ipairs(self.shieldedAllies) do
        if ally.shieldedBy == self then
            ally.shieldedBy = nil
        end
    end
    self.shieldedAllies = {}
    Effigy.super.resetCombatState(self)
end

return Effigy
