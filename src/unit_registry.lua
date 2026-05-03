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
local Migraine  = require('src.units.migraine')
local Bonk      = require('src.units.bonk')
local Sinner    = require('src.units.sinner')
local Tomb      = require('src.units.tomb')
local Clavicula = require('src.units.clavicula')
local Burrow    = require('src.units.burrow')
local Catapult  = require('src.units.catapult')
local Mend      = require('src.units.mend')
local Pouch     = require('src.units.pouch')
local Barrel    = require('src.units.barrel')
local Cart      = require('src.units.cart')
local Flint     = require('src.units.flint')
local Mason     = require('src.units.mason')

local SpellRegistry = require('src.spell_registry')

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
    migraine = Migraine,
    bonk   = Bonk,
    sinner = Sinner,
    tomb   = Tomb,
    clavicula = Clavicula,
    burrow   = Burrow,
    catapult = Catapult,
    mend   = Mend,
    pouch    = Pouch,
    barrel   = Barrel,
    cart     = Cart,
    flint    = Flint,
    mason    = Mason,
}

-- Unit groups for collection display
UnitRegistry.groups = {
    { name = "Calcium Clan", groupType = "skeleton", factionIcon = "undead",  units = {"boney", "marrow", "mend", "amalgam", "clavicula", "humerus", "migraine", "tomb", "arrows"} },
    { name = "Castle Crew",  groupType = "castle",   factionIcon = "folk",    units = {"knight", "marc", "mage", "bull", "samurai", "bonk", "sinner", "catapult", "fireball"} },
    { name = "Goblin Gang",  groupType = "goblin",   factionIcon = "monster", units = {"burrow", "pouch", "barrel", "cart", "flint", "mason"} },
}

-- Faction membership per unit type
UnitRegistry.factions = {
    boney     = {"undead", "brawler"},
    marrow    = {"undead", "marksman"},
    mend      = {"undead", "support"},
    amalgam   = {"undead", "monster"},
    clavicula = {"undead", "brawler"},
    migraine  = {"undead", "marksman"},
    humerus   = {"undead", "brawler"},
    tomb      = {"undead"},
    knight    = {"folk", "support"},
    mage      = {"folk", "marksman"},
    marc      = {"folk", "marksman"},
    samurai   = {"folk", "brawler"},
    bull      = {"folk", "monster"},
    bonk      = {"folk", "brawler"},
    sinner    = {"folk", "brawler"},
    catapult  = {"folk"},
    burrow    = {"monster", "brawler"},
    pouch     = {"monster", "marksman"},
    barrel    = {"monster", "brawler"},
    cart      = {"monster", "brawler"},
    flint     = {"monster", "marksman"},
    mason     = {"monster", "brawler"},
    -- Spells
    arrows    = {"undead"},
    fireball  = {"folk"},
}

