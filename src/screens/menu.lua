local Screen = require('lib.screen')
local Constants = require('src.constants')

local MenuScreen = {}

function MenuScreen.new()
    local self = Screen.new()

    function self:init()
        self.title = "AutoChest"
        self.subtitle = "1v1 Autobattler"
        print("MenuScreen initialized!")
    end

    function self:draw()
        local lg = love.graphics

        -- Title
        lg.setFont(Fonts.large)
        lg.setColor(1, 1, 1, 1)
        lg.printf(self.title, 0, Constants.GAME_HEIGHT / 2 - 100,
                  Constants.GAME_WIDTH, 'center')

        -- Subtitle
        lg.setFont(Fonts.medium)
        lg.setColor(0.7, 0.7, 0.7, 1)
        lg.printf(self.subtitle, 0, Constants.GAME_HEIGHT / 2 - 50,
                  Constants.GAME_WIDTH, 'center')

        -- Instruction
        lg.setFont(Fonts.small)
        lg.setColor(0.5, 0.5, 0.5, 1)
        lg.printf("Click anywhere to start", 0, Constants.GAME_HEIGHT / 2 + 50,
                  Constants.GAME_WIDTH, 'center')
    end

    function self:mousepressed(x, y, button)
        if button == 1 then
            -- Switch to game screen
            local ScreenManager = require('lib.screen_manager')
            ScreenManager.switch('game')
        end
    end

    function self:touchpressed(id, x, y, dx, dy, pressure)
        -- Same as mouse pressed for touch devices
        self:mousepressed(x, y, 1)
    end

    return self
end

return MenuScreen
