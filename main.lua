-- AutoChest - 1v1 Grid-Based Autobattler
-- Main entry point

-- Load libraries
local Push = require('lib.push')
local ScreenManager = require('lib.screen_manager')
local Constants = require('src.constants')

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

    -- Get safe area (excludes status bar / nav bar on Android & iOS)
    local safeX, safeY, safeW, safeH = 0, 0, windowWidth, windowHeight
    if love.window.getSafeArea then
        safeX, safeY, safeW, safeH = love.window.getSafeArea()
    end

    -- Calculate dynamic resolution based on safe area size
    Constants.updateResolution(safeW, safeH)

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

    -- Setup push scaled to the safe area; draw offset shifts canvas below status bar
    Push:setupScreen(
        Constants.GAME_WIDTH,    -- Virtual width
        Constants.GAME_HEIGHT,   -- Virtual height
        safeW,                   -- Safe area width (excludes system UI)
        safeH,                   -- Safe area height (excludes system UI)
        {
            fullscreen = false,
            resizable = true,
            pixelperfect = false,
            highdpi = false,
            canvas = true,
            stretched = true
        }
    )
    Push:setDrawOffset(safeX, safeY)

    -- Initialize screen manager with screen table
    local screens = {
        login   = LoginScreen,
        loading = LoadingScreen,
        menu    = MenuScreen,
        game    = GameScreen,
        lobby   = LobbyScreen,
    }
    local savedToken = love.filesystem.read("session.dat")
    local startScreen = (savedToken and #savedToken > 0) and 'loading' or 'login'
    ScreenManager.init(screens, startScreen)

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
    -- Get safe area (excludes status bar / nav bar on Android & iOS)
    local safeX, safeY, safeW, safeH = 0, 0, w, h
    if love.window.getSafeArea then
        safeX, safeY, safeW, safeH = love.window.getSafeArea()
    end

    -- Recalculate dynamic resolution for safe area size
    Constants.updateResolution(safeW, safeH)

    -- Reload fonts with new sizes (nearest filter for crisp pixel art)
    Fonts.large  = love.graphics.newFont("Pixellari.ttf", Constants.FONT_SIZES.LARGE)
    Fonts.medium = love.graphics.newFont("Pixellari.ttf", Constants.FONT_SIZES.MEDIUM)
    Fonts.small  = love.graphics.newFont("Pixellari.ttf", Constants.FONT_SIZES.SMALL)
    Fonts.tiny   = love.graphics.newFont("Pixellari.ttf", Constants.FONT_SIZES.TINY)
    Fonts.large:setFilter('nearest', 'nearest')
    Fonts.medium:setFilter('nearest', 'nearest')
    Fonts.small:setFilter('nearest', 'nearest')
    Fonts.tiny:setFilter('nearest', 'nearest')

    -- Update the virtual resolution canvas
    Push:setupScreen(
        Constants.GAME_WIDTH,
        Constants.GAME_HEIGHT,
        safeW, safeH,
        {
            fullscreen = false,
            resizable = true,
            pixelperfect = false,
            highdpi = false,
            canvas = true,
            stretched = true
        }
    )
    Push:setDrawOffset(safeX, safeY)

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

function love.quit()
    print("Goodbye!")
end