-- Rarity per unit type: "common", "rare", "epic"
UnitRegistry.rarity = {
    -- Calcium Clan
    boney     = "common",
    marrow    = "common",
    mend    = "common",
    amalgam   = "common",
    -- Goblin Gang
    burrow    = "common",
    pouch     = "common",
    barrel    = "common",
    cart      = "common",
    flint     = "common",
    mason     = "common",
    clavicula = "rare",
    humerus   = "rare",
    migraine  = "epic",
    tomb      = "epic",
    -- Castle Crew
    knight    = "common",
    marc      = "common",
    mage      = "common",
    bull      = "common",
    samurai   = "rare",
    bonk      = "rare",
    sinner    = "epic",
    catapult  = "epic",
    -- Spells
    arrows    = "common",
    fireball  = "common",
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
    migraine = {
        front = "src/assets/migraine/front.png",
        back  = "src/assets/migraine/back.png",
        dead  = "src/assets/migraine/dead.png"
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
    },
    catapult = {
        front = "src/assets/catapult/front.png",
        back  = "src/assets/catapult/back.png",
        dead  = "src/assets/catapult/dead.png"
    },
    clavicula = {
        front = "src/assets/clavicula/front.png",
        back  = "src/assets/clavicula/back.png",
        dead  = "src/assets/clavicula/dead.png"
    },
    burrow = {
        front = "src/assets/burrow/front.png",
        back  = "src/assets/burrow/back.png",
        dead  = "src/assets/burrow/dead.png"
    },
    mend = {
        front = "src/assets/mend/front.png",
        back  = "src/assets/mend/back.png",
        dead  = "src/assets/mend/dead.png"
    },
    pouch = {
        front = "src/assets/pouch/front.png",
        back  = "src/assets/pouch/back.png",
        dead  = "src/assets/pouch/front.png"  -- no dead sprite yet; reuse front
    },
    barrel = {
        front = "src/assets/barrel/barrel/front.png",
        back  = "src/assets/barrel/barrel/back.png",
        dead  = "src/assets/barrel/barrel/front.png"  -- no dead sprite; reuse front
    },
    ["barrel-free"] = {
        front = "src/assets/barrel/barrel-free/front.png",
        back  = "src/assets/barrel/barrel-free/back.png",
        dead  = "src/assets/barrel/barrel-free/front.png"
    },
    cart = {
        front = "src/assets/cart/front.png",
        back  = "src/assets/cart/back.png",
        dead  = "src/assets/cart/front.png"  -- no dead sprite yet; reuse front
    },
    flint = {
        front = "src/assets/flint/front.png",
        back  = "src/assets/flint/back.png",
        dead  = "src/assets/flint/front.png"  -- no dead sprite yet; reuse front
    },
    mason = {
        front = "src/assets/mason/front.png",
        back  = "src/assets/mason/back.png",
        dead  = "src/assets/mason/front.png"  -- no dead sprite yet; reuse front
    }
}

-- Map of unit type names to their passive ability descriptions
UnitRegistry.passiveDescriptions = {
    knight = "Taunt all enemies in a 3x3 area in front for 3 seconds at battle start",
    boney = "Deal 2x damage when below 50% HP",
    samurai = "Deal 2x damage when no allies are within 2 cells",
    marrow = "Gain +0.2 attack speed per kill",
    marc = "Target furthest enemy in range (Sniper Focus)",
    bull = "Charges forward 4 tiles at battle start, stunning the first enemy hit",
    mage   = "Every 6 hits dealt or received, launches a fireball dealing AoE damage",
    amalgam  = "Cannot die to a single hit; surviving a lethal blow grants 1s invulnerability (10s cooldown)",
    humerus   = "Royal Command: allies attacking the same target gain +20% ATK",
    migraine  = "Every 8 hits (given or taken), spawns a copy at 50% HP (max 4 on screen)",
    bonk   = "Every 3rd hit deals triple damage.",
    sinner = "Every 20 hits (given or taken), breaks free: +ATK SPD and becomes stun immune",
    tomb   = "Friendly units stepping onto a corpse cell heal 2 HP",
    clavicula = "Every 10 hits (given or taken), spins and deals damage to all adjacent enemies, healing 50% of damage dealt",
    burrow   = "Burrows underground at battle start, reappearing 1s later at the mirrored cell across the field",
    mend   = "Every 6 hits given or received, heals the lowest HP ally for 2 HP",
    catapult = "At battle start, fires a projectile 4 rows forward dealing 3 damage in a cross. Leaves burning ground for 3s.",
    pouch    = "Always switches to a new in-range target. After 3 different targets in a row, the next throw is a heavy boulder that stuns for 1s.",
    barrel   = "Rolls forward at battle start until blocked by any unit or reaches the far row. Crash deals 3 damage to a hit enemy, then breaks open into a goblin.",
    cart     = "Twice as fast between cells. A fragile-looking minecart driven by two goblins; closes the gap and crashes into the front line first.",
    flint    = "Lobs bombs onto enemy cells. Bombs fuse for 1s before exploding for 2 damage and leaving a 1s fire patch — enemies that step out of the cell during the fuse take no damage.",
    mason    = "Throws rocks at adjacent enemies. At battle start, hurls a rock 4 rows forward that damages every enemy in its path for 5."
}

