local BaseUnit       = require('src.base_unit')
local BaseUnitRanged = require('src.base_unit_ranged')
local Constants      = require('src.constants')
local ExplosionAnim  = require('src.explosion_anim')

local Flint = BaseUnitRanged:extend()

local FUSE_DURATION_DEFAULT = 1.0
local FUSE_DURATION_QUICK   = 0.3
local FIRE_DURATION_DEFAULT = 1.0
local FIRE_DURATION_STICKY  = 3.0
local BOMB_DAMAGE     = 2
local CLUSTER_DAMAGE  = 1

function Flint:new(row, col, owner, sprites)
    local stats = {
        health          = 8,
        maxHealth       = 8,
        damage          = BOMB_DAMAGE,
        attackSpeed     = 0.55,
        moveSpeed       = 1,
        attackRange     = 3,
        projectileSpeed = 6,
        unitType        = "flint",
    }

    Flint.super.new(self, row, col, owner, sprites, stats)

    self.hitSound = "soft-hit.mp3"

    self.firePatches = {}
    self.explosions  = {}

    self.upgradeTree = {
        {
            name        = "Quick Fuse",
            description = "Bombs explode after 0.3s instead of 1s",
            onApply     = function(unit) end,
        },
        {
            name        = "Sticky Bombs",
            description = "Fire patches last 3s and tick 1 dmg/sec",
            onApply     = function(unit) end,
        },
        {
            name        = "Cluster Bomb",
            description = "Explosions also deal 1 dmg to cardinal neighbors",
            onApply     = function(unit) end,
        },
    }
end

-- ============================================================
-- createProjectile: build a bomb that arcs to a snapshot of the
-- target's CURRENT cell. We deliberately drop the unit reference
-- (proj.target = nil) so the bomb is locked to a cell, not a unit.
-- Mobile enemies that step out of the cell during the fuse take
-- no damage; only whoever's standing on the cell at detonation
-- gets hit.
-- ============================================================
function Flint:createProjectile(target, grid)
    local proj = BaseUnitRanged.createProjectile(self, target, grid)
    proj.state        = "flying"
    proj.target       = nil
    proj.fuseTimer    = 0
    proj.fuseDuration = self:hasUpgrade(1) and FUSE_DURATION_QUICK or FUSE_DURATION_DEFAULT
    return proj
end

-- ============================================================
-- update: fully replaces BaseUnitRanged:update so we can run the
-- two-phase bomb lifecycle (flight → fuse → detonate) instead of
-- the standard projectile single-tick hit.
-- ============================================================
function Flint:update(dt, grid)
    for i = #self.arrows, 1, -1 do
        local b = self.arrows[i]
        if b.state == "flying" then
            b.progress = b.progress + (dt / b.duration)
            if b.progress >= 1.0 then
                b.progress = 1.0
                b.state    = "fusing"
            end
        elseif b.state == "fusing" then
            b.fuseTimer = b.fuseTimer + dt
            if b.fuseTimer >= b.fuseDuration then
                self:detonateBomb(b, grid)
                table.remove(self.arrows, i)
            end
        end
    end

    -- Tick fire patches
    for i = #self.firePatches, 1, -1 do
        local p = self.firePatches[i]
        p.timer       = p.timer       - dt
        p.damageTimer = p.damageTimer - dt
        if p.damageTimer <= 0 then
            p.damageTimer = 1
            for _, unit in ipairs(grid:getAllUnits()) do
                if unit.owner ~= self.owner and not unit.isDead
                   and unit.col == p.col and unit.row == p.row then
                    unit:takeDamage(1, self, grid)
                    if unit.isDead then
                        grid:killUnit(unit)
                        self:onKill(unit)
                    end
                end
            end
        end
        if p.timer <= 0 then
            table.remove(self.firePatches, i)
        end
    end

    ExplosionAnim.tick(self.explosions, dt)

    -- Skip BaseUnitRanged.update's arrow loop (handled above) and go
    -- straight to BaseUnit.update for movement + AI.
    BaseUnit.update(self, dt, grid)
