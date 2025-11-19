local Class = require("lib.classic")
local Constants = require("src.constants")

local Tooltip = Class:extend()

function Tooltip:new()
    self.visible = false
    self.unit = nil
    self.card = nil  -- Track if showing a card tooltip
    self.hasMatchingCard = false  -- Track if player has a matching card in hand

    -- Base dimensions (will be scaled)
    self.baseWidth = 200
    self.basePadding = 10

    -- Styling
    self.backgroundColor = {0.1, 0.1, 0.15, 0.95}
    self.borderColor = {0.4, 0.4, 0.5, 1}
    self.textColor = {1, 1, 1, 1}
    self.baseBorderWidth = 2
    self.baseCornerRadius = 8

    -- Upgrade button tracking
    self.upgradeButtons = {}  -- {index, x, y, width, height}
end

function Tooltip:show(unit, hasMatchingCard)
    self.visible = true
    self.unit = unit
    self.card = nil  -- Clear card when showing unit
    self.hasMatchingCard = hasMatchingCard or false
end

function Tooltip:showCard(card)
    self.visible = true
    self.unit = nil  -- Clear unit when showing card
    self.card = card
    self.hasMatchingCard = false
end

function Tooltip:hide()
    self.visible = false
    self.unit = nil
    self.card = nil
    self.hasMatchingCard = false
    self.upgradeButtons = {}
end

function Tooltip:toggle(unit, hasMatchingCard)
    -- If clicking the same unit, toggle off
    if self.visible and self.unit == unit then
        self:hide()
    else
        self:show(unit, hasMatchingCard)
    end
end

function Tooltip:isVisible()
    return self.visible
end

