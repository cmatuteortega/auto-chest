-- AudioManager – Solar2D port (replaces Love2D love.audio version)
--
-- Key differences from Love2D version:
--   • audio.loadStream()  instead of love.audio.newSource(..., "stream")
--   • audio.loadSound()   instead of love.audio.newSource(..., "static")
--   • audio.play()        returns a channel handle; volume is per-channel
--   • No real-time audio filters → setBattleMode() is a no-op (pre-export a
--     filtered OST variant if the effect is needed)
--   • Overlapping SFX: pre-load N copies instead of source:clone()

local audio = require("audio")
local json  = require("lib.json")

local AM = {
    musicEnabled  = true,
    sfxEnabled    = true,
    _music        = nil,    -- stream handle
    _musicChannel = nil,    -- channel currently playing music on
    _taps         = {},     -- 3 preloaded sound handles for UI taps
    _sfx          = {},     -- cache: filename → sound handle
    _battleMode   = false,
    _wasMusicPlaying = false,
}

local MUSIC_CHANNEL = 1
local SETTINGS_FILE = "settings.json"

-- ── Persistence ───────────────────────────────────────────────────────────────

local function loadSettings()
    local data = _G.readFile(SETTINGS_FILE)
    if not data then return end
    local ok, t = pcall(json.decode, data)
    if ok and type(t) == "table" then
        if t.music ~= nil then AM.musicEnabled = t.music end
        if t.sfx   ~= nil then AM.sfxEnabled   = t.sfx   end
    end
end

function AM.save()
    local ok, data = pcall(json.encode, {music = AM.musicEnabled, sfx = AM.sfxEnabled})
    if ok then _G.writeFile(SETTINGS_FILE, data) end
end

-- ── Init ──────────────────────────────────────────────────────────────────────

function AM.init()
    loadSettings()

    -- Streaming source for OST (saves memory for long track)
    AM._music = audio.loadStream("src/audio/ost.mp3")

    -- Pre-load tap SFX (3 variants)
    for i = 1, 3 do
        AM._taps[i] = audio.loadSound("src/audio/tap" .. i .. ".mp3")
    end
end

-- ── Music ─────────────────────────────────────────────────────────────────────

function AM.playMusic()
    if not AM.musicEnabled then return end
    if not AM._music then return end
    if audio.isChannelActive(MUSIC_CHANNEL) then return end

    AM._musicChannel = audio.play(AM._music, {
        channel = MUSIC_CHANNEL,
        loops   = -1,           -- loop forever
    })
    audio.setVolume(0.2, { channel = MUSIC_CHANNEL })
end

function AM.stopMusic()
    if audio.isChannelActive(MUSIC_CHANNEL) then
        audio.stop(MUSIC_CHANNEL)
    end
end

-- ── Battle mode ───────────────────────────────────────────────────────────────
-- Solar2D has no real-time audio filters.
-- To replicate the Love2D low-pass effect, export a pre-filtered OST variant
-- (e.g. "src/audio/ost_battle.mp3") and swap the stream here.

function AM.setBattleMode(enabled)
    if AM._battleMode == enabled then return end
    AM._battleMode = enabled
    -- No-op until a filtered OST variant is available.
    -- TODO: swap stream to "src/audio/ost_battle.mp3" when enabled
end

-- ── SFX ───────────────────────────────────────────────────────────────────────

function AM.playTap()
    if not AM.sfxEnabled then return end
    local src = AM._taps[math.random(1, 3)]
    if src then
        -- Find a free channel (channels 2-8 reserved for SFX)
        local ch = audio.findFreeChannel(2)
        if ch then
            audio.play(src, { channel = ch })
            audio.setVolume(1.0, { channel = ch })
        end
    end
end

function AM.playSFX(name, volume)
    if not AM.sfxEnabled then return end
    if not AM._sfx[name] then
        AM._sfx[name] = audio.loadSound("src/audio/" .. name)
    end
    local src = AM._sfx[name]
    if src then
        local ch = audio.findFreeChannel(2)
        if ch then
            audio.play(src, { channel = ch })
            audio.setVolume(volume or 0.5, { channel = ch })
        end
    end
end

-- ── Focus / background handling (replaces love.focus callbacks) ───────────────
-- main.lua wires these to the "system" Runtime event.

function AM.pauseAll()
    AM._wasMusicPlaying = audio.isChannelActive(MUSIC_CHANNEL)
    audio.pause(MUSIC_CHANNEL)
end

function AM.resumeAll()
    if AM._wasMusicPlaying and AM.musicEnabled then
        audio.resume(MUSIC_CHANNEL)
    end
    AM._wasMusicPlaying = false
end

-- ── Toggle helpers ────────────────────────────────────────────────────────────

function AM.setMusic(enabled)
    AM.musicEnabled = enabled
    AM.save()
    if enabled then
        AM.playMusic()
    else
        AM.stopMusic()
    end
end

function AM.setSFX(enabled)
    AM.sfxEnabled = enabled
    AM.save()
end

return AM
