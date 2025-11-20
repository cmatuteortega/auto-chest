-- Unit Registry: Central place to manage all unit types
local Boney = require('src.units.boney')
local Marrow = require('src.units.marrow')
local Samurai = require('src.units.samurai')
local Knight = require('src.units.knight')

local UnitRegistry = {}

-- Map of unit type names to their classes
UnitRegistry.unitClasses = {
    boney = Boney,
    marrow = Marrow,
    samurai = Samurai,
    knight = Knight
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
    }
}

-- Map of unit type names to their passive ability descriptions
UnitRegistry.passiveDescriptions = {
    knight = "Taunt all enemies within 3 cells for 3 seconds at battle start",
    boney = "Deal 2x damage when below 50% HP",
    samurai = "Deal 1.5x damage when no allies are within 2 cells",
    marrow = "Gain +0.2 attack speed per kill"
}

-- Map of unit type names to their costs
UnitRegistry.unitCosts = {
    boney = 3,
    marrow = 3,
    samurai = 3,
    knight = 3
}

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
        back = back,
        dead = dead
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