-- Returns display info for a unit type by reading it directly from a dummy
-- instance. Results are cached so each unit is only instantiated once.
local _displayInfoCache = {}

-- Sprite caches: populated on first load, reused on every subsequent call.
-- Eliminates redundant disk I/O + pixel-scanning when screens are recreated.
local _directionalSpriteCache = {}
local _allSpritesCache = nil
function UnitRegistry.getUnitDisplayInfo(unitType)
    if _displayInfoCache[unitType] then
        return _displayInfoCache[unitType]
    end

    if SpellRegistry.isSpell(unitType) then
        local info = {
            isSpell     = true,
            description = SpellRegistry.descriptions[unitType],
            displayName = SpellRegistry.displayNames[unitType],
            upgrades    = {},
        }
        _displayInfoCache[unitType] = info
        return info
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
    migraine  = 4,
    bonk   = 3,
    sinner = 4,
    tomb   = 1,
    clavicula = 4,
    burrow   = 3,
    catapult = 2,
    mend   = 3,
    pouch  = 3,
    barrel = 3,
    cart   = 4,
    flint  = 3,
    mason  = 4,
    -- Spells
    arrows   = 2,
    fireball = 4,
}

-- Count fully-transparent rows at the top of a sprite file.
local function trimTopRows(path)
    local data = love.image.newImageData(path)
    local w, h = data:getDimensions()
    local trim = 0
    for y = 0, h - 1 do
        local rowEmpty = true
        for x = 0, w - 1 do
            local a = select(4, data:getPixel(x, y))
            if a > 0.01 then rowEmpty = false; break end
        end
        if rowEmpty then trim = trim + 1 else break end
    end
    return trim
end

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

-- Units that only have legacy sprites (front/back/dead) — skip the filesystem probe
-- entirely so Android's APK zip filesystem cannot cause a false positive.
local LEGACY_ONLY_UNITS = {
    clavicula = true,
    tomb      = true,
    pouch     = true,
    barrel    = true,
    cart      = true,
    flint     = true,
    mason     = true,
}

