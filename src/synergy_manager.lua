local UnitRegistry = require('src.unit_registry')
local Constants    = require('src.constants')

local SynergyManager = {}

-- Thresholds per faction: { tier3_count, tier5_count }
SynergyManager.tiers = {
    undead   = {3, 5},
    folk     = {3, 5},
    monster  = {3, 5},
    brawler  = {3, 5},
    marksman = {3, 5},
    support  = {3, 5},
}

-- Count alive units on the board owned by `owner` per faction.
-- Returns { faction_name -> count }
function SynergyManager.countForOwner(grid, owner)
    local counts = {}
    for row = 1, grid.rows do
        for col = 1, grid.cols do
            local u = grid.cells[row][col].unit
            if u and u.owner == owner and not u.isDead then
                local factions = UnitRegistry.factions[u.unitType]
                if factions then
                    for _, faction in ipairs(factions) do
                        counts[faction] = (counts[faction] or 0) + 1
                    end
                end
            end
        end
    end
    return counts
end

-- Returns { faction -> active_tier } where active_tier is 3 or 5.
-- Only factions at or above the 3-unit threshold are included.
function SynergyManager.getActiveTiers(counts)
    local active = {}
    for faction, thresholds in pairs(SynergyManager.tiers) do
        local count = counts[faction] or 0
        if count >= thresholds[2] then
            active[faction] = thresholds[2]
        elseif count >= thresholds[1] then
            active[faction] = thresholds[1]
        end
    end
    return active
end

-- Apply synergy modifiers to a single unit based on active tiers.
-- Only bonuses for factions the unit belongs to are applied.
-- Stat changes that modify unit fields directly (maxHealth, attackRange) are
-- restored from base values each round inside resetCombatState.
function SynergyManager.applyToUnit(unit, activeTiers)
    local factions = UnitRegistry.factions[unit.unitType]
    if not factions then return end

    for _, faction in ipairs(factions) do
        local tier = activeTiers[faction]
        if not tier then goto continue end

        if faction == "undead" then
            if tier >= 3 then
                -- Calcium Armor: +20% max HP
                unit.maxHealth = math.floor(unit.maxHealth * 1.2)
                unit.health    = math.floor(unit.health    * 1.2)
            end
            if tier >= 5 then
                -- Undying Will: survive lethal hit once with 1 HP + buff animation
                unit.synergyUndyingWill = true
                unit.synergyUndyingUsed = false
            end

        elseif faction == "folk" then
            if tier >= 3 then
                -- Battle Discipline: start with 3 charges (applied post-onBattleStart in game.lua)
                unit.synergyStartingEnergy = 3
            end
            if tier >= 5 then
                -- Rally: +0.2 move speed (applied post-onBattleStart in game.lua)
                unit.synergyMoveSpeedAdd = 0.2
            end

        elseif faction == "monster" then
            if tier >= 3 then
                -- Brute Force: +1 flat damage (read in getDamage via synergyDamageAdd)
                unit.synergyDamageAdd = (unit.synergyDamageAdd or 0) + 1
            end
            if tier >= 5 then
                -- Savage Rush: +40% damage on first hit vs each enemy
                unit.synergySavageRush = true
                unit.savageRushTargets = {}
            end

        elseif faction == "brawler" then
            if tier >= 3 then
                -- Combatant: +15% attack speed (applied in attackCooldown calc in base_unit)
                unit.synergySpeedMult = (unit.synergySpeedMult or 1.0) * 1.15
            end
            if tier >= 5 then
                -- Finishing Blow: every 5th hit deals double damage
                unit.synergyFinishingBlow = true
                unit.synergyHitCounter    = 0
            end

        elseif faction == "marksman" then
            if tier >= 3 then
                -- Eagle Eye: +1 attack range
                unit.attackRange = unit.attackRange + 1
            end
            if tier >= 5 then
                -- Death Mark: +50% damage vs enemies below 50% HP
                unit.synergyDeathMark = true
            end

        elseif faction == "support" then
            if tier >= 3 then
                -- Mending: healer restores +2 extra HP (read in mend/effigy triggerHeal)
                unit.synergyHealBonus = (unit.synergyHealBonus or 0) + 2
            end
            if tier >= 5 then
                -- Guardian: this unit's CC (stun/taunt) lasts 20% longer
                unit.synergyCCDurationMult = 1.2
            end
        end

        ::continue::
    end
