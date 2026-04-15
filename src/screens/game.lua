-- AutoChest – Game Screen (Solar2D composer scene)
-- TODO-RENDER: draw() and drawUI() are stubbed. Battle simulation is fully intact.
-- Follow lobby.lua pattern: S = local state, onUpdate = enterFrame listener.

local composer     = require("composer")
local Constants    = require("src.constants")
local Grid         = require("src.grid")
local UnitRegistry = require("src.unit_registry")
local Card         = require("src.card")
local Tooltip      = require("src.tooltip")
local json         = require("lib.json")
local DeckManager  = require("src.deck_manager")

local S = {}           -- local state (reset each show)
local scene = composer.newScene()

local function getTime() return system.getTimer() / 1000 end

-- ── Forward declarations ──────────────────────────────────────────────────────

local initState, registerNetworkCallbacks, dealSetupCards
local sendMsg, computeBoardHash, checkBoardSync
local applyOpponentMsg, handleNetworkMessage
local checkBattleStart, beginBattleCountdown, startBattle, resetRound
local generateCards, rebuildCardsFromTypes, launchExitAndEnter
local enterFinishedState, areAllAnimationsComplete
local handlePress, handleMove, handleRelease
local drawUI, syncDisplayLayer

-- ── Initialisation ────────────────────────────────────────────────────────────

initState = function(params)
    params = params or {}
    S.isOnline   = params.isOnline   or false
    S.playerRole = params.playerRole or 1
    S.socket     = params.socket
    S.isSandbox  = params.isSandbox  or false
    S.isTutorial = params.isTutorial or false

    Constants.PERSPECTIVE = S.playerRole

    S.playerName     = _G.PlayerData and _G.PlayerData.username or "You"
    S.playerTrophies = _G.PlayerData and _G.PlayerData.trophies or 0
    S.opponentName   = S.isTutorial and "evil"
                    or (_G.OpponentData and _G.OpponentData.name or "Foe")
    S.opponentTrophies = S.isTutorial and 0
                      or (_G.OpponentData and _G.OpponentData.trophies or 0)

    S.trophyChange   = nil
    S.goldEarned     = nil
    S.matchResultSent = false

    S.localReady    = false
    S.opponentReady = false

    -- Sprite paths (rendering is stubbed; paths stored for TODO-RENDER pass)
    S.bgSpritePath  = 'src/assets/background_battle.png'
    S.bgOffsetY     = 42
    S.goldIconPath  = 'src/assets/ui/gold.png'

    S.sprites = UnitRegistry.loadAllSprites()

    S.grid    = Grid()
    S.tooltip = Tooltip()

    -- Button spring state (physics kept; rendering stubbed)
    S._readySpring  = { scale = 1.0, vel = 0.0, pressed = false }
    S._readyBtnRect = nil
    S._rerollSpring  = { scale = 1.0, vel = 0.0, pressed = false }
    S._rerollBtnRect = nil
    S._emoteSpring  = { scale = 1.0, vel = 0.0, pressed = false }
    S._emoteBtnRect = nil

    S.mouseX = display.contentCenterX
    S.mouseY = display.contentCenterY

    S.state  = "setup"
    S.timer  = 30
    S.battleAccumulator = 0
    S.battleStepCount   = 0
    S.currentPlayer     = 1

    S.roundNumber          = 1
    S.battleUnitsSnapshot  = {}
    S.pendingOpponentMsgs  = {}
    S.pendingWinner        = nil

    S.localBoardHash    = nil
    S.opponentBoardHash = nil

    S.localRoundEndReady    = false
    S.opponentRoundEndReady = false

    S.p1Lives = 3
    S.p2Lives = 3

    S.playerCoins  = S.isTutorial and 10 or 6
    S.rerollCost   = 1
    S.freeRerollUsed = false

    S.cards       = {}
    S.exitingCards = {}
    S.draggedCard  = nil

    S.usingDeck      = DeckManager.initDrawPile()
    S.drawnCardTypes = {}

    S.draggedUnit            = nil
    S.draggedUnitOriginalCol = nil
    S.draggedUnitOriginalRow = nil
    S.draggedUnitOffsetX     = 0
    S.draggedUnitOffsetY     = 0

    S.pressedUnit    = nil
    S.pressedUnitCol = nil
    S.pressedUnitRow = nil
    S.pressX = 0
    S.pressY = 0
    S.hasMoved = false

    S.pressedCard      = nil
    S.pressedCardIndex = nil

    S.activeTouchId = nil
    S._lastTime     = nil
    S._xpHandler    = nil

    -- Tutorial manager (pass callbacks table instead of self)
    S.tutorialManager = nil
    if S.isTutorial then
        local TutorialManager = require('src.tutorial_manager')
        -- Pass S directly: TutorialManager accesses game.grid, game.state, game.sprites, etc.
        -- Wrap the function calls TutorialManager triggers back into module-local fns.
        S._tutorialCallbacks = {
            dealSetupCards       = dealSetupCards,
            beginBattleCountdown = beginBattleCountdown,
            sendMsg              = sendMsg,
        }
        local gameProxy = setmetatable(S._tutorialCallbacks, { __index = S })
        S.tutorialManager = TutorialManager.new(gameProxy)
    end

    S._unitDisplays = {}
    S._cardDisplays = {}

    dealSetupCards()

    AudioManager.setBattleMode(true)
end

-- ── Network helpers ───────────────────────────────────────────────────────────

sendMsg = function(data)
    if S.isOnline and S.socket then
        S.socket:send("relay", data)
    end
end

registerNetworkCallbacks = function()
    local s = S.socket
    S._cb_relay = s:on("relay", function(data)
        handleNetworkMessage(data)
    end)
    S._cb_oppDisconn = s:on("opponent_disconnected", function()
        S.opponentDisconnected = true
    end)
    S._cb_disconnect = s:on("disconnect", function()
        print("[GAME] Socket disconnected")
        if S.state ~= "finished" then
            S.opponentDisconnected = true
        end
    end)
end

computeBoardHash = function()
    local entries = {}
    for row = 1, S.grid.rows do
        for col = 1, S.grid.cols do
            local cell = S.grid.cells[row][col]
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

checkBoardSync = function()
    if not (S.localBoardHash and S.opponentBoardHash) then return end
    if S.localBoardHash == S.opponentBoardHash then
        print("[SYNC] Board OK for round " .. S.roundNumber)
    else
        print("[DESYNC] Round " .. S.roundNumber .. " board mismatch!")
        print("  Local:  " .. S.localBoardHash)
        print("  Remote: " .. S.opponentBoardHash)
    end
    S.localBoardHash    = nil
    S.opponentBoardHash = nil
end

applyOpponentMsg = function(msg)
    local t = msg.type
    if t == "place_unit" then
        local unitSprites = S.sprites[msg.unitType]
        local unit = UnitRegistry.createUnit(msg.unitType, msg.row, msg.col, msg.owner, unitSprites)
        if msg.activeUpgrades then
            for _, idx in ipairs(msg.activeUpgrades) do
                unit:upgrade(idx)
            end
        end
        S.grid:placeUnit(msg.col, msg.row, unit)
    elseif t == "remove_unit" then
        S.grid:removeUnit(msg.col, msg.row)
    elseif t == "upgrade_unit" then
        local unit = S.grid:getUnitAtCell(msg.col, msg.row)
        if unit then unit:upgrade(msg.upgradeIndex) end
    end
end