function Tooltip:draw()
    if not self.visible then
        return
    end

    -- Draw card tooltip if showing a card
    if self.card then
        self:drawCardTooltip()
        return
    end

    -- Otherwise draw unit tooltip
    if not self.unit then
        return
    end

    -- Calculate scaled dimensions
    local width = self.baseWidth * Constants.SCALE
    local padding = self.basePadding * Constants.SCALE
    local borderWidth = self.baseBorderWidth * Constants.SCALE
    local cornerRadius = self.baseCornerRadius * Constants.SCALE

    -- Prepare text content
    local unitName = self:capitalize(self.unit.unitType) .. " Lv" .. self.unit.level
    local passiveDescription = self:getPassiveDescription(self.unit.unitType)

    -- Calculate text dimensions
    local textWidth = width - padding * 2
    local nameHeight = Fonts.small:getHeight()
    local separatorSpace = 6 * Constants.SCALE
    local hintHeight = Fonts.tiny:getHeight()
    local hintMargin = 6 * Constants.SCALE

    -- Check if unit has upgrade tree
    local hasUpgradeTree = self.unit.upgradeTree and #self.unit.upgradeTree > 0

    local height
    local contentY  -- Track current Y position for content

    -- Always calculate height with passive + upgrade buttons
    love.graphics.setFont(Fonts.tiny)
    local _, passiveLines = Fonts.tiny:getWrap(passiveDescription, textWidth)
    local passiveHeight = #passiveLines * Fonts.tiny:getHeight()
    local passiveMargin = 6 * Constants.SCALE

    local upgradeButtonHeight = 0
    local upgradeSpacing = 4 * Constants.SCALE

    if hasUpgradeTree then
        -- Calculate total height needed for all upgrade buttons
        for i = 1, 3 do
            if self.unit.upgradeTree[i] then
                local upgrade = self.unit.upgradeTree[i]
                local _, descLines = Fonts.tiny:getWrap(upgrade.description, textWidth - (12 * Constants.SCALE))
                local buttonHeight = (3 * Constants.SCALE) + Fonts.tiny:getHeight() + (2 * Constants.SCALE) + (#descLines * Fonts.tiny:getHeight()) + (3 * Constants.SCALE)
                upgradeButtonHeight = upgradeButtonHeight + buttonHeight + upgradeSpacing
            end
        end
    end

    height = padding + nameHeight + separatorSpace + passiveHeight + passiveMargin + upgradeButtonHeight + hintHeight + hintMargin + padding

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
        x = unitX + Constants.CELL_SIZE + spacing
    elseif spaceOnLeft >= width + spacing then
        x = unitX - width - spacing
    else
        if spaceOnRight > spaceOnLeft then
            x = unitX + Constants.CELL_SIZE + spacing
            if x + width > screenWidth then
                x = screenWidth - width - screenMargin
            end
        else
            x = unitX - width - spacing
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

    contentY = separatorY + separatorSpace

    -- Draw passive description
    love.graphics.setColor(self.textColor)
    love.graphics.setFont(Fonts.tiny)
    love.graphics.printf(passiveDescription, x + padding, contentY, textWidth, "left")
    contentY = contentY + passiveHeight + passiveMargin

    -- Draw upgrade options (always show, but grayed out when no matching card)
    if hasUpgradeTree then
        self.upgradeButtons = {}  -- Reset button tracking

        love.graphics.setFont(Fonts.tiny)

        for i = 1, 3 do
            if self.unit.upgradeTree[i] then
                local upgrade = self.unit.upgradeTree[i]
                local isActive = self.unit:hasUpgrade(i)
                local canAfford = self.unit.level < 2 and self.hasMatchingCard

                -- Calculate button height
                local _, descLines = Fonts.tiny:getWrap(upgrade.description, textWidth - (12 * Constants.SCALE))
                local buttonHeight = (3 * Constants.SCALE) + Fonts.tiny:getHeight() + (2 * Constants.SCALE) + (#descLines * Fonts.tiny:getHeight()) + (3 * Constants.SCALE)

                local buttonX = x + padding
                local buttonY = contentY
                local buttonWidth = textWidth

                -- Store button bounds for click detection (only if can afford and not already active)
                if canAfford and not isActive then
                    table.insert(self.upgradeButtons, {
                        index = i,
                        x = buttonX,
                        y = buttonY,
                        width = buttonWidth,
                        height = buttonHeight
                    })
                end

                -- Draw button background
                if isActive then
                    -- Active upgrade: green tint
                    love.graphics.setColor(0.2, 0.5, 0.2, 0.5)
                elseif canAfford then
                    -- Available upgrade: slightly highlighted
                    love.graphics.setColor(0.2, 0.2, 0.3, 0.5)
                else
                    -- Cannot afford (no card or max level): grayed out
                    love.graphics.setColor(0.15, 0.15, 0.15, 0.3)
                end
                love.graphics.rectangle("fill", buttonX, buttonY, buttonWidth, buttonHeight, (3 * Constants.SCALE))

                -- Draw button border
                if isActive then
                    love.graphics.setColor(0.3, 0.7, 0.3, 1)
                elseif canAfford then
                    love.graphics.setColor(0.4, 0.4, 0.5, 1)
                else
                    love.graphics.setColor(0.25, 0.25, 0.25, 1)
                end
                love.graphics.setLineWidth(1 * Constants.SCALE)
                love.graphics.rectangle("line", buttonX, buttonY, buttonWidth, buttonHeight, (3 * Constants.SCALE))

                -- Draw upgrade name with checkmark if active
                local nameText = upgrade.name
                if isActive then
                    nameText = "✓ " .. nameText
                end

                if isActive then
                    love.graphics.setColor(1, 1, 1, 1)
                elseif canAfford then
                    love.graphics.setColor(1, 1, 1, 1)
                else
                    love.graphics.setColor(0.4, 0.4, 0.4, 1)
                end
                love.graphics.print(nameText, buttonX + (3 * Constants.SCALE), buttonY + (3 * Constants.SCALE))

                -- Draw upgrade description
                local descY = buttonY + (3 * Constants.SCALE) + Fonts.tiny:getHeight() + (2 * Constants.SCALE)
                if isActive then
                    love.graphics.setColor(0.9, 0.9, 0.9, 1)
                elseif canAfford then
                    love.graphics.setColor(0.8, 0.8, 0.8, 1)
                else
                    love.graphics.setColor(0.4, 0.4, 0.4, 1)
                end
                love.graphics.printf(upgrade.description, buttonX + (6 * Constants.SCALE), descY, textWidth - (12 * Constants.SCALE), "left")

                contentY = contentY + buttonHeight + upgradeSpacing
            end
        end
    end

    -- Draw tap hint at bottom
    love.graphics.setFont(Fonts.tiny)
    love.graphics.setColor(0.5, 0.5, 0.5, 1)
    local hintY = y + height - padding - hintHeight
    if self.hasMatchingCard and self.unit.level < 2 then
        love.graphics.printf("Tap upgrade to select", x + padding, hintY, textWidth, "center")
    else
        love.graphics.printf("Tap to close", x + padding, hintY, textWidth, "center")
    end
end

function Tooltip:capitalize(str)
    return str:sub(1, 1):upper() .. str:sub(2)
end

function Tooltip:getPassiveDescription(unitType)
    local UnitRegistry = require("src.unit_registry")
    return UnitRegistry.passiveDescriptions[unitType] or "No passive ability"
end

-- Check if a click position hits an upgrade button
-- Returns the upgrade index (1, 2, or 3) if clicked, nil otherwise
function Tooltip:checkUpgradeClick(x, y)
    if not self.visible or not self.hasMatchingCard then
        return nil
    end

    for _, button in ipairs(self.upgradeButtons) do
        if x >= button.x and x <= button.x + button.width and
           y >= button.y and y <= button.y + button.height then
            return button.index
        end
    end

    return nil
end

function Tooltip:drawCardTooltip()
    -- Calculate scaled dimensions
    local width = self.baseWidth * Constants.SCALE
    local padding = self.basePadding * Constants.SCALE
    local borderWidth = self.baseBorderWidth * Constants.SCALE
    local cornerRadius = self.baseCornerRadius * Constants.SCALE

    -- Prepare text content
    local unitName = self:capitalize(self.card.unitType)
    local passiveDescription = self:getPassiveDescription(self.card.unitType)

    -- Calculate text dimensions
    local textWidth = width - padding * 2
    local nameHeight = Fonts.small:getHeight()
    local separatorSpace = 6 * Constants.SCALE
    local hintHeight = Fonts.tiny:getHeight()
    local hintMargin = 6 * Constants.SCALE

    -- Calculate passive description height
    love.graphics.setFont(Fonts.tiny)
    local _, passiveLines = Fonts.tiny:getWrap(passiveDescription, textWidth)
    local passiveHeight = #passiveLines * Fonts.tiny:getHeight()
    local passiveMargin = 6 * Constants.SCALE

    -- Calculate total height
    local height = padding + nameHeight + separatorSpace + passiveHeight + passiveMargin + hintHeight + hintMargin + padding

    -- Get card's screen position (center of card)
    local cardCenterX = self.card.x + (80 * Constants.SCALE) / 2
    local cardCenterY = self.card.y + (100 * Constants.SCALE) / 2

    -- Use virtual game resolution
    local screenWidth = Constants.GAME_WIDTH
    local screenHeight = Constants.GAME_HEIGHT

    -- Spacing between card and tooltip (scaled)
    local spacing = 16 * Constants.SCALE
    local screenMargin = 10 * Constants.SCALE

    -- Position tooltip above the card
    local x = cardCenterX - width / 2
    local y = self.card.y - height - spacing

    -- Clamp x to screen bounds
    if x < screenMargin then
        x = screenMargin
    elseif x + width > screenWidth - screenMargin then
        x = screenWidth - width - screenMargin
    end

    -- If tooltip would go off the top, position it below the card
    if y < screenMargin then
        y = self.card.y + (100 * Constants.SCALE) + spacing
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

    local contentY = separatorY + separatorSpace

    -- Draw passive description
    love.graphics.setColor(self.textColor)
    love.graphics.setFont(Fonts.tiny)
    love.graphics.printf(passiveDescription, x + padding, contentY, textWidth, "left")
    contentY = contentY + passiveHeight + passiveMargin

    -- Draw placement hint at bottom
    love.graphics.setFont(Fonts.tiny)
    love.graphics.setColor(0.5, 0.5, 0.5, 1)
    local hintY = y + height - padding - hintHeight
    love.graphics.printf("Drag to place on board", x + padding, hintY, textWidth, "center")
end

return Tooltip
