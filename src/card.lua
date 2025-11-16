local Class = require('lib.classic')
local Constants = require('src.constants')

local Card = Class:extend()

function Card:new(x, y, cardSprite, index)
    self.x = x
    self.y = y
    self.startX = x  -- Original position for snap-back
    self.startY = y
    self.cardSprite = cardSprite
    self.index = index

    -- Card dimensions (scaled up for better visibility)
    self.width = 80
    self.height = 100

    -- Drag state
    self.isDragging = false
    self.dragOffsetX = 0
    self.dragOffsetY = 0
end

function Card:startDrag(mouseX, mouseY)
    self.isDragging = true
    self.dragOffsetX = mouseX - self.x
    self.dragOffsetY = mouseY - self.y
end

function Card:updateDrag(mouseX, mouseY)
    if self.isDragging then
        self.x = mouseX - self.dragOffsetX
        self.y = mouseY - self.dragOffsetY
    end
end

function Card:stopDrag()
    self.isDragging = false
end

function Card:snapBack()
    self.x = self.startX
    self.y = self.startY
end

function Card:contains(mouseX, mouseY)
    return mouseX >= self.x and mouseX <= self.x + self.width and
           mouseY >= self.y and mouseY <= self.y + self.height
end

function Card:draw()
    local lg = love.graphics

    -- Card background
    if self.isDragging then
        lg.setColor(0.3, 0.3, 0.4, 0.9)
    else
        lg.setColor(0.2, 0.2, 0.3, 1)
    end
    lg.rectangle('fill', self.x, self.y, self.width, self.height, 4, 4)

    -- Card border
    lg.setColor(0.4, 0.4, 0.5, 1)
    lg.setLineWidth(2)
    lg.rectangle('line', self.x, self.y, self.width, self.height, 4, 4)

    -- Draw sprite in center of card (scaled up)
    lg.setColor(1, 1, 1, 1)
    local spriteScale = 3  -- 16x16 -> 48x48 (larger for visibility)
    local spriteX = self.x + (self.width - 16 * spriteScale) / 2
    local spriteY = self.y + 12
    lg.draw(self.cardSprite, spriteX, spriteY, 0, spriteScale, spriteScale)

    -- Card name placeholder
    lg.setFont(Fonts.tiny)
    lg.setColor(0.8, 0.8, 0.8, 1)
    lg.printf("Unit", self.x, self.y + self.height - 24, self.width, 'center')
end

return Card