handleNetworkMessage = function(msg)
    local t = msg.type

    if t == "place_unit" or t == "remove_unit" or t == "upgrade_unit" then
        local inSetup = S.state == "setup" or S.state == "intermission"
                     or S.state == "pre_battle"
        if inSetup then
            table.insert(S.pendingOpponentMsgs, msg)
        else
            applyOpponentMsg(msg)
        end

    elseif t == "ready" then
        S.opponentReady = true
        checkBattleStart()

    elseif t == "battle_start" then
        math.randomseed(msg.seed)
        beginBattleCountdown()

    elseif t == "round_end_ready" then
        S.opponentRoundEndReady = true

    elseif t == "board_sync_check" then
        S.opponentBoardHash = msg.hash
        checkBoardSync()
    end
end

checkBattleStart = function()
    if not (S.localReady and S.opponentReady) then return end
    if S.playerRole == 1 then
        local seed = os.time()
        math.randomseed(seed)
        sendMsg({type = "battle_start", seed = seed})
        beginBattleCountdown()
    end
end

beginBattleCountdown = function()
    if S.usingDeck and #S.drawnCardTypes > 0 then
        DeckManager.returnCards(S.drawnCardTypes)
        S.drawnCardTypes = {}
    end
    S.cards = {}
    S.state          = "pre_battle"
    S.preBattleTimer = 1
end

startBattle = function()
    S.timer = 0
    S.state = "battle"
    AudioManager.setBattleMode(true)
    AudioManager.playSFX("battle-start.mp3")
    S.battleAccumulator = 0
    S.battleStepCount   = 0

    for _, msg in ipairs(S.pendingOpponentMsgs) do
        applyOpponentMsg(msg)
    end
    S.pendingOpponentMsgs = {}

    if S.isOnline then
        S.localBoardHash = computeBoardHash()
        sendMsg({type = "board_sync_check", hash = S.localBoardHash})
        checkBoardSync()
    end

    local allUnits = S.grid:getAllUnits()
    S.battleUnitsSnapshot = {}
    for _, unit in ipairs(allUnits) do
        unit.homeCol = unit.col
        unit.homeRow = unit.row
        table.insert(S.battleUnitsSnapshot, unit)
        unit:onBattleStart(S.grid)
    end

    for _, unit in ipairs(allUnits) do
        local isAlly = (unit.owner == S.playerRole)
        unit.onDeathCallback = function()
            if isAlly then
                AudioManager.playSFX("ally-death.mp3")
            else
                AudioManager.playSFX("enemy-death.mp3", 0.75)
            end
        end
    end

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

resetRound = function()
    local allUnits = S.battleUnitsSnapshot

    for row = 1, S.grid.rows do
        for col = 1, S.grid.cols do
            local cell = S.grid.cells[row][col]
            cell.unit     = nil
            cell.occupied = false
            cell.reserved = false
        end
    end

    for _, unit in ipairs(allUnits) do
        if unit.homeCol and unit.homeRow then
            unit.col = unit.homeCol
            unit.row = unit.homeRow
            unit:resetCombatState()
            S.grid:placeUnit(unit.homeCol, unit.homeRow, unit)
        end
    end

    S.roundNumber          = S.roundNumber + 1
    S.winner               = nil
    S.localReady           = false
    S.opponentReady        = false
    S.freeRerollUsed       = false
    S.playerCoins          = S.playerCoins + 6
    S.pendingOpponentMsgs  = {}
    S.draggedUnit          = nil
    S.draggedCard          = nil
    S.pressedUnit          = nil
    S.pressedCard          = nil
    S.tooltip:hide()
    dealSetupCards()

    S.state = "setup"
    S.timer = 30
end

generateCards = function()
    S.cards = {}
    local cardWidth   = 80  * Constants.SCALE
    local cardHeight  = 100 * Constants.SCALE
    local cardSpacing = 30  * Constants.SCALE
    local totalWidth  = (cardWidth * 3) + (cardSpacing * 2)
    local startX      = (Constants.GAME_WIDTH - totalWidth) / 2

    local gridBottom = Constants.GRID_OFFSET_Y + Constants.GRID_HEIGHT
    S.cardY = math.floor((gridBottom + Constants.GAME_HEIGHT) / 2 - cardHeight / 2)
    local cardY = S.cardY

    for i = 1, 3 do
        local x        = startX + (i - 1) * (cardWidth + cardSpacing)
        local unitType = UnitRegistry.getRandomUnitType()
        local sprite   = S.sprites[unitType].front
        local card     = Card(x, cardY, sprite, i, unitType)
        table.insert(S.cards, card)
    end

    S.rerollButtonSize = 40 * Constants.SCALE
    local cardsEndX = startX + totalWidth
    S.rerollButtonX = cardsEndX + cardSpacing
    S.rerollButtonY = cardY + (cardHeight - S.rerollButtonSize) / 2
    S.emoteButtonX  = startX - cardSpacing - S.rerollButtonSize
    S.emoteButtonY  = S.rerollButtonY
end

rebuildCardsFromTypes = function(unitTypes)
    S.cards = {}
    local cardWidth   = 80  * Constants.SCALE
    local cardHeight  = 100 * Constants.SCALE
    local cardSpacing = 30  * Constants.SCALE
    local totalWidth  = (cardWidth * 3) + (cardSpacing * 2)
    local startX      = (Constants.GAME_WIDTH - totalWidth) / 2
    local gridBottom  = Constants.GRID_OFFSET_Y + Constants.GRID_HEIGHT
    S.cardY = math.floor((gridBottom + Constants.GAME_HEIGHT) / 2 - cardHeight / 2)
    local cardY = S.cardY

    for i, unitType in ipairs(unitTypes) do
        local x          = startX + (i - 1) * (cardWidth + cardSpacing)
        local sprite     = S.sprites[unitType].front
        local trimBottom = S.sprites[unitType].frontTrimBottom or 0
        local card       = Card(x, cardY, sprite, i, unitType, trimBottom)
        card.upFrames    = S.sprites[unitType] and S.sprites[unitType].upFrames
        table.insert(S.cards, card)
    end

    S.rerollButtonSize = 40 * Constants.SCALE
    local cardsEndX = startX + totalWidth
    S.rerollButtonX = cardsEndX + cardSpacing
    S.rerollButtonY = cardY + (cardHeight - S.rerollButtonSize) / 2
    S.emoteButtonX  = startX - cardSpacing - S.rerollButtonSize
    S.emoteButtonY  = S.rerollButtonY
end

launchExitAndEnter = function(unitTypes)
    S.exitingCards = S.exitingCards or {}
    for i, card in ipairs(S.cards) do
        card:startExitAnim((i % 2 == 0) and 1 or -1)
        table.insert(S.exitingCards, card)
    end
    rebuildCardsFromTypes(unitTypes)
    local offscreenX = Constants.GAME_WIDTH + 80 * Constants.SCALE
    for i, card in ipairs(S.cards) do
        card:setEnterAnim(offscreenX, card.x, card.y, 0.05 + (i - 1) * 0.06)
    end
end

