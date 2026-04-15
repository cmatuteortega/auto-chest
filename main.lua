-- AutoChest – Solar2D entry point (replaces Love2D main.lua)
-- Solar2D calls this file automatically after config.lua is processed.

-- ── Display setup ─────────────────────────────────────────────────────────────
display.setStatusBar(display.HiddenStatusBar)
display.setDefault("minTextureFilter", "nearest")  -- crisp pixel art scaling
display.setDefault("magTextureFilter", "nearest")

-- ── Core modules ──────────────────────────────────────────────────────────────
local composer     = require("composer")
local Constants    = require("src.constants")
AudioManager       = require("src.audio_manager")   -- global: screens reference it without require
local UnitRegistry = require("src.unit_registry")
local json         = require("lib.json")

-- ── File I/O helpers (replaces love.filesystem) ───────────────────────────────
-- Exposed globally so screens can use them without re-requiring.

function _G.readFile(name)
    local path = system.pathForFile(name, system.DocumentsDirectory)
    local f = io.open(path, "r")
    if not f then return nil end
    local data = f:read("*a")
    f:close()
    return data
end

function _G.writeFile(name, data)
    local path = system.pathForFile(name, system.DocumentsDirectory)
    local f = io.open(path, "w")
    if not f then return end
    f:write(data)
    f:close()
end

function _G.fileExists(name)
    local path = system.pathForFile(name, system.DocumentsDirectory)
    local f = io.open(path, "r")
    if f then f:close(); return true end
    return false
end

function _G.deleteFile(name)
    local path = system.pathForFile(name, system.DocumentsDirectory)
    os.remove(path)
end

-- ── Resolution & safe area ────────────────────────────────────────────────────
-- Solar2D content scaling (config.lua letterBox) already handles the virtual
-- resolution, so GAME_WIDTH/GAME_HEIGHT stay at 540×960.
-- We still call updateResolution so Constants.CELL_SIZE, SCALE, etc. are set.
Constants.updateResolution(display.contentWidth, display.contentHeight)

-- Safe area insets (notch / home-bar avoidance)
Constants.SAFE_INSET_TOP    = display.safeScreenOriginY
Constants.SAFE_INSET_LEFT   = display.safeScreenOriginX
Constants.SAFE_INSET_BOTTOM = display.contentHeight
                              - (display.safeScreenOriginY + display.safeActualContentHeight)
Constants.SAFE_INSET_RIGHT  = display.contentWidth
                              - (display.safeScreenOriginX + display.safeActualContentWidth)

-- ── Global font descriptors (replaces love.graphics.newFont) ─────────────────
-- Solar2D accepts a TTF filename + size directly in display.newText().
-- Screens reference Fonts.small.name / Fonts.small.size instead of a font object.
Fonts = {
    large  = { name = "Pixellari.ttf", size = Constants.FONT_SIZES.LARGE  },
    medium = { name = "Pixellari.ttf", size = Constants.FONT_SIZES.MEDIUM },
    small  = { name = "Pixellari.ttf", size = Constants.FONT_SIZES.SMALL  },
    tiny   = { name = "Pixellari.ttf", size = Constants.FONT_SIZES.TINY   },
}

-- ── Device ID (replaces love.filesystem device_id.dat) ───────────────────────
local storedId = _G.readFile("device_id.dat")
if storedId then storedId = storedId:match("^%s*(.-)%s*$") end

if storedId and #storedId == 32 then
    _G.DeviceId = storedId
else
    local chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
    local id = ""
    for _ = 1, 32 do
        local idx = math.random(1, #chars)
        id = id .. chars:sub(idx, idx)
    end
    _G.DeviceId = id
    _G.writeFile("device_id.dat", id)
end

-- ── Sprite preload ────────────────────────────────────────────────────────────
UnitRegistry.loadAllSprites()

-- ── Audio init ────────────────────────────────────────────────────────────────
AudioManager.init()

-- ── App lifecycle (replaces love.focus) ──────────────────────────────────────
Runtime:addEventListener("system", function(event)
    if event.type == "applicationSuspend" then
        AudioManager.pauseAll()
    elseif event.type == "applicationResume" then
        AudioManager.resumeAll()
    end
end)

-- ── Navigate to first screen ──────────────────────────────────────────────────
local tutorialDone = _G.fileExists("tutorial_done.dat")
local savedToken   = _G.readFile("session.dat")

if not tutorialDone then
    -- First launch: show tutorial (offline game)
    composer.gotoScene("src.screens.game", {
        params = {
            isOnline  = false,
            playerRole = 1,
            socket    = nil,
            isSandbox = false,
            isTutorial = true,
        }
    })
elseif savedToken and #savedToken > 0 then
    composer.gotoScene("src.screens.loading")
else
    composer.gotoScene("src.screens.login")
end