end

-- ============================================================
-- detonateBomb: explode at the bomb's locked cell. Damage whoever
-- is standing on that cell, optionally splash cardinals (Cluster
-- Bomb), plant a fire patch, queue an explosion animation.
-- ============================================================
function Flint:detonateBomb(bomb, grid)
    local cx, cy = bomb.targetCol, bomb.targetRow

    -- Primary detonation: damage whoever's currently on the cell
    if grid:isValidCell(cx, cy) then
        local cell   = grid:getCell(cx, cy)
        local target = cell and cell.unit
        if target and not target.isDead and target.owner ~= self.owner then
            target:takeDamage(BOMB_DAMAGE, self, grid)
            if target.isDead then
                grid:killUnit(target)
                self:onKill(target)
            end
        end
    end

    -- Cluster Bomb (upgrade 3): 1 dmg to cardinal neighbors
    if self:hasUpgrade(3) then
        local cardinals = { {0, 1}, {0, -1}, {1, 0}, {-1, 0} }
        for _, d in ipairs(cardinals) do
            local tc, tr = cx + d[1], cy + d[2]
            if grid:isValidCell(tc, tr) then
                local cell   = grid:getCell(tc, tr)
                local target = cell and cell.unit
                if target and not target.isDead and target.owner ~= self.owner then
                    target:takeDamage(CLUSTER_DAMAGE, self, grid)
                    if target.isDead then
                        grid:killUnit(target)
                        self:onKill(target)
                    end
                end
            end
        end
    end

    -- Plant fire patch at the explosion cell
    if grid:isValidCell(cx, cy) then
        local fireDur = self:hasUpgrade(2) and FIRE_DURATION_STICKY or FIRE_DURATION_DEFAULT
        table.insert(self.firePatches, {
            col         = cx,
            row         = cy,
            duration    = fireDur,
            timer       = fireDur,
            damageTimer = 1,
        })
    end

    table.insert(self.explosions, ExplosionAnim.new(cx, cy))
    AudioManager.playSFX("fireball.mp3", 0.4)
end

-- ============================================================
-- drawProjectile: only the FLYING phase renders here (it's called
-- via drawAttackVisuals, on top of units). The fusing phase is
-- routed through drawGroundEffects so a unit standing on the
-- bomb's cell visually covers it.
-- ============================================================
function Flint:drawProjectile(projectile)
    if projectile.state ~= "flying" then return end

    local lg     = love.graphics
    local frames = self.sprites and self.sprites.fuseFrames
    if not frames or #frames == 0 then return end

    local startVR  = Constants.toVisualRow(projectile.startRow)
    local targetVR = Constants.toVisualRow(projectile.targetRow)
    local startX = Constants.GRID_OFFSET_X + (projectile.startCol - 1)  * Constants.CELL_SIZE + Constants.CELL_SIZE / 2
    local startY = Constants.GRID_OFFSET_Y + (startVR - 1)              * Constants.CELL_SIZE + Constants.CELL_SIZE / 2
    local endX   = Constants.GRID_OFFSET_X + (projectile.targetCol - 1) * Constants.CELL_SIZE + Constants.CELL_SIZE / 2
    local endY   = Constants.GRID_OFFSET_Y + (targetVR - 1)             * Constants.CELL_SIZE + Constants.CELL_SIZE / 2

    local t  = projectile.progress
    local cx = startX + (endX - startX) * t
    local cy = startY + (endY - startY) * t - math.sin(t * math.pi) * 14 * Constants.SCALE

    local fps      = 8
    local frameIdx = math.floor((t * projectile.duration) * fps) % #frames + 1
    local img      = frames[frameIdx]
    local sw, sh   = img:getWidth(), img:getHeight()
    local scale    = Constants.CELL_SIZE / 16  -- canonical pixel scale (sprite is 6x6, renders proportionally)

    lg.setColor(1, 1, 1, 1)
    lg.setShader(BaseUnit.getPaletteShader())
    lg.draw(img, cx, cy, 0, scale, scale, sw / 2, sh / 2)
    lg.setShader()
    lg.setColor(1, 1, 1, 1)