end

-- Synergy bonus descriptions for the tooltip, keyed by faction then tier.
SynergyManager.descriptions = {
    undead   = {
        [3] = {"Calcium Armor", "+20% max HP"},
        [5] = {"Undying Will",  "Survive a lethal hit once at 1 HP"},
    },
    folk     = {
        [3] = {"Battle Discipline", "Start with 3 energy charges"},
        [5] = {"Rally",             "+0.2 movement speed"},
    },
    monster  = {
        [3] = {"Brute Force",  "+1 flat damage"},
        [5] = {"Savage Rush",  "+40% damage on first hit vs each enemy"},
    },
    brawler  = {
        [3] = {"Combatant",       "+15% attack speed"},
        [5] = {"Finishing Blow",  "Every 5th hit deals double damage"},
    },
    marksman = {
        [3] = {"Eagle Eye",   "+1 attack range"},
        [5] = {"Death Mark",  "+50% damage vs enemies below 50% HP"},
    },
    support  = {
        [3] = {"Mending",   "Heals restore +2 extra HP"},
        [5] = {"Guardian",  "Crowd control lasts 20% longer"},
    },
}

-- Faction display names (title-cased)
local FACTION_LABELS = {
    undead   = "Undead",
    folk     = "Folk",
    monster  = "Monster",
    brawler  = "Brawler",
    marksman = "Marksman",
    support  = "Support",
}

-- Draw synergy HUD at rerollButtonX, stacked above the grid bottom.
-- Returns the overall bounding rect {x, y, w, h} or nil if nothing drawn.
function SynergyManager.drawHUD(rerollButtonX, counts, activeTiers)
    local icons = UnitRegistry.factionIcons
    if not icons then return nil end

    local sc     = Constants.SCALE
    local iconSz = math.floor(28 * sc)   -- slightly larger icon
    local gap    = math.floor(6  * sc)
    local countFont = Fonts.small        -- slightly larger count label

    -- Collect active synergies, sorted alphabetically for a stable order
    local active = {}
    for faction, thresholds in pairs(SynergyManager.tiers) do
        local count = counts[faction] or 0
        if count >= thresholds[1] then
            table.insert(active, {
                faction = faction,
                count   = count,
                tier    = activeTiers[faction],
            })
        end
    end
    table.sort(active, function(a, b) return a.faction < b.faction end)

    if #active == 0 then return nil end

    local lg = love.graphics

    -- Row height = icon height; count label sits centered next to it
    local rowH   = iconSz
    local countW = math.floor(14 * sc)
    local rowW   = iconSz + math.floor(4 * sc) + countW

    local totalH = #active * rowH + (#active - 1) * gap
    local gridBottom = Constants.GRID_OFFSET_Y + Constants.GRID_HEIGHT
    local startY = gridBottom - totalH
    local startX = rerollButtonX

    for i, s in ipairs(active) do
        local rowX = startX
        local rowY = startY + (i - 1) * (rowH + gap)

        -- Faction icon (no background)
        local icon = icons[s.faction]
        if icon then
            local iw, ih = icon:getWidth(), icon:getHeight()
            local isc    = iconSz / math.max(iw, ih)
            local offX   = math.floor((iconSz - iw * isc) / 2)
            local offY   = math.floor((rowH   - ih * isc) / 2)
            lg.setColor(1, 1, 1, 1)
            lg.draw(icon, rowX + offX, rowY + offY, 0, isc, isc)
        end

        -- Count label right of icon
        lg.setFont(countFont)
        lg.setColor(1, 1, 1, 1)
        local tx = rowX + iconSz + math.floor(4 * sc)
        local ty = rowY + math.floor((rowH - countFont:getHeight()) / 2)
        lg.print(tostring(s.count), tx, ty)
    end

    lg.setColor(1, 1, 1, 1)
    return { x = startX, y = startY, w = rowW, h = totalH }
