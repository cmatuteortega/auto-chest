-- AutoChest - 1v1 Grid-Based Autobattler
-- Main entry point

-- Load libraries
local Push = require('lib.push')
local ScreenManager = require('lib.screen_manager')
local Constants = require('src.constants')
require('lib.audio')  -- overrides love.audio.play/stop with source-tracking wrappers

-- Global audio manager (music + SFX)
AudioManager = require('src.audio_manager')

local UnitRegistry = require('src.unit_registry')

-- Load screens
local LoginScreen   = require('src.screens.login')
local LoadingScreen = require('src.screens.loading')
local MenuScreen    = require('src.screens.menu')
local GameScreen    = require('src.screens.game')
local LobbyScreen   = require('src.screens.lobby')

-- Global fonts (loaded once, shared by all screens)
Fonts = {}

-- Resize debouncing
local resizeTimer = 0
local resizeDelay = 0.1  -- Wait 0.1 seconds after resize stops before applying changes
local pendingResize = nil
local lastWidth, lastHeight = 0, 0  -- Track last applied size

function love.load()
    -- Set default filter to 'nearest' for crisp pixel art
    love.graphics.setDefaultFilter('nearest', 'nearest')

    -- Disable line smoothing for pixel-perfect rendering
    love.graphics.setLineStyle('rough')

    -- Get window dimensions
    local windowWidth = love.graphics.getWidth()
    local windowHeight = love.graphics.getHeight()

    -- Get safe area insets (for UI margin safety on mobile)
    local safeX, safeY, safeW, safeH = 0, 0, windowWidth, windowHeight
    if love.window.getSafeArea then
        safeX, safeY, safeW, safeH = love.window.getSafeArea()
    end

    -- Use FULL window for rendering (edge-to-edge, no gaps on any device)
    Constants.updateResolution(windowWidth, windowHeight)

    -- Load Pixellari font once globally with scaled sizes
    -- Filter set to 'nearest' so pixel-art glyphs stay crisp (no bilinear blur)
    Fonts.large  = love.graphics.newFont("Pixellari.ttf", Constants.FONT_SIZES.LARGE)
    Fonts.medium = love.graphics.newFont("Pixellari.ttf", Constants.FONT_SIZES.MEDIUM)
    Fonts.small  = love.graphics.newFont("Pixellari.ttf", Constants.FONT_SIZES.SMALL)
    Fonts.tiny   = love.graphics.newFont("Pixellari.ttf", Constants.FONT_SIZES.TINY)
    Fonts.large:setFilter('nearest', 'nearest')
    Fonts.medium:setFilter('nearest', 'nearest')
    Fonts.small:setFilter('nearest', 'nearest')
    Fonts.tiny:setFilter('nearest', 'nearest')

    -- Initialize audio (loads sources, reads settings.json)
    AudioManager.init()

    -- Render to the full window (edge-to-edge); safe insets used only for UI margins
    local isMobile = love.system.getOS() == "Android" or love.system.getOS() == "iOS"
    Push:setupScreen(
        Constants.GAME_WIDTH,    -- Virtual width
        Constants.GAME_HEIGHT,   -- Virtual height
        windowWidth,             -- Full window width (edge-to-edge)
        windowHeight,            -- Full window height (edge-to-edge)
        {
            fullscreen = isMobile,
            resizable = not isMobile,
            pixelperfect = false,
            highdpi = false,
            canvas = true,
            stretched = true
        }
    )

    -- Store safe insets in virtual coordinates for UI elements near edges
    Constants.updateSafeInsets(safeX, safeY, safeW, safeH, windowWidth, windowHeight)

    -- Load or generate a permanent per-device UUID (survives logout, never cleared)
    local storedDeviceId = love.filesystem.read("device_id.dat")
    if storedDeviceId then
        storedDeviceId = storedDeviceId:match("^%s*(.-)%s*$")
    end
    if storedDeviceId and #storedDeviceId == 32 then
        _G.DeviceId = storedDeviceId
    else
        local chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
        local id = ""
        for _ = 1, 32 do
            id = id .. chars:sub(math.random(1, #chars), math.random(1, #chars))
        end
        _G.DeviceId = id
        love.filesystem.write("device_id.dat", id)
    end

    -- Preload all sprites once at startup so screen transitions are instant.
    -- Subsequent calls in menu/lobby/game screens return from cache immediately.
    UnitRegistry.loadAllSprites()

    -- Initialize screen manager with screen table
    local screens = {
        login   = LoginScreen,
        loading = LoadingScreen,
        menu    = MenuScreen,
        game    = GameScreen,
        lobby   = LobbyScreen,
    }
    -- First-time detection: if tutorial_done.dat doesn't exist, show tutorial before login.
    local tutorialDone = love.filesystem.getInfo("tutorial_done.dat")
    if not tutorialDone then
        -- Start game in tutorial mode (isOnline=false, playerRole=1, socket=nil, isSandbox=false, isTutorial=true)
        ScreenManager.init(screens, 'game', false, 1, false, false, true)
    else
        local savedToken = love.filesystem.read("session.dat")
        local startScreen = (savedToken and #savedToken > 0) and 'loading' or 'login'
        ScreenManager.init(screens, startScreen)
    end

    -- Track initial size
    lastWidth = windowWidth
    lastHeight = windowHeight

    print("AutoChest loaded!")
    print(string.format("Window: %dx%d", windowWidth, windowHeight))
    print(string.format("Virtual Resolution: %dx%d", Constants.GAME_WIDTH, Constants.GAME_HEIGHT))
    print(string.format("Grid: %dx%d cells (%dpx cells)",
                       Constants.GRID_COLS, Constants.GRID_ROWS, Constants.CELL_SIZE))
    print(string.format("Scale: %.2f", Constants.SCALE))
end

function love.update(dt)
    -- Handle debounced resize
    if pendingResize then
        resizeTimer = resizeTimer + dt
        if resizeTimer >= resizeDelay then
            local w, h = pendingResize.w, pendingResize.h
            pendingResize = nil
            resizeTimer = 0

            -- Only apply if size actually changed
            if w ~= lastWidth or h ~= lastHeight then
                applyResize(w, h)
                lastWidth = w
                lastHeight = h
            end
        end
    end

    love.audio.update()
    ScreenManager.update(dt)
end

function love.draw()
    -- Draw background color to fill entire window (before Push starts)
    love.graphics.clear(Constants.COLORS.BACKGROUND)

    -- Start rendering to push's virtual resolution
    Push:start()

    -- Draw current screen
    ScreenManager.draw()

    -- Finish rendering
    Push:finish()
end

-- Input callbacks
function love.mousemoved(x, y, dx, dy, istouch)
    x, y = Push:toGame(x, y)
    if x and y then
        ScreenManager.mousemoved(x, y, dx, dy, istouch)
    end
end

function love.mousepressed(x, y, button, istouch, presses)
    x, y = Push:toGame(x, y)
    if x and y then
        ScreenManager.mousepressed(x, y, button, istouch, presses)
    end
end

function love.mousereleased(x, y, button, istouch, presses)
    x, y = Push:toGame(x, y)
    if x and y then
        ScreenManager.mousereleased(x, y, button, istouch, presses)
    end
end

function love.touchmoved(id, x, y, dx, dy, pressure)
    x, y = Push:toGame(x, y)
    if x and y then
        ScreenManager.touchmoved(id, x, y, dx, dy, pressure)
    end
end

function love.touchpressed(id, x, y, dx, dy, pressure)
    x, y = Push:toGame(x, y)
    if x and y then
        ScreenManager.touchpressed(id, x, y, dx, dy, pressure)
    end
end

function love.touchreleased(id, x, y, dx, dy, pressure)
    x, y = Push:toGame(x, y)
    if x and y then
        ScreenManager.touchreleased(id, x, y, dx, dy, pressure)
    end
end

function love.textinput(t)
    ScreenManager.textinput(t)
end

function love.keypressed(key, scancode, isrepeat)
    -- Global keyboard shortcuts
    if key == 'f11' or (key == 'return' and love.keyboard.isDown('lalt', 'ralt')) then
        -- Toggle fullscreen with F11 or Alt+Enter
        Push:switchFullscreen()
        return
    end

    ScreenManager.keypressed(key, scancode, isrepeat)
end

function love.keyreleased(key, scancode)
    ScreenManager.keyreleased(key, scancode)
end

-- Apply resize (debounced)
function applyResize(w, h)
    -- Get safe area insets (for UI margin safety on mobile)
    local safeX, safeY, safeW, safeH = 0, 0, w, h
    if love.window.getSafeArea then
        safeX, safeY, safeW, safeH = love.window.getSafeArea()
    end

    -- Use FULL window for rendering (edge-to-edge)
    Constants.updateResolution(w, h)

    -- Reload fonts with new sizes (nearest filter for crisp pixel art)
    Fonts.large  = love.graphics.newFont("Pixellari.ttf", Constants.FONT_SIZES.LARGE)
    Fonts.medium = love.graphics.newFont("Pixellari.ttf", Constants.FONT_SIZES.MEDIUM)
    Fonts.small  = love.graphics.newFont("Pixellari.ttf", Constants.FONT_SIZES.SMALL)
    Fonts.tiny   = love.graphics.newFont("Pixellari.ttf", Constants.FONT_SIZES.TINY)
    Fonts.large:setFilter('nearest', 'nearest')
    Fonts.medium:setFilter('nearest', 'nearest')
    Fonts.small:setFilter('nearest', 'nearest')
    Fonts.tiny:setFilter('nearest', 'nearest')

    -- Render to the full window (edge-to-edge)
    local isMobile = love.system.getOS() == "Android" or love.system.getOS() == "iOS"
    Push:setupScreen(
        Constants.GAME_WIDTH,
        Constants.GAME_HEIGHT,
        w, h,
        {
            fullscreen = isMobile,
            resizable = not isMobile,
            pixelperfect = false,
            highdpi = false,
            canvas = true,
            stretched = true
        }
    )

    -- Store safe insets in virtual coordinates for UI elements near edges
    Constants.updateSafeInsets(safeX, safeY, safeW, safeH, w, h)

    print(string.format("Resized to: %dx%d (Virtual: %dx%d, Scale: %.2f)",
                       w, h, Constants.GAME_WIDTH, Constants.GAME_HEIGHT, Constants.SCALE))
end

function love.resize(w, h)
    -- Ignore resize events that don't actually change the size
    if w == lastWidth and h == lastHeight then
        return
    end

    -- Debounce the heavy operations (font loading, recalculation)
    pendingResize = {w = w, h = h}
    resizeTimer = 0
end

function love.focus(focus)
    ScreenManager.focus(focus)
    if not focus then
        -- App going to background: pause audio immediately
        AudioManager.pauseAll()
    else
        -- App returning to foreground: resume audio
        AudioManager.resumeAll()
    end
end

function love.quit()
    print("Goodbye!")
end
