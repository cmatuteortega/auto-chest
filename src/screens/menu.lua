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
        local sc = Constants.SCALE

        -- Calculate proportional spacing
        local centerY = Constants.GAME_HEIGHT / 2
        local titleOffset    = 110 * sc
        local subtitleOffset =  60 * sc

        -- Title
        lg.setFont(Fonts.large)
        lg.setColor(1, 1, 1, 1)
        lg.printf(self.title, 0, centerY - titleOffset,
                  Constants.GAME_WIDTH, 'center')

        -- Subtitle
        lg.setFont(Fonts.medium)
        lg.setColor(0.7, 0.7, 0.7, 1)
        lg.printf(self.subtitle, 0, centerY - subtitleOffset,
                  Constants.GAME_WIDTH, 'center')

        -- ── Buttons ──────────────────────────────────────────────────────────
        local btnW  = 220 * sc
        local btnH  = 54  * sc
        local gap   = 20  * sc
        local totalH = btnH * 2 + gap
        local btnX  = (Constants.GAME_WIDTH - btnW) / 2
        local btn1Y = centerY - totalH / 2 + 20 * sc
        local btn2Y = btn1Y + btnH + gap

        -- Local button
        local mx, my = self.mouseX or 0, self.mouseY or 0
        local localHover = mx >= btnX and mx <= btnX + btnW
                        and my >= btn1Y and my <= btn1Y + btnH
        lg.setColor(localHover and {0.3, 0.6, 0.3, 1} or {0.2, 0.45, 0.2, 1})
        lg.rectangle('fill', btnX, btn1Y, btnW, btnH, 8 * sc, 8 * sc)
        lg.setFont(Fonts.medium)
        lg.setColor(1, 1, 1, 1)
        lg.printf("JUGAR LOCAL", btnX, btn1Y + (btnH - Fonts.medium:getHeight()) / 2,
                  btnW, 'center')

        -- Online button
        local onlineHover = mx >= btnX and mx <= btnX + btnW
                         and my >= btn2Y and my <= btn2Y + btnH
        lg.setColor(onlineHover and {0.2, 0.4, 0.7, 1} or {0.15, 0.3, 0.6, 1})
        lg.rectangle('fill', btnX, btn2Y, btnW, btnH, 8 * sc, 8 * sc)
        lg.setColor(1, 1, 1, 1)
        lg.printf("JUGAR ONLINE", btnX, btn2Y + (btnH - Fonts.medium:getHeight()) / 2,
                  btnW, 'center')

        self._btnX  = btnX;  self._btn1Y = btn1Y; self._btn2Y = btn2Y
        self._btnW  = btnW;  self._btnH  = btnH
    end

    function self:mousemoved(x, y)
        self.mouseX = x
        self.mouseY = y
    end

    function self:touchmoved(id, x, y) self.mouseX = x; self.mouseY = y end
    function self:mousereleased() end
    function self:touchreleased() end

    function self:_handleClick(x, y)
        local ScreenManager = require('lib.screen_manager')
        local bx, bw, bh = self._btnX or 0, self._btnW or 0, self._btnH or 0
        local b1y = self._btn1Y or 0
        local b2y = self._btn2Y or 0

        if x >= bx and x <= bx + bw then
            if y >= b1y and y <= b1y + bh then
                ScreenManager.switch('game')
            elseif y >= b2y and y <= b2y + bh then
                ScreenManager.switch('lobby')
            end
        end
    end

    function self:mousepressed(x, y, button)
        if button == 1 then self:_handleClick(x, y) end
    end

    function self:touchpressed(id, x, y, dx, dy, pressure)
        self:_handleClick(x, y)
    end

    return self
end

return MenuScreen
