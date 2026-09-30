local BaseUnit       = require('src.base_unit')
local BaseUnitRanged = require('src.base_unit_ranged')
local Constants      = require('src.constants')

local Mend = BaseUnitRanged:extend()

-- ============================================================
-- Mend — Calcium Clan ranged healer (3 coins)
-- Passive 1 (Leech): each attack heals Mend for 1 HP.
-- Passive 2 (Energy 0/3): every 3 attacks given, Mend drains
--   3 HP from itself and heals the lowest HP ally for 3 HP.
-- Sap animation travels enemy → Mend on each attack.
-- Heal animation plays on every healed ally.
-- ============================================================

local HEAL_FPS       = 14   -- frames per second for heal overlay
local HEAL_FRAMES    = 21
local HEAL_DURATION  = HEAL_FRAMES / HEAL_FPS

function Mend:new(row, col, owner, sprites)
    local stats = {
        health          = 8,
        maxHealth       = 8,
        damage          = 1,
        attackSpeed     = 0.65,
        moveSpeed       = 1,
        attackRange     = 3,
        projectileSpeed = 12,
        unitType        = "mend"
    }

    Mend.super.new(self, row, col, owner, sprites, stats)

    self.hitSound = "poof.mp3"

    -- Energy counter: tracks attacks given; triggers at 3
    self.energyCounter = 0

    -- Active heal overlay animations: { unit, elapsed }
    self.healAnims = {}

    -- Active attack-speed buffs applied to healed allies (Upgrade 2):
    -- each entry: { unit = u, timer = 2.0, baseSpeed = originalSpeed }
    self.healBuffs = {}

    self.upgradeTree = {
        {
            name        = "Mending Touch",
            description = "Energy heal costs 2 HP from Mend instead of 3",
            onApply     = function(unit) end
        },
        {
            name        = "Invigorating Pulse",
            description = "Healed ally gains +15% attack speed for 2s",
            onApply     = function(unit) end
        },
        {
            name        = "Double Dose",
            description = "Costs 4 HP from Mend; heals two lowest HP allies for 2 HP each",
            onApply     = function(unit) end
        }
    }
end

-- ── Energy bar display ────────────────────────────────────────
function Mend:getEnergy()
    return self.energyCounter, 3
end

-- ── Ally sort helper ──────────────────────────────────────────
-- Returns allies sorted by lowest HP ratio; tie-break: col → row.
local function sortedAlliesByHP(self, grid)
    local allies = {}
    for _, unit in ipairs(grid:getAllUnits()) do
        if unit.owner == self.owner and unit ~= self and not unit.isDead then
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

-- ── Energy trigger: self-drain + ally heal ────────────────────
function Mend:triggerHeal(grid)
    local selfDrain, healAmt, count
    if self:hasUpgrade(3) then
        selfDrain, healAmt, count = 4, 2, 2
    else
        selfDrain = self:hasUpgrade(1) and 2 or 3
        healAmt, count = 3, 1
    end

    -- Direct self-drain (not via takeDamage to avoid re-triggering counter)
    self.health = self.health - selfDrain
    if self.health <= 0 then
        self.health = 0
        self.isDead = true
        grid:killUnit(self)
        return
    end

    local allies = sortedAlliesByHP(self, grid)
    for i = 1, math.min(count, #allies) do
        local target = allies[i]
        target.health = math.min(target.maxHealth, target.health + healAmt + (self.synergyHealBonus or 0))

        -- Heal animation on the ally
        table.insert(self.healAnims, { unit = target, elapsed = 0 })

        -- Upgrade 2: +15% attack speed for 2s (no stacking)
        if self:hasUpgrade(2) then
            for j = #self.healBuffs, 1, -1 do
                if self.healBuffs[j].unit == target then
                    target.attackSpeed = self.healBuffs[j].baseSpeed
                    table.remove(self.healBuffs, j)
                end
            end
            local base = target.attackSpeed
            target.attackSpeed = base * 1.15
            table.insert(self.healBuffs, { unit = target, timer = 2.0, baseSpeed = base })
        end
    end
end

-- ── Sap projectile: travels enemy → Mend ─────────────────────
function Mend:createProjectile(target, grid)
    local dCol = target.col - self.col
    local dRow = target.row - self.row
    local dist = math.sqrt(dCol * dCol + dRow * dRow)
    local duration = (self.projectileSpeed > 0) and (dist / self.projectileSpeed) or 0.01
    if duration < 0.01 then duration = 0.01 end

    return {
        startCol  = target.col,   -- visual origin: enemy
        startRow  = target.row,
        targetCol = self.col,     -- visual destination: Mend
        targetRow = self.row,
        progress  = 0,
        duration  = duration,
        animTime  = 0,
        target    = target,       -- damage target is still the enemy
        damage    = self:getDamage(grid),
        shooter   = self
    }
end

-- ── Attack: leech self-heal + energy counter ─────────────────
function Mend:attack(target, grid)
    Mend.super.attack(self, target, grid)
    self.health = math.min(self.maxHealth, self.health + 1)
    self.energyCounter = self.energyCounter + 1
    if self.energyCounter >= 3 then
        self.energyCounter = 0
        self:triggerHeal(grid)
    end
end

-- ── Update ────────────────────────────────────────────────────
function Mend:update(dt, grid)
    -- Tick heal overlay animations
    for i = #self.healAnims, 1, -1 do
        local anim = self.healAnims[i]
        anim.elapsed = anim.elapsed + dt
        if anim.elapsed >= HEAL_DURATION then
            table.remove(self.healAnims, i)
        end
    end

    -- Tick attack-speed buffs (Upgrade 2)
    for i = #self.healBuffs, 1, -1 do
        local buff = self.healBuffs[i]
        buff.timer = buff.timer - dt
        if buff.timer <= 0 or buff.unit.isDead then
            if not buff.unit.isDead then
                buff.unit.attackSpeed = buff.baseSpeed
            end
            table.remove(self.healBuffs, i)
        end
    end

    Mend.super.update(self, dt, grid)
end

-- ── Top-layer draw: heal overlays rendered above all units ────
function Mend:drawTopLayer()
    local frames = self.sprites and self.sprites.healFrames
    if not frames or #frames == 0 or #self.healAnims == 0 then return end

    local lg = love.graphics
    for _, anim in ipairs(self.healAnims) do
        local u = anim.unit
        if not u.isDead then
            local x, y = u:getDrawPos()
            x = x + Constants.CELL_SIZE / 2
            y = y + Constants.CELL_SIZE / 2

            local frameIdx = math.min(#frames, math.floor(anim.elapsed * HEAL_FPS) + 1)
            local img = frames[frameIdx]
            local sw, sh = img:getWidth(), img:getHeight()
            local scale = Constants.SCALE * 3

            lg.setColor(1, 1, 1, 1)
            lg.setShader(BaseUnit.getPaletteShader())
            lg.draw(img, x, y, 0, scale, scale, sw / 2, sh / 2)
            lg.setShader()
        end
    end
end

-- ── Reset ─────────────────────────────────────────────────────
function Mend:resetCombatState()
    Mend.super.resetCombatState(self)
    self.energyCounter = 0
    self.healAnims = {}
    for _, buff in ipairs(self.healBuffs) do
        if not buff.unit.isDead then
            buff.unit.attackSpeed = buff.baseSpeed
        end
    end
    self.healBuffs = {}
end

return Mend