-- Load directional sprites for a unit type (8-direction animation system).
-- Falls back to loadSprites() if no directional sprites exist for this unit.
-- Results are cached so each unit is only loaded from disk once per session.
function UnitRegistry.loadDirectionalSprites(unitType)
    if _directionalSpriteCache[unitType] then
        return _directionalSpriteCache[unitType]
    end

    local result

    if LEGACY_ONLY_UNITS[unitType] then
        result = UnitRegistry.loadSprites(unitType)
    else
        local basePath = "src/assets/" .. unitType .. "/"

        -- Probe: if idle_0_1.png absent, fall back to legacy system
        if not love.filesystem.getInfo(basePath .. "idle_0_1.png") then
            result = UnitRegistry.loadSprites(unitType)
        else

    -- Load legacy sprites as base (provides front/back/dead fallback + trimBottom)
    result = UnitRegistry.loadSprites(unitType)
    result.hasDirectionalSprites = true
    result.directional = {idle = {}, walk = {}, hit = {}}

    -- Scan numbered frames for a state+angle combo until a file is absent
    local function loadFrames(stateKey, angle)
        local frames, trims, trimTops = {}, {}, {}
        local i = 1
        while true do
            local path = basePath .. stateKey .. "_" .. angle .. "_" .. i .. ".png"
            if not love.filesystem.getInfo(path) then break end
            local img = love.graphics.newImage(path)
            img:setFilter('nearest', 'nearest')
            table.insert(frames, img)
            table.insert(trims, trimBottomRows(path))
            table.insert(trimTops, trimTopRows(path))
            i = i + 1
        end
        if #frames > 0 then
            result.directional[stateKey][angle] = {frames = frames, trimBottom = trims, trimTop = trimTops}
        end
    end

    -- Idle: directions 0° and 180°
    for _, angle in ipairs({0, 180}) do
        loadFrames("idle", angle)
    end

    -- Walk and hit (attack windup): 8 directions
    for _, angle in ipairs({0, 45, 90, 135, 180, 225, 270, 315}) do
        loadFrames("walk", angle)
        loadFrames("hit", angle)
    end

    -- Load action animation frames (battle-start one-shot) from action/ subfolder
    local actionBase = basePath .. "action/"
    if love.filesystem.getInfo(actionBase .. "action_0_1.png") then
        result.directional.action = {}
        result.directional.actionIdleOverride = {}
        local function loadActionFrames(destTable, angle)
            local frames, trims, trimTops = {}, {}, {}
            local i = 1
            while true do
                local path = actionBase .. "action_" .. angle .. "_" .. i .. ".png"
                if not love.filesystem.getInfo(path) then break end
                local img = love.graphics.newImage(path)
                img:setFilter('nearest', 'nearest')
                table.insert(frames, img)
                table.insert(trims, trimBottomRows(path))
                table.insert(trimTops, trimTopRows(path))
                i = i + 1
            end
            if #frames > 0 then
                destTable[angle] = {frames = frames, trimBottom = trims, trimTop = trimTops}
            end
        end
        local function loadActionIdleFrames(destTable, angle)
            local frames, trims, trimTops = {}, {}, {}
            local i = 1
            while true do
                local path = actionBase .. "idle_" .. angle .. "_" .. i .. ".png"
                if not love.filesystem.getInfo(path) then break end
                local img = love.graphics.newImage(path)
                img:setFilter('nearest', 'nearest')
                table.insert(frames, img)
                table.insert(trims, trimBottomRows(path))
                table.insert(trimTops, trimTopRows(path))
                i = i + 1
            end
            if #frames > 0 then
                destTable[angle] = {frames = frames, trimBottom = trims, trimTop = trimTops}
            end
        end
        for _, angle in ipairs({0, 180}) do
            loadActionFrames(result.directional.action, angle)
            loadActionIdleFrames(result.directional.actionIdleOverride, angle)
        end
    end

    -- Load background animation frames if a background-anim/ folder exists
    local bgFrames = {}
    local i = 1
    while true do
        local path = basePath .. "background-anim/background-" .. i .. ".png"
        if not love.filesystem.getInfo(path) then break end
        local img = love.graphics.newImage(path)
        img:setFilter('nearest', 'nearest')
        table.insert(bgFrames, img)
        i = i + 1
    end
    if #bgFrames > 0 then
        result.bgAnimFrames = bgFrames
    end

        end -- close: directional path else
    end -- close: non-legacy else

    _directionalSpriteCache[unitType] = result
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
        frontTrimBottom = trimBottomRows(paths.front),
        backTrimBottom  = trimBottomRows(paths.back),
        deadTrimBottom  = trimBottomRows(paths.dead),
        frontTrimTop    = trimTopRows(paths.front),
        backTrimTop     = trimTopRows(paths.back),
        deadTrimTop     = trimTopRows(paths.dead),
    }
end

-- Incremental sprite loader. `getLoadSteps()` returns a list of closures that
-- can be executed one per frame while a splash screen draws a progress bar.
-- After running all steps, call `finalizeSprites()` to wire up the cross-unit
-- shared sprites (particles, projectiles, faction icons). `loadAllSprites()`
-- stays as a convenience wrapper for tests/desktop offline paths.

local _loadingAllSprites = nil  -- built progressively by getLoadSteps()

local function loadSharedStunFrames()
    local frames = {}
    for i = 1, 3 do
        local path = "src/assets/particles/stun-" .. i .. ".png"
        if love.filesystem.getInfo(path) then
            local img = love.graphics.newImage(path)
            img:setFilter('nearest', 'nearest')
            table.insert(frames, img)
        end
    end
    return frames
end

local function loadSharedTauntImg()
    local path = "src/assets/particles/taunt.png"
    if love.filesystem.getInfo(path) then
        local img = love.graphics.newImage(path)
        img:setFilter('nearest', 'nearest')
        return img
    end
end

