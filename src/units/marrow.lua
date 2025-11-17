local BaseUnitRanged = require('src.base_unit_ranged')

local Marrow = BaseUnitRanged:extend()

function Marrow:new(row, col, owner, sprites)
    -- Marrow stats: ranged archer
    local stats = {
        health = 7,
        maxHealth = 7,
        damage = 1,
        attackSpeed = 1.2,      -- 1 attack per second
        moveSpeed = 1,        -- 1 cell per second
        attackRange = 3,      -- 3 cells range
        projectileSpeed = 0.2, -- Arrow flight time
        unitType = "marrow"
    }

    Marrow.super.new(self, row, col, owner, sprites, stats)
end

-- Passive: Gain attack speed on kill
function Marrow:onKill(target)
    -- Increase attack speed by 0.2 per kill (stacks permanently for the battle)
    self.attackSpeed = self.attackSpeed + 0.2
end


return Marrow
