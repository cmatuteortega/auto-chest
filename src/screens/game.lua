local Screen = require('lib.screen')
local Constants = require('src.constants')
local Grid = require('src.grid')
local Unit = require('src.unit')
local Card = require('src.card')

local GameScreen = {}

function GameScreen.new()
    local self = Screen.new()

    function self:init()
        -- Load sprites
        self.sprites = {
            front = love.graphics.newImage('src/assets/front.png'),
            back = love.graphics.newImage('src/assets/back.png'),
            dead = love.graphics.newImage('src/assets/dead.png')
        }

        -- Create grid
        self.grid = Grid()

        -- Mouse/touch position
        self.mouseX = 0
        self.mouseY = 0

        -- Game state
        self.state = "setup" -- setup, battle, finished
        self.timer = 30 -- seconds for setup phase
        self.currentPlayer = 1  -- Player 1 is always the bottom player

        -- Card drafting
        self.cards = {}
        self.draggedCard = nil
        self:generateCards()

        -- Place Player 2 placeholder units for testing
        self:placePlayer2Units()
    end

    function self:placePlayer2Units()
        -- Place 4 Player 2 units in the top zone for testing
        local positions = {
            {col = 2, row = 3},
            {col = 4, row = 3},
            {col = 6, row = 3},
            {col = 3, row = 5},
        }

        for _, pos in ipairs(positions) do
            local unit = Unit(pos.row, pos.col, 2, self.sprites)
            self.grid:placeUnit(pos.col, pos.row, unit)
        end
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
            local card = Card(x, cardY, self.sprites.front, i)
            table.insert(self.cards, card)
        end
    end

    function self:update(dt)
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
    end

    function self:draw()
        local lg = love.graphics

        -- Draw grid
        self.grid:draw()

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

        -- Instructions
        lg.setColor(0.6, 0.6, 0.6, 1)
        if self.state == "setup" then
            lg.printf("Drag cards to place units", 0, Constants.GAME_HEIGHT - 130,
                      Constants.GAME_WIDTH, 'center')
        elseif self.state == "finished" then
            lg.printf("Press 'R' to restart", 0, Constants.GAME_HEIGHT - 130,
                      Constants.GAME_WIDTH, 'center')
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
    end

    function self:touchmoved(id, x, y, dx, dy, pressure)
        self.mouseX = x
        self.mouseY = y

        -- Update dragged card position
        if self.draggedCard then
            self.draggedCard:updateDrag(x, y)
        end
    end

    function self:mousepressed(x, y, button)
        if button == 1 and self.state == "setup" then
            -- Check if clicking on a card
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
        if button == 1 and self.draggedCard then
            -- Try to place unit on grid
            local col, row = self.grid:worldToGrid(x, y)

            if col and row and self.grid:canPlaceUnit(col, row, self.currentPlayer) then
                -- Create and place unit
                local unit = Unit(row, col, self.currentPlayer, self.sprites)
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

                    print(string.format("Placed unit at [%d, %d]", col, row))
                end
            else
                -- Snap card back to original position
                self.draggedCard:snapBack()
            end

            self.draggedCard:stopDrag()
            self.draggedCard = nil
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
