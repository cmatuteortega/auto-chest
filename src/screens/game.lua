local Screen = require('lib.screen')
local Constants = require('src.constants')
local Grid = require('src.grid')
local UnitRegistry = require('src.unit_registry')
local Card = require('src.card')
local suit = require('lib.suit')

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

        self:generateCards()
    end

    function self:generateCards()
        -- Generate 3 cards at bottom of screen
        self.cards = {}
        local cardWidth = 80  -- Updated to match new card size
        local cardSpacing = 30
        local totalWidth = (cardWidth * 3) + (cardSpacing * 2)
        local startX = (Constants.GAME_WIDTH - totalWidth) / 2
        local cardY = Constants.GAME_HEIGHT - 130  -- More space for larger cards

        for i = 1, 3 do
            local x = startX + (i - 1) * (cardWidth + cardSpacing)

            -- Randomly assign a unit type to each card
            local unitType = UnitRegistry.getRandomUnitType()
            local sprite = self.sprites[unitType].front

            local card = Card(x, cardY, sprite, i, unitType)
            table.insert(self.cards, card)
        end
    end

    function self:update(dt)
        -- SUIT frame management
        self.suit:enterFrame()

        -- Update timer
        if self.state == "setup" then
            self.timer = self.timer - dt
            if self.timer <= 0 then
                self.timer = 0
                self.state = "battle"
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

        -- SUIT frame management
        self.suit:exitFrame()
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
    end

    function self:drawUI()
        local lg = love.graphics

        -- Title at top
        lg.setFont(Fonts.large)
        lg.setColor(1, 1, 1, 1)
        lg.printf("AutoChest", 0, 20, Constants.GAME_WIDTH, 'center')

        -- State and timer
        lg.setFont(Fonts.medium)
        lg.setColor(0.9, 0.9, 0.9, 1)
        local stateText = self.state:upper()
        if self.state == "setup" then
            stateText = stateText .. " - " .. math.ceil(self.timer) .. "s"
        elseif self.state == "finished" and self.winner then
            stateText = "PLAYER " .. self.winner .. " WINS!"
            lg.setColor(1, 1, 0, 1)
        end
        lg.printf(stateText, 0, 50, Constants.GAME_WIDTH, 'center')

        -- Player labels
        lg.setFont(Fonts.small)
        lg.setColor(0.5, 0.7, 1, 1)
        lg.printf("Player 2 (Top)", 0, 100, Constants.GAME_WIDTH, 'center')

        lg.setColor(1, 0.7, 0.5, 1)
        lg.printf("Player 1 (Bottom)", 0, Constants.GAME_HEIGHT - 100,
                  Constants.GAME_WIDTH, 'center')

        -- Instructions and buttons
        lg.setColor(0.6, 0.6, 0.6, 1)
        if self.state == "setup" then
            lg.printf("Drag cards to place units", 0, Constants.GAME_HEIGHT - 130,
                      Constants.GAME_WIDTH, 'center')
            lg.printf("Drag units to reposition them", 0, Constants.GAME_HEIGHT - 110,
                      Constants.GAME_WIDTH, 'center')

            -- Ready button below the grid
            local buttonWidth = 120
            local buttonHeight = 40
            local buttonX = (Constants.GAME_WIDTH - buttonWidth) / 2
            local buttonY = Constants.GRID_OFFSET_Y + Constants.GRID_HEIGHT + 20

            local readyButton = self.suit:Button("READY", buttonX, buttonY, buttonWidth, buttonHeight)
            if readyButton.hit then
                self.timer = 0
                self.state = "battle"
            end
        elseif self.state == "finished" then
            -- Restart button using SUIT
            local buttonWidth = 120
            local buttonHeight = 40
            local buttonX = (Constants.GAME_WIDTH - buttonWidth) / 2
            local buttonY = Constants.GAME_HEIGHT / 2 + 40

            local button = self.suit:Button("Restart", buttonX, buttonY, buttonWidth, buttonHeight)
            if button.hit then
                self:init()
            end
        end

        -- Debug: Show highlighted cell
        if self.grid.highlightedCell then
            lg.setFont(Fonts.tiny)
            local cellInfo = string.format("Cell: [%d, %d]",
                                          self.grid.highlightedCell.col,
                                          self.grid.highlightedCell.row)
            lg.setColor(1, 1, 0, 1)
            lg.printf(cellInfo, 0, Constants.GAME_HEIGHT - 40,
                      Constants.GAME_WIDTH, 'center')
        end
    end

    function self:mousemoved(x, y, dx, dy)
        self.mouseX = x
        self.mouseY = y

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
        self.mouseX = x
        self.mouseY = y

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

    function self:mousepressed(x, y, button)
        if button == 1 and self.state == "setup" then
            -- First, check if clicking on an existing unit to reposition it
            local col, row = self.grid:worldToGrid(x, y)
            if col and row then
                local unit = self.grid:getUnitAtCell(col, row)
                if unit then
                    -- Pick up the unit
                    self.draggedUnit = unit
                    self.draggedUnitOriginalCol = col
                    self.draggedUnitOriginalRow = row

                    -- Calculate offset so unit doesn't jump to cursor
                    local unitX = Constants.GRID_OFFSET_X + (col - 1) * Constants.CELL_SIZE
                    local unitY = Constants.GRID_OFFSET_Y + (row - 1) * Constants.CELL_SIZE
                    self.draggedUnitOffsetX = x - unitX
                    self.draggedUnitOffsetY = y - unitY

                    -- Initialize drag position
                    unit.dragX = unitX
                    unit.dragY = unitY

                    -- Remove unit from grid temporarily
                    self.grid:removeUnit(col, row)
                    return
                end
            end

            -- If not clicking on a unit, check if clicking on a card
            for i = #self.cards, 1, -1 do  -- Iterate backwards for proper z-order
                local card = self.cards[i]
                if card:contains(x, y) then
                    self.draggedCard = card
                    card:startDrag(x, y)
                    return
                end
            end
        end
    end

    function self:mousereleased(x, y, button)
        if button == 1 then
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

                    -- Create and place unit with the appropriate owner using the card's unit type
                    local unitType = self.draggedCard.unitType
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

                        print(string.format("Placed Player %d unit at [%d, %d]", owner, col, row))
                    end
                else
                    -- Snap card back to original position
                    self.draggedCard:snapBack()
                end

                self.draggedCard:stopDrag()
                self.draggedCard = nil
            end
        end
    end

    function self:touchpressed(id, x, y, dx, dy, pressure)
        self:mousepressed(x, y, 1)
    end

    function self:touchreleased(id, x, y, dx, dy, pressure)
        self:mousereleased(x, y, 1)
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
