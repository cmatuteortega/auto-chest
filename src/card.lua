local Class = require('lib.classic')
local Constants = require('src.constants')

local Card = Class:extend()

function Card:new(x, y, cardSprite, index, unitType)
    self.x = x
    self.y = y
    self.startX = x  -- Original position for snap-back
    self.startY = y
    self.cardSprite = cardSprite
    self.index = index
    self.unitType = unitType or "unknown"  -- Type of unit this card will spawn

    -- Card dimensions (scaled proportionally based on screen size)
    self.width = 80 * Constants.SCALE
    self.height = 100 * Constants.SCALE

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

    -- Scaled values
    local cornerRadius = 4 * Constants.SCALE
    local borderWidth = 2 * Constants.SCALE
    local namePadding = 4 * Constants.SCALE
    local spriteYOffset = 24 * Constants.SCALE

    -- Card background
    if self.isDragging then
        lg.setColor(0.3, 0.3, 0.4, 0.9)
    else
        lg.setColor(0.2, 0.2, 0.3, 1)
    end
    lg.rectangle('fill', self.x, self.y, self.width, self.height, cornerRadius, cornerRadius)

    -- Card border
    lg.setColor(0.4, 0.4, 0.5, 1)
    lg.setLineWidth(borderWidth)
    lg.rectangle('line', self.x, self.y, self.width, self.height, cornerRadius, cornerRadius)

    -- Card name (capitalize first letter) - at the top
    lg.setFont(Fonts.tiny)
    lg.setColor(0.8, 0.8, 0.8, 1)
    local displayName = self.unitType:sub(1, 1):upper() .. self.unitType:sub(2)
    lg.printf(displayName, self.x, self.y + namePadding, self.width, 'center')

    -- Draw sprite in center of card (scaled proportionally with integer scale for crisp pixels)
    lg.setColor(1, 1, 1, 1)
    local spriteScale = math.max(1, math.floor(3 * Constants.SCALE))
    local spriteWidth = self.cardSprite:getWidth()
    local spriteHeight = self.cardSprite:getHeight()
    local spriteX = math.floor(self.x + (self.width - spriteWidth * spriteScale) / 2)
    local spriteY = math.floor(self.y + spriteYOffset)
    lg.draw(self.cardSprite, spriteX, spriteY, 0, spriteScale, spriteScale)
end

return Card