end

-- ============================================================
-- drawFusingBomb: render a bomb sitting on its target cell while
-- the fuse counts down. Sprite spins on its own center for
-- visual readability of the imminent boom.
-- ============================================================
function Flint:drawFusingBomb(bomb)
    local lg     = love.graphics
    local frames = self.sprites and self.sprites.fuseFrames
    if not frames or #frames == 0 then return end

    local visualRow = Constants.toVisualRow(bomb.targetRow)
    local cx = Constants.GRID_OFFSET_X + (bomb.targetCol - 1) * Constants.CELL_SIZE + Constants.CELL_SIZE / 2
    local cy = Constants.GRID_OFFSET_Y + (visualRow - 1)      * Constants.CELL_SIZE + Constants.CELL_SIZE / 2

    local fps      = 8
    local frameIdx = math.floor(bomb.fuseTimer * fps) % #frames + 1
    local img      = frames[frameIdx]
    local sw, sh   = img:getWidth(), img:getHeight()
    local scale    = Constants.CELL_SIZE / 16  -- canonical pixel scale (sprite is 6x6, renders proportionally)
    local rotation = bomb.fuseTimer * math.pi * 4

    lg.setColor(1, 1, 1, 1)
    lg.setShader(BaseUnit.getPaletteShader())
    lg.draw(img, cx, cy, rotation, scale, scale, sw / 2, sh / 2)
    lg.setShader()
    lg.setColor(1, 1, 1, 1)
end

-- ============================================================
-- drawGroundEffects: drawn BEFORE any unit sprite. We render the
-- fusing bombs and fire patches here so a unit standing on the
-- target cell visually sits on top of the bomb sprite.
-- ============================================================
function Flint:drawGroundEffects()
    -- Fusing bombs (sprite spinning on the cell)
    for _, bomb in ipairs(self.arrows) do
        if bomb.state == "fusing" then
            self:drawFusingBomb(bomb)
        end
    end

    -- Fire patches
    local fireFrames = self.sprites and self.sprites.fireFrames
    if fireFrames and #fireFrames > 0 then
        local lg = love.graphics
        for _, patch in ipairs(self.firePatches) do
            local visualRow = Constants.toVisualRow(patch.row)
            local cx = Constants.GRID_OFFSET_X + (patch.col - 1) * Constants.CELL_SIZE + Constants.CELL_SIZE / 2
            local cy = Constants.GRID_OFFSET_Y + (visualRow - 1) * Constants.CELL_SIZE + Constants.CELL_SIZE / 2
            local elapsed  = patch.duration - patch.timer
            local fps      = 8
            local frameIdx = math.floor(elapsed * fps) % #fireFrames + 1
            local img      = fireFrames[frameIdx]
            local sw, sh   = img:getWidth(), img:getHeight()
            local scale    = Constants.CELL_SIZE / sw
            local alpha    = math.min(1, patch.timer / 1) * 0.85 + 0.15

            lg.setColor(1, 1, 1, alpha)
            lg.setShader(BaseUnit.getPaletteShader())
            lg.draw(img, cx, cy, 0, scale, scale, sw / 2, sh / 2)
            lg.setShader()
        end
        lg.setColor(1, 1, 1, 1)
    end
end

-- ============================================================
-- drawAttackVisuals: super draws flying bombs (drawProjectile is
-- now early-returning for fusing state, so only flight renders
-- here). Explosion animations layer on top.
-- ============================================================
function Flint:drawAttackVisuals()
    Flint.super.drawAttackVisuals(self)
    ExplosionAnim.drawAll(self.explosions, self.sprites)
end

-- ============================================================
-- resetCombatState: clear per-round bomb/fire/explosion state.
-- ============================================================
function Flint:resetCombatState()
    Flint.super.resetCombatState(self)
    self.firePatches = {}
    self.explosions  = {}
end

return Flint
