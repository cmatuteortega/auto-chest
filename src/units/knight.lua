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
end

-- Passive: Taunt all enemies within 3 cells for 3 seconds at battle start
function Knight:onBattleStart(grid)
    local allUnits = grid:getAllUnits()
    for _, unit in ipairs(allUnits) do
        -- Only taunt enemy units
        if unit.owner ~= self.owner and not unit.isDead then
            local distance = math.sqrt((unit.col - self.col)^2 + (unit.row - self.row)^2)
            if distance <= 3 then
                -- Apply taunt
                unit.tauntedBy = self
                unit.tauntTimer = 3  -- 3 seconds
            end
        end
    end
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
