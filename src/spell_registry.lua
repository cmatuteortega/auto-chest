-- Spell Registry: parallel to UnitRegistry for spell-type cards.
-- Spells are placed on the grid like units but trigger once at battle start
-- (no health, no ongoing combat, no upgrades, no cell occupancy).

local SpellRegistry = {}

-- Set membership: SpellRegistry.spellTypes[t] is truthy if t is a spell.
SpellRegistry.spellTypes = {
    arrows = true,
}

-- Cost in coins per spell type (mirrors UnitRegistry.unitCosts shape).
SpellRegistry.spellCosts = {
    arrows = 2,
}

SpellRegistry.rarity = {
    arrows = "common",
}

SpellRegistry.factions = {
    arrows = {"undead"},
}

SpellRegistry.spritePaths = {
    arrows = { front = "src/assets/arrows/arrows.png" },
}

SpellRegistry.descriptions = {
    arrows = "Arrows fall from the sky in a 3x3 area, dealing 2 damage to each enemy in range.",
}

SpellRegistry.displayNames = {
    arrows = "Arrows",
}

local _spriteCache = nil

function SpellRegistry.isSpell(t)
    return SpellRegistry.spellTypes[t] == true
end

function SpellRegistry.getAllSpellTypes()
    local types = {}
    for spellType, _ in pairs(SpellRegistry.spellTypes) do
        table.insert(types, spellType)
    end
    return types
end

local function loadImage(path)
    if not love.filesystem.getInfo(path) then return nil end
    local img = love.graphics.newImage(path)
    img:setFilter('nearest', 'nearest')
    return img
end

function SpellRegistry.loadSprites()
    if _spriteCache then return _spriteCache end
    _spriteCache = {}
    for spellType, paths in pairs(SpellRegistry.spritePaths) do
        local front = loadImage(paths.front)
        _spriteCache[spellType] = { front = front }
    end
    return _spriteCache
end

function SpellRegistry.getSprite(spellType)
    if not _spriteCache then SpellRegistry.loadSprites() end
    return _spriteCache[spellType]
end

return SpellRegistry
