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
local Bonk   = require('src.units.bonk')
local Sinner = require('src.units.sinner')
local Tomb   = require('src.units.tomb')

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
    clavicula = Clavicula,
    bonk   = Bonk,
    sinner = Sinner,
    tomb   = Tomb
}

-- Unit groups for collection display
UnitRegistry.groups = {
    { name = "Calcium Clan", groupType = "skeleton", units = {"boney", "marrow", "amalgam", "humerus", "clavicula", "tomb"} },
    { name = "Castle Crew",  groupType = "castle",   units = {"knight", "marc", "mage", "samurai", "bull", "bonk", "sinner"} },
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
    },
    bonk = {
        front = "src/assets/bonk/front.png",
        back  = "src/assets/bonk/back.png",
        dead  = "src/assets/bonk/dead.png"
    },
    sinner = {
        front = "src/assets/sinner/sinner/front.png",
        back  = "src/assets/sinner/sinner/back.png",
        dead  = "src/assets/sinner/sinner/dead.png"
    },
    ["sinner-free"] = {
        front = "src/assets/sinner/sinner-free/front.png",
        back  = "src/assets/sinner/sinner-free/back.png",
        dead  = "src/assets/sinner/sinner-free/dead.png"
    },
    tomb = {
        front = "src/assets/tomb/front.png",
        back  = "src/assets/tomb/back.png",
        dead  = "src/assets/tomb/front.png"  -- no dead sprite; tomb stays upright
    }
}

-- Map of unit type names to their passive ability descriptions
UnitRegistry.passiveDescriptions = {
    knight = "Taunt all enemies within 3 cells for 3 seconds at battle start",
    boney = "Deal 2x damage when below 50% HP",
    samurai = "Deal 2x damage when no allies are within 2 cells",
    marrow = "Gain +0.2 attack speed per kill",
    marc = "Target furthest enemy in range (Sniper Focus)",
    bull = "Charges forward 4 tiles at battle start, stunning the first enemy hit",
    mage   = "Every 6 hits dealt or received, launches a fireball dealing AoE damage",
    amalgam  = "Cannot die to a single hit; surviving a lethal blow grants 1s invulnerability (10s cooldown)",
    humerus   = "Royal Command: allies attacking the same target gain +20% ATK",
    clavicula = "Every 8 hits (given or taken), spawns a copy at 50% HP (max 4 on screen)",
    bonk   = "Every 3rd hit deals triple damage.",
    sinner = "Every 20 hits (given or taken), breaks free: +ATK SPD and becomes stun immune",
    tomb   = "Friendly units stepping onto a corpse cell heal 2 HP"
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
    boney = 2,
    marrow = 2,
    samurai = 3,
    knight = 3,
    marc = 3,
    bull    = 4,
    mage    = 4,
    amalgam = 4,
    humerus   = 5,
    clavicula = 4,
    bonk   = 3,
    sinner = 4,
    tomb   = 3
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

-- Load directional sprites for a unit type (8-direction animation system).
-- Falls back to loadSprites() if no directional sprites exist for this unit.
function UnitRegistry.loadDirectionalSprites(unitType)
    local basePath = "src/assets/" .. unitType .. "/"

    -- Probe: if idle_0_1.png absent, fall back to legacy system
    if not love.filesystem.getInfo(basePath .. "idle_0_1.png") then
        return UnitRegistry.loadSprites(unitType)
    end

    -- Load legacy sprites as base (provides front/back/dead fallback + trimBottom)
    local result = UnitRegistry.loadSprites(unitType)
    result.hasDirectionalSprites = true
    result.directional = {idle = {}, walk = {}, hit = {}}

    -- Scan numbered frames for a state+angle combo until a file is absent
    local function loadFrames(stateKey, angle)
        local frames, trims = {}, {}
        local i = 1
        while true do
            local path = basePath .. stateKey .. "_" .. angle .. "_" .. i .. ".png"
            if not love.filesystem.getInfo(path) then break end
            local img = love.graphics.newImage(path)
            img:setFilter('nearest', 'nearest')
            table.insert(frames, img)
            table.insert(trims, trimBottomRows(path))
            i = i + 1
        end
        if #frames > 0 then
            result.directional[stateKey][angle] = {frames = frames, trimBottom = trims}
        end
    end

    -- Idle: directions 0° and 180°
    for _, angle in ipairs({0, 180}) do
        loadFrames("idle", angle)
    end

    -- Walk and hit (attack windup): 6 directions
    for _, angle in ipairs({0, 45, 135, 180, 225, 315}) do
        loadFrames("walk", angle)
        loadFrames("hit", angle)
    end

    return result
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
        allSprites[unitType] = UnitRegistry.loadDirectionalSprites(unitType)
    end
    -- Attach sinner's free-form sprites so the unit can swap at form-change time
    allSprites["sinner"].freeForm = UnitRegistry.loadSprites("sinner-free")
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
