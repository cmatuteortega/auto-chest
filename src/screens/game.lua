local Screen = require('lib.screen')
local Constants = require('src.constants')
local Grid = require('src.grid')
local UnitRegistry = require('src.unit_registry')
local Card = require('src.card')
local suit = require('lib.suit')
local Tooltip = require('src.tooltip')
local json = require('lib.json')
local DeckManager = require('src.deck_manager')

local GameScreen = {}

function GameScreen.new()
    local self = Screen.new()

    -- ── init ──────────────────────────────────────────────────────────────────
    -- Parameters (online mode only):
    --   isOnline   (boolean) – true when playing over the network
    --   playerRole (number)  – 1 (host/P1) or 2 (guest/P2)
    --   socket     (table)   – sock.lua Client already connected to the relay server
    function self:init(isOnline, playerRole, socket, isSandbox, isTutorial)
        -- Online mode setup
        self.isOnline   = isOnline   or false
        self.playerRole = playerRole or 1   -- 1 = local is P1, 2 = local is P2
        self.socket     = socket
        self.isSandbox  = isSandbox  or false
        self.isTutorial = isTutorial or false

        -- Set rendering perspective so the local player always appears at the bottom
        Constants.PERSPECTIVE = self.playerRole

        -- Player & opponent info (for trophy display)
        self.playerName = _G.PlayerData and _G.PlayerData.username or "You"
        self.playerTrophies = _G.PlayerData and _G.PlayerData.trophies or 0
        self.opponentName = self.isTutorial and "evil"
                         or (_G.OpponentData and _G.OpponentData.name or "Foe")
        self.opponentTrophies = self.isTutorial and 0
                             or (_G.OpponentData and _G.OpponentData.trophies or 0)

        -- Trophy and gold changes (calculated when match ends)
        self.trophyChange = nil
        self.goldEarned   = nil
        self.matchResultSent = false

        -- Opponent ready / battle-start tracking (online only)
        self.localReady    = false
        self.opponentReady = false

        -- Register network callbacks once (cleared when screen is closed)
        if self.isOnline and self.socket then
            self:registerNetworkCallbacks()
        end

        -- Load sprites for all unit types
        self.sprites = UnitRegistry.loadAllSprites()

        -- Load battle background sprite
        self.bgSprite = love.graphics.newImage('src/assets/background_battle.png')
        self.bgOffsetY = 42  -- adjust to shift the background up (negative) or down (positive)

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
        self.state = "setup" -- setup, intermission, battle, battle_ending, finished
        self.timer = 30 -- seconds for setup phase
        -- Fixed timestep simulation (prevents dt desync between clients)
        self.battleAccumulator = 0
        self.battleStepCount   = 0
        self.currentPlayer = 1  -- Player 1 is always the bottom player in canonical coords

        -- Round tracking
        self.roundNumber         = 1
        self.battleUnitsSnapshot  = {}  -- all units alive at battle start, for reliable reset
        self.pendingOpponentMsgs  = {}  -- buffered opponent placement msgs, applied at battle start
        self.pendingWinner        = nil -- winner saved during intermission before life deduction

        -- Desync detection
        self.localBoardHash    = nil
        self.opponentBoardHash = nil

        -- Round-end sync (online): both clients must signal done before resetting
        self.localRoundEndReady    = false
        self.opponentRoundEndReady = false

        -- Lives
        self.p1Lives = 3
        self.p2Lives = 3

        -- Economy
        self.playerCoins = self.isTutorial and 10 or 6
        self.rerollCost = 1

        -- Card drafting
        self.cards = {}
        self.draggedCard = nil

        -- Deck draw pile (populated from DeckManager; false = fallback to random)
        self.usingDeck      = DeckManager.initDrawPile()
        self.drawnCardTypes = {}

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

        -- Card press tracking (for tap vs drag detection)
        self.pressedCard = nil
        self.pressedCardIndex = nil

        -- Touch tracking (to prevent double-handling on mobile)
        self.activeTouchId = nil

        -- Tutorial: set up the tutorial manager (must be before dealSetupCards)
        self.tutorialManager = nil
        if self.isTutorial then
            local TutorialManager = require('src.tutorial_manager')
            self.tutorialManager = TutorialManager.new(self)
        end

        self:dealSetupCards()

        -- Apply battle-mode filter immediately (music stays moody for the full match)
        AudioManager.setBattleMode(true)
    end

    -- ── Network helpers ───────────────────────────────────────────────────────

    function self:sendMsg(data)
        if self.isOnline and self.socket then
            self.socket:send("relay", data)
        end
    end

    function self:registerNetworkCallbacks()
        local s = self.socket

        -- The relay server forwards the opponent's "relay" events to us
        self._cb_relay = s:on("relay", function(data)
            self:handleNetworkMessage(data)
        end)

        self._cb_oppDisconn = s:on("opponent_disconnected", function()
            self.opponentDisconnected = true
        end)

        self._cb_disconnect = s:on("disconnect", function()
            print("[GAME] Socket disconnected")
            if self.state ~= "finished" then
                self.opponentDisconnected = true
            end
        end)
    end

    -- Compute a deterministic string hash of all units on the board (type, position, owner, level).
    -- Used to verify both clients are in sync at battle start.
    function self:computeBoardHash()
        local entries = {}
        for row = 1, self.grid.rows do
            for col = 1, self.grid.cols do
                local cell = self.grid.cells[row][col]
                if cell.unit then
                    local u = cell.unit
                    table.insert(entries, string.format("%s,%d,%d,%d,%d",
                        u.unitType, u.col, u.row, u.owner, u.level or 0))
                end
            end
        end
        table.sort(entries)
        return table.concat(entries, "|")
    end

    function self:checkBoardSync()
        if not (self.localBoardHash and self.opponentBoardHash) then return end
        if self.localBoardHash == self.opponentBoardHash then
            print("[SYNC] Board OK for round " .. self.roundNumber)
        else
            print("[DESYNC] Round " .. self.roundNumber .. " board mismatch!")
            print("  Local:  " .. self.localBoardHash)
            print("  Remote: " .. self.opponentBoardHash)
        end
        self.localBoardHash    = nil
        self.opponentBoardHash = nil
    end

    -- Apply a single opponent placement/removal/upgrade message to the grid.
    function self:applyOpponentMsg(msg)
        local t = msg.type
        if t == "place_unit" then
            local unitSprites = self.sprites[msg.unitType]
            local unit = UnitRegistry.createUnit(msg.unitType, msg.row, msg.col, msg.owner, unitSprites)
            -- Restore upgrades when the message carries level info (repositioned upgraded unit)
            if msg.activeUpgrades then
                for _, idx in ipairs(msg.activeUpgrades) do
                    unit:upgrade(idx)
                end
            end
            self.grid:placeUnit(msg.col, msg.row, unit)
        elseif t == "remove_unit" then
            self.grid:removeUnit(msg.col, msg.row)
        elseif t == "upgrade_unit" then
            local unit = self.grid:getUnitAtCell(msg.col, msg.row)
            if unit then unit:upgrade(msg.upgradeIndex) end
        end
    end

    function self:handleNetworkMessage(msg)
        local t = msg.type

        if t == "place_unit" or t == "remove_unit" or t == "upgrade_unit" then
            -- During setup/intermission/pre_battle, buffer opponent moves so their
            -- positions stay frozen at last-round home spots until battle starts.
            local inSetup = self.state == "setup" or self.state == "intermission"
                         or self.state == "pre_battle"
            if inSetup then
                table.insert(self.pendingOpponentMsgs, msg)
            else
                self:applyOpponentMsg(msg)
            end

        elseif t == "ready" then
            self.opponentReady = true
            self:checkBattleStart()

        elseif t == "battle_start" then
            math.randomseed(msg.seed)
            self:beginBattleCountdown()

        elseif t == "round_end_ready" then
            self.opponentRoundEndReady = true

        elseif t == "board_sync_check" then
            self.opponentBoardHash = msg.hash
            self:checkBoardSync()
        end
    end

    function self:checkBattleStart()
        if not (self.localReady and self.opponentReady) then return end

        if self.playerRole == 1 then
            local seed = os.time()
            math.randomseed(seed)
            self:sendMsg({type = "battle_start", seed = seed})
            self:beginBattleCountdown()
        end
        -- Guest waits for the "battle_start" message (handled above)
    end

    function self:beginBattleCountdown()
        -- Return any unplayed drawn cards to the deck pile before battle
        if self.usingDeck and #self.drawnCardTypes > 0 then
            DeckManager.returnCards(self.drawnCardTypes)
            self.drawnCardTypes = {}
        end
        self.cards = {}

        self.state          = "pre_battle"
        self.preBattleTimer = 1
    end

    function self:startBattle()
        self.timer = 0
        self.state = "battle"
        AudioManager.setBattleMode(true)
        self.battleAccumulator = 0
        self.battleStepCount   = 0

        -- Apply all buffered opponent moves now that battle is starting
        for _, msg in ipairs(self.pendingOpponentMsgs) do
            self:applyOpponentMsg(msg)
        end
        self.pendingOpponentMsgs = {}

        -- Validate board sync with opponent (both clients compute the same hash if in sync)
        if self.isOnline then
            self.localBoardHash = self:computeBoardHash()
            self:sendMsg({type = "board_sync_check", hash = self.localBoardHash})
            self:checkBoardSync()
        end

        local allUnits = self.grid:getAllUnits()
        self.battleUnitsSnapshot = {}
        for _, unit in ipairs(allUnits) do
            unit.homeCol = unit.col
            unit.homeRow = unit.row
            table.insert(self.battleUnitsSnapshot, unit)
            unit:onBattleStart(self.grid)
        end

        -- ACTION move system: delay non-action units until all ACTION moves complete
        local maxActionDuration = 0
        for _, unit in ipairs(allUnits) do
            if unit.isActionUnit and unit.actionDuration > maxActionDuration then
                maxActionDuration = unit.actionDuration
            end
        end
        if maxActionDuration > 0 then
            for _, unit in ipairs(allUnits) do
                if not unit.isActionUnit then
                    unit.actionDelayTimer = maxActionDuration
                end
            end
        end
    end

    function self:resetRound()
        -- Use the snapshot taken at battle start (reliable even if units left the grid mid-battle)
        local allUnits = self.battleUnitsSnapshot

        -- Clear the grid entirely
        for row = 1, self.grid.rows do
            for col = 1, self.grid.cols do
                local cell = self.grid.cells[row][col]
                cell.unit     = nil
                cell.occupied = false
                cell.reserved = false
            end
        end

        -- Re-place all units at their pre-battle home positions
        for _, unit in ipairs(allUnits) do
            if unit.homeCol and unit.homeRow then
                unit.col = unit.homeCol
                unit.row = unit.homeRow
                unit:resetCombatState()
                self.grid:placeUnit(unit.homeCol, unit.homeRow, unit)
            end
        end

        self.roundNumber          = self.roundNumber + 1
        self.winner               = nil
        self.localReady           = false
        self.opponentReady        = false
        self.playerCoins          = self.playerCoins + 6
        self.pendingOpponentMsgs  = {}
        self.draggedUnit          = nil
        self.draggedCard          = nil
        self.pressedUnit          = nil
        self.pressedCard          = nil
        self.tooltip:hide()
        self:dealSetupCards()

        self.state = "setup"
        self.timer = 30
    end

    function self:generateCards()
        -- Generate 3 cards at bottom with 10% margin (matching grid top margin)
        self.cards = {}
        local cardWidth = 80 * Constants.SCALE
        local cardHeight = 100 * Constants.SCALE
        local cardSpacing = 30 * Constants.SCALE
        local totalWidth = (cardWidth * 3) + (cardSpacing * 2)
        local startX = (Constants.GAME_WIDTH - totalWidth) / 2

        -- Position cards with 10% bottom margin
        local bottomMarginPercent = 0.10
        self.cardY = Constants.GAME_HEIGHT * (1 - bottomMarginPercent) - cardHeight
        local cardY = self.cardY

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

    -- Build Card objects from an array of unitType strings.
    -- Pure UI construction — does not interact with DeckManager.
    function self:_rebuildCardsFromTypes(unitTypes)
        self.cards = {}
        local cardWidth   = 80  * Constants.SCALE
        local cardHeight  = 100 * Constants.SCALE
        local cardSpacing = 30  * Constants.SCALE
        local totalWidth  = (cardWidth * 3) + (cardSpacing * 2)
        local startX      = (Constants.GAME_WIDTH - totalWidth) / 2
        local bottomMarginPercent = 0.10
        self.cardY = Constants.GAME_HEIGHT * (1 - bottomMarginPercent) - cardHeight
        local cardY = self.cardY

        for i, unitType in ipairs(unitTypes) do
            local x      = startX + (i - 1) * (cardWidth + cardSpacing)
            local sprite     = self.sprites[unitType].front
            local trimBottom = self.sprites[unitType].frontTrimBottom or 0
            local card       = Card(x, cardY, sprite, i, unitType, trimBottom)
            table.insert(self.cards, card)
        end

        -- Reroll button position
        self.rerollButtonSize = 40 * Constants.SCALE
        local cardsEndX = startX + totalWidth
        self.rerollButtonX = cardsEndX + cardSpacing
        self.rerollButtonY = cardY + (cardHeight - self.rerollButtonSize) / 2
    end

    -- Draw cards from the deck pile (or fall back to random) and display them.
    -- Returns any leftover unplayed drawn cards from the previous call to the pile first.
    function self:dealSetupCards()
        -- Return unplayed cards from last deal back to pile
        if self.usingDeck and #self.drawnCardTypes > 0 then
            DeckManager.returnCards(self.drawnCardTypes)
            self.drawnCardTypes = {}
        end

        local unitTypes
        if self.isTutorial then
            -- Tutorial: draw from a restricted pool so the player sees relevant units
            local pool = {"boney", "marrow", "knight", "mage"}
            unitTypes = {}
            for _ = 1, 3 do
                table.insert(unitTypes, pool[math.random(#pool)])
            end
        elseif self.usingDeck then
            unitTypes = DeckManager.drawCards(3)
            -- In sandbox, loop the deck when the pile runs out
            if self.isSandbox then
                while #unitTypes < 3 do
                    DeckManager.initDrawPile()
                    local extra = DeckManager.drawCards(3 - #unitTypes)
                    if #extra == 0 then break end
                    for _, u in ipairs(extra) do table.insert(unitTypes, u) end
                end
            end
        else
            unitTypes = {}
            for _ = 1, 3 do
                table.insert(unitTypes, UnitRegistry.getRandomUnitType())
            end
        end

        self.drawnCardTypes = unitTypes
        self:_rebuildCardsFromTypes(unitTypes)
    end

    -- Helper: Enter finished state with trophy calculation
    function self:enterFinishedState(winnerId)
        self.state = "finished"
        self.winner = winnerId

        -- Calculate trophy and gold changes (only in online mode, not sandbox)
        if self.isOnline and not self.isSandbox and not self.trophyChange then
            local didWin = (winnerId == self.playerRole)
            self.trophyChange = didWin and 20 or -15
            self.goldEarned   = didWin and 10 or 5

            -- Send match result to server (once)
            if not self.matchResultSent then
                self.matchResultSent = true
                if self.socket then
                    self.socket:send("match_result", {
                        winner_id = _G.PlayerData.id and (didWin and _G.PlayerData.id or nil) or 0
                    })
                end

                -- Update local trophy and gold counts immediately
                self.playerTrophies = math.max(0, self.playerTrophies + self.trophyChange)
                if _G.PlayerData then
                    _G.PlayerData.trophies = self.playerTrophies
                    _G.PlayerData.gold = (_G.PlayerData.gold or 0) + self.goldEarned
                end
            end
        end
    end

    function self:update(dt)
        -- Tutorial manager update (AI placement, step auto-advancement)
        if self.isTutorial and self.tutorialManager then
            self.tutorialManager:update(dt)
        end

        -- Poll network (must happen every frame)
        if self.isOnline and self.socket then
            self.socket:update()
        end

        -- Opponent disconnected mid-game
        if self.opponentDisconnected and self.state ~= "finished" then
            self.opponentDisconnected = false
            self:enterFinishedState(self.playerRole)  -- local player wins by forfeit
            self.statusMsg = "Oponente desconectado. ¡Ganaste!"
        end

        -- Intermission countdown (bodies stay on board during this period)
        if self.state == "intermission" then
            self.intermissionTimer = self.intermissionTimer - dt
            if self.intermissionTimer <= 0 then
                if self.isTutorial then
                    -- Tutorial ends after the first round regardless of who won
                    local w = self.pendingWinner or 1
                    self.pendingWinner = nil
                    self:enterFinishedState(w)
                else
                    local w = self.pendingWinner
                    self.pendingWinner = nil
                    if w == 1 then
                        self.p2Lives = self.p2Lives - 1
                        if self.p2Lives <= 0 then
                            if self.isSandbox then self.p2Lives = 3; self:resetRound() else self:enterFinishedState(1) end
                        else self:resetRound() end
                    elseif w == 2 then
                        self.p1Lives = self.p1Lives - 1
                        if self.p1Lives <= 0 then
                            if self.isSandbox then self.p1Lives = 3; self:resetRound() else self:enterFinishedState(2) end
                        else self:resetRound() end
                    else
                        self.state = "setup"
                    end
                end
            end
        end

        -- Pre-battle GO! countdown (setup → battle transition)
        if self.state == "pre_battle" then
            self.preBattleTimer = self.preBattleTimer - dt
            if self.preBattleTimer <= 0 then
                self:startBattle()
            end
        end

        -- Update timer (always counts down for display; only P1 auto-triggers battle in online mode)
        -- In tutorial mode the timer is disabled so the player can take their time.
        if self.state == "setup" and not self.isTutorial then
            self.timer = self.timer - dt
            if self.timer <= 0 then
                self.timer = 0
                if not self.isOnline then
                    self:beginBattleCountdown()
                elseif not self.localReady then
                    -- Both players auto-ready when timer expires
                    self.localReady = true
                    self:sendMsg({type = "ready"})
                    self:checkBattleStart()
                end
            end
        elseif self.state == "battle" then
            -- Fixed timestep simulation: accumulate real dt and drain in discrete steps.
            -- Both clients run the exact same number of steps per battle, eliminating
            -- floating-point divergence caused by variable frame rates.
            local FIXED_DT = 1 / 60
            self.battleAccumulator = self.battleAccumulator + dt

            while self.battleAccumulator >= FIXED_DT do
                self.battleAccumulator = self.battleAccumulator - FIXED_DT
                self.battleStepCount   = self.battleStepCount + 1

                local allUnits = self.grid:getAllUnits()
                for _, unit in ipairs(allUnits) do
                    unit:update(FIXED_DT, self.grid)
                end

                -- Check victory condition after each simulation step
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

                if p1Alive == 0 or p2Alive == 0 then
                    self.state = "battle_ending"
                    self.winner = p1Alive > 0 and 1 or 2
                    break
                end
            end
        elseif self.state == "battle_ending" then
            -- Continue updating units to allow animations to complete
            local allUnits = self.grid:getAllUnits()
            for _, unit in ipairs(allUnits) do
                unit:update(dt, self.grid)
            end

            -- Once animations finish, sync with opponent then handle lives
            if self:areAllAnimationsComplete() then
                -- Signal done once (send only once)
                if not self.localRoundEndReady then
                    self.localRoundEndReady = true
                    if self.isOnline then
                        self:sendMsg({type = "round_end_ready"})
                    end
                end

                -- Proceed only when both sides are done
                local bothDone = self.localRoundEndReady and
                                 (not self.isOnline or self.opponentRoundEndReady)
                if bothDone then
                    self.localRoundEndReady    = false
                    self.opponentRoundEndReady = false
                    -- Consolation coins for the losing player (+3)
                    local loser = (self.winner == 1) and 2 or 1
                    if self.playerRole == loser then
                        self.playerCoins = self.playerCoins + 3
                    end

                    -- Leave bodies on board; apply life deduction after intermission
                    self.pendingWinner     = self.winner
                    self.state             = "intermission"
                    self.intermissionTimer = 2.5
                end
            end
        end

        -- Visual-only update for directional sprite animation (all game states, real dt)
        local allUnitsForVisuals = self.grid:getAllUnits()
        for _, unit in ipairs(allUnitsForVisuals) do
            unit:updateVisuals(dt, self.state)
        end

        -- Update grid with current mouse position
        self.grid:update(dt, self.mouseX, self.mouseY)
    end

    function self:draw()
        local lg = love.graphics

        -- Draw battle background centered on the grid at unit sprite scale
        local spriteScale = Constants.CELL_SIZE / 16
        local bgW = self.bgSprite:getWidth()
        local bgH = self.bgSprite:getHeight()
        local bgX = Constants.GRID_OFFSET_X + Constants.GRID_WIDTH / 2
        local bgY = Constants.GRID_OFFSET_Y + Constants.GRID_HEIGHT / 2 + self.bgOffsetY
        lg.setColor(1, 1, 1, 1)
        lg.draw(self.bgSprite, bgX, bgY, 0, spriteScale, spriteScale, bgW / 2, bgH / 2)

        -- During online setup, hide the opponent's units for the element of surprise.
        local hideOwner = (self.isOnline and self.state == "setup" and self.roundNumber == 1) and (3 - self.playerRole) or nil
        self.grid:draw(self.draggedUnit, hideOwner)

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

        -- Draw tutorial bubble overlay on top of everything (tutorial mode only)
        if self.isTutorial and self.tutorialManager then
            self.tutorialManager:draw()
        end
    end

    function self:drawUI()
        local lg = love.graphics

        -- State and timer (positioned as percentage from top)
        lg.setFont(Fonts.medium)
        lg.setColor(0.9, 0.9, 0.9, 1)
        local stateText = self.state:upper()
        if self.state == "setup" then
            if not self.isTutorial then
                stateText = stateText .. " - " .. math.ceil(self.timer) .. "s"
            end
        elseif self.state == "intermission" then
            stateText = "ROUND " .. self.roundNumber
        elseif self.state == "pre_battle" then
            stateText = "GO!"
            lg.setColor(0.3, 1, 0.3, 1)
        elseif self.state == "battle_ending" then
            stateText = ""
        elseif self.state == "finished" and self.winner then
            local didWin = (self.winner == self.playerRole)
            stateText = didWin and "YOU WIN!" or "YOU LOSE"
            lg.setColor(didWin and {0.3, 1, 0.3, 1} or {1, 0.3, 0.3, 1})
        end
        local stateTextY = Constants.GAME_HEIGHT * 0.025  -- 2.5% from top
        lg.printf(stateText, 0, stateTextY, Constants.GAME_WIDTH, 'center')

        -- Trophy and gold changes (if in finished state and online mode)
        if self.state == "finished" and self.trophyChange and self.isOnline and not self.isSandbox then
            local sc = Constants.SCALE
            local offsetY = stateTextY + Fonts.large:getHeight() + 10 * sc
            local trophyText = (self.trophyChange >= 0 and "+" or "") .. self.trophyChange .. " trophies"
            lg.setFont(Fonts.medium)
            local trophyColor = self.trophyChange >= 0 and {0.4, 1, 0.4, 1} or {1, 0.5, 0.5, 1}
            lg.setColor(trophyColor)
            lg.printf(trophyText, 0, offsetY, Constants.GAME_WIDTH, 'center')

            if self.goldEarned then
                lg.setColor(0.95, 0.80, 0.20, 1)
                lg.printf("+" .. self.goldEarned .. " gold", 0, offsetY + Fonts.medium:getHeight() + 4 * sc, Constants.GAME_WIDTH, 'center')
            end
        end

        -- Player labels (proportional positioning)
        -- In online mode the local player is always shown at the bottom right.
        lg.setFont(Fonts.large)
        local topMargin = 15 * Constants.SCALE
        local fontHeight = Fonts.large:getHeight()
        local bottomMargin = topMargin

        -- Determine which label goes where based on perspective
        local topLabel     = self.opponentName  -- Opponent always at top
        local bottomLabel  = self.playerName    -- Player always at bottom
        local topTrophies  = self.opponentTrophies
        local bottomTrophies = self.playerTrophies
        local topColor    = self.playerRole == 2 and {1, 0.7, 0.5, 1} or {0.5, 0.7, 1, 1}
        local bottomColor = self.playerRole == 2 and {0.5, 0.7, 1, 1} or {1, 0.7, 0.5, 1}

        -- Lives for each visual position
        local topLives    = (self.playerRole == 1) and self.p2Lives or self.p1Lives
        local bottomLives = (self.playerRole == 1) and self.p1Lives or self.p2Lives

        -- Helper: draw life pips starting at (x, y), left-to-right, using given color
        local pipSize = 8 * Constants.SCALE
        local pipGap  = 4 * Constants.SCALE
        local function drawLives(x, y, lives, color)
            for i = 1, 3 do
                if i <= lives then
                    lg.setColor(color)
                else
                    lg.setColor(0.25, 0.25, 0.25, 1)
                end
                lg.rectangle('fill', x + (i - 1) * (pipSize + pipGap),
                             y, pipSize, pipSize)
            end
        end

        -- Top player (opponent)
        lg.setColor(topColor)
        lg.print(topLabel, topMargin, topMargin)
        lg.setFont(Fonts.tiny)
        lg.setColor(0.9, 0.85, 0.3, 1)
        lg.print(topTrophies .. " trophies", topMargin, topMargin + Fonts.large:getHeight())
        drawLives(topMargin, topMargin + Fonts.large:getHeight() + Fonts.tiny:getHeight() + 3 * Constants.SCALE, topLives, topColor)

        -- Bottom player (you)
        lg.setFont(Fonts.large)
        lg.setColor(bottomColor)
        local bLabelWidth = Fonts.large:getWidth(bottomLabel)
        local bLabelX = Constants.GAME_WIDTH - bLabelWidth - topMargin
        lg.print(bottomLabel, bLabelX, Constants.GAME_HEIGHT - fontHeight - bottomMargin)
        lg.setFont(Fonts.tiny)
        lg.setColor(0.9, 0.85, 0.3, 1)
        local trophyText = bottomTrophies .. " trophies"
        local trophyW = Fonts.tiny:getWidth(trophyText)
        lg.print(trophyText, Constants.GAME_WIDTH - trophyW - topMargin, Constants.GAME_HEIGHT - bottomMargin - fontHeight - Fonts.tiny:getHeight())
        drawLives(bLabelX, Constants.GAME_HEIGHT - fontHeight - bottomMargin - pipSize - 5 * Constants.SCALE,
                  bottomLives, bottomColor)

        -- Coin display in bottom left (uses same font size as player name)
        lg.setFont(Fonts.large)
        lg.setColor(1, 1, 1, 1)  -- White color
        local coinText = self.isSandbox and "¤ ∞" or ("¤ " .. self.playerCoins)
        lg.print(coinText, topMargin, Constants.GAME_HEIGHT - fontHeight - bottomMargin)

        -- Reset font for buttons
        lg.setFont(Fonts.medium)

        -- Button dimensions (scaled proportionally)
        local buttonHeight = 40 * Constants.SCALE
        -- Position button at middle height between grid bottom and card top
        local gridBottom = Constants.GRID_OFFSET_Y + Constants.GRID_HEIGHT
        local buttonY = ((gridBottom + self.cardY) / 2) - (buttonHeight / 2)

        -- Buttons
        if self.state == "setup" then
            -- In online mode: show "READY" until pressed, then "Esperando…"
            local buttonText = "READY"
            if self.isOnline and self.localReady then
                buttonText = "Esperando…"
            end
            local buttonPadding = 20 * Constants.SCALE
            local textWidth = Fonts.medium:getWidth(buttonText)
            local buttonWidth = textWidth + buttonPadding * 2
            local buttonX = (Constants.GAME_WIDTH - buttonWidth) / 2

            -- Ready button below the grid (disabled after pressing in online mode)
            local readyButton = self.suit:Button(buttonText, {id="ready_btn"}, buttonX, buttonY, buttonWidth, buttonHeight)
            if readyButton.hit and not (self.isOnline and self.localReady) then
                AudioManager.playTap()
                if self.isOnline then
                    self.localReady = true
                    self:sendMsg({type = "ready"})
                    self:checkBattleStart()
                else
                    self.timer = 0
                    self:beginBattleCountdown()
                end
            end

            -- Reroll button to the right of cards
            local rerollButton = self.suit:Button("@", {id="reroll_btn"},
                self.rerollButtonX, self.rerollButtonY,
                self.rerollButtonSize, self.rerollButtonSize)
            if rerollButton.hit then
                AudioManager.playTap()
                if self.isSandbox or self.playerCoins >= self.rerollCost then
                    if not self.isSandbox then self.playerCoins = self.playerCoins - self.rerollCost end
                    if self.usingDeck and not self.isSandbox then
                        local newTypes = DeckManager.reshuffleAndDraw(self.drawnCardTypes, 3)
                        self.drawnCardTypes = newTypes
                        self:_rebuildCardsFromTypes(newTypes)
                    else
                        self:dealSetupCards()
                    end
                end
            end
            -- Sandbox: MENU button at top-right corner
            if self.isSandbox then
                local menuBtnW = Fonts.medium:getWidth("MENU") + 20 * Constants.SCALE
                local menuBtnH = buttonHeight
                local menuBtnX = Constants.GAME_WIDTH - menuBtnW - 10 * Constants.SCALE
                local menuBtn = self.suit:Button("MENU", {id="menu_btn"}, menuBtnX, 6 * Constants.SCALE, menuBtnW, menuBtnH)
                if menuBtn.hit then
                    AudioManager.playTap()
                    Constants.PERSPECTIVE = 1
                    local ScreenManager = require('lib.screen_manager')
                    ScreenManager.switch('menu')
                end
            end
        elseif self.state == "finished" then
            if self.isTutorial then
                -- Tutorial end: invite player to create an account
                local btnText = "Play Online!"
                local buttonPadding = 20 * Constants.SCALE
                local textWidth = Fonts.medium:getWidth(btnText)
                local buttonWidth = textWidth + buttonPadding * 2
                local buttonX = (Constants.GAME_WIDTH - buttonWidth) / 2
                local playBtn = self.suit:Button(btnText, {id="play_online_btn"}, buttonX, buttonY, buttonWidth, buttonHeight)
                if playBtn.hit then
                    AudioManager.playTap()
                    love.filesystem.write("tutorial_done.dat", "1")
                    Constants.PERSPECTIVE = 1
                    local ScreenManager = require('lib.screen_manager')
                    ScreenManager.switch('login')
                end
            else
                local buttonText = self.isOnline and "IR AL MENÚ" or "RESTART"
                local buttonPadding = 20 * Constants.SCALE
                local textWidth = Fonts.medium:getWidth(buttonText)
                local buttonWidth = textWidth + buttonPadding * 2
                local buttonX = (Constants.GAME_WIDTH - buttonWidth) / 2

                local restartButton = self.suit:Button(buttonText, {id="restart_btn"}, buttonX, buttonY, buttonWidth, buttonHeight)

                if restartButton.hit then
                    AudioManager.playTap()
                    if self.isOnline then
                        -- Keep socket alive so player can re-queue without re-logging in
                        _G.GameSocket = self.socket
                        Constants.PERSPECTIVE = 1
                        local ScreenManager = require('lib.screen_manager')
                        ScreenManager.switch('menu')
                    else
                        print("Restart button clicked!")
                        self:init()
                    end
                end
            end
        end
    end

    function self:mousemoved(x, y, dx, dy)
        self.mouseX = x
        self.mouseY = y

        -- Update SUIT mouse position
        self.suit:updateMouse(x, y)

        -- Track if user has moved significantly (for tap vs drag detection)
        if self.pressedUnit or self.draggedUnit or self.draggedCard or self.pressedCard then
            local distMoved = math.sqrt((x - self.pressX)^2 + (y - self.pressY)^2)
            if distMoved > 10 then  -- Increased threshold for mobile
                self.hasMoved = true
            end
        end

        -- Check if we should start dragging a pressed card (only during setup AND with movement)
        if self.pressedCard and not self.draggedCard and self.state == "setup" and self.hasMoved then
            -- Start dragging the card
            self.draggedCard = self.pressedCard
            self.pressedCard:startDrag(self.pressX, self.pressY)
            self.pressedCard:updateDrag(x, y)

            -- Clear pressed state
            self.pressedCard = nil
            self.pressedCardIndex = nil
        end

        -- Check if we should start dragging a pressed unit (only during setup AND with movement)
        -- Enemy units cannot be repositioned; only tap them for tooltip info.
        local isOwnPressedUnit = not self.pressedUnit
            or not self.isOnline
            or self.pressedUnit.owner == self.playerRole
        if self.pressedUnit and not self.draggedUnit and self.state == "setup" and self.hasMoved and isOwnPressedUnit then
            -- Start dragging the unit
            self.tooltip:hide()

            self.draggedUnit = self.pressedUnit
            self.draggedUnitOriginalCol = self.pressedUnitCol
            self.draggedUnitOriginalRow = self.pressedUnitRow

            -- Calculate offset so unit doesn't jump to cursor.
            -- Use gridToWorld so the perspective flip (P2) is accounted for.
            local unitX, unitY = self.grid:gridToWorld(self.pressedUnitCol, self.pressedUnitRow)
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

            -- During setup, also check for card press (tap vs drag detection)
            if self.state == "setup" then
                for i = #self.cards, 1, -1 do  -- Iterate backwards for proper z-order
                    local card = self.cards[i]
                    if card:contains(x, y) then
                        -- Hide tooltip when pressing card
                        self.tooltip:hide()

                        -- Clear pressedUnit to prevent tooltip on card release
                        self.pressedUnit = nil
                        self.pressedUnitCol = nil
                        self.pressedUnitRow = nil

                        -- Store the card but don't start dragging yet
                        -- Drag threshold will determine if this is a tap or drag
                        self.pressedCard = card
                        self.pressedCardIndex = i
                        return
                    end
                end
            end
        end
    end

    -- Shared release logic (called from both mousereleased and touchreleased)
    function self:handleRelease(x, y)
        -- Tutorial bubble tap-to-advance (does not consume the event)
        if self.isTutorial and self.tutorialManager then
            self.tutorialManager:handleTap(x, y)
        end

        -- ── Tooltip upgrade button ────────────────────────────────────────────
        if self.tooltip:isVisible() then
            local upgradeIndex = self.tooltip:checkUpgradeClick(x, y)
            if upgradeIndex then
                local unit = self.tooltip.unit
                -- Cannot upgrade enemy units in online mode
                if self.isOnline and unit.owner ~= self.playerRole then
                    return
                end
                local cost = UnitRegistry.unitCosts[unit.unitType] or 3
                if not self.isSandbox and self.playerCoins < cost then
                    print("Not enough coins for upgrade")
                    self.pressedUnit = nil
                    self.pressedUnitCol = nil
                    self.pressedUnitRow = nil
                    return
                end
                if unit:upgrade(upgradeIndex) then
                    if not self.isSandbox then self.playerCoins = self.playerCoins - cost end
                    print(string.format("Upgraded %s with upgrade %d to level %d",
                          unit.unitType, upgradeIndex, unit.level))
                    for i, card in ipairs(self.cards) do
                        if card.unitType == unit.unitType then
                            table.remove(self.cards, i); break
                        end
                    end
                    for j, u in ipairs(self.drawnCardTypes) do
                        if u == unit.unitType then
                            table.remove(self.drawnCardTypes, j); break
                        end
                    end
                    -- Send upgrade over the network
                    self:sendMsg({type = "upgrade_unit",
                                  col = unit.col, row = unit.row,
                                  upgradeIndex = upgradeIndex})
                    local hasMatchingCard = false
                    for _, card in ipairs(self.cards) do
                        if card.unitType == unit.unitType then
                            hasMatchingCard = true; break
                        end
                    end
                    self.tooltip:show(unit, hasMatchingCard)
                end
                self.pressedUnit = nil
                self.pressedUnitCol = nil
                self.pressedUnitRow = nil
                return
            end
        end

        -- ── Tap on unit → tooltip ─────────────────────────────────────────────
        if self.pressedUnit and not self.draggedUnit then
            local unit = self.pressedUnit
            self.pressedUnit = nil
            self.pressedUnitCol = nil
            self.pressedUnitRow = nil
            -- Only show upgrade button for units the local player owns
            local isOwnUnit = not self.isOnline or unit.owner == self.playerRole
            local hasMatchingCard = false
            if isOwnUnit then
                for _, card in ipairs(self.cards) do
                    if card.unitType == unit.unitType then
                        hasMatchingCard = true; break
                    end
                end
            end
            self.tooltip:toggle(unit, hasMatchingCard)
            return
        end

        -- ── Tap on card → tooltip ─────────────────────────────────────────────
        if self.pressedCard and not self.draggedCard then
            local card = self.pressedCard
            self.pressedCard = nil
            self.pressedCardIndex = nil
            self.tooltip:showCard(card)
            return
        end

        -- ── Unit repositioning drag ───────────────────────────────────────────
        if self.draggedUnit then
            local col, row = self.grid:worldToGrid(x, y)
            local origCol = self.draggedUnitOriginalCol
            local origRow = self.draggedUnitOriginalRow
            -- In online mode only allow repositioning within own zone
            local zoneOwner = self.isOnline and self.playerRole or nil
            if col and row and self.grid:canPlaceUnit(col, row, zoneOwner) then
                self.draggedUnit.col = col
                self.draggedUnit.row = row
                self.grid:placeUnit(col, row, self.draggedUnit)
                -- Sync: tell opponent to mirror the move
                self:sendMsg({type = "remove_unit", col = origCol, row = origRow})
                self:sendMsg({type = "place_unit",
                              unitType = self.draggedUnit.unitType,
                              col = col, row = row,
                              owner = self.draggedUnit.owner,
                              level = self.draggedUnit.level,
                              activeUpgrades = self.draggedUnit.activeUpgrades})
                print(string.format("Repositioned unit to [%d, %d]", col, row))
            else
                self.draggedUnit.col = origCol
                self.draggedUnit.row = origRow
                self.grid:placeUnit(origCol, origRow, self.draggedUnit)
                print(string.format("Returned unit to [%d, %d]", origCol, origRow))
            end
            self.draggedUnit.dragX = nil
            self.draggedUnit.dragY = nil
            self.draggedUnit = nil
            self.draggedUnitOriginalCol = nil
            self.draggedUnitOriginalRow = nil
            return
        end

        -- ── Card placement drag ───────────────────────────────────────────────
        if self.draggedCard then
            local col, row = self.grid:worldToGrid(x, y)
            if col and row then
                local owner    = self.grid:getOwner(row)
                local unitType = self.draggedCard.unitType
                local cell     = self.grid:getCell(col, row)
                local cost     = UnitRegistry.unitCosts[unitType] or 3
                -- In online mode restrict placement to local player's zone
                if self.isOnline and owner ~= self.playerRole then
                    self.draggedCard:snapBack()
                elseif not self.isSandbox and self.playerCoins < cost then
                    print("Not enough coins")
                    self.draggedCard:snapBack()
                elseif cell and cell.occupied and cell.unit then
                    local targetUnit = cell.unit
                    if targetUnit.unitType == unitType
                       and targetUnit.owner == owner
                       and targetUnit.level < 3 then
                        if targetUnit:upgrade() then
                            if not self.isSandbox then self.playerCoins = self.playerCoins - cost end
                            print(string.format("Upgraded Player %d %s to level %d (direct drop)",
                                  owner, unitType, targetUnit.level))
                            for i, card in ipairs(self.cards) do
                                if card == self.draggedCard then
                                    table.remove(self.cards, i); break
                                end
                            end
                            for j, u in ipairs(self.drawnCardTypes) do
                                if u == unitType then
                                    table.remove(self.drawnCardTypes, j); break
                                end
                            end
                            self:sendMsg({type = "upgrade_unit",
                                          col = col, row = row,
                                          upgradeIndex = nil})
                        else
                            print(string.format("Player %d %s is already max level", owner, unitType))
                            self.draggedCard:snapBack()
                        end
                    else
                        self.draggedCard:snapBack()
                    end
                elseif self.grid:canPlaceUnit(col, row, self.isOnline and self.playerRole or nil) then
                    local existingUnit = self.grid:findUnitByTypeAndOwner(unitType, owner)
                    if existingUnit then
                        if existingUnit:upgrade() then
                            if not self.isSandbox then self.playerCoins = self.playerCoins - cost end
                            print(string.format("Upgraded Player %d %s to level %d",
                                  owner, unitType, existingUnit.level))
                            for i, card in ipairs(self.cards) do
                                if card == self.draggedCard then
                                    table.remove(self.cards, i); break
                                end
                            end
                            for j, u in ipairs(self.drawnCardTypes) do
                                if u == unitType then
                                    table.remove(self.drawnCardTypes, j); break
                                end
                            end
                            self:sendMsg({type = "upgrade_unit",
                                          col = existingUnit.col, row = existingUnit.row,
                                          upgradeIndex = nil})
                        else
                            print(string.format("Player %d %s is already max level", owner, unitType))
                            self.draggedCard:snapBack()
                        end
                    else
                        local unitSprites = self.sprites[unitType]
                        local unit = UnitRegistry.createUnit(unitType, row, col, owner, unitSprites)
                        if self.grid:placeUnit(col, row, unit) then
                            if not self.isSandbox then self.playerCoins = self.playerCoins - cost end
                            for i, card in ipairs(self.cards) do
                                if card == self.draggedCard then
                                    table.remove(self.cards, i); break
                                end
                            end
                            for j, u in ipairs(self.drawnCardTypes) do
                                if u == unitType then
                                    table.remove(self.drawnCardTypes, j); break
                                end
                            end
                            self:sendMsg({type = "place_unit",
                                          unitType = unitType,
                                          col = col, row = row,
                                          owner = owner})
                            print(string.format("Placed Player %d %s at [%d, %d]",
                                  owner, unitType, col, row))
                        end
                    end
                else
                    self.draggedCard:snapBack()
                end
            else
                self.draggedCard:snapBack()
            end
            self.draggedCard:stopDrag()
            self.draggedCard = nil
            return
        end

        -- ── Empty tap → hide tooltip ──────────────────────────────────────────
        if self.tooltip:isVisible() then
            self.tooltip:hide()
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
            self:handleRelease(x, y)
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

        -- During setup, also check for card press (tap vs drag detection)
        if self.state == "setup" then
            for i = #self.cards, 1, -1 do  -- Iterate backwards for proper z-order
                local card = self.cards[i]
                if card:contains(x, y) then
                    -- Hide tooltip when pressing card
                    self.tooltip:hide()

                    -- Clear pressedUnit to prevent tooltip on card release
                    self.pressedUnit = nil
                    self.pressedUnitCol = nil
                    self.pressedUnitRow = nil

                    -- Store the card but don't start dragging yet
                    -- Drag threshold will determine if this is a tap or drag
                    self.pressedCard = card
                    self.pressedCardIndex = i
                    return
                end
            end
        end
    end

    function self:touchreleased(id, x, y, dx, dy, pressure)
        if self.activeTouchId ~= id then return end
        self.activeTouchId = nil
        self.suit:updateMouse(x, y, false)
        self:handleRelease(x, y)
    end

    function self:keypressed(key)
        if key == 'escape' then
            love.event.quit()
        elseif key == 'r' then
            -- Reset
            self:init()
        end
    end

    function self:focus(hasFocus)
        if hasFocus and self.isOnline and self.socket then
            -- Returning from background: if socket died mid-game, treat as disconnect
            if not self.socket:isConnected() and self.state ~= "finished" then
                print("[GAME] Socket lost while backgrounded, triggering disconnect")
                self.opponentDisconnected = true
            end
        end
    end

    function self:close()
        -- Unregister network callbacks so stale handlers don't fire in future games
        if self.socket then
            if self._cb_relay      then self.socket:removeCallback(self._cb_relay)      end
            if self._cb_oppDisconn then self.socket:removeCallback(self._cb_oppDisconn) end
            if self._cb_disconnect then self.socket:removeCallback(self._cb_disconnect) end
        end
        -- Reset global perspective when leaving the game screen
        Constants.PERSPECTIVE = 1
        AudioManager.setBattleMode(false)
    end

    -- Check if all attack animations have completed
    function self:areAllAnimationsComplete()
        local allUnits = self.grid:getAllUnits()
        for _, unit in ipairs(allUnits) do
            -- Check if unit is mid-attack animation
            if unit.attackAnimProgress < 1 and unit.attackTargetCol and unit.attackTargetRow then
                return false
            end

            -- Check for ranged units with projectiles in flight
            if unit.arrows and #unit.arrows > 0 then
                return false
            end
        end
        return true
    end

    return self
end

return GameScreen
