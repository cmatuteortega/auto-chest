local Class = require("lib.classic")
local Constants = require("src.constants")

local Tooltip = Class:extend()

function Tooltip:new()
    self.visible = false
    self.unit = nil

    -- Base dimensions (will be scaled)
    self.baseWidth = 147
    self.basePadding = 12

    -- Styling
    self.backgroundColor = {0.1, 0.1, 0.15, 0.95}
    self.borderColor = {0.4, 0.4, 0.5, 1}
    self.textColor = {1, 1, 1, 1}
    self.baseBorderWidth = 2
    self.baseCornerRadius = 8
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

    -- Calculate scaled dimensions
    local width = self.baseWidth * Constants.SCALE
    local padding = self.basePadding * Constants.SCALE
    local borderWidth = self.baseBorderWidth * Constants.SCALE
    local cornerRadius = self.baseCornerRadius * Constants.SCALE

    -- Prepare text content
    local unitName = self:capitalize(self.unit.unitType)
    local passiveDescription = self:getPassiveDescription(self.unit.unitType)

    -- Calculate text dimensions
    local textWidth = width - padding * 2

    -- Calculate wrapped text height for description
    love.graphics.setFont(Fonts.tiny)
    local _, descriptionLines = Fonts.tiny:getWrap(passiveDescription, textWidth)
    local descriptionHeight = #descriptionLines * Fonts.tiny:getHeight()

    -- Calculate total height needed (scaled)
    local nameHeight = Fonts.small:getHeight()
    local separatorSpace = 8 * Constants.SCALE
    local descriptionMargin = 6 * Constants.SCALE
    local hintHeight = Fonts.tiny:getHeight()
    local hintMargin = 8 * Constants.SCALE

    local height = padding + nameHeight + separatorSpace +
                   descriptionHeight + descriptionMargin +
                   hintHeight + hintMargin + padding

    -- Get unit's screen position
    local unitX = Constants.GRID_OFFSET_X + (self.unit.col - 1) * Constants.CELL_SIZE
    local unitY = Constants.GRID_OFFSET_Y + (self.unit.row - 1) * Constants.CELL_SIZE
    local unitCenterX = unitX + Constants.CELL_SIZE / 2
    local unitCenterY = unitY + Constants.CELL_SIZE / 2

    -- Use virtual game resolution
    local screenWidth = Constants.GAME_WIDTH
    local screenHeight = Constants.GAME_HEIGHT

    -- Spacing between unit and tooltip (scaled)
    local spacing = 16 * Constants.SCALE
    local screenMargin = 10 * Constants.SCALE

    -- Calculate position to the right or left of the unit
    local x, y

    -- Check if there's more space on the right or left
    local spaceOnRight = screenWidth - (unitX + Constants.CELL_SIZE)
    local spaceOnLeft = unitX

    if spaceOnRight >= width + spacing then
        -- Position to the right
        x = unitX + Constants.CELL_SIZE + spacing
    elseif spaceOnLeft >= width + spacing then
        -- Position to the left
        x = unitX - width - spacing
    else
        -- Not enough space on either side, position on the side with more space
        if spaceOnRight > spaceOnLeft then
            x = unitX + Constants.CELL_SIZE + spacing
            -- Clamp to screen bounds
            if x + width > screenWidth then
                x = screenWidth - width - screenMargin
            end
        else
            x = unitX - width - spacing
            -- Clamp to screen bounds
            if x < 0 then
                x = screenMargin
            end
        end
    end

    -- Vertically center the tooltip with the unit
    y = unitCenterY - height / 2

    -- Clamp y to screen bounds
    if y < screenMargin then
        y = screenMargin
    elseif y + height > screenHeight - screenMargin then
        y = screenHeight - height - screenMargin
    end

    -- Draw background with rounded corners
    love.graphics.setColor(self.backgroundColor)
    love.graphics.rectangle("fill", x, y, width, height, cornerRadius)

    -- Draw border
    love.graphics.setColor(self.borderColor)
    love.graphics.setLineWidth(borderWidth)
    love.graphics.rectangle("line", x, y, width, height, cornerRadius)

    -- Draw unit name (title)
    love.graphics.setColor(self.textColor)
    love.graphics.setFont(Fonts.small)
    local nameY = y + padding
    love.graphics.printf(unitName, x + padding, nameY, textWidth, "center")

    -- Draw separator line
    local separatorY = nameY + nameHeight + (4 * Constants.SCALE)
    love.graphics.setColor(self.borderColor)
    love.graphics.setLineWidth(1 * Constants.SCALE)
    love.graphics.line(x + padding, separatorY, x + width - padding, separatorY)

    -- Draw passive description with word wrap (no label)
    local descriptionY = separatorY + separatorSpace + descriptionMargin
    love.graphics.setColor(self.textColor)
    love.graphics.setFont(Fonts.tiny)
    love.graphics.printf(passiveDescription, x + padding, descriptionY, textWidth, "left")

    -- Draw tap hint at bottom
    love.graphics.setFont(Fonts.tiny)
    love.graphics.setColor(0.7, 0.7, 0.7, 1)
    local hintY = y + height - padding - hintHeight
    love.graphics.printf("Tap to close", x + padding, hintY, textWidth, "center")
end

function Tooltip:capitalize(str)
    return str:sub(1, 1):upper() .. str:sub(2)
end

function Tooltip:getPassiveDescription(unitType)
    local UnitRegistry = require("src.unit_registry")
    return UnitRegistry.passiveDescriptions[unitType] or "No passive ability"
end

return Tooltip
