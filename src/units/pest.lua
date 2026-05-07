local BaseUnitRanged = require('src.base_unit_ranged')

local Pest = BaseUnitRanged:extend()

function Pest:new(row, col, owner, sprites)
    local stats = {
        health          = 8,
        maxHealth       = 8,
        damage          = 1,
        attackSpeed     = 0.7,
        moveSpeed       = 1,
        attackRange     = 3,
        projectileSpeed = 12,
        unitType        = "pest"
    }

    Pest.super.new(self, row, col, owner, sprites, stats)

    self.currentTarget = nil

    self.upgradeTree = {
        {
            name = "Plague Spread",
            description = "Slow also applies to one adjacent enemy of the target",
            onApply = function(unit) end
        },
        {
            name = "Crippling Bite",
            description = "Slow strength increased to 60%",
            onApply = function(unit) end
        },
        {
            name = "Plague Carrier",
            description = "+1 damage to slowed targets",
            onApply = function(unit) end
        }
    }
end

-- ============================================================
-- Upgrade 3: Plague Carrier — +1 damage to already-slowed targets.
-- self.currentTarget is set in attack() before createProjectile.
-- ============================================================
function Pest:getDamage(grid)
    local dmg = self.damage

    if self:hasUpgrade(3) and self.currentTarget and not self.currentTarget.isDead then
        if self.currentTarget.slowTimer and self.currentTarget.slowTimer > 0 then
            dmg = dmg + 1
        end
    end

    return math.floor(dmg * (self.royalCommandBonus or 1))
end

function Pest:attack(target, grid)
    if not target or target.isDead then return end
    self.currentTarget = target
    BaseUnitRanged.attack(self, target, grid)
    self.currentTarget = nil
end

-- ============================================================
-- Upgrade 1: Plague Spread — find one enemy adjacent (Manhattan=1)
-- to the primary target. Deterministic tie-break: lowest col, then
-- lowest row (matches engine-wide ordering convention).
-- ============================================================
function Pest:findAdjacentEnemy(target, grid)
    local best = nil
    for _, u in ipairs(grid:getAllUnits()) do
        if u.owner ~= self.owner and not u.isDead and u ~= target then
            local d = math.abs(u.col - target.col) + math.abs(u.row - target.row)
            if d == 1 then
                if not best
                   or u.col < best.col
                   or (u.col == best.col and u.row < best.row) then
                    best = u
                end
            end
        end
    end
    return best
end

-- ============================================================
-- Festering Bite passive: every basic-attack hit slows the target's
-- attack speed and movement by 40% (60% with Crippling Bite) for 2s.
-- Refreshes on re-hit. Plague Spread also slows one adjacent enemy.
-- ============================================================
function Pest:onProjectileHit(projectile, grid)
    if projectile.target and not projectile.target.isDead then
        local duration = 2.0
        local mult     = self:hasUpgrade(2) and 0.4 or 0.6  -- 1 - strength
        projectile.target:applySlow(duration, mult, mult)

        if self:hasUpgrade(1) then
            local splash = self:findAdjacentEnemy(projectile.target, grid)
            if splash then
                splash:applySlow(duration, mult, mult)
            end
        end
    end

    BaseUnitRanged.onProjectileHit(self, projectile, grid)
end

function Pest:resetCombatState()
    Pest.super.resetCombatState(self)
    self.currentTarget = nil
end

return Pest