local function loadSharedUpFrames()
    local frames = {}
    for i = 1, 6 do
        local path = "src/assets/particles/up-" .. i .. ".png"
        if love.filesystem.getInfo(path) then
            local img = love.graphics.newImage(path)
            img:setFilter('nearest', 'nearest')
            table.insert(frames, img)
        end
    end
    return frames
end

local function loadProjectileImg(path)
    if love.filesystem.getInfo(path) then
        local img = love.graphics.newImage(path)
        img:setFilter('nearest', 'nearest')
        return img
    end
end

local function loadFrameSequence(pattern, maxFrames)
    local frames = {}
    for i = 1, maxFrames do
        local path = pattern:format(i)
        if love.filesystem.getInfo(path) then
            local img = love.graphics.newImage(path)
            img:setFilter('nearest', 'nearest')
            table.insert(frames, img)
        end
    end
    return frames
end

-- Shared buffers populated during steps, consumed by finalizeSprites().
local _shared = nil

local function resetShared()
    _shared = {
        stunFrames       = nil,
        tauntImg         = nil,
        upFrames         = nil,
        arrowImg         = nil,
        magicImg         = nil,
        fireballFrames   = nil,
        fireFrames       = nil,
        explosionFrames  = nil,
        migraineBgFrames = nil,
        catapultProjImg  = nil,
        fuseFrames       = nil,
        rockFrames       = nil,
        rockBreakFrames  = nil,
    }
end

-- Load a sequence of frames whose suffix indices come from a table (e.g. {0,1,2,...}).
-- Different from loadFrameSequence (which is 1..maxFrames) — needed for explosion0..6.
local function loadFrameIndices(pattern, indices)
    local frames = {}
    for _, i in ipairs(indices) do
        local path = pattern:format(i)
        if love.filesystem.getInfo(path) then
            local img = love.graphics.newImage(path)
            img:setFilter('nearest', 'nearest')
            table.insert(frames, img)
        end
    end
    return frames
end