dealSetupCards = function()
    if S.usingDeck and #S.drawnCardTypes > 0 then
        DeckManager.returnCards(S.drawnCardTypes)
        S.drawnCardTypes = {}
    end

    local unitTypes
    if S.isTutorial then
        local pool = {"boney", "marrow", "knight", "mage"}
        unitTypes = {}
        for _ = 1, 3 do
            table.insert(unitTypes, pool[math.random(#pool)])
        end
    elseif S.usingDeck then
        unitTypes = DeckManager.drawCards(3)
        if S.isSandbox then
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

    S.drawnCardTypes = unitTypes
    launchExitAndEnter(unitTypes)
end

enterFinishedState = function(winnerId)
    S.state  = "finished"
    S.winner = winnerId

    if S.isOnline and not S.isSandbox and not S.trophyChange then
        local didWin    = (winnerId == S.playerRole)
        S.trophyChange  = didWin and 20 or -15
        S.goldEarned    = didWin and 10 or 5

        if not S.matchResultSent then
            S.matchResultSent = true
            if S.socket then
                S.socket:send("match_result", {
                    winner_id = didWin and (_G.PlayerData and _G.PlayerData.id or 0) or 0,
                    did_win   = didWin
                })
            end

            S.playerTrophies = math.max(0, S.playerTrophies + S.trophyChange)
            if _G.PlayerData then
                _G.PlayerData.trophies = S.playerTrophies
                _G.PlayerData.gold     = (_G.PlayerData.gold or 0) + S.goldEarned
            end
        end

        if S.socket and not S._xpHandler then
            S._xpHandler = S.socket:on("currency_update", function(data)
                if _G.PlayerData then
                    if data.xp      ~= nil then _G.PlayerData.xp      = data.xp      end
                    if data.level   ~= nil then _G.PlayerData.level   = data.level   end
                    if data.gold    ~= nil then _G.PlayerData.gold    = data.gold    end
                    if data.gems    ~= nil then _G.PlayerData.gems    = data.gems    end
                    if data.unlocks ~= nil then _G.PlayerData.unlocks = data.unlocks end
                end
            end)
        end
    end
end

-- ── Game loop ─────────────────────────────────────────────────────────────────

local function onUpdate(event)
    local now = event.time / 1000
    local dt  = math.min(now - (S._lastTime or now), 1 / 30)
    S._lastTime = now

    if S.isTutorial and S.tutorialManager then
        S.tutorialManager:update(dt)
    end

    if S.isOnline and S.socket then
        local ok, err = pcall(function() S.socket:update() end)
        if not ok then
            print("[GAME] Socket error: " .. tostring(err))
            S.opponentDisconnected = true
        end
    end

    if S.opponentDisconnected and S.state ~= "finished" then
        S.opponentDisconnected = false
        enterFinishedState(S.playerRole)
        S.statusMsg = "Oponente desconectado. ¡Ganaste!"
    end

    if S.state == "intermission" then
        S.intermissionTimer = S.intermissionTimer - dt
        if S.intermissionTimer <= 0 then
            if S.isTutorial then
                local w = S.pendingWinner or 1
                S.pendingWinner = nil
                enterFinishedState(w)
            else
                local w = S.pendingWinner
                S.pendingWinner = nil
                if w == 1 then
                    S.p2Lives = S.p2Lives - 1
                    if S.p2Lives <= 0 then
                        if S.isSandbox then S.p2Lives = 3; resetRound() else enterFinishedState(1) end
                    else resetRound() end
                elseif w == 2 then
                    S.p1Lives = S.p1Lives - 1
                    if S.p1Lives <= 0 then
                        if S.isSandbox then S.p1Lives = 3; resetRound() else enterFinishedState(2) end
                    else resetRound() end
                else
                    S.state = "setup"
                end
            end
        end
    end

    if S.state == "pre_battle" then
        S.preBattleTimer = S.preBattleTimer - dt
        if S.preBattleTimer <= 0 then
            startBattle()
        end
    end

    if S.state == "setup" and not S.isTutorial then
        S.timer = S.timer - dt
        if S.timer <= 0 then
            S.timer = 0
            if not S.isOnline then
                beginBattleCountdown()
            elseif not S.localReady then
                S.localReady = true
                sendMsg({type = "ready"})
                checkBattleStart()
            end
        end
    end

    if S.state == "setup" and #S.cards > 0 then
        local upgradeableTypes = {}
        for _, unit in ipairs(S.grid:getAllUnits()) do
            local isOwn = (not S.isOnline) or (unit.owner == S.playerRole)
            if isOwn and not unit.isDead and unit.level < 3 then
                upgradeableTypes[unit.unitType] = true
            end
        end
        local CARD_ANIM_DURATION = 6 / 8
        for _, card in ipairs(S.cards) do
            card:update(dt)
            if upgradeableTypes[card.unitType] then
                if card.upAnimTimer <= 0 then card.upAnimTimer = CARD_ANIM_DURATION end
            else
                card.upAnimTimer = 0
            end
        end
    end

    if S.exitingCards and #S.exitingCards > 0 then
        for i = #S.exitingCards, 1, -1 do
            local card = S.exitingCards[i]
            card:update(dt)
            if not card.isExiting then table.remove(S.exitingCards, i) end
        end
    end

    if S.state == "battle" then
        local FIXED_DT = 1 / 60
        S.battleAccumulator = S.battleAccumulator + dt
        while S.battleAccumulator >= FIXED_DT do
            S.battleAccumulator = S.battleAccumulator - FIXED_DT
            S.battleStepCount   = S.battleStepCount   + 1

            local allUnits = S.grid:getAllUnits()
            for _, unit in ipairs(allUnits) do
                unit:update(FIXED_DT, S.grid)
            end

            local p1Alive, p2Alive = 0, 0
            for _, unit in ipairs(allUnits) do
                if not unit.isDead then
                    if unit.owner == 1 then p1Alive = p1Alive + 1
                    else                    p2Alive = p2Alive + 1 end
                end
            end

            if p1Alive == 0 or p2Alive == 0 then
                S.state  = "battle_ending"
                S.winner = p1Alive > 0 and 1 or 2
                break
            end
        end
    elseif S.state == "battle_ending" then
        local allUnits = S.grid:getAllUnits()
        for _, unit in ipairs(allUnits) do
            unit:update(dt, S.grid)
        end

        if areAllAnimationsComplete() then
            if not S.localRoundEndReady then
                S.localRoundEndReady = true
                if S.isOnline then sendMsg({type = "round_end_ready"}) end
            end

            local bothDone = S.localRoundEndReady and
                             (not S.isOnline or S.opponentRoundEndReady)
            if bothDone then
                S.localRoundEndReady    = false
                S.opponentRoundEndReady = false
                local loser = (S.winner == 1) and 2 or 1
                if S.playerRole == loser then S.playerCoins = S.playerCoins + 3 end

                AudioManager.playSFX("battle-end.mp3")
                S.pendingWinner     = S.winner
                S.state             = "intermission"
                S.intermissionTimer = 2.5
            end
        end
    end

    local allUnitsForVisuals = S.grid:getAllUnits()
    for _, unit in ipairs(allUnitsForVisuals) do
        unit:updateVisuals(dt, S.state)
    end

    S.grid:update(dt, S.mouseX, S.mouseY)

    -- Spring physics (buttons – used for hit-rect squish even while rendering is stubbed)
    local emTarget = S._emoteSpring.pressed and 0.93 or 1.0
    local emAccel  = -480 * (S._emoteSpring.scale - emTarget) - 18 * S._emoteSpring.vel
    S._emoteSpring.vel   = S._emoteSpring.vel   + emAccel * dt
    S._emoteSpring.scale = S._emoteSpring.scale + S._emoteSpring.vel * dt
    S._emoteSpring.scale = math.max(0.85, math.min(1.12, S._emoteSpring.scale))

    local rrTarget = S._rerollSpring.pressed and 0.93 or 1.0
    local rrAccel  = -480 * (S._rerollSpring.scale - rrTarget) - 18 * S._rerollSpring.vel
    S._rerollSpring.vel   = S._rerollSpring.vel   + rrAccel * dt
    S._rerollSpring.scale = S._rerollSpring.scale + S._rerollSpring.vel * dt
    S._rerollSpring.scale = math.max(0.85, math.min(1.12, S._rerollSpring.scale))

    local rspTarget = S._readySpring.pressed and 0.93 or 1.0
    local rspAccel  = -480 * (S._readySpring.scale - rspTarget) - 18 * S._readySpring.vel
    S._readySpring.vel   = S._readySpring.vel   + rspAccel * dt
    S._readySpring.scale = S._readySpring.scale + S._readySpring.vel * dt
    S._readySpring.scale = math.max(0.85, math.min(1.12, S._readySpring.scale))

    drawUI()
    syncDisplayLayer()
end

-- ── Rendering ────────────────────────────────────────────────────────────────

local function draw() end   -- no-op: Solar2D display objects handle rendering

drawUI = function()
    -- Set hit-rects used by input handling
    --
    -- Hit-rects needed for input (set here when rendering is restored):
    if S.state == "setup" then
        local buttonHeight = 40 * Constants.SCALE
        local gridBottom   = Constants.GRID_OFFSET_Y + Constants.GRID_HEIGHT
        local buttonY      = ((gridBottom + (S.cardY or gridBottom)) / 2) - (buttonHeight / 2)
        local buttonPadding = 20 * Constants.SCALE
        local buttonWidth   = 120 * Constants.SCALE  -- approximate; will be precise in render pass
        local buttonX       = (Constants.GAME_WIDTH - buttonWidth) / 2
        local maxFloat      = math.floor(4 * Constants.SCALE)

        S._readyBtnRect  = { x = buttonX, y = buttonY - maxFloat, w = buttonWidth, h = buttonHeight + maxFloat }

        if S.rerollButtonX then
            local rsz = S.rerollButtonSize or (40 * Constants.SCALE)
            S._rerollBtnRect = { x = S.rerollButtonX, y = S.rerollButtonY - maxFloat, w = rsz, h = rsz + maxFloat }
            S._emoteBtnRect  = { x = S.emoteButtonX,  y = S.emoteButtonY  - maxFloat, w = rsz, h = rsz + maxFloat }
        end
    end
end

-- ── syncDisplayLayer ─────────────────────────────────────────────────────────
-- Updates all Solar2D display objects to match current game state.
-- Called at the end of every onUpdate().

syncDisplayLayer = function()
    if not S.grid             then return end
    if not scene._unitsGroup  then return end
    if not S._unitDisplays    then S._unitDisplays = {} end
    if not S._cardDisplays    then S._cardDisplays = {} end

    local CS  = Constants.CELL_SIZE
    local sc  = Constants.SCALE
    local pad = math.max(3, math.floor(4 * sc))

    -- ── Unit display objects ──────────────────────────────────────────────────
    local allUnits = S.grid:getAllUnits()
    local inGrid   = {}
    for _, u in ipairs(allUnits) do inGrid[u] = true end
    if S.draggedUnit then inGrid[S.draggedUnit] = true end

    -- Purge stale entries (collect first, remove after to avoid modifying during pairs)
    local staleUnits = {}
    for u in pairs(S._unitDisplays) do
        if not inGrid[u] then staleUnits[#staleUnits + 1] = u end
    end
    for _, u in ipairs(staleUnits) do
        display.remove(S._unitDisplays[u].group)
        S._unitDisplays[u] = nil
    end

    for _, u in ipairs(allUnits) do
        local wx, wy
        if u == S.draggedUnit and u.dragX and u.dragY then
            wx = u.dragX - CS / 2
            wy = u.dragY - CS / 2
        else
            wx, wy = S.grid:gridToWorld(u.col, u.row)
        end
        local ucx = wx + CS / 2
        local ucy = wy + CS / 2

        local disp = S._unitDisplays[u]
        if not disp then
            local grp   = display.newGroup()
            scene._unitsGroup:insert(grp)

            local bodyW = CS - pad * 2
            local bodyH = CS - pad * 2
            local rad   = math.max(2, math.floor(3 * sc))
            local body  = display.newRoundedRect(grp, 0, 0, bodyW, bodyH, rad)
            if u.owner == 1 then
                body:setFillColor(0.18, 0.38, 0.80)
                body:setStrokeColor(0.45, 0.65, 1.00)
            else
                body:setFillColor(0.80, 0.18, 0.18)
                body:setStrokeColor(1.00, 0.45, 0.45)
            end
            body.strokeWidth = math.max(1, math.floor(sc))

            local lbl = display.newText({
                parent   = grp,
                text     = u.unitType:sub(1, 3):upper(),
                x = 0, y = -bodyH * 0.12,
                font     = Fonts.tiny.name,
                fontSize = Fonts.tiny.size,
                align    = "center",
            })
            lbl:setFillColor(1, 1, 1)

            local lvl = display.newText({
                parent   = grp,
                text     = "L" .. (u.level or 0),
                x = 0, y = bodyH * 0.22,
                font     = Fonts.tiny.name,
                fontSize = Fonts.tiny.size,
                align    = "center",
            })
            lvl:setFillColor(1, 1, 0.5)

            -- Health bar
            local hbH  = math.max(3, math.floor(3 * sc))
            local hbW  = bodyW - 4
            local hbY  = bodyH / 2 - hbH - 2
            local hbBg = display.newRect(grp, 0, hbY, hbW, hbH)
            hbBg:setFillColor(0.12, 0.12, 0.12, 0.9)

            -- Fill anchored to its left edge so xScale shrinks rightward
            local hbFill = display.newRect(grp, -hbW / 2, hbY, hbW, hbH)
            hbFill.anchorX = 0

            disp = { group=grp, body=body, lbl=lbl, lvl=lvl,
                     hbFill=hbFill, hbW=hbW }
            S._unitDisplays[u] = disp
        end

        -- Position
        disp.group.x = ucx
        disp.group.y = ucy

        -- Level text
        disp.lvl.text = "L" .. (u.level or 0)

        -- Health bar scale (xScale shrinks from left anchor)
        local maxHp = math.max(1, u.maxHealth or 1)
        local ratio = math.max(0, math.min(1, (u.health or maxHp) / maxHp))
        disp.hbFill.xScale = math.max(0.001, ratio)
        if     ratio < 0.33 then disp.hbFill:setFillColor(0.90, 0.20, 0.20, 1)
        elseif ratio < 0.66 then disp.hbFill:setFillColor(0.90, 0.75, 0.10, 1)
        else                     disp.hbFill:setFillColor(0.20, 0.88, 0.20, 1) end

        -- Dead units fade
        disp.group.alpha = u.isDead and 0.32 or 1.0

        if S.draggedUnit == u then disp.group:toFront() end
    end

    -- ── Card display objects ──────────────────────────────────────────────────
    local activeCrds = {}
    for _, c in ipairs(S.cards       or {}) do activeCrds[c] = true end
    for _, c in ipairs(S.exitingCards or {}) do activeCrds[c] = true end

    local staleCards = {}
    for c in pairs(S._cardDisplays) do
        if not activeCrds[c] then staleCards[#staleCards + 1] = c end
    end
    for _, c in ipairs(staleCards) do
        display.remove(S._cardDisplays[c].group)
        S._cardDisplays[c] = nil
    end

    local allCards = {}
    for _, c in ipairs(S.cards       or {}) do table.insert(allCards, c) end
    for _, c in ipairs(S.exitingCards or {}) do table.insert(allCards, c) end

    for _, c in ipairs(allCards) do
        local cW   = c.width  or (80  * sc)
        local cH   = c.height or (100 * sc)
        local disp = S._cardDisplays[c]

        if not disp then
            local grp  = display.newGroup()
            scene._cardsGroup:insert(grp)

            local body = display.newRoundedRect(grp, 0, 0, cW, cH,
                             math.max(2, math.floor(4 * sc)))
            body:setFillColor(0.18, 0.18, 0.28)
            body:setStrokeColor(0.40, 0.40, 0.52)
            body.strokeWidth = math.max(1, math.floor(2 * sc))

            local nameLbl = display.newText({
                parent   = grp,
                text     = c.unitType:sub(1,1):upper() .. c.unitType:sub(2),
                x = 0, y = -cH * 0.27,
                font     = Fonts.tiny.name,
                fontSize = Fonts.tiny.size,
                align    = "center",
            })
            nameLbl:setFillColor(0.85, 0.85, 0.85)

            local cost    = UnitRegistry.unitCosts[c.unitType] or 3
            local costLbl = display.newText({
                parent   = grp,
                text     = tostring(cost) .. "g",
                x = 0, y = cH * 0.18,
                font     = Fonts.small.name,
                fontSize = Fonts.small.size,
                align    = "center",
            })
            costLbl:setFillColor(1.00, 0.88, 0.28)

            disp = { group=grp, body=body }
            S._cardDisplays[c] = disp
        end

        -- card.x/y is top-left; Solar2D groups are centered
        disp.group.x = c.x + cW / 2
        disp.group.y = c.y + cH / 2

        local alpha = 1
        if     c.isExiting  then alpha = c.exitAlpha  or 0
        elseif c.isEntering then alpha = c.enterAlpha or 0 end
        disp.group.alpha    = math.max(0, alpha)
        disp.group.rotation = c.isExiting and math.deg(c.exitRotation or 0) or 0

        if c == S.draggedCard then disp.group:toFront() end
    end

    -- ── UI label updates ──────────────────────────────────────────────────────
    if scene._playerNameText then scene._playerNameText.text = S.playerName  or "You" end
    if scene._oppNameText    then scene._oppNameText.text    = S.opponentName or "Foe" end

    if scene._timerText then
        if S.state == "setup" then
            scene._timerText.text      = tostring(math.ceil(math.max(0, S.timer or 0)))
            scene._timerText.isVisible = true
        else
            scene._timerText.isVisible = false
        end
    end

    if scene._coinsText then
        scene._coinsText.text      = tostring(S.playerCoins or 0) .. "g"
        scene._coinsText.isVisible = (S.state == "setup")
    end

    if scene._stateText then
        local txt, vis = "", false
        if     S.state == "pre_battle"   then txt = "GO!";                     vis = true
        elseif S.state == "intermission" then txt = "ROUND " .. (S.roundNumber or 1); vis = true
        elseif S.state == "finished"     then
            txt = (S.winner == (S.playerRole or 1)) and "YOU WIN!" or "YOU LOSE"
            vis = true
        end
        scene._stateText.text      = txt
        scene._stateText.isVisible = vis
    end

    -- Life pips
    if scene._p1Pips then
        for i = 1, 3 do
            if scene._p1Pips[i] then
                if (S.p1Lives or 3) >= i then scene._p1Pips[i]:setFillColor(0.90, 0.85, 0.30, 1)
                else                          scene._p1Pips[i]:setFillColor(0.25, 0.25, 0.25, 0.5) end
            end
        end
    end
    if scene._p2Pips then
        for i = 1, 3 do
            if scene._p2Pips[i] then
                if (S.p2Lives or 3) >= i then scene._p2Pips[i]:setFillColor(0.90, 0.85, 0.30, 1)
                else                          scene._p2Pips[i]:setFillColor(0.25, 0.25, 0.25, 0.5) end
            end
        end
    end

    -- Button visibility + position (follow hit-rects set by drawUI)
    if scene._readyBtn then
        if S._readyBtnRect then
            local rb = S._readyBtnRect
            scene._readyBtn.x         = rb.x + rb.w / 2
            scene._readyBtn.y         = rb.y + rb.h / 2
            scene._readyBtn.isVisible = (S.state == "setup") and not S.localReady
        else
            scene._readyBtn.isVisible = false
        end
    end
    if scene._rerollBtn then
        if S._rerollBtnRect then
            local rb = S._rerollBtnRect
            scene._rerollBtn.x         = rb.x + rb.w / 2
            scene._rerollBtn.y         = rb.y + rb.h / 2
            scene._rerollBtn.isVisible = (S.state == "setup")
        else
            scene._rerollBtn.isVisible = false
        end
    end
    if scene._finishedGroup then
        scene._finishedGroup.isVisible = (S.state == "finished")
    end

    -- Apply spring scale to buttons
    if scene._readyBtn  then
        scene._readyBtn.xScale  = S._readySpring.scale
        scene._readyBtn.yScale  = S._readySpring.scale
    end
    if scene._rerollBtn then
        scene._rerollBtn.xScale = S._rerollSpring.scale
        scene._rerollBtn.yScale = S._rerollSpring.scale
    end
end

areAllAnimationsComplete = function()
    local allUnits = S.grid:getAllUnits()
    for _, unit in ipairs(allUnits) do
        if unit.attackAnimProgress < 1 and unit.attackTargetCol and unit.attackTargetRow then
            return false
        end
        if unit.arrows and #unit.arrows > 0 then
            return false
        end
    end
    return true
end

-- ── Input ─────────────────────────────────────────────────────────────────────

handlePress = function(x, y)
    S.pressX     = x
    S.pressY     = y
    S.pressedUnit = nil
    S.hasMoved   = false

    local function checkButtonSprings()
        if S.state ~= "setup" then return end
        if S._readyBtnRect then
            local rb = S._readyBtnRect
            if x >= rb.x and x <= rb.x + rb.w and y >= rb.y and y <= rb.y + rb.h then
                S._readySpring.pressed = true
            end
        end
        if S._rerollBtnRect then
            local rb = S._rerollBtnRect
            if x >= rb.x and x <= rb.x + rb.w and y >= rb.y and y <= rb.y + rb.h then
                S._rerollSpring.pressed = true
            end
        end
        if S._emoteBtnRect then
            local rb = S._emoteBtnRect
            if x >= rb.x and x <= rb.x + rb.w and y >= rb.y and y <= rb.y + rb.h then
                S._emoteSpring.pressed = true
            end
        end
    end

    local col, row = S.grid:worldToGrid(x, y)
    if col and row then
        local unit = S.grid:getUnitAtCell(col, row)
        if unit then
            S.pressedUnit    = unit
            S.pressedUnitCol = col
            S.pressedUnitRow = row
            checkButtonSprings()
            return
        end
    end

    if S.state == "setup" then
        for i = #S.cards, 1, -1 do
            local card = S.cards[i]
            if card:contains(x, y) then
                S.tooltip:hide()
                S.pressedUnit    = nil
                S.pressedUnitCol = nil
                S.pressedUnitRow = nil
                S.pressedCard      = card
                S.pressedCardIndex = i
                return
            end
        end
    end

    checkButtonSprings()
end

handleMove = function(x, y)
    S.mouseX = x
    S.mouseY = y

    if S.pressedUnit or S.draggedUnit or S.draggedCard or S.pressedCard then
        local distMoved = math.sqrt((x - S.pressX)^2 + (y - S.pressY)^2)
        if distMoved > 10 then S.hasMoved = true end
    end

    if S.pressedCard and not S.draggedCard and S.state == "setup" and S.hasMoved then
        S.draggedCard = S.pressedCard
        S.pressedCard:startDrag(S.pressX, S.pressY)
        S.pressedCard:updateDrag(x, y)
        S.pressedCard      = nil
        S.pressedCardIndex = nil
    end

    local isOwnPressedUnit = not S.pressedUnit
        or not S.isOnline
        or S.pressedUnit.owner == S.playerRole
    if S.pressedUnit and not S.draggedUnit and S.state == "setup" and S.hasMoved and isOwnPressedUnit then
        S.tooltip:hide()
        S.draggedUnit            = S.pressedUnit
        S.draggedUnitOriginalCol = S.pressedUnitCol
        S.draggedUnitOriginalRow = S.pressedUnitRow

        local unitX, unitY = S.grid:gridToWorld(S.pressedUnitCol, S.pressedUnitRow)
        S.draggedUnitOffsetX = S.pressX - unitX
        S.draggedUnitOffsetY = S.pressY - unitY
        S.draggedUnit.dragX  = unitX
        S.draggedUnit.dragY  = unitY

        S.grid:removeUnit(S.pressedUnitCol, S.pressedUnitRow)
        S.pressedUnit    = nil
        S.pressedUnitCol = nil
        S.pressedUnitRow = nil
    end

    if S.draggedCard then S.draggedCard:updateDrag(x, y) end

    if S.draggedUnit then
        S.draggedUnit.dragX = x - S.draggedUnitOffsetX
        S.draggedUnit.dragY = y - S.draggedUnitOffsetY
    end
end

handleRelease = function(x, y)
    if S.isTutorial and S.tutorialManager then
        S.tutorialManager:handleTap(x, y)
    end

    S._readySpring.pressed  = false
    S._rerollSpring.pressed = false
    S._emoteSpring.pressed  = false

    -- Ready button
    if S.state == "setup" and S._readyBtnRect then
        local rb = S._readyBtnRect
        if x >= rb.x and x <= rb.x + rb.w and y >= rb.y and y <= rb.y + rb.h then
            if not (S.isOnline and S.localReady) then
                AudioManager.playTap()
                if S.isOnline then
                    S.localReady = true
                    sendMsg({type = "ready"})
                    checkBattleStart()
                else
                    S.timer = 0
                    beginBattleCountdown()
                end
            end
            return
        end
    end

    -- Reroll button
    if S.state == "setup" and S._rerollBtnRect then
        local rb = S._rerollBtnRect
        if x >= rb.x and x <= rb.x + rb.w and y >= rb.y and y <= rb.y + rb.h then
            if S.isSandbox or (not S.freeRerollUsed) or S.playerCoins >= S.rerollCost then
                if not S.isSandbox then
                    if not S.freeRerollUsed then
                        S.freeRerollUsed = true
                        AudioManager.playTap()
                    else
                        S.playerCoins = S.playerCoins - S.rerollCost
                        AudioManager.playSFX("reroll.mp3")
                    end
                else
                    AudioManager.playTap()
                end
                if S.usingDeck then
                    if S.isSandbox and DeckManager.pileSize() < 3 then
                        DeckManager.returnCards(S.drawnCardTypes)
                        S.drawnCardTypes = {}
                        DeckManager.initDrawPile()
                        S.drawnCardTypes = DeckManager.drawCards(3)
                        launchExitAndEnter(S.drawnCardTypes)
                    else
                        local newTypes = DeckManager.reshuffleAndDraw(S.drawnCardTypes, 3)
                        S.drawnCardTypes = newTypes
                        launchExitAndEnter(newTypes)
                    end
                else
                    dealSetupCards()
                end
            end
            return
        end
    end

    -- Tooltip upgrade button
    if S.tooltip:isVisible() then
        local upgradeIndex = S.tooltip:checkUpgradeClick(x, y)
        if upgradeIndex then
            local unit = S.tooltip.unit
            if S.isOnline and unit.owner ~= S.playerRole then return end
            local cost = UnitRegistry.unitCosts[unit.unitType] or 3
            if not S.isSandbox and S.playerCoins < cost then
                print("Not enough coins for upgrade")
                S.pressedUnit = nil; S.pressedUnitCol = nil; S.pressedUnitRow = nil
                return
            end
            if unit:upgrade(upgradeIndex) then
                if not S.isSandbox then S.playerCoins = S.playerCoins - cost end
                print(string.format("Upgraded %s with upgrade %d to level %d",
                      unit.unitType, upgradeIndex, unit.level))
                for i, card in ipairs(S.cards) do
                    if card.unitType == unit.unitType then table.remove(S.cards, i); break end
                end
                for j, u in ipairs(S.drawnCardTypes) do
                    if u == unit.unitType then table.remove(S.drawnCardTypes, j); break end
                end
                sendMsg({type = "upgrade_unit", col = unit.col, row = unit.row, upgradeIndex = upgradeIndex})
                local hasMatchingCard = false
                for _, card in ipairs(S.cards) do
                    if card.unitType == unit.unitType then hasMatchingCard = true; break end
                end
                S.tooltip:show(unit, hasMatchingCard)
            end
            S.pressedUnit = nil; S.pressedUnitCol = nil; S.pressedUnitRow = nil
            return
        end
    end

    -- Tap on unit → tooltip
    if S.pressedUnit and not S.draggedUnit then
        local unit = S.pressedUnit
        S.pressedUnit = nil; S.pressedUnitCol = nil; S.pressedUnitRow = nil
        local isOwnUnit = not S.isOnline or unit.owner == S.playerRole
        local hasMatchingCard = false
        if isOwnUnit then
            for _, card in ipairs(S.cards) do
                if card.unitType == unit.unitType then hasMatchingCard = true; break end
            end
        end
        S.tooltip:toggle(unit, hasMatchingCard)
        return
    end

    -- Tap on card → tooltip
    if S.pressedCard and not S.draggedCard then
        local card = S.pressedCard
        S.pressedCard = nil; S.pressedCardIndex = nil
        S.tooltip:showCard(card)
        return
    end

    -- Unit repositioning drag
    if S.draggedUnit then
        local col, row = S.grid:worldToGrid(x, y)
        local origCol  = S.draggedUnitOriginalCol
        local origRow  = S.draggedUnitOriginalRow
        local zoneOwner = S.isOnline and S.playerRole or nil
        if col and row and S.grid:canPlaceUnit(col, row, zoneOwner) then
            S.draggedUnit.col = col
            S.draggedUnit.row = row
            S.grid:placeUnit(col, row, S.draggedUnit)
            AudioManager.playSFX("place.mp3")
            sendMsg({type = "remove_unit", col = origCol, row = origRow})
            sendMsg({type = "place_unit",
                     unitType = S.draggedUnit.unitType,
                     col = col, row = row,
                     owner = S.draggedUnit.owner,
                     level = S.draggedUnit.level,
                     activeUpgrades = S.draggedUnit.activeUpgrades})
            print(string.format("Repositioned unit to [%d, %d]", col, row))
        else
            S.draggedUnit.col = origCol
            S.draggedUnit.row = origRow
            S.grid:placeUnit(origCol, origRow, S.draggedUnit)
            print(string.format("Returned unit to [%d, %d]", origCol, origRow))
        end
        S.draggedUnit.dragX = nil; S.draggedUnit.dragY = nil
        S.draggedUnit = nil
        S.draggedUnitOriginalCol = nil; S.draggedUnitOriginalRow = nil
        return
    end

    -- Card placement drag
    if S.draggedCard then
        local col, row = S.grid:worldToGrid(x, y)
        if col and row then
            local owner    = S.grid:getOwner(row)
            local unitType = S.draggedCard.unitType
            local cell     = S.grid:getCell(col, row)
            local cost     = UnitRegistry.unitCosts[unitType] or 3
            if S.isOnline and owner ~= S.playerRole then
                S.draggedCard:snapBack()
            elseif not S.isSandbox and S.playerCoins < cost then
                print("Not enough coins")
                S.draggedCard:snapBack()
            elseif cell and cell.occupied and cell.unit then
                local targetUnit = cell.unit
                if targetUnit.unitType == unitType
                   and targetUnit.owner == owner
                   and targetUnit.level < 3 then
                    if targetUnit:upgrade() then
                        if not S.isSandbox then S.playerCoins = S.playerCoins - cost end
                        print(string.format("Upgraded Player %d %s to level %d (direct drop)",
                              owner, unitType, targetUnit.level))
                        for i, card in ipairs(S.cards) do
                            if card == S.draggedCard then table.remove(S.cards, i); break end
                        end
                        for j, u in ipairs(S.drawnCardTypes) do
                            if u == unitType then table.remove(S.drawnCardTypes, j); break end
                        end
                        sendMsg({type = "upgrade_unit", col = col, row = row, upgradeIndex = nil})
                    else
                        print(string.format("Player %d %s is already max level", owner, unitType))
                        S.draggedCard:snapBack()
                    end
                else
                    S.draggedCard:snapBack()
                end
            elseif S.grid:canPlaceUnit(col, row, S.isOnline and S.playerRole or nil) then
                local existingUnit = S.grid:findUnitByTypeAndOwner(unitType, owner)
                if existingUnit then
                    if existingUnit:upgrade() then
                        if not S.isSandbox then S.playerCoins = S.playerCoins - cost end
                        print(string.format("Upgraded Player %d %s to level %d",
                              owner, unitType, existingUnit.level))
                        for i, card in ipairs(S.cards) do
                            if card == S.draggedCard then table.remove(S.cards, i); break end
                        end
                        for j, u in ipairs(S.drawnCardTypes) do
                            if u == unitType then table.remove(S.drawnCardTypes, j); break end
                        end
                        sendMsg({type = "upgrade_unit",
                                  col = existingUnit.col, row = existingUnit.row,
                                  upgradeIndex = nil})
                    else
                        print(string.format("Player %d %s is already max level", owner, unitType))
                        S.draggedCard:snapBack()
                    end
                else
                    local unitSprites = S.sprites[unitType]
                    local unit = UnitRegistry.createUnit(unitType, row, col, owner, unitSprites)
                    if S.grid:placeUnit(col, row, unit) then
                        AudioManager.playSFX("place.mp3")
                        if not S.isSandbox then S.playerCoins = S.playerCoins - cost end
                        for i, card in ipairs(S.cards) do
                            if card == S.draggedCard then table.remove(S.cards, i); break end
                        end
                        for j, u in ipairs(S.drawnCardTypes) do
                            if u == unitType then table.remove(S.drawnCardTypes, j); break end
                        end
                        sendMsg({type = "place_unit",
                                  unitType = unitType,
                                  col = col, row = row,
                                  owner = owner})
                        print(string.format("Placed Player %d %s at [%d, %d]",
                              owner, unitType, col, row))
                    end
                end
            else
                S.draggedCard:snapBack()
            end
        else
            S.draggedCard:snapBack()
        end
        S.draggedCard:stopDrag()
        S.draggedCard = nil
        return
    end

    if S.tooltip:isVisible() then S.tooltip:hide() end
end

local function onTouch(event)
    local x, y = event.x, event.y
    if event.phase == "began" then
        S.activeTouchId = event.id
        handlePress(x, y)
    elseif event.phase == "moved" then
        if event.id == S.activeTouchId then handleMove(x, y) end
    elseif event.phase == "ended" or event.phase == "cancelled" then
        if event.id == S.activeTouchId then
            S.activeTouchId = nil
            handleRelease(x, y)
        end
    end
    return true
end

local function onSystem(event)
    if event.type == "applicationFocus" then
        if S.isOnline and S.socket then
            if not S.socket:isConnected() and S.state ~= "finished" then
                print("[GAME] Socket lost while backgrounded, triggering disconnect")
                S.opponentDisconnected = true
            end
        end
    end
end

-- ── Composer scene lifecycle ──────────────────────────────────────────────────

function scene:create(event)
    local group = self.view
    local W   = Constants.GAME_WIDTH
    local H   = Constants.GAME_HEIGHT
    local sc  = Constants.SCALE
    local cx  = W / 2

    -- Background
    local bg = display.newRect(group, cx, H / 2, W, H)
    bg:setFillColor(0.08, 0.08, 0.12)

    -- ── Chess board ───────────────────────────────────────────────────────────
    local GX   = Constants.GRID_OFFSET_X
    local GY   = Constants.GRID_OFFSET_Y
    local CS   = Constants.CELL_SIZE
    local COLS = Constants.GRID_COLS
    local ROWS = Constants.GRID_ROWS
    local GW   = COLS * CS
    local GH   = ROWS * CS

    local CDARK  = Constants.COLORS.CHESS_DARK
    local CLIGHT = Constants.COLORS.CHESS_LIGHT

    local gridGroup = display.newGroup()
    group:insert(gridGroup)

    for row = 1, ROWS do
        for col = 1, COLS do
            local cellCX = GX + (col - 1) * CS + CS / 2
            local cellCY = GY + (row - 1) * CS + CS / 2
            local cell   = display.newRect(gridGroup, cellCX, cellCY, CS, CS)
            local c      = ((row + col) % 2 == 0) and CDARK or CLIGHT
            cell:setFillColor(c[1], c[2], c[3])
        end
    end

    -- Grid border
    local border = display.newRect(gridGroup, GX + GW / 2, GY + GH / 2, GW, GH)
    border:setFillColor(0, 0, 0, 0)
    border:setStrokeColor(0.30, 0.30, 0.42)
    border.strokeWidth = math.max(1, math.floor(sc))

    -- Zone divider line between P2 (rows 1-4) and P1 (rows 5-8)
    local divY    = GY + (ROWS / 2) * CS
    local divLine = display.newLine(gridGroup, GX, divY, GX + GW, divY)
    divLine:setStrokeColor(0.90, 0.50, 0.20, 0.85)
    divLine.strokeWidth = math.max(1, math.floor(2 * sc))

    -- ── Dynamic content groups ────────────────────────────────────────────────
    self._unitsGroup = display.newGroup()
    group:insert(self._unitsGroup)

    self._cardsGroup = display.newGroup()
    group:insert(self._cardsGroup)

    -- ── UI labels ─────────────────────────────────────────────────────────────
    local tinyS  = Fonts.tiny.size
    local smallS = Fonts.small.size
    local medS   = Fonts.medium.size

    -- Timer (above grid, center)
    self._timerText = display.newText({
        parent   = group,
        text     = "30",
        x        = cx,
        y        = GY - medS / 2 - 4 * sc,
        font     = Fonts.medium.name,
        fontSize = medS,
        align    = "center",
    })
    self._timerText:setFillColor(1, 1, 1)

    -- State overlay: GO!, ROUND X, YOU WIN!, YOU LOSE
    self._stateText = display.newText({
        parent   = group,
        text     = "",
        x        = cx,
        y        = H / 2,
        font     = Fonts.large.name,
        fontSize = Fonts.large.size,
        align    = "center",
    })
    self._stateText:setFillColor(1, 0.90, 0.28)
    self._stateText.isVisible = false

    -- Player name — bottom-right of grid
    self._playerNameText = display.newText({
        parent   = group,
        text     = "You",
        x        = GX + GW,
        y        = GY + GH + 4 * sc + tinyS / 2,
        font     = Fonts.tiny.name,
        fontSize = tinyS,
        align    = "right",
    })
    self._playerNameText.anchorX = 1
    self._playerNameText:setFillColor(0.80, 0.80, 1.00)

    -- Opponent name — top-left of grid
    self._oppNameText = display.newText({
        parent   = group,
        text     = "Foe",
        x        = GX,
        y        = GY - 4 * sc - tinyS / 2,
        font     = Fonts.tiny.name,
        fontSize = tinyS,
        align    = "left",
    })
    self._oppNameText.anchorX = 0
    self._oppNameText:setFillColor(1.00, 0.60, 0.60)

    -- Coins — bottom-left of grid
    self._coinsText = display.newText({
        parent   = group,
        text     = "6g",
        x        = GX,
        y        = GY + GH + 4 * sc + tinyS / 2,
        font     = Fonts.small.name,
        fontSize = smallS,
        align    = "left",
    })
    self._coinsText.anchorX = 0
    self._coinsText:setFillColor(1.00, 0.90, 0.28)

    -- Life pips — P1 (bottom-right row, below grid)
    local pipSz  = math.max(8,  math.floor(10 * sc))
    local pipGap = math.max(2,  math.floor( 3 * sc))
    local p1PipY = GY + GH + 4 * sc + tinyS + 6 * sc + pipSz / 2
    self._p1Pips = {}
    for i = 1, 3 do
        local px  = GX + GW - (i - 1) * (pipSz + pipGap) - pipSz / 2 - 2 * sc
        local pip = display.newRect(group, px, p1PipY, pipSz, pipSz)
        pip:setFillColor(0.90, 0.85, 0.28)
        pip:setStrokeColor(0.55, 0.50, 0.10)
        pip.strokeWidth = 1
        self._p1Pips[i] = pip
    end

    -- Life pips — P2 (top-right row, above grid)
    local p2PipY = GY - 4 * sc - tinyS - 6 * sc - pipSz / 2
    self._p2Pips = {}
    for i = 1, 3 do
        local px  = GX + GW - (i - 1) * (pipSz + pipGap) - pipSz / 2 - 2 * sc
        local pip = display.newRect(group, px, p2PipY, pipSz, pipSz)
        pip:setFillColor(0.90, 0.85, 0.28)
        pip:setStrokeColor(0.55, 0.50, 0.10)
        pip.strokeWidth = 1
        self._p2Pips[i] = pip
    end

    -- ── Buttons (display only – input handled by Runtime onTouch + hit-rects) ─
    local btnW = math.floor(120 * sc)
    local btnH = math.floor(44  * sc)

    -- Initial estimate for Y (corrected each frame by syncDisplayLayer via hit-rects)
    local gridBot  = GY + GH
    local initBtnY = gridBot + math.floor((H - gridBot) * 0.28)

    -- Ready button
    local readyBtn = display.newGroup()
    group:insert(readyBtn)
    readyBtn.x = cx
    readyBtn.y = initBtnY

    local readyBg = display.newRoundedRect(readyBtn, 0, 0, btnW, btnH, 8 * sc)
    readyBg:setFillColor(0.765, 0.639, 0.541)
    readyBg:setStrokeColor(0.865, 0.739, 0.641)
    readyBg.strokeWidth = math.max(1, math.floor(2 * sc))

    local readyLbl = display.newText({
        parent   = readyBtn,
        text     = "READY",
        x = 0, y = 0,
        font     = Fonts.small.name,
        fontSize = smallS,
        align    = "center",
    })
    readyLbl:setFillColor(0.12, 0.08, 0.04)
    self._readyBtn = readyBtn

    -- Reroll button
    local rBtnSz  = math.floor(44 * sc)
    local rerollBtn = display.newGroup()
    group:insert(rerollBtn)
    rerollBtn.x = cx + btnW / 2 + rBtnSz / 2 + math.floor(14 * sc)
    rerollBtn.y = initBtnY

    local rerollBg = display.newRoundedRect(rerollBtn, 0, 0, rBtnSz, rBtnSz, 6 * sc)
    rerollBg:setFillColor(0.28, 0.48, 0.70)
    rerollBg:setStrokeColor(0.38, 0.58, 0.80)
    rerollBg.strokeWidth = math.max(1, math.floor(2 * sc))

    local rerollLbl = display.newText({
        parent   = rerollBtn,
        text     = "Re",
        x = 0, y = 0,
        font     = Fonts.tiny.name,
        fontSize = tinyS,
        align    = "center",
    })
    rerollLbl:setFillColor(1, 1, 1)
    self._rerollBtn = rerollBtn

    -- ── Finished-state overlay ────────────────────────────────────────────────
    self._finishedGroup = display.newGroup()
    group:insert(self._finishedGroup)
    self._finishedGroup.isVisible = false

    local finBtnW = math.floor(180 * sc)
    local finBtnH = math.floor(52  * sc)
    local finBtn  = display.newGroup()
    self._finishedGroup:insert(finBtn)
    finBtn.x = cx
    finBtn.y = math.floor(H * 0.72)

    local finBg = display.newRoundedRect(finBtn, 0, 0, finBtnW, finBtnH, 8 * sc)
    finBg:setFillColor(0.32, 0.48, 0.72)
    finBg:setStrokeColor(0.42, 0.58, 0.82)
    finBg.strokeWidth = math.max(1, math.floor(2 * sc))

    local finLbl = display.newText({
        parent   = finBtn,
        text     = "GO TO MENU",
        x = 0, y = 0,
        font     = Fonts.small.name,
        fontSize = smallS,
        align    = "center",
    })
    finLbl:setFillColor(1, 1, 1)

    finBtn:addEventListener("touch", function(e)
        if e.phase == "ended" then
            if S.isTutorial then _G.writeFile("tutorial_done.dat", "1") end
            composer.gotoScene("src.screens.menu", { effect = "fade", time = 300 })
        end
        return true
    end)
end

function scene:show(event)
    if event.phase ~= "did" then return end
    local p = event.params or {}
    initState(p)

    -- Clear any display objects left from a previous game session
    if self._unitsGroup then
        for i = self._unitsGroup.numChildren, 1, -1 do
            display.remove(self._unitsGroup[i])
        end
    end
    if self._cardsGroup then
        for i = self._cardsGroup.numChildren, 1, -1 do
            display.remove(self._cardsGroup[i])
        end
    end
    S._unitDisplays = {}
    S._cardDisplays = {}

    if S.isOnline and S.socket then
        registerNetworkCallbacks()
    end
    S._lastTime = system.getTimer() / 1000
    Runtime:addEventListener("enterFrame", onUpdate)
    Runtime:addEventListener("touch",      onTouch)
    Runtime:addEventListener("system",     onSystem)
end

function scene:hide(event)
    if event.phase ~= "will" then return end
    Runtime:removeEventListener("enterFrame", onUpdate)
    Runtime:removeEventListener("touch",      onTouch)
    Runtime:removeEventListener("system",     onSystem)
    -- Clear display object caches (objects stay in view group, cleaned by composer)
    S._unitDisplays = {}
    S._cardDisplays = {}
end

function scene:destroy(event)
    if S.socket then
        if S._cb_relay      then S.socket:removeCallback(S._cb_relay)      end
        if S._cb_oppDisconn then S.socket:removeCallback(S._cb_oppDisconn) end
        if S._cb_disconnect then S.socket:removeCallback(S._cb_disconnect) end
        if S._xpHandler     then S.socket:removeCallback(S._xpHandler)     end
    end
    Constants.PERSPECTIVE = 1
    AudioManager.setBattleMode(false)
end

scene:addEventListener("create",  scene)
scene:addEventListener("show",    scene)
scene:addEventListener("hide",    scene)
scene:addEventListener("destroy", scene)

return scene
