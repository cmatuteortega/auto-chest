-- AutoChest - 1v1 Grid-Based Autobattler
-- Main entry point

-- Load libraries
local Push = require('lib.push')
local ScreenManager = require('lib.screen_manager')
local Constants = require('src.constants')

-- Load screens
local MenuScreen = require('src.screens.menu')
local GameScreen = require('src.screens.game')

-- Global fonts (loaded once, shared by all screens)
Fonts = {}

function love.load()
    -- Set default font filter to 'nearest' for crisp pixel art
    love.graphics.setDefaultFilter('nearest', 'nearest')

    -- Disable line smoothing for pixel-perfect rendering
    love.graphics.setLineStyle('rough')

    -- Load Pixellari font once globally
    Fonts.large = love.graphics.newFont("Pixellari.ttf", Constants.FONT_SIZES.LARGE)
    Fonts.medium = love.graphics.newFont("Pixellari.ttf", Constants.FONT_SIZES.MEDIUM)
    Fonts.small = love.graphics.newFont("Pixellari.ttf", Constants.FONT_SIZES.SMALL)
    Fonts.tiny = love.graphics.newFont("Pixellari.ttf", Constants.FONT_SIZES.TINY)

    -- Setup push for resolution scaling
    Push:setupScreen(
        Constants.GAME_WIDTH,    -- Game width (virtual resolution)
        Constants.GAME_HEIGHT,   -- Game height (virtual resolution)
        love.graphics.getWidth(),  -- Window width (actual)
        love.graphics.getHeight(), -- Window height (actual)
        {
            fullscreen = false,
            resizable = true,        -- Enable resizable window support
            pixelperfect = true,     -- Force integer scaling for crisp pixels
            highdpi = false,         -- Disable highdpi to prevent scaling issues
            canvas = true,
            stretched = false        -- Maintain aspect ratio (no distortion)
        }
    )

    -- Initialize screen manager with screen table
    local screens = {
        menu = MenuScreen,
        game = GameScreen
    }
    ScreenManager.init(screens, 'menu')

    print("AutoChest loaded!")
    print(string.format("Game Resolution: %dx%d", Constants.GAME_WIDTH, Constants.GAME_HEIGHT))
    print(string.format("Grid: %dx%d cells (%dpx cells)",
                       Constants.GRID_COLS, Constants.GRID_ROWS, Constants.CELL_SIZE))
end

function love.update(dt)
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

function love.resize(w, h)
    Push:resize(w, h)
end

function love.quit()
    print("Goodbye!")
end
