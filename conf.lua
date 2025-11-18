function love.conf(t)
    t.identity = "autochest"
    t.version = "11.4"
    t.console = false
    t.accelerometerjoystick = true
    t.externalstorage = false
    t.gammacorrect = false

    t.audio.mic = false
    t.audio.mixwithsystem = true

    t.window.title = "AutoChest"
    t.window.icon = nil
    t.window.width = 540  -- Default window width
    t.window.height = 960 -- Default window height
    t.window.borderless = false
    t.window.resizable = true  -- Enable window resizing on desktop
    t.window.minwidth = 270    -- Minimum width (half of base)
    t.window.minheight = 480   -- Minimum height (half of base)
    t.window.fullscreen = false
    t.window.fullscreentype = "desktop"
    t.window.vsync = 1
    t.window.msaa = 0
    t.window.depth = nil
    t.window.stencil = nil
    t.window.display = 1
    t.window.highdpi = false     -- Disable for pixel-perfect rendering
    t.window.usedpiscale = false -- Disable DPI scaling for crisp pixels
    t.window.x = nil
    t.window.y = nil

    -- Mobile orientation (portrait mode lock)
    if love.system then
        t.window.orientation = "portrait"  -- Lock to portrait on mobile devices
    end

    t.modules.audio = true
    t.modules.data = true
    t.modules.event = true
    t.modules.font = true
    t.modules.graphics = true
    t.modules.image = true
    t.modules.joystick = true
    t.modules.keyboard = true
    t.modules.math = true
    t.modules.mouse = true
    t.modules.physics = false
    t.modules.sound = true
    t.modules.system = true
    t.modules.thread = true
    t.modules.timer = true
    t.modules.touch = true
    t.modules.video = false
    t.modules.window = true
end
