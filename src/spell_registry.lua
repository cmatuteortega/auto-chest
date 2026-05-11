-- Spell Registry: parallel to UnitRegistry for spell-type cards.
-- Spells are placed on the grid like units but trigger once at battle start
-- (no health, no ongoing combat, no upgrades, no cell occupancy).

local SpellRegistry = {}

-- Set membership: SpellRegistry.spellTypes[t] is truthy if t is a spell.
SpellRegistry.spellTypes = {
    arrows   = true,
    fireball = true,
    rock     = true,
    quake    = true,
    horns    = true,
}

-- Cost in coins per spell type (mirrors UnitRegistry.unitCosts shape).
SpellRegistry.spellCosts = {
    arrows   = 2,
    fireball = 4,
    rock     = 3,
    quake    = 4,
    horns    = 3,
}

SpellRegistry.rarity = {
    arrows   = "common",
    fireball = "common",
    rock     = "common",
    quake    = "common",
    horns    = "common",
}

SpellRegistry.factions = {
    arrows   = {"undead"},
    fireball = {"folk"},
    rock     = {"monster"},
    quake    = {"monster"},
    horns    = {"folk"},
}

SpellRegistry.spritePaths = {
    arrows   = { front = "src/assets/arrows/arrows.png" },
    fireball = { front = "src/assets/fireball/fireball.png" },
    rock     = { front = "src/assets/rock/rock.png" },
    quake    = { front = "src/assets/quake/quake.png" },
    horns    = { front = "src/assets/horns/horns.png" },
}

SpellRegistry.descriptions = {
    arrows   = "Arrows fall from the sky in a 3x3 area, dealing 2 damage to each enemy in range.",
    fireball = "Hurls a fireball at one cell, dealing 5 damage and leaving a fire patch for 4 seconds.",
    rock     = "Spawns a boulder at the target cell, blocking movement and projectiles for the round. Displaces any unit there.",
    quake    = "Creates a 3x3 seismic zone for 5 seconds. Units inside move 50% slower and attack 20% slower.",
    horns    = "Trumpets buff all ally units in the target row with +25% attack speed for 5 seconds.",
}

-- Area-of-effect footprint per spell (cols x rows centered on the target cell).
SpellRegistry.aoeSize = {
    arrows   = { cols = 3, rows = 3 },
    fireball = { cols = 1, rows = 1 },
    rock     = { cols = 1, rows = 1 },
    quake    = { cols = 3, rows = 3 },
    horns    = { cols = 5, rows = 1 },
}

SpellRegistry.displayNames = {
    arrows   = "Arrows",
    fireball = "Fireball",
    rock     = "Rock",
    quake    = "Quake",
    horns    = "Horns",
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

local function loadFrameSequence(pattern, indices)
    local frames = {}
    for _, i in ipairs(indices) do
        local img = loadImage(pattern:format(i))
        if img then table.insert(frames, img) end
    end
    if #frames == 0 then return nil end
    return frames
end

function SpellRegistry.loadSprites()
    if _spriteCache then return _spriteCache end
    _spriteCache = {}
    for spellType, paths in pairs(SpellRegistry.spritePaths) do
        local front = loadImage(paths.front)
        _spriteCache[spellType] = { front = front }
    end
    -- Fireball flight frames (explosion frames now live in UnitRegistry's shared loader)
    if _spriteCache.fireball then
        _spriteCache.fireball.flightFrames = loadFrameSequence("src/assets/fireball/fireball%d.png", {1,2,3,4})
    end
    -- Quake ground-shake animation frames
    if _spriteCache.quake then
        _spriteCache.quake.frames = loadFrameSequence("src/assets/particles/quake/quake%d.png", {1,2,3,4,5})
    end
    -- Horns trumpet and note particle sprites
    if _spriteCache.horns then
        _spriteCache.horns.trumpet = loadImage("src/assets/particles/horns-particles/trumpet.png")
        local noteFrames = {
            loadImage("src/assets/particles/horns-particles/nota1.png"),
            loadImage("src/assets/particles/horns-particles/nota2.png"),
            loadImage("src/assets/particles/horns-particles/nota3.png"),
            loadImage("src/assets/particles/horns-particles/nota5.png"),
            loadImage("src/assets/particles/horns-particles/note4.png"),
        }
        local filtered = {}
        for _, f in ipairs(noteFrames) do
            if f then table.insert(filtered, f) end
        end
        _spriteCache.horns.noteFrames = filtered
    end
    return _spriteCache
end

function SpellRegistry.getSprite(spellType)
    if not _spriteCache then SpellRegistry.loadSprites() end
    return _spriteCache[spellType]
end

return SpellRegistry