-- Returns an ordered list of closures. Executing all of them in sequence
-- populates `_loadingAllSprites` and the `_shared` buffers. Call finalizeSprites()
-- afterwards to commit to the cache and wire up shared assets.
function UnitRegistry.getLoadSteps()
    if _allSpritesCache then
        -- Already loaded; return a single no-op step so callers don't crash.
        return { function() end }
    end

    _loadingAllSprites = {}
    resetShared()

    local steps = {}

    -- One step per unit type (the heavy bulk — sprite PNGs + pixel trim scans)
    for unitType, _ in pairs(UnitRegistry.unitClasses) do
        table.insert(steps, function()
            _loadingAllSprites[unitType] = UnitRegistry.loadDirectionalSprites(unitType)
        end)
    end

    -- Sinner free-form + marrow lance (both small, single-sprite bundles)
    table.insert(steps, function()
        if _loadingAllSprites["sinner"] then
            _loadingAllSprites["sinner"].freeForm = UnitRegistry.loadSprites("sinner-free")
        end
        if _loadingAllSprites["barrel"] then
            _loadingAllSprites["barrel"].freeForm = UnitRegistry.loadSprites("barrel-free")
        end
        local lancePath = "src/assets/particles/lance.png"
        if love.filesystem.getInfo(lancePath) and _loadingAllSprites["marrow"] then
            local lanceImg = love.graphics.newImage(lancePath)
            lanceImg:setFilter('nearest', 'nearest')
            _loadingAllSprites["marrow"].lance = lanceImg
        end
    end)

    -- Shared particle frames
    table.insert(steps, function()
        _shared.stunFrames = loadSharedStunFrames()
        _shared.tauntImg   = loadSharedTauntImg()
        _shared.upFrames   = loadSharedUpFrames()
    end)

    -- Projectiles + fireball/fire shared frames
    table.insert(steps, function()
        _shared.arrowImg = loadProjectileImg("src/assets/particles/arrow.png")
        _shared.magicImg = loadProjectileImg("src/assets/particles/magic-projectile.png")
        _shared.fireballFrames = loadFrameSequence("src/assets/particles/fireball-%d.png", 4)
        _shared.fireFrames     = loadFrameSequence("src/assets/particles/fire-%d.png", 5)
    end)

    -- Migraine background animation + catapult projectile
    table.insert(steps, function()
        _shared.migraineBgFrames = loadFrameSequence("src/assets/migraine/background-anim/background-%d.png", 8)
        _shared.catapultProjImg  = loadProjectileImg("src/assets/particles/catapult-projectile.png")
        _shared.explosionFrames  = loadFrameIndices("src/assets/particles/explosion/explosion%d.png", {0,1,2,3,4,5,6})
        _shared.fuseFrames       = loadFrameSequence("src/assets/particles/fuse/fuse%d.png", 4)
        _shared.rockFrames       = loadFrameSequence("src/assets/particles/rock/rock%d.png", 4)
        _shared.rockBreakFrames  = loadFrameSequence("src/assets/particles/rock/break%d.png", 2)
    end)

    -- Generic death animations (played by Grid:drawCorpsesInRow for any fallen unit, 0-indexed).
    -- Two variants: enemy-perspective frames (death/) and ally-perspective frames (death-ally/).
    table.insert(steps, function()
        local function loadDeathSequence(pattern)
            local frames = {}
            for i = 0, 16 do
                local path = string.format(pattern, i)
                if love.filesystem.getInfo(path) then
                    local img = love.graphics.newImage(path)
                    img:setFilter('nearest', 'nearest')
                    table.insert(frames, img)
                end
            end
            return frames
        end
        _shared.deathFrames     = loadDeathSequence("src/assets/death/death-anim%d.png")
        _shared.deathAllyFrames = loadDeathSequence("src/assets/death-ally/death-ally%d.png")
    end)

    -- Cell spawn / despawn effects (played when a board cell changes between setup and battle).
    table.insert(steps, function()
        local function loadAnimSequence(pattern)
            local frames = {}
            for i = 0, 31 do
                local path = string.format(pattern, i)
                if love.filesystem.getInfo(path) then
                    local img = love.graphics.newImage(path)
                    img:setFilter('nearest', 'nearest')
                    table.insert(frames, img)
                end
            end
            return frames
        end
        _shared.spawnFrames   = loadAnimSequence("src/assets/spawn/spawn%d.png")
        _shared.despawnFrames = loadAnimSequence("src/assets/despawn/despawn%d.png")
    end)

    -- Faction icons
    table.insert(steps, function()
        UnitRegistry.factionIcons = {}
        local factionNames = {"brawler", "folk", "marksman", "monster", "support", "undead"}
        for _, fname in ipairs(factionNames) do
            local path = "src/assets/factions/" .. fname .. ".png"
            if love.filesystem.getInfo(path) then
                local icon = love.graphics.newImage(path)
                icon:setFilter("nearest", "nearest")
                UnitRegistry.factionIcons[fname] = icon
            end
        end
    end)

    return steps
end

