local BaseUnitRanged = require('src.base_unit_ranged')
local Constants      = require('src.constants')

local Clavicula = BaseUnitRanged:extend()

-- AoE explosion radius for Cursed Ground (upgrade 3), in cell units
local EXPLOSION_RADIUS = 2
local EXPLOSION_DAMAGE = 3

function Clavicula:new(row, col, owner, sprites)
    local stats = {
        health          = 9,
        maxHealth       = 9,
        damage          = 1,
        attackSpeed     = 0.65,        -- 1 attack per ~1.54s
        moveSpeed       = 1,
        attackRange     = 3,
        projectileSpeed = 0.22,
        unitType        = "clavicula"
    }

    Clavicula.super.new(self, row, col, owner, sprites, stats)

    -- Spectral Mitosis: track combined hits (given + taken)
    self.hitCounter      = 0
    self.mitosisFlag     = false   -- consumed in update() where grid is available

    -- Soul Drain (upgrade 2): pending heal to distribute to surviving clones after death
    self.soulDrainPending = false
    self.soulDrainAmount  = 0

    -- Cursed Ground (upgrade 3): pending explosion on death
    self.explosionPending = false

    -- Visual: active explosion flash { col, row, timer }
    self.explosionFlash  = nil

    self.upgradeTree = {
        {
            name        = "Twin Spirits",
            description = "Copies spawn at 65% HP instead of 50%",
            onApply     = function(unit) end
        },
        {
            name        = "Soul Drain",
            description = "When a copy dies, surviving copies are healed",
            onApply     = function(unit) end
        },
        {
            name        = "Cursed Ground",
            description = "Clavicula and clones explode on death, dealing AoE damage",
            onApply     = function(unit) end
        }
    }
end

function Clavicula:resetCombatState()
    Clavicula.super.resetCombatState(self)
    self.hitCounter       = 0
    self.mitosisFlag      = false
    self.soulDrainPending = false
    self.soulDrainAmount  = 0
    self.explosionPending = false
    self.explosionFlash   = nil
end

-- Track hits received toward Spectral Mitosis
function Clavicula:takeDamage(amount)
    Clavicula.super.takeDamage(self, amount)

    if self.isDead then
        -- Cursed Ground: schedule explosion
        if self:hasUpgrade(3) then
            self.explosionPending = true
        end
        -- Soul Drain: surviving copies will be healed
        if self:hasUpgrade(2) then
            self.soulDrainPending = true
            self.soulDrainAmount  = math.floor(self.maxHealth / 4)
        end
        return
    end

    -- Spectral Mitosis
    self.hitCounter = self.hitCounter + 1
    if self.hitCounter >= 8 then
        self.hitCounter  = 0
        self.mitosisFlag = true
    end
end

-- Track hits given toward Spectral Mitosis
function Clavicula:attack(target, grid)
    Clavicula.super.attack(self, target, grid)

    self.hitCounter = self.hitCounter + 1
    if self.hitCounter >= 8 then
        self.hitCounter  = 0
        self.mitosisFlag = true
    end
end

-- Find the nearest free cell (searches up to radius 3 from self, prefers closest)
function Clavicula:findFreeCell(grid)
    local best     = nil
    local bestDist = math.huge

    for dr = -3, 3 do
        for dc = -3, 3 do
            if not (dr == 0 and dc == 0) then
                local nr = self.row + dr
                local nc = self.col + dc
                if grid:isValidCell(nc, nr) and grid:isCellAvailable(nc, nr) then
                    local dist = math.abs(dr) + math.abs(dc)
                    -- Deterministic tie-break: prefer lower row, then lower col
                    local better = dist < bestDist
                    if dist == bestDist and best then
                        better = (nr < best.row) or (nr == best.row and nc < best.col)
                    end
                    if better then
                        bestDist = dist
                        best     = { col = nc, row = nr }
                    end
                end
            end
        end
    end

    if best then return best.col, best.row end
    return nil, nil
end

