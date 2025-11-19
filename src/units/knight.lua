local BaseUnit = require('src.base_unit')

local Knight = BaseUnit:extend()

function Knight:new(row, col, owner, sprites)
    -- Knight stats: melee fighter
    local stats = {
        health = 10,
        maxHealth = 10,
        damage = 1,
        attackSpeed = 1,  -- 1 attack per second
        moveSpeed = 1,    -- 1 cell per second
        attackRange = 0,  -- Melee (adjacent cells only)
        unitType = "knight"
    }

    Knight.super.new(self, row, col, owner, sprites, stats)

    -- Upgrade tracking flags
    self.hasHealed = false  -- Track if Mend heal has been used
    self.wasAboveHalfHealth = true  -- Track HP threshold crossing
    self.hpBonusApplied = false  -- Track if Guardian HP bonus was applied

    -- Define upgrade tree (3 upgrades, can choose 2)
    self.upgradeTree = {
        -- Upgrade 1: Increased taunt duration
        {
            name = "Iron Will",
            description = "Taunt duration increased to 5s",
            onApply = function(unit)
                -- No immediate effect, handled in onBattleStart()
            end
        },
        -- Upgrade 2: +5 HP per enemy in taunt radius
        {
            name = "Guardian",
            description = "+5 max HP per enemy in taunt radius",
            onApply = function(unit)
                -- No immediate effect, handled in onBattleStart()
            end
        },
        -- Upgrade 3: Mend (same as Boney)
        {
            name = "Mend",
            description = "Heal 25% HP when reaching 50% HP",
            onApply = function(unit)
                -- No immediate effect, handled in update()
            end
        }
    }
end

-- Passive: Taunt all enemies within 3 cells at battle start
function Knight:onBattleStart(grid)
    local allUnits = grid:getAllUnits()
    local enemiesInRadius = 0

    -- Determine taunt duration based on upgrade 1
    local tauntDuration = 3  -- Base duration
    if self:hasUpgrade(1) then
        tauntDuration = 5  -- Extended duration with Iron Will
    end

    for _, unit in ipairs(allUnits) do
        -- Only taunt enemy units
        if unit.owner ~= self.owner and not unit.isDead then
            local distance = math.sqrt((unit.col - self.col)^2 + (unit.row - self.row)^2)
            if distance <= 3 then
                -- Apply taunt
                unit.tauntedBy = self
                unit.tauntTimer = tauntDuration
                enemiesInRadius = enemiesInRadius + 1
            end
        end
    end

    -- Upgrade 2: Guardian - +5 max HP per enemy in taunt radius
    if self:hasUpgrade(2) and not self.hpBonusApplied then
        local hpBonus = enemiesInRadius * 5
        self.maxHealth = self.maxHealth + hpBonus
        self.health = self.health + hpBonus
        self.hpBonusApplied = true
    end
end

-- Override update for Mend heal logic (upgrade 3)
function Knight:update(dt, grid)
    -- Handle Mend upgrade (heal once at 50% HP threshold)
    if self:hasUpgrade(3) and not self.hasHealed and not self.isDead then
        local belowHalf = self.health < self.maxHealth * 0.5

        -- Check if we just crossed the 50% threshold
        if self.wasAboveHalfHealth and belowHalf then
            -- Trigger one-time heal
            local healAmount = math.floor(self.maxHealth * 0.25)
            self.health = math.min(self.health + healAmount, self.maxHealth)
            self.hasHealed = true
        end

        -- Update threshold tracker
        self.wasAboveHalfHealth = not belowHalf
    end

    -- Call parent update for normal behavior
    Knight.super.update(self, dt, grid)
end

-- Melee attack: lunge toward target and apply damage
function Knight:attack(target, grid)
    if target and not target.isDead then
        -- Trigger attack animation (lunge)
        self.attackAnimProgress = 0  -- Reset to start
        self.attackTargetCol = target.col
        self.attackTargetRow = target.row

        -- Apply damage (use getDamage() for passive abilities, pass grid)
        target:takeDamage(self:getDamage(grid))

        -- If target died, mark cell as unoccupied but keep unit visible
        if target.isDead then
            local cell = grid:getCell(target.col, target.row)
            if cell then
                cell.occupied = false  -- Allow movement through this cell
                -- Keep cell.unit so the dead sprite remains visible
            end

            -- Trigger onKill hook for passive abilities
            self:onKill(target)
        end
    end
end

return Knight