-- Wire up the shared assets onto the unit sprite tables and commit the cache.
-- Must be called after all getLoadSteps() closures have been executed.
function UnitRegistry.finalizeSprites()
    if _allSpritesCache then return _allSpritesCache end
    local allSprites = _loadingAllSprites or {}

    if _shared then
        if (_shared.stunFrames and #_shared.stunFrames > 0) or _shared.tauntImg or (_shared.upFrames and #_shared.upFrames > 0) or (_shared.explosionFrames and #_shared.explosionFrames > 0) then
            for _, sprites in pairs(allSprites) do
                if _shared.stunFrames and #_shared.stunFrames > 0 then sprites.stunFrames = _shared.stunFrames end
                if _shared.tauntImg                              then sprites.tauntImg   = _shared.tauntImg   end
                if _shared.upFrames and #_shared.upFrames > 0    then sprites.upFrames   = _shared.upFrames   end
                if _shared.explosionFrames and #_shared.explosionFrames > 0 then sprites.explosionFrames = _shared.explosionFrames end
            end
        end

        for _, unitType in ipairs({"marc", "marrow", "mend"}) do
            if _shared.arrowImg and allSprites[unitType] then
                allSprites[unitType].projectile = _shared.arrowImg
            end
        end
        for _, unitType in ipairs({"migraine", "mage"}) do
            if _shared.magicImg and allSprites[unitType] then
                allSprites[unitType].projectile = _shared.magicImg
                allSprites[unitType].projectileAngleOffset = math.pi / 2
            end
        end

        if _shared.fireballFrames and #_shared.fireballFrames > 0 and allSprites["mage"] then
            allSprites["mage"].fireballFrames = _shared.fireballFrames
        end

        if _shared.fireFrames and #_shared.fireFrames > 0 then
            for _, unitType in ipairs({"mage", "catapult", "migraine", "bull", "flint"}) do
                if allSprites[unitType] then
                    allSprites[unitType].fireFrames = _shared.fireFrames
                end
            end
        end

        if _shared.fuseFrames and #_shared.fuseFrames > 0 and allSprites["flint"] then
            allSprites["flint"].fuseFrames = _shared.fuseFrames
        end

        if _shared.rockFrames and #_shared.rockFrames > 0 and allSprites["mason"] then
            allSprites["mason"].rockFrames = _shared.rockFrames
        end
        if _shared.rockBreakFrames and #_shared.rockBreakFrames > 0 and allSprites["mason"] then
            allSprites["mason"].rockBreakFrames = _shared.rockBreakFrames
        end

        if _shared.migraineBgFrames and #_shared.migraineBgFrames > 0 and allSprites["migraine"] then
            allSprites["migraine"].bgAnimFrames = _shared.migraineBgFrames
        end

        if _shared.catapultProjImg and allSprites["catapult"] then
            allSprites["catapult"].catapultProjectile = _shared.catapultProjImg
        end
        if _shared.catapultProjImg and allSprites["pouch"] then
            allSprites["pouch"].catapultProjectile = _shared.catapultProjImg
        end

        if _shared.deathFrames then
            UnitRegistry.deathFrames = _shared.deathFrames
        end
        if _shared.deathAllyFrames then
            UnitRegistry.deathAllyFrames = _shared.deathAllyFrames
        end
        if _shared.spawnFrames then
            UnitRegistry.spawnFrames = _shared.spawnFrames
        end
        if _shared.despawnFrames then
            UnitRegistry.despawnFrames = _shared.despawnFrames
        end
    end

    _allSpritesCache = allSprites
    _loadingAllSprites = nil
    _shared = nil
    return allSprites
end

-- Convenience wrapper: executes all load steps serially then finalizes.
-- Used by desktop offline paths / tests that don't need the splash UI.
function UnitRegistry.loadAllSprites()
    if _allSpritesCache then
        return _allSpritesCache
    end
    local steps = UnitRegistry.getLoadSteps()
    for _, step in ipairs(steps) do step() end
    return UnitRegistry.finalizeSprites()
end

-- Create a unit of the specified type
function UnitRegistry.createUnit(unitType, row, col, owner, sprites)
    if SpellRegistry.isSpell(unitType) then
        error("createUnit called for spell type: " .. tostring(unitType))
    end
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

-- ── Progression constants ────────────────────────────────────────────────

-- Units every new player starts with (2 copies each)
UnitRegistry.starterUnits = { "boney", "marrow", "knight", "marc" }
UnitRegistry.STARTER_COPIES = 2

-- Max copies of a single unit a player can own via progression
UnitRegistry.MAX_CARD_COPIES = 4

-- Rarity tiers for milestone unlock ordering (commons exhausted first, then rares, then epics)
UnitRegistry.rarityTiers = {
    { tier = "common", units = { "mend", "amalgam", "mage", "bull" } },
    { tier = "common", units = { "burrow", "pouch", "barrel", "cart", "flint", "mason", "arrows", "fireball" } },
    { tier = "rare",   units = { "samurai", "bonk", "clavicula", "humerus" } },
    { tier = "epic",   units = { "migraine", "tomb", "sinner", "catapult" } },
}

return UnitRegistry