end

-- Stable display order for the reference tooltip
local FACTION_ORDER = {"brawler", "folk", "marksman", "monster", "support", "undead"}

-- Draw a reference panel listing ALL factions and ALL their tier bonuses.
-- Anchored so its top-right corner sits at (anchorX, anchorY).
function SynergyManager.drawAllPassivesTooltip(anchorX, anchorY)
    local sc      = Constants.SCALE
    local padding = math.floor(10 * sc)
    local lineH   = Fonts.tiny:getHeight()
    local rowGap  = math.floor(6  * sc)
    local lineGap = math.floor(2  * sc)
    local icons   = UnitRegistry.factionIcons
    local iconSz  = math.floor(14 * sc)

    -- Build lines (same structure as drawTooltip)
    local lines = {}
    for gi, fname in ipairs(FACTION_ORDER) do
        local label = (FACTION_LABELS[fname] or fname)
        table.insert(lines, {
            isHeader = true,
            text     = label,
            gap      = gi > 1 and rowGap or 0,
            faction  = fname,
        })
        local descs = SynergyManager.descriptions[fname]
        if descs then
            for _, t in ipairs({3, 5}) do
                if descs[t] then
                    local e = descs[t]
                    table.insert(lines, {
                        isHeader = false,
                        text     = "  ×" .. t .. " " .. e[2],
                        gap      = 0,
                    })
                end
            end
        end
    end

    -- Measure width
    local maxLineW = 0
    for _, ln in ipairs(lines) do
        local w = Fonts.tiny:getWidth(ln.text)
        if w > maxLineW then maxLineW = w end
    end
    local width  = math.max(math.floor(200 * sc), math.min(math.floor(340 * sc), maxLineW + padding * 2 + iconSz + math.floor(4 * sc)))
    local textW  = width - padding * 2

    -- Measure height
    local totalH = padding * 2
    for _, ln in ipairs(lines) do
        totalH = totalH + ln.gap
        local _, wrapped = Fonts.tiny:getWrap(ln.text, textW)
        totalH = totalH + #wrapped * lineH + lineGap
    end
    totalH = totalH - lineGap

    -- Position: below the icon strip, right-aligned to anchorX; clamp to screen
    local margin = math.floor(8 * sc)
    local gap6   = math.floor(6 * sc)
    local panelX = math.max(margin, math.min(Constants.GAME_WIDTH - width - margin, anchorX - width))
    local panelY = anchorY + gap6
    panelY = math.max(margin, math.min(Constants.GAME_HEIGHT - totalH - margin, panelY))

    local lg      = love.graphics
    local cornerR = math.floor(6 * sc)

    lg.setColor(0.08, 0.08, 0.13, 0.95)
    lg.rectangle("fill", panelX, panelY, width, totalH, cornerR)
    lg.setColor(0.40, 0.40, 0.55, 1)
    lg.setLineWidth(math.floor(1 * sc))
    lg.rectangle("line", panelX, panelY, width, totalH, cornerR)

    lg.setFont(Fonts.tiny)
    local cy = panelY + padding
    for _, ln in ipairs(lines) do
        cy = cy + ln.gap
        if ln.isHeader then
            -- Draw faction icon left of header text
            if icons and ln.faction and icons[ln.faction] then
                local icon = icons[ln.faction]
                local iw, ih = icon:getWidth(), icon:getHeight()
                local isc = iconSz / math.max(iw, ih)
                lg.setColor(1, 1, 1, 1)
                lg.draw(icon, panelX + padding, cy + math.floor((lineH - ih * isc) / 2), 0, isc, isc)
            end
            lg.setColor(1, 1, 1, 1)
            local textX = panelX + padding + iconSz + math.floor(4 * sc)
            local _, wrapped = Fonts.tiny:getWrap(ln.text, textW - iconSz - math.floor(4 * sc))
            lg.printf(ln.text, textX, cy, textW - iconSz - math.floor(4 * sc), "left")
            cy = cy + #wrapped * lineH + lineGap
        else
            lg.setColor(0.80, 0.80, 0.80, 1)
            local _, wrapped = Fonts.tiny:getWrap(ln.text, textW)
            lg.printf(ln.text, panelX + padding, cy, textW, "left")
            cy = cy + #wrapped * lineH + lineGap
        end
    end

    lg.setColor(1, 1, 1, 1)