-- Spawn a copy of this unit on the grid
function Clavicula:spawnClone(grid)
    if self.isDead then return end

    -- Replication cap: max 4 Claviculas per owner on the board
    local count = 0
    for _, unit in ipairs(grid:getAllUnits()) do
        if unit.owner == self.owner and unit.unitType == "clavicula" and not unit.isDead then
            count = count + 1
        end
    end
    if count >= 4 then return end

    local spawnCol, spawnRow = self:findFreeCell(grid)
    if not spawnCol then return end  -- No free cell found

    local clone = Clavicula(spawnRow, spawnCol, self.owner, self.sprites)

    -- Copy active upgrades so clone benefits from purchased abilities
    clone.activeUpgrades = {}
    for _, idx in ipairs(self.activeUpgrades) do
        table.insert(clone.activeUpgrades, idx)
    end
    clone.level    = self.level
    -- Apply scaled stats matching the original's level
    local mult     = 1.3 ^ self.level
    clone.maxHealth = math.floor(clone.baseHealth * mult)
    clone.damage    = math.floor(clone.baseDamage  * mult)

    -- Set spawn HP: 65% with Twin Spirits (upgrade 1), else 50%
    local hpFraction = self:hasUpgrade(1) and 0.65 or 0.5
    clone.health    = math.max(1, math.floor(clone.maxHealth * hpFraction))

    grid:placeUnit(spawnCol, spawnRow, clone)
end

-- AoE explosion: deal damage to all nearby enemies
function Clavicula:doExplosion(grid)
    local allUnits = grid:getAllUnits()
    for _, unit in ipairs(allUnits) do
        if unit.owner ~= self.owner and not unit.isDead then
            local dx   = unit.col - self.col
            local dy   = unit.row - self.row
            local dist = math.sqrt(dx * dx + dy * dy)
            if dist <= EXPLOSION_RADIUS then
                unit:takeDamage(EXPLOSION_DAMAGE)
                if unit.isDead then
                    local cell = grid:getCell(unit.col, unit.row)
                    if cell then cell.occupied = false end
                    -- No onKill credit since this is a death explosion
                end
            end
        end
    end

    -- Visual flash
    self.explosionFlash = { col = self.col, row = self.row, timer = 0.4 }
end

-- Distribute soul-drain heals from dead clones to surviving copies
function Clavicula:doSoulDrain(grid, healAmount)
    local allUnits = grid:getAllUnits()
    for _, unit in ipairs(allUnits) do
        if unit.owner == self.owner and unit.unitType == "clavicula" and not unit.isDead then
            unit.health = math.min(unit.maxHealth, unit.health + healAmount)
            unit:triggerBuffAnim()
        end
    end
end

function Clavicula:update(dt, grid)
    -- Consume pending flags BEFORE super (which early-returns when dead)

    if self.mitosisFlag then
        self.mitosisFlag = false
        self:spawnClone(grid)
    end

    if self.explosionPending then
        self.explosionPending = false
        self:doExplosion(grid)
    end

    if self.soulDrainPending then
        self.soulDrainPending = false
        self:doSoulDrain(grid, self.soulDrainAmount)
    end

    -- Advance explosion flash visual
    if self.explosionFlash then
        self.explosionFlash.timer = self.explosionFlash.timer - dt
        if self.explosionFlash.timer <= 0 then
            self.explosionFlash = nil
        end
    end

    Clavicula.super.update(self, dt, grid)
end

function Clavicula:drawAttackVisuals()
    -- Draw regular projectiles via parent
    Clavicula.super.drawAttackVisuals(self)

    -- Draw explosion flash (Cursed Ground)
    if self.explosionFlash then
        local flash = self.explosionFlash
        local t     = flash.timer / 0.4   -- 1 → 0 as it fades
        local alpha = t * 0.7

        local lg        = love.graphics
        local centerX   = Constants.GRID_OFFSET_X + (flash.col - 0.5) * Constants.CELL_SIZE
        local centerY   = Constants.GRID_OFFSET_Y + (Constants.toVisualRow(flash.row) - 0.5) * Constants.CELL_SIZE
        local radius    = EXPLOSION_RADIUS * Constants.CELL_SIZE * (1.1 - t * 0.5)

        ---@diagnostic disable: redundant-parameter
        lg.setColor(0.7, 0.2, 1, alpha)
        lg.circle('fill', centerX, centerY, radius)
        lg.setColor(1, 0.8, 1, alpha * 0.6)
        lg.circle('fill', centerX, centerY, radius * 0.5)
        lg.setColor(1, 1, 1, 1)
        ---@diagnostic enable: redundant-parameter
    end
end


return Clavicula
