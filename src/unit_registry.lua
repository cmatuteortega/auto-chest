-- Unit Registry: Central place to manage all unit types
local Boney = require('src.units.boney')
local Marrow = require('src.units.marrow')
local Samurai = require('src.units.samurai')
local Knight = require('src.units.knight')
local Marc = require('src.units.marc')
local Bull = require('src.units.bull')
local Mage   = require('src.units.mage')
local Amalgam = require('src.units.amalgam')
local Humerus   = require('src.units.humerus')
local Clavicula = require('src.units.clavicula')

local UnitRegistry = {}

-- Map of unit type names to their classes
UnitRegistry.unitClasses = {
    boney = Boney,
    marrow = Marrow,
    samurai = Samurai,
    knight = Knight,
    marc = Marc,
    bull   = Bull,
    mage   = Mage,
    amalgam = Amalgam,
    humerus   = Humerus,
    clavicula = Clavicula
}

-- Map of unit type names to their sprite paths
UnitRegistry.spritePaths = {
    boney = {
        front = "src/assets/boney/front.png",
        back = "src/assets/boney/back.png",
        dead = "src/assets/boney/dead.png"
    },
    marrow = {
        front = "src/assets/marrow/front.png",
        back = "src/assets/marrow/back.png",
        dead = "src/assets/marrow/dead.png"
    },
    samurai = {
        front = "src/assets/samurai/front.png",
        back = "src/assets/samurai/back.png",
        dead = "src/assets/samurai/dead.png"
    },
    knight = {
        front = "src/assets/knight/front.png",
        back = "src/assets/knight/back.png",
        dead = "src/assets/knight/dead.png"
    },
    marc = {
        front = "src/assets/marc/front.png",
        back = "src/assets/marc/back.png",
        dead = "src/assets/marc/dead.png"
    },
    bull = {
        front = "src/assets/bull/front.png",
        back  = "src/assets/bull/back.png",
        dead  = "src/assets/bull/dead.png"
    },
    mage = {
        front = "src/assets/mage/front.png",
        back  = "src/assets/mage/back.png",
        dead  = "src/assets/mage/dead.png"
    },
    amalgam = {
        front = "src/assets/amalgam/front.png",
        back  = "src/assets/amalgam/back.png",
        dead  = "src/assets/amalgam/dead.png"
    },
    humerus = {
        front = "src/assets/humerus/front.png",
        back  = "src/assets/humerus/back.png",
        dead  = "src/assets/humerus/dead.png"
    },
    clavicula = {
        front = "src/assets/clavicula/front.png",
        back  = "src/assets/clavicula/back.png",
        dead  = "src/assets/clavicula/dead.png"
    }
}

-- Map of unit type names to their passive ability descriptions
UnitRegistry.passiveDescriptions = {
    knight = "Taunt all enemies within 3 cells for 3 seconds at battle start",
    boney = "Deal 2x damage when below 50% HP",
    samurai = "Deal 1.5x damage when no allies are within 2 cells",
    marrow = "Gain +0.2 attack speed per kill",
    marc = "Target furthest enemy in range (Sniper Focus)",
    bull = "Charges forward 4 tiles at battle start, stunning the first enemy hit",
    mage   = "Every 6 hits dealt or received, launches a fireball dealing AoE damage",
    amalgam  = "Cannot die to a single hit; surviving a lethal blow grants 1s invulnerability (10s cooldown)",
    humerus   = "Royal Command: allies attacking the same target gain +20% ATK",
    clavicula = "Every 6 hits (given or taken), spawns a copy of itself at half HP"
}

-- Returns display info for a unit type by reading it directly from a dummy
-- instance. Results are cached so each unit is only instantiated once.
local _displayInfoCache = {}
function UnitRegistry.getUnitDisplayInfo(unitType)
    if _displayInfoCache[unitType] then
        return _displayInfoCache[unitType]
    end

    local UnitClass = UnitRegistry.unitClasses[unitType]
    local dummy = UnitClass(1, 1, 1, {})

    local upgrades = {}
    for _, u in ipairs(dummy.upgradeTree or {}) do
        table.insert(upgrades, { name = u.name, description = u.description })
    end

    local info = {
        hp        = dummy.health,
        atk       = dummy.damage,
        spd       = dummy.attackSpeed,
        rng       = dummy.attackRange,
        unitClass = dummy.attackRange > 0 and "Ranged" or "Melee",
        upgrades  = upgrades,
    }

    _displayInfoCache[unitType] = info
    return info
end

-- Map of unit type names to their costs
UnitRegistry.unitCosts = {
    boney = 3,
    marrow = 3,
    samurai = 3,
    knight = 3,
    marc = 2,
    bull    = 3,
    mage    = 3,
    amalgam = 3,
    humerus   = 3,
    clavicula = 3
}

-- Count fully-transparent rows at the bottom of a sprite file.
-- Used to normalise the visual baseline across sprites with different amounts of padding.
local function trimBottomRows(path)
    local data = love.image.newImageData(path)
    local w, h = data:getDimensions()
    local trim = 0
    for y = h - 1, 0, -1 do
        local rowEmpty = true
        for x = 0, w - 1 do
            local a = select(4, data:getPixel(x, y))
            if a > 0.01 then rowEmpty = false; break end
        end
        if rowEmpty then trim = trim + 1 else break end
    end
    return trim
end

-- Load sprites for a specific unit type
function UnitRegistry.loadSprites(unitType)
    local paths = UnitRegistry.spritePaths[unitType]
    if not paths then
        error("Unknown unit type: " .. tostring(unitType))
    end

    -- Load sprites with nearest-neighbor filtering for pixel-perfect scaling
    local front = love.graphics.newImage(paths.front)
    front:setFilter('nearest', 'nearest')

    local back = love.graphics.newImage(paths.back)
    back:setFilter('nearest', 'nearest')

    local dead = love.graphics.newImage(paths.dead)
    dead:setFilter('nearest', 'nearest')

    return {
        front = front,
        back  = back,
        dead  = dead,
        -- Transparent row counts used by BaseUnit:draw() for baseline alignment
        frontTrimBottom = trimBottomRows(paths.front),
        backTrimBottom  = trimBottomRows(paths.back),
        deadTrimBottom  = trimBottomRows(paths.dead),
    }
end

-- Load all sprites for all unit types
function UnitRegistry.loadAllSprites()
    local allSprites = {}
    for unitType, _ in pairs(UnitRegistry.unitClasses) do
        allSprites[unitType] = UnitRegistry.loadSprites(unitType)
    end
    return allSprites
end

-- Create a unit of the specified type
function UnitRegistry.createUnit(unitType, row, col, owner, sprites)
    local UnitClass = UnitRegistry.unitClasses[unitType]
    if not UnitClass then
        error("Unknown unit type: " .. tostring(unitType))
    end

    return UnitClass(row, col, owner, sprites)
end

-- Get list of all available unit types
function UnitRegistry.getAllUnitTypes()
    local types = {}
    for unitType, _ in pairs(UnitRegistry.unitClasses) do
        table.insert(types, unitType)
    end
    return types
end

-- Get a random unit type
function UnitRegistry.getRandomUnitType()
    local types = UnitRegistry.getAllUnitTypes()
    return types[math.random(#types)]
end

return UnitRegistry
