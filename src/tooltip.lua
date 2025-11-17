local Class = require("lib.classic")

local Tooltip = Class:extend()

function Tooltip:new()
    self.visible = false
    self.unit = nil

    -- Fixed width, dynamic height (33% less wide: 220 * 0.67 ≈ 147)
    self.width = 147
    self.padding = 12

    -- Styling
    self.backgroundColor = {0.1, 0.1, 0.15, 0.95}
    self.borderColor = {0.4, 0.4, 0.5, 1}
    self.textColor = {1, 1, 1, 1}
    self.borderWidth = 2
    self.cornerRadius = 8
end

function Tooltip:show(unit)
    self.visible = true
    self.unit = unit
end

function Tooltip:hide()
    self.visible = false
    self.unit = nil
end

function Tooltip:toggle(unit)
    -- If clicking the same unit, toggle off
    if self.visible and self.unit == unit then
        self:hide()
    else
        self:show(unit)
    end
end

function Tooltip:isVisible()
    return self.visible
end

function Tooltip:draw()
    if not self.visible or not self.unit then
        return
    end

    local Constants = require("src.constants")

    -- Prepare text content
    local unitName = self:capitalize(self.unit.unitType)
    local passiveDescription = self:getPassiveDescription(self.unit.unitType)

    -- Calculate text dimensions
    local textWidth = self.width - self.padding * 2

    -- Calculate wrapped text height for description
    love.graphics.setFont(Fonts.tiny)
    local _, descriptionLines = Fonts.tiny:getWrap(passiveDescription, textWidth)
    local descriptionHeight = #descriptionLines * Fonts.tiny:getHeight()

    -- Calculate total height needed
    local nameHeight = 24  -- Fonts.small height
    local separatorSpace = 8
    local descriptionMargin = 6
    local hintHeight = 16  -- Fonts.tiny height
    local hintMargin = 8

    local height = self.padding + nameHeight + separatorSpace +
                   descriptionHeight + descriptionMargin +
                   hintHeight + hintMargin + self.padding

    -- Get unit's screen position
    local unitX = Constants.GRID_OFFSET_X + (self.unit.col - 1) * Constants.CELL_SIZE
    local unitY = Constants.GRID_OFFSET_Y + (self.unit.row - 1) * Constants.CELL_SIZE
    local unitCenterX = unitX + Constants.CELL_SIZE / 2
    local unitCenterY = unitY + Constants.CELL_SIZE / 2

    local screenWidth = love.graphics.getWidth()
    local screenHeight = love.graphics.getHeight()

    -- Spacing between unit and tooltip
    local spacing = 16

    -- Calculate position to the right or left of the unit
    local x, y

    -- Check if there's more space on the right or left
    local spaceOnRight = screenWidth - (unitX + Constants.CELL_SIZE)
    local spaceOnLeft = unitX

    if spaceOnRight >= self.width + spacing then
        -- Position to the right
        x = unitX + Constants.CELL_SIZE + spacing
    elseif spaceOnLeft >= self.width + spacing then
        -- Position to the left
        x = unitX - self.width - spacing
    else
        -- Not enough space on either side, position on the side with more space
        if spaceOnRight > spaceOnLeft then
            x = unitX + Constants.CELL_SIZE + spacing
            -- Clamp to screen bounds
            if x + self.width > screenWidth then
                x = screenWidth - self.width - 10
            end
        else
            x = unitX - self.width - spacing
            -- Clamp to screen bounds
            if x < 0 then
                x = 10
            end
        end
    end

    -- Vertically center the tooltip with the unit
    y = unitCenterY - height / 2

    -- Clamp y to screen bounds
    if y < 10 then
        y = 10
    elseif y + height > screenHeight - 10 then
        y = screenHeight - height - 10
    end

    -- Draw background with rounded corners
    love.graphics.setColor(self.backgroundColor)
    love.graphics.rectangle("fill", x, y, self.width, height, self.cornerRadius)

    -- Draw border
    love.graphics.setColor(self.borderColor)
    love.graphics.setLineWidth(self.borderWidth)
    love.graphics.rectangle("line", x, y, self.width, height, self.cornerRadius)

    -- Draw unit name (title)
    love.graphics.setColor(self.textColor)
    love.graphics.setFont(Fonts.small)
    local nameY = y + self.padding
    love.graphics.printf(unitName, x + self.padding, nameY, textWidth, "center")

    -- Draw separator line
    local separatorY = nameY + nameHeight + 4
    love.graphics.setColor(self.borderColor)
    love.graphics.setLineWidth(1)
    love.graphics.line(x + self.padding, separatorY, x + self.width - self.padding, separatorY)

    -- Draw passive description with word wrap (no label)
    local descriptionY = separatorY + separatorSpace + descriptionMargin
    love.graphics.setColor(self.textColor)
    love.graphics.setFont(Fonts.tiny)
    love.graphics.printf(passiveDescription, x + self.padding, descriptionY, textWidth, "left")

    -- Draw tap hint at bottom
    love.graphics.setFont(Fonts.tiny)
    love.graphics.setColor(0.7, 0.7, 0.7, 1)
    local hintY = y + height - self.padding - hintHeight
    love.graphics.printf("Tap to close", x + self.padding, hintY, textWidth, "center")
end

function Tooltip:capitalize(str)
    return str:sub(1, 1):upper() .. str:sub(2)
end

function Tooltip:getPassiveDescription(unitType)
    local UnitRegistry = require("src.unit_registry")
    return UnitRegistry.passiveDescriptions[unitType] or "No passive ability"
end

return Tooltip