end

-- Draw the synergy tooltip panel to the left of pillX.
-- active: list of { faction, count, tier } (same as drawHUD uses internally)
function SynergyManager.drawTooltip(pillX, counts, activeTiers)
    local active = {}
    for faction, thresholds in pairs(SynergyManager.tiers) do
        local count = counts[faction] or 0
        if count >= thresholds[1] then
            table.insert(active, { faction = faction, count = count, tier = activeTiers[faction] })
        end
    end
    table.sort(active, function(a, b) return a.faction < b.faction end)
    if #active == 0 then return end

    local sc      = Constants.SCALE
    local padding = math.floor(10 * sc)
    local lineH   = Fonts.tiny:getHeight()
    local rowGap  = math.floor(6  * sc)
    local lineGap = math.floor(2  * sc)

    -- Build content lines per faction so we can measure width and height together
    -- Each entry: { isHeader=bool, text=string }
    local lines = {}
    for gi, s in ipairs(active) do
        local header = (FACTION_LABELS[s.faction] or s.faction) .. " ×" .. s.count
        table.insert(lines, { isHeader = true, text = header, gap = gi > 1 and rowGap or 0 })
        local descs = SynergyManager.descriptions[s.faction]
        for _, t in ipairs({3, 5}) do
            if descs and descs[t] and (s.tier or 0) >= t then
                local entry = descs[t]
                table.insert(lines, { isHeader = false, text = "  " .. entry[1] .. " — " .. entry[2], gap = 0 })
            end
        end
    end

    -- Adaptive width: widest single line + padding, clamped to a sensible range
    local maxLineW = 0
    for _, ln in ipairs(lines) do
        local w = Fonts.tiny:getWidth(ln.text)
        if w > maxLineW then maxLineW = w end
    end
    local width    = math.max(math.floor(120 * sc), math.min(math.floor(240 * sc), maxLineW + padding * 2))
    local textW    = width - padding * 2

    -- Adaptive height: measure each line, wrapping as needed
    local totalH = padding * 2
    for _, ln in ipairs(lines) do
        totalH = totalH + ln.gap
        local _, wrapped = Fonts.tiny:getWrap(ln.text, textW)
        totalH = totalH + #wrapped * lineH + lineGap
    end
    totalH = totalH - lineGap  -- remove trailing gap

    -- Position: left of the pills, bottom-aligned to grid bottom, clamped on screen
    local gridBottom = Constants.GRID_OFFSET_Y + Constants.GRID_HEIGHT
    local screenTop  = math.floor(8 * sc)
    local panelX = pillX - width - math.floor(8 * sc)
    local panelY = math.max(screenTop, gridBottom - totalH)

    local lg = love.graphics
    local cornerR = math.floor(6 * sc)

    -- Background + border
    lg.setColor(0.08, 0.08, 0.13, 0.95)
    lg.rectangle("fill", panelX, panelY, width, totalH, cornerR)
    lg.setColor(0.40, 0.40, 0.55, 1)
    lg.setLineWidth(math.floor(1 * sc))
    lg.rectangle("line", panelX, panelY, width, totalH, cornerR)

    lg.setFont(Fonts.tiny)
    local cy = panelY + padding
    for _, ln in ipairs(lines) do
        cy = cy + ln.gap
        if ln.isHeader then
            lg.setColor(1, 1, 1, 1)
        else
            lg.setColor(0.80, 0.80, 0.80, 1)
        end
        local _, wrapped = Fonts.tiny:getWrap(ln.text, textW)
        lg.printf(ln.text, panelX + padding, cy, textW, "left")
        cy = cy + #wrapped * lineH + lineGap
    end

    lg.setColor(1, 1, 1, 1)
end

return SynergyManager
