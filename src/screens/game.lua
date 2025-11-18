local Screen = require('lib.screen')
local Constants = require('src.constants')
local Grid = require('src.grid')
local UnitRegistry = require('src.unit_registry')
local Card = require('src.card')
local suit = require('lib.suit')
local Tooltip = require('src.tooltip')

local GameScreen = {}

function GameScreen.new()
    local self = Screen.new()

    function self:init()
        -- Load sprites for all unit types
        self.sprites = UnitRegistry.loadAllSprites()

        -- Create grid
        self.grid = Grid()

        -- Initialize SUIT
        self.suit = suit.new()

        -- Initialize Tooltip
        self.tooltip = Tooltip()

        -- Mouse/touch position
        self.mouseX = 0
        self.mouseY = 0

        -- Game state
        self.state = "setup" -- setup, battle, finished
        self.timer = 15 -- seconds for setup phase
        self.currentPlayer = 1  -- Player 1 is always the bottom player

        -- Card drafting
        self.cards = {}
        self.draggedCard = nil

        -- Unit dragging (for repositioning during setup)
        self.draggedUnit = nil
        self.draggedUnitOriginalCol = nil
        self.draggedUnitOriginalRow = nil
        self.draggedUnitOffsetX = 0
        self.draggedUnitOffsetY = 0

        -- Press tracking (for tap vs drag detection)
        self.pressedUnit = nil
        self.pressedUnitCol = nil
        self.pressedUnitRow = nil
        self.pressX = 0
        self.pressY = 0
        self.hasMoved = false  -- Track if user has actually moved (not just tap jitter)

        -- Touch tracking (to prevent double-handling on mobile)
        self.activeTouchId = nil

        self:generateCards()
    end

    function self:generateCards()
        -- Generate 3 cards at bottom with 10% margin (matching grid top margin)
        self.cards = {}
        local cardWidth = 80 * Constants.SCALE
        local cardHeight = 100 * Constants.SCALE
        local cardSpacing = 30 * Constants.SCALE
        local totalWidth = (cardWidth * 3) + (cardSpacing * 2)
        local startX = (Constants.GAME_WIDTH - totalWidth) / 2

        -- Position cards with 15% bottom margin (matching grid's 15% top margin)
        local bottomMarginPercent = 0.10
        local cardY = Constants.GAME_HEIGHT * (1 - bottomMarginPercent) - cardHeight

        for i = 1, 3 do
            local x = startX + (i - 1) * (cardWidth + cardSpacing)

            -- Randomly assign a unit type to each card
            local unitType = UnitRegistry.getRandomUnitType()
            local sprite = self.sprites[unitType].front

            local card = Card(x, cardY, sprite, i, unitType)
            table.insert(self.cards, card)
        end

        -- Calculate reroll button position (aligned to right of cards with spacing)
        self.rerollButtonSize = 40 * Constants.SCALE
        local cardsEndX = startX + totalWidth
        self.rerollButtonX = cardsEndX + cardSpacing
        self.rerollButtonY = cardY + (cardHeight - self.rerollButtonSize) / 2
    end

    function self:update(dt)
        -- Update timer
        if self.state == "setup" then
            self.timer = self.timer - dt
            if self.timer <= 0 then
                self.timer = 0
                self.state = "battle"

                -- Trigger onBattleStart for all units
                local allUnits = self.grid:getAllUnits()
                for _, unit in ipairs(allUnits) do
                    unit:onBattleStart(self.grid)
                end
            end
        elseif self.state == "battle" then
            -- Update all units during battle
            local allUnits = self.grid:getAllUnits()
            for _, unit in ipairs(allUnits) do
                unit:update(dt, self.grid)
            end

            -- Check victory condition
            local p1Alive = 0
            local p2Alive = 0
            for _, unit in ipairs(allUnits) do
                if not unit.isDead then
                    if unit.owner == 1 then
                        p1Alive = p1Alive + 1
                    else
                        p2Alive = p2Alive + 1
                    end
                end
            end

            -- Battle ends when one side has no units left
            if p1Alive == 0 or p2Alive == 0 then
                self.state = "finished"
                if p1Alive > 0 then
                    self.winner = 1
                else
                    self.winner = 2
                end
            end
        end

        -- Update grid with current mouse position
        self.grid:update(dt, self.mouseX, self.mouseY)
    end

    function self:draw()
        local lg = love.graphics

        -- Draw grid (pass dragged unit so it can skip drawing it)
        self.grid:draw(self.draggedUnit)

        -- Draw UI
        self:drawUI()

        -- Draw cards (non-dragged first, dragged last so it's on top)
        for _, card in ipairs(self.cards) do
            if card ~= self.draggedCard then
                card:draw()
            end
        end

        -- Draw dragged card on top
        if self.draggedCard then
            self.draggedCard:draw()
        end

        -- Draw dragged unit on top (if repositioning during setup)
        if self.draggedUnit then
            self.draggedUnit:draw()
        end

        -- Draw SUIT UI elements
        self.suit:draw()

        -- Draw tooltip on top of everything
        self.tooltip:draw()
    end

    function self:drawUI()
        local lg = love.graphics

        -- State and timer (positioned as percentage from top)
        lg.setFont(Fonts.medium)
        lg.setColor(0.9, 0.9, 0.9, 1)
        local stateText = self.state:upper()
        if self.state == "setup" then
            stateText = stateText .. " - " .. math.ceil(self.timer) .. "s"
        elseif self.state == "finished" and self.winner then
            stateText = "PLAYER " .. self.winner .. " WINS!"
            lg.setColor(1, 1, 0, 1)
        end
        local stateTextY = Constants.GAME_HEIGHT * 0.025  -- 2.5% from top
        lg.printf(stateText, 0, stateTextY, Constants.GAME_WIDTH, 'center')

        -- Player labels (proportional positioning)
        lg.setFont(Fonts.medium)
        local labelMargin = 10 * Constants.SCALE

        lg.setColor(0.5, 0.7, 1, 1)
        lg.print("P2", labelMargin, labelMargin)

        lg.setColor(1, 0.7, 0.5, 1)
        -- Measure text width to align right with same offset as P2
        local p1Text = "P1"
        local p1Width = Fonts.medium:getWidth(p1Text)
        lg.print(p1Text, Constants.GAME_WIDTH - p1Width - labelMargin,
                 Constants.GAME_HEIGHT - (30 * Constants.SCALE))

        -- Button dimensions (scaled proportionally)
        local buttonHeight = 40 * Constants.SCALE
        local buttonSpacing = 20 * Constants.SCALE
        local buttonY = Constants.GRID_OFFSET_Y + Constants.GRID_HEIGHT + buttonSpacing

        -- Buttons
        if self.state == "setup" then
            local buttonText = "READY"
            local buttonPadding = 20 * Constants.SCALE
            local textWidth = Fonts.medium:getWidth(buttonText)
            local buttonWidth = textWidth + buttonPadding * 2
            local buttonX = (Constants.GAME_WIDTH - buttonWidth) / 2

            -- Ready button below the grid
            local readyButton = self.suit:Button(buttonText, {id="ready_btn"}, buttonX, buttonY, buttonWidth, buttonHeight)
            if readyButton.hit then
                self.timer = 0
                self.state = "battle"

                -- Trigger onBattleStart for all units
                local allUnits = self.grid:getAllUnits()
                for _, unit in ipairs(allUnits) do
                    unit:onBattleStart(self.grid)
                end
            end

            -- Reroll button to the right of cards
            local rerollButton = self.suit:Button("@", {id="reroll_btn"},
                self.rerollButtonX, self.rerollButtonY,
                self.rerollButtonSize, self.rerollButtonSize)
            if rerollButton.hit then
                self:generateCards()
            end
        elseif self.state == "finished" then
            local buttonText = "RESTART"
            local buttonPadding = 20 * Constants.SCALE
            local textWidth = Fonts.medium:getWidth(buttonText)
            local buttonWidth = textWidth + buttonPadding * 2
            local buttonX = (Constants.GAME_WIDTH - buttonWidth) / 2

            -- Restart button at same position as Ready button
            local restartButton = self.suit:Button(buttonText, {id="restart_btn"}, buttonX, buttonY, buttonWidth, buttonHeight)

            if restartButton.hit then
                print("Restart button clicked!")
                self:init()
            end
        end
    end

    function self:mousemoved(x, y, dx, dy)
        self.mouseX = x
        self.mouseY = y

        -- Update SUIT mouse position
        self.suit:updateMouse(x, y)

        -- Track if user has moved significantly (for tap vs drag detection)
        if self.pressedUnit or self.draggedUnit or self.draggedCard then
            local distMoved = math.sqrt((x - self.pressX)^2 + (y - self.pressY)^2)
            if distMoved > 10 then  -- Increased threshold for mobile
                self.hasMoved = true
            end
        end

        -- Check if we should start dragging a pressed unit (only during setup AND with movement)
        if self.pressedUnit and not self.draggedUnit and self.state == "setup" and self.hasMoved then
            -- Start dragging the unit
            self.tooltip:hide()

            self.draggedUnit = self.pressedUnit
            self.draggedUnitOriginalCol = self.pressedUnitCol
            self.draggedUnitOriginalRow = self.pressedUnitRow

            -- Calculate offset so unit doesn't jump to cursor
            local Constants = require("src.constants")
            local unitX = Constants.GRID_OFFSET_X + (self.pressedUnitCol - 1) * Constants.CELL_SIZE
            local unitY = Constants.GRID_OFFSET_Y + (self.pressedUnitRow - 1) * Constants.CELL_SIZE
            self.draggedUnitOffsetX = self.pressX - unitX
            self.draggedUnitOffsetY = self.pressY - unitY

            -- Initialize drag position
            self.draggedUnit.dragX = unitX
            self.draggedUnit.dragY = unitY

            -- Remove unit from grid temporarily
            self.grid:removeUnit(self.pressedUnitCol, self.pressedUnitRow)

            -- Clear pressed state
            self.pressedUnit = nil
            self.pressedUnitCol = nil
            self.pressedUnitRow = nil
        end

        -- Update dragged card position
        if self.draggedCard then
            self.draggedCard:updateDrag(x, y)
        end

        -- Update dragged unit position
        if self.draggedUnit then
            -- Store the screen position for rendering
            self.draggedUnit.dragX = x - self.draggedUnitOffsetX
            self.draggedUnit.dragY = y - self.draggedUnitOffsetY
        end
    end

    function self:touchmoved(id, x, y, dx, dy, pressure)
        self:mousemoved(x, y, dx, dy)
    end

    function self:mousepressed(x, y, button, istouch)
        -- Skip if this is a touch-generated mouse event (we handle it in touchpressed)
        if istouch and self.activeTouchId then
            return
        end

        -- Update SUIT mouse state
        if button == 1 then
            self.suit:updateMouse(x, y, true)
        end

        if button == 1 then
            -- Always store initial press position for tap vs drag detection
            self.pressX = x
            self.pressY = y
            self.pressedUnit = nil
            self.hasMoved = false  -- Reset movement flag

            -- Check if clicking on a unit (in any game state)
            local col, row = self.grid:worldToGrid(x, y)
            if col and row then
                local unit = self.grid:getUnitAtCell(col, row)
                if unit then
                    -- Store the unit but don't start dragging yet
                    -- Drag threshold will determine if this is a tap or drag
                    self.pressedUnit = unit
                    self.pressedUnitCol = col
                    self.pressedUnitRow = row
                    return
                end
            end

            -- During setup, also check for card dragging
            if self.state == "setup" then
                for i = #self.cards, 1, -1 do  -- Iterate backwards for proper z-order
                    local card = self.cards[i]
                    if card:contains(x, y) then
                        -- Hide tooltip when starting to drag
                        self.tooltip:hide()

                        -- Clear pressedUnit to prevent tooltip on card release
                        self.pressedUnit = nil
                        self.pressedUnitCol = nil
                        self.pressedUnitRow = nil

                        self.draggedCard = card
                        card:startDrag(x, y)
                        return
                    end
                end
            end
        end
    end

    function self:mousereleased(x, y, button, istouch)
        -- Skip if this is a touch-generated mouse event (we handle it in touchreleased)
        if istouch and self.activeTouchId then
            return
        end

        -- Update SUIT mouse state
        if button == 1 then
            self.suit:updateMouse(x, y, false)
        end

        if button == 1 then
            -- Check if a unit was pressed but not dragged (tap for tooltip)
            if self.pressedUnit and not self.draggedUnit then
                local unit = self.pressedUnit
                -- Clear pressed state
                self.pressedUnit = nil
                self.pressedUnitCol = nil
                self.pressedUnitRow = nil

                -- Toggle tooltip for this unit
                self.tooltip:toggle(unit)
                return
            end

            -- Handle unit repositioning
            if self.draggedUnit then
                local col, row = self.grid:worldToGrid(x, y)

                -- Try to place unit at new position
                if col and row and self.grid:canPlaceUnit(col, row, self.currentPlayer) then
                    -- Place unit at new position
                    self.draggedUnit.col = col
                    self.draggedUnit.row = row
                    self.grid:placeUnit(col, row, self.draggedUnit)
                    print(string.format("Repositioned unit to [%d, %d]", col, row))
                else
                    -- Invalid position, return to original spot
                    self.draggedUnit.col = self.draggedUnitOriginalCol
                    self.draggedUnit.row = self.draggedUnitOriginalRow
                    self.grid:placeUnit(self.draggedUnitOriginalCol, self.draggedUnitOriginalRow, self.draggedUnit)
                    print(string.format("Returned unit to original position [%d, %d]", self.draggedUnitOriginalCol, self.draggedUnitOriginalRow))
                end

                -- Clear dragging state
                self.draggedUnit.dragX = nil
                self.draggedUnit.dragY = nil
                self.draggedUnit = nil
                self.draggedUnitOriginalCol = nil
                self.draggedUnitOriginalRow = nil
                return
            end

            -- Handle card placement
            if self.draggedCard then
                -- Try to place unit on grid
                local col, row = self.grid:worldToGrid(x, y)

                if col and row and self.grid:canPlaceUnit(col, row, self.currentPlayer) then
                    -- Determine owner based on which zone the card is dropped in
                    local owner = self.grid:getOwner(row)

                    -- Check if this unit type already exists for this owner (upgrade system)
                    local unitType = self.draggedCard.unitType
                    local existingUnit = self.grid:findUnitByTypeAndOwner(unitType, owner)

                    if existingUnit then
                        -- Unit type exists - try to upgrade it
                        if existingUnit:upgrade() then
                            -- Upgrade successful
                            print(string.format("Upgraded Player %d %s to level %d", owner, unitType, existingUnit.level))

                            -- Remove the card from hand
                            for i, card in ipairs(self.cards) do
                                if card == self.draggedCard then
                                    table.remove(self.cards, i)
                                    break
                                end
                            end

                            -- Generate new cards
                            self:generateCards()
                        else
                            -- Already max level, snap card back
                            print(string.format("Player %d %s is already max level", owner, unitType))
                            self.draggedCard:snapBack()
                        end
                    else
                        -- No existing unit of this type - place new unit
                        local unitSprites = self.sprites[unitType]
                        local unit = UnitRegistry.createUnit(unitType, row, col, owner, unitSprites)
                        if self.grid:placeUnit(col, row, unit) then
                            -- Remove the card from hand
                            for i, card in ipairs(self.cards) do
                                if card == self.draggedCard then
                                    table.remove(self.cards, i)
                                    break
                                end
                            end

                            -- Generate new cards
                            self:generateCards()

                            print(string.format("Placed Player %d %s at [%d, %d]", owner, unitType, col, row))
                        end
                    end
                else
                    -- Snap card back to original position
                    self.draggedCard:snapBack()
                end

                self.draggedCard:stopDrag()
                self.draggedCard = nil
                return
            end

            -- If tapping anywhere else (not on a unit), hide tooltip
            if self.tooltip:isVisible() then
                self.tooltip:hide()
            end
        end
    end

    function self:touchpressed(id, x, y, dx, dy, pressure)
        -- Track the active touch to prevent double-handling
        self.activeTouchId = id

        -- Handle the touch event (bypasses the istouch check since we called it directly)
        -- Update SUIT mouse state
        self.suit:updateMouse(x, y, true)

        -- Always store initial press position for tap vs drag detection
        self.pressX = x
        self.pressY = y
        self.pressedUnit = nil
        self.hasMoved = false  -- Reset movement flag

        -- Check if clicking on a unit (in any game state)
        local col, row = self.grid:worldToGrid(x, y)
        if col and row then
            local unit = self.grid:getUnitAtCell(col, row)
            if unit then
                -- Store the unit but don't start dragging yet
                -- Drag threshold will determine if this is a tap or drag
                self.pressedUnit = unit
                self.pressedUnitCol = col
                self.pressedUnitRow = row
                return
            end
        end

        -- During setup, also check for card dragging
        if self.state == "setup" then
            for i = #self.cards, 1, -1 do  -- Iterate backwards for proper z-order
                local card = self.cards[i]
                if card:contains(x, y) then
                    -- Hide tooltip when starting to drag
                    self.tooltip:hide()

                    -- Clear pressedUnit to prevent tooltip on card release
                    self.pressedUnit = nil
                    self.pressedUnitCol = nil
                    self.pressedUnitRow = nil

                    self.draggedCard = card
                    card:startDrag(x, y)
                    return
                end
            end
        end
    end

    function self:touchreleased(id, x, y, dx, dy, pressure)
        -- Only handle if this is our active touch
        if self.activeTouchId ~= id then
            return
        end

        -- Clear active touch
        self.activeTouchId = nil

        -- Handle the touch release
        -- Update SUIT mouse state
        self.suit:updateMouse(x, y, false)

        -- Check if a unit was pressed but not dragged (tap for tooltip)
        if self.pressedUnit and not self.draggedUnit then
            local unit = self.pressedUnit
            -- Clear pressed state
            self.pressedUnit = nil
            self.pressedUnitCol = nil
            self.pressedUnitRow = nil

            -- Toggle tooltip for this unit
            self.tooltip:toggle(unit)
            return
        end

        -- Handle unit repositioning
        if self.draggedUnit then
            local col, row = self.grid:worldToGrid(x, y)

            -- Try to place unit at new position
            if col and row and self.grid:canPlaceUnit(col, row, self.currentPlayer) then
                -- Place unit at new position
                self.draggedUnit.col = col
                self.draggedUnit.row = row
                self.grid:placeUnit(col, row, self.draggedUnit)
                print(string.format("Repositioned unit to [%d, %d]", col, row))
            else
                -- Invalid position, return to original spot
                self.draggedUnit.col = self.draggedUnitOriginalCol
                self.draggedUnit.row = self.draggedUnitOriginalRow
                self.grid:placeUnit(self.draggedUnitOriginalCol, self.draggedUnitOriginalRow, self.draggedUnit)
                print(string.format("Returned unit to original position [%d, %d]", self.draggedUnitOriginalCol, self.draggedUnitOriginalRow))
            end

            -- Clear dragging state
            self.draggedUnit.dragX = nil
            self.draggedUnit.dragY = nil
            self.draggedUnit = nil
            self.draggedUnitOriginalCol = nil
            self.draggedUnitOriginalRow = nil
            return
        end

        -- Handle card placement
        if self.draggedCard then
            -- Try to place unit on grid
            local col, row = self.grid:worldToGrid(x, y)

            if col and row and self.grid:canPlaceUnit(col, row, self.currentPlayer) then
                -- Determine owner based on which zone the card is dropped in
                local owner = self.grid:getOwner(row)

                -- Check if this unit type already exists for this owner (upgrade system)
                local unitType = self.draggedCard.unitType
                local existingUnit = self.grid:findUnitByTypeAndOwner(unitType, owner)

                if existingUnit then
                    -- Unit type exists - try to upgrade it
                    if existingUnit:upgrade() then
                        -- Upgrade successful
                        print(string.format("Upgraded Player %d %s to level %d", owner, unitType, existingUnit.level))

                        -- Remove the card from hand
                        for i, card in ipairs(self.cards) do
                            if card == self.draggedCard then
                                table.remove(self.cards, i)
                                break
                            end
                        end

                        -- Generate new cards
                        self:generateCards()
                    else
                        -- Already max level, snap card back
                        print(string.format("Player %d %s is already max level", owner, unitType))
                        self.draggedCard:snapBack()
                    end
                else
                    -- No existing unit of this type - place new unit
                    local unitSprites = self.sprites[unitType]
                    local unit = UnitRegistry.createUnit(unitType, row, col, owner, unitSprites)
                    if self.grid:placeUnit(col, row, unit) then
                        -- Remove the card from hand
                        for i, card in ipairs(self.cards) do
                            if card == self.draggedCard then
                                table.remove(self.cards, i)
                                break
                            end
                        end

                        -- Generate new cards
                        self:generateCards()

                        print(string.format("Placed Player %d %s at [%d, %d]", owner, unitType, col, row))
                    end
                end
            else
                -- Snap card back to original position
                self.draggedCard:snapBack()
            end

            self.draggedCard:stopDrag()
            self.draggedCard = nil
            return
        end

        -- If tapping anywhere else (not on a unit), hide tooltip
        if self.tooltip:isVisible() then
            self.tooltip:hide()
        end
    end

    function self:keypressed(key)
        if key == 'escape' then
            love.event.quit()
        elseif key == 'r' then
            -- Reset
            self:init()
        end
    end

    return self
end

return GameScreen
