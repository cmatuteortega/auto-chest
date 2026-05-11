local Screen = require('lib.screen')
local Constants = require('src.constants')
local Grid = require('src.grid')
local UnitRegistry = require('src.unit_registry')
local Card = require('src.card')
local suit = require('lib.suit')
local Tooltip = require('src.tooltip')
local json = require('lib.json')
local DeckManager = require('src.deck_manager')
local BaseUnit = require('src.base_unit')
local SpellRegistry = require('src.spell_registry')
local ArrowsSpell = require('src.spells.arrows')
local FireballSpell = require('src.spells.fireball')
local RockSpell = require('src.spells.rock')
local QuakeSpell = require('src.spells.quake')
local HornsSpell = require('src.spells.horns')
local SigilSpell = require('src.spells.sigil')

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

        -- Load spell sprites (parallel registry; markers + projectile shared)
        self.spellSprites = SpellRegistry.loadSprites()
        -- Hand the shared arrow particle to the spell so its draw call has it
        self.arrowParticleSprite = self.sprites.marrow and self.sprites.marrow.projectile
                                or self.sprites.marc   and self.sprites.marc.projectile

        -- Corner indicator sprites (AOE preview + unit snap-cell hint)
        self.cornerSprites = {}
        for _, k in ipairs({"topleft", "topright", "bottomleft", "bottomright"}) do
            local img = love.graphics.newImage("src/assets/ui/" .. k .. ".png")
            img:setFilter('nearest', 'nearest')
            self.cornerSprites[k] = img
        end

        -- Load battle background sprite
        self.bgSprite = love.graphics.newImage('src/assets/background_battle.png')
        self.bgOffsetY = 273 -- adjust to shift the background up (negative) or down (positive)
        self.cameraShiftY = 0
        self.goldIcon = love.graphics.newImage('src/assets/ui/gold.png')
        self.goldIcon:setFilter('nearest', 'nearest')

        -- Create grid
        self.grid = Grid()
        self.grid.deathFrames     = UnitRegistry.deathFrames
        self.grid.deathAllyFrames = UnitRegistry.deathAllyFrames
        self.grid.spawnFrames     = UnitRegistry.spawnFrames
        self.grid.despawnFrames   = UnitRegistry.despawnFrames

        -- Initialize SUIT
        self.suit = suit.new()

        -- Ready button spring + hit rect
        self._readySpring  = { scale = 1.0, vel = 0.0, pressed = false }
        self._readyBtnRect = nil

        -- Reroll button spring + hit rect
        self._rerollSpring  = { scale = 1.0, vel = 0.0, pressed = false }
        self._rerollBtnRect = nil

        -- Emote button spring + hit rect
        self._emoteSpring  = { scale = 1.0, vel = 0.0, pressed = false }
        self._emoteBtnRect = nil

        -- Emote panel state
        self._emotePanelOpen   = false
        self._emotePanelCards  = {}    -- per-card animation state tables
        self._emotePanelRects  = {}    -- hit rects for the 4 cards (set during draw)

        -- Emote cooldown: player cannot send another emote for 5s after sending
        self._emoteCooldown    = 0.0   -- counts down from 5 to 0

        -- Active emote display state
        self._myEmoteDisplay  = nil    -- { timer, phase, emoteIndex, scale, alpha }
        self._oppEmoteDisplay = nil

        -- Emote image assets
        self._emoteBoxImg  = love.graphics.newImage('src/assets/emotes/emote-box.png')
        self._emotePlayP1  = love.graphics.newImage('src/assets/emotes/emote-play-p1.png')
        self._emotePlayP2  = love.graphics.newImage('src/assets/emotes/emote-play-p2.png')
        self._emoteBoxImg:setFilter('nearest', 'nearest')
        self._emotePlayP1:setFilter('nearest', 'nearest')
        self._emotePlayP2:setFilter('nearest', 'nearest')

        -- Emote registry: index → { frames = {}, fps = N }
        local function loadEmote(folder, frameCount)
            local frames = {}
            for i = 1, frameCount do
                local img = love.graphics.newImage('src/assets/emotes/' .. folder .. '/' .. i .. '.png')
                img:setFilter('nearest', 'nearest')
                frames[i] = img
            end
            return frames
        end
        self._emoteRegistry = {
            [1] = { frames = loadEmote('plead', 11), fps = 7 },
        }

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
        self.freeRerollUsed = false

        -- Card drafting
        self.cards = {}
        self.exitingCards = {}
        self.draggedCard = nil

        -- Spells: setup-phase placements + battle-time active effects
        self.spellPlacements    = {}   -- array of {placementId, spellType, col, row, owner}
        self.activeSpellEffects = {}   -- array of in-flight spell effect objects
        self._spellPlacementCounter = 0
        self.draggedSpell           = nil
        self.draggedSpellOriginalCol = nil
        self.draggedSpellOriginalRow = nil
        self.draggedSpellOffsetX    = 0
        self.draggedSpellOffsetY    = 0
        self.pressedSpell           = nil

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

    -- Draw corner-bracket indicators around a (cols x rows) footprint centered on (col, row).
    -- Used for spell AOE previews and unit snap-cell hints. Footprint may extend off-grid
    -- (the corners are clamped against the grid bounds so they always fall on visible cells).
    function self:drawCellIndicator(col, row, footprintCols, footprintRows)
        local lg = love.graphics
        if not self.cornerSprites then return end
        footprintCols = footprintCols or 1
        footprintRows = footprintRows or 1

        local halfC0 = math.floor((footprintCols - 1) / 2)
        local halfC1 = math.ceil((footprintCols - 1) / 2)
        local halfR0 = math.floor((footprintRows - 1) / 2)
        local halfR1 = math.ceil((footprintRows - 1) / 2)
        local leftCol   = math.max(1, col - halfC0)
        local rightCol  = math.min(self.grid.cols, col + halfC1)
        local topRow    = math.max(1, row - halfR0)
        local bottomRow = math.min(self.grid.rows, row + halfR1)

        -- Each cell's top-left in screen space; perspective flip is folded in.
        local cs = Constants.CELL_SIZE
        local x1, y1 = self.grid:gridToWorld(leftCol,  topRow)
        local x2, y2 = self.grid:gridToWorld(rightCol, bottomRow)
        local minX = math.min(x1, x2)
        local maxX = math.max(x1, x2) + cs
        local minY = math.min(y1, y2)
        local maxY = math.max(y1, y2) + cs

        local scale = cs / 16
        local tl = self.cornerSprites.topleft
        local tr = self.cornerSprites.topright
        local bl = self.cornerSprites.bottomleft
        local br = self.cornerSprites.bottomright
        if not (tl and tr and bl and br) then return end

        lg.setColor(1, 1, 1, 1)
        local sw, sh = tl:getWidth(), tl:getHeight()
        lg.draw(tl, minX, minY, 0, scale, scale, 0, 0)
        lg.draw(tr, maxX, minY, 0, scale, scale, sw, 0)
        lg.draw(bl, minX, maxY, 0, scale, scale, 0, sh)
        lg.draw(br, maxX, maxY, 0, scale, scale, sw, sh)
    end

    -- Draw a single corner-bracket sprite at one corner of one cell.
    -- `corner` is "topleft" / "topright" / "bottomleft" / "bottomright".
    function self:drawCornerBracket(col, row, corner)
        local lg = love.graphics
        if not self.cornerSprites then return end
        local sprite = self.cornerSprites[corner]
        if not sprite then return end

        local cs = Constants.CELL_SIZE
        local x, y = self.grid:gridToWorld(col, row)
        local minX, maxX = x, x + cs
        local minY, maxY = y, y + cs
        local scale = cs / 16
        local sw, sh = sprite:getWidth(), sprite:getHeight()

        lg.setColor(1, 1, 1, 1)
        if corner == "topleft" then
            lg.draw(sprite, minX, minY, 0, scale, scale, 0, 0)
        elseif corner == "topright" then
            lg.draw(sprite, maxX, minY, 0, scale, scale, sw, 0)
        elseif corner == "bottomleft" then
            lg.draw(sprite, minX, maxY, 0, scale, scale, 0, sh)
        elseif corner == "bottomright" then
            lg.draw(sprite, maxX, maxY, 0, scale, scale, sw, sh)
        end
    end

    -- Draw a corner-bracket outline of an arbitrary AoE shape. `hitOffsets` is
    -- a list of {dc, dr} offsets relative to (originCol, originRow). For each
    -- cell in the shape's bounding box, emits a bracket sprite at every corner
    -- where the two cardinal neighbors that share that corner are both hits
    -- (concave, on a miss cell) or both misses (convex, on a hit cell). Other
    -- mixed corners are interior edges and get no bracket.
    function self:drawAoEOutline(originCol, originRow, hitOffsets)
        local hits = {}
        local function key(c, r) return c .. "," .. r end
        local minC, maxC = math.huge, -math.huge
        local minR, maxR = math.huge, -math.huge
        for _, o in ipairs(hitOffsets) do
            local c = originCol + o[1]
            local r = originRow + o[2]
            hits[key(c, r)] = true
            if c < minC then minC = c end
            if c > maxC then maxC = c end
            if r < minR then minR = r end
            if r > maxR then maxR = r end
        end

        for r = minR, maxR do
            for c = minC, maxC do
                if not self.grid:isValidCell(c, r) then goto continue end
                local isHit = hits[key(c, r)] or false
                local n = hits[key(c, r - 1)] or false
                local s = hits[key(c, r + 1)] or false
                local e = hits[key(c + 1, r)] or false
                local w = hits[key(c - 1, r)] or false

                -- A corner is drawn when both cardinal neighbors that share
                -- it match the OPPOSITE state of the cell itself. On hits =>
                -- both neighbors are misses (convex). On misses => both are
                -- hits (concave).
                local match = not isHit  -- value the neighbors must equal
                if (n == match) and (w == match) then self:drawCornerBracket(c, r, "topleft")     end
                if (n == match) and (e == match) then self:drawCornerBracket(c, r, "topright")    end
                if (s == match) and (w == match) then self:drawCornerBracket(c, r, "bottomleft")  end
                if (s == match) and (e == match) then self:drawCornerBracket(c, r, "bottomright") end
                ::continue::
            end
        end
    end

    -- Find this player's own spell placement at (col, row), or nil.
    function self:findOwnSpellAt(col, row)
        for i, p in ipairs(self.spellPlacements) do
            if p.owner == self.playerRole and p.col == col and p.row == row then
                return p, i
            end
        end
        return nil, nil
    end

    function self:nextSpellPlacementId()
        self._spellPlacementCounter = self._spellPlacementCounter + 1
        -- Tag with playerRole so IDs from both clients never collide.
        return self.playerRole * 1000000 + self._spellPlacementCounter
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
        elseif t == "place_spell" then
            table.insert(self.spellPlacements, {
                placementId = msg.placementId,
                spellType   = msg.spellType,
                col         = msg.col,
                row         = msg.row,
                owner       = msg.owner,
            })
        elseif t == "move_spell" then
            for _, p in ipairs(self.spellPlacements) do
                if p.placementId == msg.placementId then
                    p.col = msg.toCol
                    p.row = msg.toRow
                    break
                end
            end
        end
    end

    function self:handleNetworkMessage(msg)
        local t = msg.type

        if t == "place_unit" or t == "remove_unit" or t == "upgrade_unit"
           or t == "place_spell" or t == "move_spell" then
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

        elseif t == "emote" then
            self._oppEmoteDisplay = { timer = 0, phase = "in", emoteIndex = msg.emoteIndex or 1, scale = 0, alpha = 0 }
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
        AudioManager.playSFX("battle-start.mp3")
        self.battleAccumulator = 0
        self.battleStepCount   = 0

        -- Snapshot the visible board so we can diff after opponent placements are applied
        -- and queue per-cell spawn / despawn animations for any cell that changed.
        local boardSnapshot = {}
        for row = 1, self.grid.rows do
            boardSnapshot[row] = {}
            for col = 1, self.grid.cols do
                local u = self.grid.cells[row][col].unit
                if u then
                    boardSnapshot[row][col] = { unitType = u.unitType, owner = u.owner }
                end
            end
        end

        -- Apply all buffered opponent moves now that battle is starting
        for _, msg in ipairs(self.pendingOpponentMsgs) do
            self:applyOpponentMsg(msg)
        end
        self.pendingOpponentMsgs = {}

        for row = 1, self.grid.rows do
            for col = 1, self.grid.cols do
                local before = boardSnapshot[row][col]
                local after  = self.grid.cells[row][col].unit
                if not before and after then
                    self.grid:addCellEffect(col, row, "spawn")
                elseif before and not after then
                    self.grid:addCellEffect(col, row, "despawn")
                elseif before and after then
                    if before.unitType ~= after.unitType or before.owner ~= after.owner then
                        self.grid:addCellEffect(col, row, "spawn")
                    end
                end
            end
        end

        -- Validate board sync with opponent (both clients compute the same hash if in sync)
        if self.isOnline then
            self.localBoardHash = self:computeBoardHash()
            self:sendMsg({type = "board_sync_check", hash = self.localBoardHash})
            self:checkBoardSync()
        end

        -- Phase 0: terrain spells (Rock) — must run before onBattleStart so displaced units
        -- start their action passives from the correct post-displacement positions.
        if #self.spellPlacements > 0 then
            table.sort(self.spellPlacements, function(a, b)
                return (a.placementId or 0) < (b.placementId or 0)
            end)
            for i = #self.spellPlacements, 1, -1 do
                local p = self.spellPlacements[i]
                if p.spellType == "rock" then
                    local sprite = self.spellSprites and self.spellSprites.rock and self.spellSprites.rock.front
                    local fx = RockSpell.new(p.col, p.row, p.owner, self.grid, sprite, p.placementId)
                    table.insert(self.activeSpellEffects, fx)
                    table.remove(self.spellPlacements, i)
                end
            end
        end

        local allUnits = self.grid:getAllUnits()
        self.battleUnitsSnapshot = {}
        for _, unit in ipairs(allUnits) do
            unit.homeCol = unit.col
            unit.homeRow = unit.row
            table.insert(self.battleUnitsSnapshot, unit)
            unit:onBattleStart(self.grid)
        end

        -- Set up death sound callbacks (relative to local player's perspective)
        for _, unit in ipairs(allUnits) do
            local isAlly = (unit.owner == self.playerRole)
            unit.onDeathCallback = function()
                if isAlly then
                    AudioManager.playSFX("ally-death.mp3")
                else
                    AudioManager.playSFX("enemy-death.mp3", 0.75)
                end
            end
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

        -- Spawn spell effects from setup-phase placements (deterministic order via placementId).
        if #self.spellPlacements > 0 then
            table.sort(self.spellPlacements, function(a, b)
                return (a.placementId or 0) < (b.placementId or 0)
            end)
            self.activeSpellEffects = {}
            for _, p in ipairs(self.spellPlacements) do
                if p.spellType == "arrows" then
                    local sprites = { arrow = self.arrowParticleSprite }
                    local fx = ArrowsSpell.new(p.col, p.row, p.owner, self.grid, sprites, p.placementId)
                    table.insert(self.activeSpellEffects, fx)
                elseif p.spellType == "fireball" then
                    local fbSprites = self.spellSprites and self.spellSprites.fireball
                    local catSprites = self.sprites.catapult
                    local sprites = {
                        flightFrames    = fbSprites and fbSprites.flightFrames,
                        explosionFrames = catSprites and catSprites.explosionFrames,
                        fireFrames      = catSprites and catSprites.fireFrames,
                    }
                    local fx = FireballSpell.new(p.col, p.row, p.owner, self.grid, sprites, p.placementId)
                    table.insert(self.activeSpellEffects, fx)
                elseif p.spellType == "quake" then
                    local qkSprites = self.spellSprites and self.spellSprites.quake
                    local sprites = { frames = qkSprites and qkSprites.frames }
                    local fx = QuakeSpell.new(p.col, p.row, p.owner, self.grid, sprites, p.placementId)
                    table.insert(self.activeSpellEffects, fx)
                elseif p.spellType == "horns" then
                    local hnSprites = self.spellSprites and self.spellSprites.horns
                    local sprites = {
                        trumpet    = hnSprites and hnSprites.trumpet,
                        noteFrames = hnSprites and hnSprites.noteFrames,
                    }
                    local fx = HornsSpell.new(p.col, p.row, p.owner, self.grid, sprites, p.placementId)
                    table.insert(self.activeSpellEffects, fx)
                elseif p.spellType == "sigil" then
                    local sgSprites = self.spellSprites and self.spellSprites.sigil
                    local sprites = {
                        sigilSprite = sgSprites and sgSprites.sigilSprite,
                        healFrames  = sgSprites and sgSprites.healFrames,
                    }
                    local fx = SigilSpell.new(p.col, p.row, p.owner, self.grid, sprites, p.placementId)
                    table.insert(self.activeSpellEffects, fx)
                end
            end
            self.spellPlacements = {}
        end
    end

    function self:resetRound()
        -- Use the snapshot taken at battle start (reliable even if units left the grid mid-battle)
        local allUnits = self.battleUnitsSnapshot

        -- Snapshot end-of-battle board (live units in their final positions) so we can
        -- diff against the post-reset board and queue spawn/despawn cell animations.
        local boardSnapshot = {}
        for row = 1, self.grid.rows do
            boardSnapshot[row] = {}
            for col = 1, self.grid.cols do
                local u = self.grid.cells[row][col].unit
                if u then
                    boardSnapshot[row][col] = { unitType = u.unitType, owner = u.owner }
                end
            end
        end

        -- Clear the grid entirely
        for row = 1, self.grid.rows do
            for col = 1, self.grid.cols do
                local cell = self.grid.cells[row][col]
                cell.unit     = nil
                cell.occupied = false
                cell.reserved = false
            end
        end

        -- Drop the corpse list and any lingering ground effects (Migraine fire patches, Rock terrain).
        self.grid.corpses      = {}
        self.grid.firePatches  = {}
        self.grid.quakePatches = {}
        self.grid.sigilPatches = {}
        self.grid.cellEffects  = {}
        self.grid.hiddenUnits = {}
        self.grid:clearRocks()

        -- Spells never persist between rounds.
        self.spellPlacements    = {}
        self.activeSpellEffects = {}

        -- Re-place all units at their pre-battle home positions
        for _, unit in ipairs(allUnits) do
            if unit.homeCol and unit.homeRow then
                unit.col = unit.homeCol
                unit.row = unit.homeRow
                unit:resetCombatState()
                self.grid:placeUnit(unit.homeCol, unit.homeRow, unit)
            end
        end

        -- Diff end-of-battle vs. start-of-setup boards and queue cell effects.
        for row = 1, self.grid.rows do
            for col = 1, self.grid.cols do
                local before = boardSnapshot[row][col]
                local after  = self.grid.cells[row][col].unit
                if not before and after then
                    self.grid:addCellEffect(col, row, "spawn")
                elseif before and not after then
                    self.grid:addCellEffect(col, row, "despawn")
                elseif before and after then
                    if before.unitType ~= after.unitType or before.owner ~= after.owner then
                        self.grid:addCellEffect(col, row, "spawn")
                    end
                end
            end
        end

        self.roundNumber          = self.roundNumber + 1
        self.winner               = nil
        self.localReady           = false
        self.opponentReady        = false
        self.freeRerollUsed       = false
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
        local gridBottom = Constants.GRID_OFFSET_Y + Constants.GRID_HEIGHT
        self.cardY = math.floor((gridBottom + Constants.GAME_HEIGHT) / 2 - cardHeight / 2)
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
        -- Emote button (same height, opposite side)
        self.emoteButtonX = startX - cardSpacing - self.rerollButtonSize
        self.emoteButtonY = self.rerollButtonY
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
        local gridBottom = Constants.GRID_OFFSET_Y + Constants.GRID_HEIGHT
        self.cardY = math.floor((gridBottom + Constants.GAME_HEIGHT) / 2 - cardHeight / 2)
        local cardY = self.cardY

        for i, unitType in ipairs(unitTypes) do
            local x = startX + (i - 1) * (cardWidth + cardSpacing)
            local sprite, trimBottom, upFrames
            if SpellRegistry.isSpell(unitType) then
                local sp = self.spellSprites[unitType]
                sprite     = sp and sp.front
                trimBottom = 0
                upFrames   = nil
            else
                sprite     = self.sprites[unitType].front
                trimBottom = self.sprites[unitType].frontTrimBottom or 0
                upFrames   = self.sprites[unitType] and self.sprites[unitType].upFrames
            end
            local card    = Card(x, cardY, sprite, i, unitType, trimBottom)
            card.upFrames = upFrames
            table.insert(self.cards, card)
        end

        -- Reroll button position
        self.rerollButtonSize = 40 * Constants.SCALE
        local cardsEndX = startX + totalWidth
        self.rerollButtonX = cardsEndX + cardSpacing
        self.rerollButtonY = cardY + (cardHeight - self.rerollButtonSize) / 2
        -- Emote button (same height, opposite side)
        self.emoteButtonX = startX - cardSpacing - self.rerollButtonSize
        self.emoteButtonY = self.rerollButtonY
    end

    -- Trigger exit animations on current cards and deal-in animations on new ones.
    -- Old cards slide down off screen; new cards slide in from the right with stagger.
    function self:_launchExitAndEnter(unitTypes)
        self.exitingCards = self.exitingCards or {}
        for i, card in ipairs(self.cards) do
            card:startExitAnim((i % 2 == 0) and 1 or -1)
            table.insert(self.exitingCards, card)
        end
        self:_rebuildCardsFromTypes(unitTypes)
        local offscreenX = Constants.GAME_WIDTH + 80 * Constants.SCALE
        for i, card in ipairs(self.cards) do
            card:setEnterAnim(offscreenX, card.x, card.y, 0.05 + (i - 1) * 0.06)
        end
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
        self:_launchExitAndEnter(unitTypes)
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
                        winner_id = didWin and (_G.PlayerData and _G.PlayerData.id or 0) or 0,
                        did_win   = didWin
                    })
                end

                -- Update local trophy, gold and XP counts immediately
                self.playerTrophies = math.max(0, self.playerTrophies + self.trophyChange)
                if _G.PlayerData then
                    _G.PlayerData.trophies = self.playerTrophies
                    _G.PlayerData.gold = (_G.PlayerData.gold or 0) + self.goldEarned
                end
            end

            -- Apply XP/level update from server when it arrives (message comes while still in game)
            if self.socket and not self._xpHandler then
                self._xpHandler = self.socket:on("currency_update", function(data)
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

    function self:update(dt)
        -- Cosmetic per-cell spawn/despawn animations advance in real dt across every state.
        self.grid:tickCellEffects(dt)

        -- Camera shift: grid slides to vertical center during battle, returns for setup UI
        local gridCenterY = Constants.GRID_OFFSET_Y + Constants.GRID_HEIGHT / 2
        local cameraShiftTarget = 0
        if self.state == "pre_battle" or self.state == "battle" or self.state == "battle_ending" then
            cameraShiftTarget = Constants.GAME_HEIGHT / 2 - gridCenterY
        end
        self.cameraShiftY = self.cameraShiftY + (cameraShiftTarget - self.cameraShiftY) * math.min(1, dt * 7)

        -- Tutorial manager update (AI placement, step auto-advancement)
        if self.isTutorial and self.tutorialManager then
            self.tutorialManager:update(dt)
        end

        -- Poll network (must happen every frame)
        if self.isOnline and self.socket then
            local ok, err = pcall(function() self.socket:update() end)
            if not ok then
                print("[GAME] Socket error: " .. tostring(err))
                self.opponentDisconnected = true
            end
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
            self.grid:tickDeathAnims(dt)
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
        end

        -- Update card up-anim: loop animation on cards whose unit type has an upgradeable field unit
        if self.state == "setup" and #self.cards > 0 then
            local upgradeableTypes = {}
            for _, unit in ipairs(self.grid:getAllUnits()) do
                local isOwn = (not self.isOnline) or (unit.owner == self.playerRole)
                if isOwn and not unit.isDead and unit.level < 3 then
                    upgradeableTypes[unit.unitType] = true
                end
            end
            local CARD_ANIM_DURATION = 6 / 8  -- 6 frames @ 8 fps, mirrors card.lua constant
            for _, card in ipairs(self.cards) do
                card:update(dt)
                if upgradeableTypes[card.unitType] then
                    if card.upAnimTimer <= 0 then
                        card.upAnimTimer = CARD_ANIM_DURATION
                    end
                else
                    card.upAnimTimer = 0
                end
            end
        end

        -- Update and prune exiting cards (run every frame so they animate even outside setup)
        if self.exitingCards and #self.exitingCards > 0 then
            for i = #self.exitingCards, 1, -1 do
                local card = self.exitingCards[i]
                card:update(dt)
                if not card.isExiting then
                    table.remove(self.exitingCards, i)
                end
            end
        end

        if self.state == "battle" then
            -- Fixed timestep simulation: accumulate real dt and drain in discrete steps.
            -- Both clients run the exact same number of steps per battle, eliminating
            -- floating-point divergence caused by variable frame rates.
            local FIXED_DT = 1 / 60
            self.battleAccumulator = self.battleAccumulator + dt

            while self.battleAccumulator >= FIXED_DT do
                self.battleAccumulator = self.battleAccumulator - FIXED_DT
                self.battleStepCount   = self.battleStepCount + 1

                -- Iterate hidden units too (e.g. Burrow underground) so their
                -- timers tick and they can re-emerge on schedule.
                local allUnits = self.grid:getAllUnitsIncludingHidden()
                for _, unit in ipairs(allUnits) do
                    unit:update(FIXED_DT, self.grid)
                end

                -- Tick active spell effects (deterministic, fixed-DT step)
                for i = #self.activeSpellEffects, 1, -1 do
                    local fx = self.activeSpellEffects[i]
                    fx:update(FIXED_DT, self.grid)
                    if fx.complete then
                        table.remove(self.activeSpellEffects, i)
                    end
                end

                -- Tick grid-owned ground effects (fire patches, quake slow zones, sigil heal zones)
                self.grid:tickFirePatches(FIXED_DT)
                self.grid:tickQuakePatches(FIXED_DT)
                self.grid:tickSigilPatches(FIXED_DT)
                self.grid:tickDeathAnims(FIXED_DT)

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
            local allUnits = self.grid:getAllUnitsIncludingHidden()
            for _, unit in ipairs(allUnits) do
                unit:update(dt, self.grid)
            end
            for i = #self.activeSpellEffects, 1, -1 do
                local fx = self.activeSpellEffects[i]
                fx:update(dt, self.grid)
                if fx.complete then
                    table.remove(self.activeSpellEffects, i)
                end
            end
            self.grid:tickFirePatches(dt)
            self.grid:tickQuakePatches(dt)
            self.grid:tickSigilPatches(dt)
            self.grid:tickDeathAnims(dt)

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

                    -- Loot (Buried Treasure): each surviving Loot pays its owner;
                    -- each destroyed Loot pays the opponent. Greed upgrade scales both.
                    local lootAlive = self.grid:getAllUnitsIncludingHidden()
                    for _, u in ipairs(lootAlive) do
                        if u.unitType == "loot" and not u.isDead then
                            if u.owner == self.playerRole then
                                self.playerCoins = self.playerCoins + u:getSurvivalBonus()
                            end
                        end
                    end
                    for _, u in ipairs(self.grid.corpses) do
                        if u.unitType == "loot" and u.owner ~= self.playerRole then
                            self.playerCoins = self.playerCoins + u:getKillBonus()
                        end
                    end

                    -- Leave bodies on board; apply life deduction after intermission
                    AudioManager.playSFX("battle-end.mp3")
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

        -- Spring physics for emote button
        local emTarget = self._emoteSpring.pressed and 0.93 or 1.0
        local emAccel  = -480 * (self._emoteSpring.scale - emTarget) - 18 * self._emoteSpring.vel
        self._emoteSpring.vel   = self._emoteSpring.vel   + emAccel * dt
        self._emoteSpring.scale = self._emoteSpring.scale + self._emoteSpring.vel * dt
        self._emoteSpring.scale = math.max(0.85, math.min(1.12, self._emoteSpring.scale))

        -- Update emote panel cards (enter slide-in + exit gravity/spin/fade)
        do
            local sc       = Constants.SCALE
            local imgScale = math.max(1, math.floor(3 * sc))
            local cardSize = math.floor(24 * imgScale)
            local ci = 1
            while ci <= #self._emotePanelCards do
                local c = self._emotePanelCards[ci]
                if c.isEntering then
                    c.enterDelay = c.enterDelay - dt
                    if c.enterDelay <= 0 then
                        local adt    = math.min(dt, 1/30)
                        local dx, dy = c.targetX - c.x, c.targetY - c.y
                        c.velX  = c.velX * 0.004 + dx * 1200 * adt
                        c.velY  = c.velY * 0.004 + dy * 1200 * adt
                        c.x     = c.x + c.velX * adt
                        c.y     = c.y + c.velY * adt
                        c.alpha = math.min(1, c.alpha + dt * 240)
                        if math.abs(dx) < 1 and math.abs(dy) < 1
                        and math.abs(c.velX) < 5 and math.abs(c.velY) < 5 then
                            c.x, c.y     = c.targetX, c.targetY
                            c.isEntering = false
                        end
                    end
                elseif c.isExiting then
                    c.exitVelY     = c.exitVelY + 600 * sc * dt
                    c.x            = c.x + c.exitVelX * dt
                    c.y            = c.y + c.exitVelY * dt
                    c.exitRotation = c.exitRotation + c.exitRotVel * dt
                    c.alpha        = c.alpha - dt * 3
                    if c.alpha <= 0 or c.y > Constants.GAME_HEIGHT + cardSize then
                        table.remove(self._emotePanelCards, ci)
                        ci = ci - 1
                    end
                end
                ci = ci + 1
            end
        end

        -- Emote cooldown countdown
        if self._emoteCooldown > 0 then
            self._emoteCooldown = math.max(0, self._emoteCooldown - dt)
        end

        -- Emote display updater (pop-in / hold / pop-out)
        do
            local IN_DUR, HOLD_DUR, OUT_DUR = 0.3, 3.0, 0.25
            local function updateEmoteDisp(disp)
                if not disp then return nil end
                disp.timer     = disp.timer     + dt
                disp.animTimer = (disp.animTimer or 0) + dt
                if disp.phase == "in" then
                    local t = math.min(1, disp.timer / IN_DUR)
                    -- outBack approximation: overshoot then settle
                    disp.scale = t * t * (2.7 * t - 1.7)
                    disp.alpha = t
                    if disp.timer >= IN_DUR then
                        disp.phase = "hold"; disp.timer = 0
                        disp.scale = 1;      disp.alpha = 1
                    end
                elseif disp.phase == "hold" then
                    disp.scale = 1; disp.alpha = 1
                    if disp.timer >= HOLD_DUR then disp.phase = "out"; disp.timer = 0 end
                elseif disp.phase == "out" then
                    local t = math.min(1, disp.timer / OUT_DUR)
                    local s = 1 - t
                    disp.scale = s * s   -- ease-in shrink
                    disp.alpha = 1 - t
                    if disp.timer >= OUT_DUR then return nil end
                end
                return disp
            end
            self._myEmoteDisplay  = updateEmoteDisp(self._myEmoteDisplay)
            self._oppEmoteDisplay = updateEmoteDisp(self._oppEmoteDisplay)
        end

        -- Spring physics for reroll button
        local rrTarget = self._rerollSpring.pressed and 0.93 or 1.0
        local rrAccel  = -480 * (self._rerollSpring.scale - rrTarget) - 18 * self._rerollSpring.vel
        self._rerollSpring.vel   = self._rerollSpring.vel   + rrAccel * dt
        self._rerollSpring.scale = self._rerollSpring.scale + self._rerollSpring.vel * dt
        self._rerollSpring.scale = math.max(0.85, math.min(1.12, self._rerollSpring.scale))

        -- Spring physics for ready button
        local rspTarget = self._readySpring.pressed and 0.93 or 1.0
        local rspAccel  = -480 * (self._readySpring.scale - rspTarget) - 18 * self._readySpring.vel
        self._readySpring.vel   = self._readySpring.vel   + rspAccel * dt
        self._readySpring.scale = self._readySpring.scale + self._readySpring.vel * dt
        self._readySpring.scale = math.max(0.85, math.min(1.12, self._readySpring.scale))
    end

    function self:draw()
        local lg = love.graphics

        -- Draw battle background and grid, shifted by camera animation.
        -- Store shift on Constants so drawFirePatch scissor calls can offset to screen space.
        Constants.cameraShiftY = math.floor(self.cameraShiftY)
        lg.push()
        lg.translate(0, Constants.cameraShiftY)

        local spriteScale = Constants.CELL_SIZE / 16
        local bgW = self.bgSprite:getWidth()
        local bgH = self.bgSprite:getHeight()
        local bgX = Constants.GRID_OFFSET_X + Constants.GRID_WIDTH / 2
        local bgY = Constants.GRID_OFFSET_Y + Constants.GRID_HEIGHT / 2 + self.bgOffsetY
        lg.setColor(1, 1, 1, 1)
        lg.setShader(BaseUnit.getPaletteShader())
        lg.draw(self.bgSprite, bgX, bgY, 0, spriteScale, spriteScale, bgW / 2, bgH / 2)
        lg.setShader()

        -- During online setup, hide the opponent's units for the element of surprise.
        local hideOwner = (self.isOnline and self.state == "setup" and self.roundNumber == 1) and (3 - self.playerRole) or nil
        BaseUnit.renderState = self.state
        self.grid:draw(self.draggedUnit, hideOwner)
        self.grid:drawCellEffects()

        -- Draw own spell markers during setup/pre-battle (opponent markers stay hidden).
        if (self.state == "setup" or self.state == "pre_battle")
           and self.spellPlacements and #self.spellPlacements > 0 then
            local markerScale = Constants.CELL_SIZE / 16
            for _, p in ipairs(self.spellPlacements) do
                if p.owner == self.playerRole and p ~= self.draggedSpell then
                    -- AOE indicator stays drawn for placed spells until they fire.
                    local size = SpellRegistry.aoeSize and SpellRegistry.aoeSize[p.spellType]
                    local fpC = (size and size.cols) or 1
                    local fpR = (size and size.rows) or 1
                    self:drawCellIndicator(p.col, p.row, fpC, fpR)

                    local sp = self.spellSprites and self.spellSprites[p.spellType]
                    local img = sp and sp.front
                    if img then
                        local cx, cy = self.grid:getCellCenter(p.col, p.row)
                        local sw, sh = img:getWidth(), img:getHeight()
                        lg.setColor(1, 1, 1, 0.9)
                        lg.draw(img, cx, cy, 0, markerScale, markerScale, sw / 2, sh / 2)
                    end
                end
            end
            lg.setColor(1, 1, 1, 1)
        end

        -- AOE / snap-cell indicator beneath dragged sprites.
        do
            local indCol, indRow, fpC, fpR
            if self.draggedSpell then
                indCol, indRow = self.grid:worldToGrid(self.mouseX, self.mouseY)
                local size = SpellRegistry.aoeSize and SpellRegistry.aoeSize[self.draggedSpell.spellType]
                fpC, fpR = (size and size.cols) or 1, (size and size.rows) or 1
            elseif self.draggedCard and SpellRegistry.isSpell(self.draggedCard.unitType) then
                indCol, indRow = self.grid:worldToGrid(self.mouseX, self.mouseY)
                local size = SpellRegistry.aoeSize and SpellRegistry.aoeSize[self.draggedCard.unitType]
                fpC, fpR = (size and size.cols) or 1, (size and size.rows) or 1
            elseif self.draggedUnit then
                indCol, indRow = self.grid:worldToGrid(self.mouseX, self.mouseY)
                fpC, fpR = 1, 1
            elseif self.draggedCard then
                -- Unit card drag: 1x1 snap target (only inside the player's own zone).
                local col, row = self.grid:worldToGrid(self.mouseX, self.mouseY)
                if col and row then
                    local owner = self.grid:getOwner(row)
                    if (not self.isOnline) or owner == self.playerRole then
                        indCol, indRow, fpC, fpR = col, row, 1, 1
                    end
                end
            end
            if indCol and indRow and self.grid:isValidCell(indCol, indRow) then
                self:drawCellIndicator(indCol, indRow, fpC, fpR)

                -- Burrow tunnels to the mirrored row at battle start; preview
                -- the emerge cell so the player can see where it'll pop out.
                local dragType = (self.draggedUnit and self.draggedUnit.unitType)
                              or (self.draggedCard and self.draggedCard.unitType)
                if dragType == "burrow" then
                    local mirrorRow = Constants.GRID_ROWS + 1 - indRow
                    if self.grid:isValidCell(indCol, mirrorRow) then
                        self:drawCellIndicator(indCol, mirrorRow, fpC, fpR)
                    end
                elseif dragType == "knight" then
                    -- Knight taunts all enemies in a 3x3 area in front at
                    -- battle start. Draw one bracket around the whole area
                    -- (Arrows-spell style) by centering the 3x3 footprint
                    -- 2 rows ahead of the knight.
                    local owner = self.grid:getOwner(indRow)
                    local dirRow
                    if owner == 1 then dirRow = -1
                    elseif owner == 2 then dirRow = 1
                    end
                    if dirRow then
                        local centerRow = indRow + dirRow * 2
                        if self.grid:isValidCell(indCol, centerRow) then
                            self:drawCellIndicator(indCol, centerRow, 3, 3)
                        end
                    end
                elseif dragType == "catapult" then
                    -- Catapult fires 4 rows forward at battle start, exploding
                    -- in a 5-cell cross. Preview each hit cell individually.
                    local owner = self.grid:getOwner(indRow)
                    local targetRow
                    if owner == 1 then
                        targetRow = math.max(1, indRow - 4)
                    elseif owner == 2 then
                        targetRow = math.min(Constants.GRID_ROWS, indRow + 4)
                    end
                    if targetRow then
                        local crossOffsets = { {0,0}, {1,0}, {-1,0}, {0,1}, {0,-1} }
                        self:drawAoEOutline(indCol, targetRow, crossOffsets)
                    end
                elseif dragType == "effigy" then
                    -- Show the 1-cell ward ring (8 surrounding tiles) that Effigy
                    -- will shield. Upgrade 3 expands this to a 2-cell radius.
                    local radius = 1
                    if self.draggedUnit and self.draggedUnit:hasUpgrade(3) then
                        radius = 2
                    end
                    local offsets = {}
                    for dc = -radius, radius do
                        for dr = -radius, radius do
                            if not (dc == 0 and dr == 0) then
                                table.insert(offsets, { dc, dr })
                            end
                        end
                    end
                    self:drawAoEOutline(indCol, indRow, offsets)
                elseif dragType == "bull" or dragType == "marrow" or dragType == "barrel" or dragType == "cannon" then
                    -- Forward-line action units: outline the cells the unit
                    -- moves/fires through at battle start. Bull = 4 tiles;
                    -- Marrow & Barrel = full column to the far row.
                    local owner = self.grid:getOwner(indRow)
                    local dirRow
                    if owner == 1 then dirRow = -1
                    elseif owner == 2 then dirRow = 1
                    end
                    if dirRow then
                        local maxSteps = (dragType == "bull") and 4 or Constants.GRID_ROWS
                        local offsets = {}
                        for i = 1, maxSteps do
                            local r = indRow + dirRow * i
                            if r < 1 or r > Constants.GRID_ROWS then break end
                            table.insert(offsets, { 0, dirRow * i })
                        end
                        if #offsets > 0 then
                            self:drawAoEOutline(indCol, indRow, offsets)
                        end
                    end
                end
            end
        end

        -- Draw the spell marker currently being dragged at cursor position.
        if self.draggedSpell then
            local sp = self.spellSprites and self.spellSprites[self.draggedSpell.spellType]
            local img = sp and sp.front
            if img then
                local mx = self.draggedSpell.dragX or 0
                local my = self.draggedSpell.dragY or 0
                local sw, sh = img:getWidth(), img:getHeight()
                local markerScale = Constants.CELL_SIZE / 16
                lg.setColor(1, 1, 1, 0.85)
                lg.draw(img, mx, my, 0, markerScale, markerScale, sw / 2, sh / 2)
                lg.setColor(1, 1, 1, 1)
            end
        end

        -- Draw active spell effects (arrow rain etc.) during battle.
        if self.activeSpellEffects and #self.activeSpellEffects > 0 then
            for _, fx in ipairs(self.activeSpellEffects) do
                fx:draw()
            end
        end

        lg.pop()

        -- Draw entering cards behind the UI (behind reroll button)
        if self.cards then
            for _, card in ipairs(self.cards) do
                if card.isEntering and card ~= self.draggedCard then
                    card:draw()
                end
            end
        end

        -- Draw UI
        self:drawUI()

        -- Draw exiting cards behind the active hand
        if self.exitingCards then
            for _, card in ipairs(self.exitingCards) do
                card:draw()
            end
        end

        -- Draw settled/non-entering cards (non-dragged first, dragged last so it's on top)
        for _, card in ipairs(self.cards) do
            if not card.isEntering and card ~= self.draggedCard then
                card:draw()
            end
        end

        -- Draw dragged card on top
        if self.draggedCard then
            self.draggedCard:draw()
        end

        -- Draw dragged unit on top (if repositioning during setup)
        if self.draggedUnit then
            self.draggedUnit:drawGroundEffects()
            self.draggedUnit:draw()
        end

        -- Draw SUIT UI elements
        self.suit:draw()

        -- Draw emote speech bubble popups (above SUIT, below tooltip)
        self:_drawEmoteDisplay(self._myEmoteDisplay, true)
        self:_drawEmoteDisplay(self._oppEmoteDisplay, false)

        -- Draw tooltip on top of everything
        self.tooltip:draw()

        -- Draw tutorial bubble overlay on top of everything (tutorial mode only)
        if self.isTutorial and self.tutorialManager then
            self.tutorialManager:draw()
        end
    end

    -- Opens the emote panel: creates 4 card states that slide in from the left.
    function self:_openEmotePanel()
        local sc           = Constants.SCALE
        local imgScale     = math.max(1, math.floor(3 * sc))
        local cardSize     = math.floor(24 * imgScale)
        local gap          = math.floor(10 * sc)
        local buttonHeight = 40 * sc
        local gridBottom   = Constants.GRID_OFFSET_Y + Constants.GRID_HEIGHT
        local buttonY      = ((gridBottom + self.cardY) / 2) - (buttonHeight / 2)
        local card4CyTop   = buttonY + buttonHeight - cardSize  -- card 4 bottom = ready button bottom

        self._emotePanelCards = {}
        self._emotePanelOpen  = true
        for i = 1, 4 do
            local targetX = self.emoteButtonX
            local targetY = card4CyTop - (4 - i) * (cardSize + gap)
            self._emotePanelCards[i] = {
                x = -cardSize, y = targetY,
                targetX = targetX, targetY = targetY,
                velX = 0, velY = 0,
                alpha = 0,
                enterDelay = (i - 1) * 0.03,
                isEntering = true,
                isExiting  = false,
                exitVelX = 0, exitVelY = 0,
                exitRotation = 0, exitRotVel = 0,
            }
        end
    end

    -- Closes the emote panel: triggers exit (gravity+spin+fade) on all remaining cards.
    function self:_closeEmotePanel()
        self._emotePanelOpen = false
        local sc = Constants.SCALE
        for i, c in ipairs(self._emotePanelCards) do
            if not c.isExiting then
                c.isEntering   = false
                c.isExiting    = true
                local rotDir   = (i % 2 == 0) and 1 or -1
                c.exitVelX     = rotDir * 20 * sc
                c.exitVelY     = 180 * sc
                c.exitRotVel   = rotDir * 2.5
                c.exitRotation = 0
            end
        end
    end

    -- Draws an emote speech bubble popup with pop-in/hold/pop-out animation.
    -- isMine = true  → P1 sprite, horizontally at emote button, vertically centred on grid bottom
    -- isMine = false → P2 sprite, horizontally at emote button, vertically centred on grid top
    function self:_drawEmoteDisplay(disp, isMine)
        if not disp or disp.alpha <= 0 then return end
        local lg  = love.graphics
        local sc  = Constants.SCALE

        -- Choose speech bubble sprite based on perspective
        local sprite = isMine and self._emotePlayP1 or self._emotePlayP2
        local imgW   = sprite:getWidth()
        local imgH   = sprite:getHeight()
        -- Scale: 4× pixel size, then animate with disp.scale
        local bubScale = sc * 4 * disp.scale

        -- Horizontal: left-align with the emote button
        local bx = self.emoteButtonX

        -- Vertical: P1 centred on grid bottom row, P2 centred on grid top row
        local gridBottom = Constants.GRID_OFFSET_Y + Constants.GRID_HEIGHT
        local rowH       = Constants.CELL_SIZE
        local by
        if isMine then
            -- centre of the bottom half-row = gridBottom - rowH/2, shifted with camera
            by = math.floor(gridBottom - rowH / 2 - imgH * bubScale / 2 + (Constants.cameraShiftY or 0))
        else
            -- centre of the top half-row = GRID_OFFSET_Y + rowH/2
            by = math.floor(Constants.GRID_OFFSET_Y + rowH / 2 - imgH * bubScale / 2)
        end

        -- Draw speech bubble background sprite
        lg.setColor(1, 1, 1, disp.alpha)
        lg.draw(sprite, bx, by, 0, bubScale, bubScale)

        -- Emote animation (if a registered emote exists for this index)
        local emote = self._emoteRegistry[disp.emoteIndex]
        if emote and #emote.frames > 0 then
            local frameCount  = #emote.frames
            local frameIdx    = math.floor((disp.animTimer or 0) * emote.fps) % frameCount + 1
            local frame       = emote.frames[frameIdx]
            local emScale     = bubScale  -- same pixel scale as bubble
            local emW         = frame:getWidth()  * emScale
            local emH         = frame:getHeight() * emScale

            -- Centre of bubble content area
            local cx = bx + imgW * bubScale * 0.5
            local cyOffset = isMine and math.floor(6 * bubScale) or 0
            local cy = by + imgH * bubScale * 0.42 - cyOffset

            -- Smooth bounce: ±6% of emH, sin wave
            local t          = love.timer.getTime()
            local bounceAmp  = emH * 0.06
            local bounceY    = math.sin(t * 3.0) * bounceAmp * disp.alpha

            -- Draw ellipse shadow behind emote (on top of bubble sprite)
            local shadowW      = emW * 0.65
            local shadowH2     = emH * 0.12
            local shadowX      = cx
            local shadowOffset = isMine and math.floor(4 * bubScale) or math.floor(6 * bubScale)
            local shadowY      = cy + emH * 0.5 + emH * 0.04 - shadowOffset
            lg.setColor(0, 0, 0, 0.28 * disp.alpha)
            -- Approximate ellipse with a scaled circle
            lg.push()
            lg.translate(shadowX, shadowY)
            lg.scale(1, shadowH2 / (shadowW * 0.5))
            lg.circle('fill', 0, 0, shadowW * 0.5)
            lg.pop()

            -- Draw emote frame centred on cx/cy + bounce
            lg.setColor(1, 1, 1, disp.alpha)
            lg.draw(frame, cx, cy + bounceY, 0, emScale, emScale, emW / emScale / 2, emH / emScale / 2)
        end
    end

    function self:drawUI()
        local lg = love.graphics
        local shOff = math.floor(2 * Constants.SCALE)

        -- Player labels (proportional positioning)
        -- In online mode the local player is always shown at the bottom right.
        lg.setFont(Fonts.large)
        local topMargin    = math.max(15 * Constants.SCALE, Constants.SAFE_INSET_TOP    + 4 * Constants.SCALE)
        local bottomMargin = math.max(15 * Constants.SCALE, Constants.SAFE_INSET_BOTTOM + 4 * Constants.SCALE)
        local leftMargin   = 20 * Constants.SCALE
        local rightMargin  = 20 * Constants.SCALE
        local fontHeight = Fonts.large:getHeight()

        -- State label: top-right, same font/Y as P2 name; timer on line below during setup
        lg.setFont(Fonts.large)
        local stateText = ""
        local timerText = nil
        if self.state == "setup" then
            stateText = "SETUP"
            if not self.isTutorial then
                timerText = math.ceil(self.timer) .. "s"
            end
            lg.setColor(0.9, 0.9, 0.9, 1)
        elseif self.state == "intermission" then
            stateText = "ROUND " .. self.roundNumber
            lg.setColor(0.9, 0.9, 0.9, 1)
        elseif self.state == "pre_battle" then
            stateText = "GO!"
            lg.setColor(0.3, 1, 0.3, 1)
        elseif self.state == "battle" then
            stateText = "BATTLE"
            lg.setColor(0.9, 0.9, 0.9, 1)
        elseif self.state == "battle_ending" then
            stateText = ""
        elseif self.state == "finished" and self.winner then
            local didWin = (self.winner == self.playerRole)
            stateText = didWin and "YOU WIN!" or "YOU LOSE"
            lg.setColor(didWin and {0.3, 1, 0.3, 1} or {1, 0.3, 0.3, 1})
        end
        local rightEdge = Constants.GAME_WIDTH - rightMargin
        if stateText ~= "" then
            local r, g, b, a = lg.getColor()
            lg.setColor(0, 0, 0, 0.65)
            lg.printf(stateText, shOff, topMargin + shOff, rightEdge, 'right')
            lg.setColor(r, g, b, a)
            lg.printf(stateText, 0, topMargin, rightEdge, 'right')
        end
        if timerText then
            lg.setFont(Fonts.medium)
            lg.setColor(0, 0, 0, 0.65)
            lg.printf(timerText, shOff, topMargin + Fonts.large:getHeight() + shOff, rightEdge, 'right')
            lg.setColor(0.9, 0.9, 0.9, 1)
            lg.printf(timerText, 0, topMargin + Fonts.large:getHeight(), rightEdge, 'right')
        end
        local stateTextY = topMargin

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
                lg.setColor(0, 0, 0, 0.5)
                lg.rectangle('fill', x + (i - 1) * (pipSize + pipGap) + shOff, y + shOff, pipSize, pipSize)
            end
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
        lg.setFont(Fonts.large)
        lg.setColor(0, 0, 0, 0.65)
        lg.print(topLabel, leftMargin + shOff, topMargin + shOff)
        lg.setColor(topColor)
        lg.print(topLabel, leftMargin, topMargin)
        lg.setFont(Fonts.tiny)
        lg.setColor(0, 0, 0, 0.65)
        lg.print(topTrophies .. " trophies", leftMargin + shOff, topMargin + Fonts.large:getHeight() + shOff)
        lg.setColor(0.9, 0.85, 0.3, 1)
        lg.print(topTrophies .. " trophies", leftMargin, topMargin + Fonts.large:getHeight())
        drawLives(leftMargin, topMargin + Fonts.large:getHeight() + Fonts.tiny:getHeight() + 3 * Constants.SCALE, topLives, topColor)

        -- Bottom player (you)
        lg.setFont(Fonts.large)
        local bLabelWidth = Fonts.large:getWidth(bottomLabel)
        local bLabelX = Constants.GAME_WIDTH - bLabelWidth - rightMargin
        lg.setColor(0, 0, 0, 0.65)
        lg.print(bottomLabel, bLabelX + shOff, Constants.GAME_HEIGHT - fontHeight - bottomMargin + shOff)
        lg.setColor(bottomColor)
        lg.print(bottomLabel, bLabelX, Constants.GAME_HEIGHT - fontHeight - bottomMargin)
        lg.setFont(Fonts.tiny)
        local trophyText = bottomTrophies .. " trophies"
        local trophyW = Fonts.tiny:getWidth(trophyText)
        lg.setColor(0, 0, 0, 0.65)
        lg.print(trophyText, Constants.GAME_WIDTH - trophyW - rightMargin + shOff, Constants.GAME_HEIGHT - bottomMargin - fontHeight - Fonts.tiny:getHeight() + shOff)
        lg.setColor(0.9, 0.85, 0.3, 1)
        lg.print(trophyText, Constants.GAME_WIDTH - trophyW - rightMargin, Constants.GAME_HEIGHT - bottomMargin - fontHeight - Fonts.tiny:getHeight())
        drawLives(bLabelX, Constants.GAME_HEIGHT - fontHeight - bottomMargin - pipSize - 5 * Constants.SCALE,
                  bottomLives, bottomColor)

        -- Coin display in bottom left (icon + number)
        lg.setFont(Fonts.large)
        local coinStr = self.isSandbox and "999" or tostring(self.playerCoins)
        local baseY = Constants.GAME_HEIGHT - fontHeight - bottomMargin
        local iconH = math.floor(fontHeight * 0.55)
        local iconSc = iconH / self.goldIcon:getHeight()
        local iconW = self.goldIcon:getWidth() * iconSc
        local iconGap = math.floor(4 * Constants.SCALE)
        local visH  = Fonts.large:getAscent() - Fonts.large:getDescent()
        local iconY = math.floor(baseY + (visH - iconH) / 2)
        lg.setColor(0, 0, 0, 0.65)
        lg.draw(self.goldIcon, leftMargin + shOff, iconY + shOff, 0, iconSc, iconSc)
        lg.print(coinStr, leftMargin + iconW + iconGap + shOff, baseY + shOff)
        lg.setColor(1, 1, 1, 1)
        lg.draw(self.goldIcon, leftMargin, iconY, 0, iconSc, iconSc)
        lg.print(coinStr, leftMargin + iconW + iconGap, baseY)

        -- Reset font for buttons
        lg.setFont(Fonts.medium)

        -- Button dimensions (scaled proportionally)
        local buttonHeight = 40 * Constants.SCALE
        -- Position button at middle height between grid bottom and card top
        local gridBottom = Constants.GRID_OFFSET_Y + Constants.GRID_HEIGHT
        local buttonY = ((gridBottom + self.cardY) / 2) - (buttonHeight / 2)

        -- Helper functions for rounded-rect buttons
        local function roundedRect(x, y, w, h, r, sc)
            lg.rectangle('fill', x, y, w, h, r * sc, r * sc)
        end
        local function roundedRectLine(x, y, w, h, r, sc, lw)
            lg.setLineWidth(lw)
            lg.rectangle('line', x, y, w, h, r * sc, r * sc)
        end
        local function textCY(font, boxY, boxH)
            return math.floor(boxY + (boxH - (font:getAscent() - font:getDescent())) / 2)
        end

        -- Buttons
        if self.state == "setup" then
            local buttonPadding = 20 * Constants.SCALE
            -- Size button to fit the wider of the two possible labels
            local readyW   = Fonts.medium:getWidth("READY")
            local waitW    = Fonts.medium:getWidth("Esperando…")
            local buttonWidth = math.max(readyW, waitW) + buttonPadding * 2
            local buttonX = (Constants.GAME_WIDTH - buttonWidth) / 2

            -- Custom ready button (Play style → Sandbox style after press)
            local sc       = Constants.SCALE
            local maxFloat = math.floor(4 * sc)
            local shadowH  = math.floor(4 * sc)
            local sp       = self._readySpring
            local floatOff = math.floor(maxFloat * math.max(0, (sp.scale - 0.93) / 0.07))
            local isWaiting = self.isOnline and self.localReady

            -- Store hit rect for press/release handlers
            self._readyBtnRect = { x = buttonX, y = buttonY - maxFloat, w = buttonWidth, h = buttonHeight + maxFloat }

            if not isWaiting then
                -- PLAY button style: warm tan, cream border, idle bob + rotation
                local t       = love.timer.getTime()
                local idleBob = math.sin(t * 1.8) * 2 * sc
                local idleRot = math.sin(t * 1.3) * 0.012
                local drawY   = buttonY - floatOff + math.floor(idleBob)

                lg.setColor(0.031, 0.078, 0.118, 1)
                roundedRect(buttonX + math.floor(2 * sc), buttonY + shadowH, buttonWidth, buttonHeight, 8, sc)

                local pivX = buttonX + buttonWidth / 2
                local pivY = drawY + buttonHeight / 2
                local bx   = -buttonWidth / 2
                local by   = -buttonHeight / 2
                lg.push()
                lg.translate(pivX, pivY)
                lg.rotate(idleRot)
                lg.scale(sp.scale, sp.scale)
                lg.setColor(0.765, 0.639, 0.541, 1)
                roundedRect(bx, by, buttonWidth, buttonHeight, 8, sc)
                lg.setColor(0.965, 0.839, 0.741, 1)
                roundedRectLine(bx, by, buttonWidth, buttonHeight, 8, sc, 2 * sc)
                lg.setFont(Fonts.medium)
                lg.setColor(1, 1, 1, 1)
                lg.printf("READY", bx, textCY(Fonts.medium, by, buttonHeight), buttonWidth, 'center')
                lg.pop()
            else
                -- SANDBOX button style: dusty mauve, same-color border, no bob/rotation
                local drawY = buttonY - floatOff

                lg.setColor(0.031, 0.078, 0.118, 1)
                roundedRect(buttonX + math.floor(2 * sc), buttonY + shadowH, buttonWidth, buttonHeight, 8, sc)

                local pivX = buttonX + buttonWidth / 2
                local pivY = drawY + buttonHeight / 2
                lg.push()
                lg.translate(pivX, pivY)
                lg.scale(sp.scale, sp.scale)
                lg.translate(-pivX, -pivY)
                lg.setColor(0.600, 0.459, 0.467, 1)
                roundedRect(buttonX, drawY, buttonWidth, buttonHeight, 8, sc)
                lg.setColor(0.600, 0.459, 0.467, 1)
                roundedRectLine(buttonX, drawY, buttonWidth, buttonHeight, 8, sc, 2 * sc)
                lg.setFont(Fonts.medium)
                lg.setColor(1, 1, 1, 1)
                lg.printf("Esperando…", buttonX, textCY(Fonts.medium, drawY, buttonHeight), buttonWidth, 'center')
                lg.pop()
            end

            -- Reroll button (custom draw: play style when affordable, sandbox when not)
            do
                local rx        = self.rerollButtonX
                local ry        = self.rerollButtonY
                local rsz       = self.rerollButtonSize
                local rsp       = self._rerollSpring
                local rfloatOff = math.floor(maxFloat * math.max(0, (rsp.scale - 0.93) / 0.07))
                local canAfford = self.isSandbox or (not self.freeRerollUsed) or self.playerCoins >= self.rerollCost

                self._rerollBtnRect = { x = rx, y = ry - maxFloat, w = rsz, h = rsz + maxFloat }

                -- Cost label above reroll button
                do
                    local labelH = Fonts.tiny:getHeight()
                    local labelY = ry - maxFloat - labelH - math.floor(3 * sc)
                    lg.setFont(Fonts.tiny)
                    if not self.freeRerollUsed then
                        lg.setColor(1, 1, 1, 0.6)
                        lg.printf("Free", rx, labelY, rsz, 'center')
                    else
                        local iconH  = labelH
                        local iconSc = iconH / self.goldIcon:getHeight()
                        local iconW  = math.floor(self.goldIcon:getWidth() * iconSc)
                        local numStr = "1"
                        local numW   = Fonts.tiny:getWidth(numStr)
                        local gap    = math.floor(2 * sc)
                        local totalW = iconW + gap + numW
                        local startX = rx + math.floor((rsz - totalW) / 2)
                        lg.setColor(0.9, 0.85, 0.3, 1)
                        lg.draw(self.goldIcon, startX, labelY, 0, iconSc, iconSc)
                        lg.setFont(Fonts.tiny)
                        lg.setColor(1, 1, 1, 1)
                        lg.print(numStr, startX + iconW + gap, labelY)
                    end
                end

                if canAfford then
                    local t       = love.timer.getTime()
                    local idleBob = math.sin(t * 1.8) * 2 * sc
                    local idleRot = math.sin(t * 1.3) * 0.012
                    local drawY   = ry - rfloatOff + math.floor(idleBob)

                    lg.setColor(0.031, 0.078, 0.118, 1)
                    roundedRect(rx + math.floor(2 * sc), ry + shadowH, rsz, rsz, 8, sc)

                    local pivX = rx + rsz / 2
                    local pivY = drawY + rsz / 2
                    local bx   = -rsz / 2
                    local by   = -rsz / 2
                    lg.push()
                    lg.translate(pivX, pivY)
                    lg.rotate(idleRot)
                    lg.scale(rsp.scale, rsp.scale)
                    lg.setColor(0.765, 0.639, 0.541, 1)
                    roundedRect(bx, by, rsz, rsz, 8, sc)
                    lg.setColor(0.965, 0.839, 0.741, 1)
                    roundedRectLine(bx, by, rsz, rsz, 8, sc, 2 * sc)
                    lg.setFont(Fonts.medium)
                    lg.setColor(1, 1, 1, 1)
                    lg.printf("X", bx, textCY(Fonts.medium, by, rsz), rsz, 'center')
                    lg.pop()
                else
                    local drawY = ry - rfloatOff

                    lg.setColor(0.031, 0.078, 0.118, 1)
                    roundedRect(rx + math.floor(2 * sc), ry + shadowH, rsz, rsz, 8, sc)

                    local pivX = rx + rsz / 2
                    local pivY = drawY + rsz / 2
                    lg.push()
                    lg.translate(pivX, pivY)
                    lg.scale(rsp.scale, rsp.scale)
                    lg.translate(-pivX, -pivY)
                    lg.setColor(0.600, 0.459, 0.467, 1)
                    roundedRect(rx, drawY, rsz, rsz, 8, sc)
                    lg.setColor(0.600, 0.459, 0.467, 1)
                    roundedRectLine(rx, drawY, rsz, rsz, 8, sc, 2 * sc)
                    lg.setFont(Fonts.medium)
                    lg.setColor(1, 1, 1, 1)
                    lg.printf("X", rx, textCY(Fonts.medium, drawY, rsz), rsz, 'center')
                    lg.pop()
                end
            end

            -- Emote button (drawn for setup state; also drawn for battle state below)
            do
                local ex             = self.emoteButtonX
                local ey             = self.emoteButtonY
                local esz            = self.rerollButtonSize
                local esp            = self._emoteSpring
                local emoteDisabled  = self._emoteCooldown > 0 or self._emotePanelOpen or #self._emotePanelCards > 0
                local efloatOff      = math.floor(maxFloat * math.max(0, (esp.scale - 0.93) / 0.07))
                local t              = love.timer.getTime()
                local idleBob        = math.sin(t * 1.8 + 1.0) * 2 * sc
                local idleRot        = math.sin(t * 1.3 + 1.0) * 0.012
                local drawY          = ey - efloatOff + math.floor(idleBob)

                self._emoteBtnRect = { x = ex, y = ey - maxFloat, w = esz, h = esz + maxFloat }

                lg.setColor(0.031, 0.078, 0.118, 1)
                roundedRect(ex + math.floor(2 * sc), ey + shadowH, esz, esz, 8, sc)

                local pivX = ex + esz / 2
                local pivY = drawY + esz / 2
                local bx   = -esz / 2
                local by   = -esz / 2
                lg.push()
                lg.translate(pivX, pivY)
                lg.rotate(idleRot)
                lg.scale(esp.scale, esp.scale)
                if emoteDisabled then
                    -- Orange style: cooldown or panel open
                    lg.setColor(0.600, 0.350, 0.080, 1)
                    roundedRect(bx, by, esz, esz, 8, sc)
                    lg.setColor(0.780, 0.460, 0.100, 1)
                    roundedRectLine(bx, by, esz, esz, 8, sc, 2 * sc)
                else
                    -- Normal play style: warm tan + cream border
                    lg.setColor(0.765, 0.639, 0.541, 1)
                    roundedRect(bx, by, esz, esz, 8, sc)
                    lg.setColor(0.965, 0.839, 0.741, 1)
                    roundedRectLine(bx, by, esz, esz, 8, sc, 2 * sc)
                end
                lg.setFont(Fonts.medium)
                lg.setColor(1, 1, 1, 1)
                lg.printf("@", bx, textCY(Fonts.medium, by, esz), esz, 'center')
                lg.pop()
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
                    TransitionManager.cloudCurtain(function()
                        local ScreenManager = require('lib.screen_manager')
                        ScreenManager.switch('menu')
                    end)
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
                    ScreenManager.switch('name_entry')
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
                        TransitionManager.cloudCurtain(function()
                            local ScreenManager = require('lib.screen_manager')
                            ScreenManager.switch('menu')
                        end)
                    else
                        print("Restart button clicked!")
                        self:init()
                    end
                end
            end
        end

        -- ── Emote button (all states except setup, which draws it above, and finished) ──
        if self.state ~= "setup" and self.state ~= "finished" then
            local sc       = Constants.SCALE
            local maxFloat = math.floor(4 * sc)
            local shadowH  = math.floor(4 * sc)
            local ex       = self.emoteButtonX
            local ey       = self.emoteButtonY
            local esz      = self.rerollButtonSize
            local esp      = self._emoteSpring
            local emoteDisabled = self._emoteCooldown > 0 or self._emotePanelOpen or #self._emotePanelCards > 0
            local efloatOff = math.floor(maxFloat * math.max(0, (esp.scale - 0.93) / 0.07))
            local t         = love.timer.getTime()
            local idleBob   = math.sin(t * 1.8 + 1.0) * 2 * sc
            local idleRot   = math.sin(t * 1.3 + 1.0) * 0.012
            local drawY     = ey - efloatOff + math.floor(idleBob)

            self._emoteBtnRect = { x = ex, y = ey - maxFloat, w = esz, h = esz + maxFloat }

            lg.setColor(0.031, 0.078, 0.118, 1)
            roundedRect(ex + math.floor(2 * sc), ey + shadowH, esz, esz, 8, sc)

            local pivX = ex + esz / 2
            local pivY = drawY + esz / 2
            local bx   = -esz / 2
            local by   = -esz / 2
            lg.push()
            lg.translate(pivX, pivY)
            lg.rotate(idleRot)
            lg.scale(esp.scale, esp.scale)
            if emoteDisabled then
                lg.setColor(0.600, 0.350, 0.080, 1)
                roundedRect(bx, by, esz, esz, 8, sc)
                lg.setColor(0.780, 0.460, 0.100, 1)
                roundedRectLine(bx, by, esz, esz, 8, sc, 2 * sc)
            else
                lg.setColor(0.765, 0.639, 0.541, 1)
                roundedRect(bx, by, esz, esz, 8, sc)
                lg.setColor(0.965, 0.839, 0.741, 1)
                roundedRectLine(bx, by, esz, esz, 8, sc, 2 * sc)
            end
            lg.setFont(Fonts.medium)
            lg.setColor(1, 1, 1, 1)
            lg.printf("@", bx, textCY(Fonts.medium, by, esz), esz, 'center')
            lg.pop()
        end

        -- ── Emote panel cards (slide in from left / fly off on dismiss) ────────
        self._emotePanelRects = {}
        if #self._emotePanelCards > 0 then
            local sc       = Constants.SCALE
            local imgScale = math.max(1, math.floor(3 * sc))
            local cardSize = math.floor(24 * imgScale)
            for i, c in ipairs(self._emotePanelCards) do
                if c.alpha > 0 then
                    local pivX = c.x + cardSize / 2
                    local pivY = c.y + cardSize / 2
                    lg.push()
                    lg.translate(pivX, pivY)
                    lg.rotate(c.isExiting and c.exitRotation or 0)
                    lg.setColor(1, 1, 1, c.alpha)
                    lg.draw(self._emoteBoxImg, 0, 0, 0, imgScale, imgScale, 12, 12)
                    -- Draw emote preview frame on top of box
                    local emote = self._emoteRegistry[i]
                    if emote and #emote.frames > 0 then
                        local frame = emote.frames[1]
                        lg.setColor(1, 1, 1, c.alpha)
                        lg.draw(frame, 0, 0, 0, imgScale, imgScale, 12, 12)
                    end
                    lg.pop()

                    -- Hit rect only while entering/settled, not exiting
                    if not c.isExiting and c.alpha > 0.4 then
                        self._emotePanelRects[i] = { x = c.x, y = c.y, w = cardSize, h = cardSize }
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
        if self.pressedUnit or self.draggedUnit or self.draggedCard or self.pressedCard
           or self.pressedSpell or self.draggedSpell then
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

        -- Promote a pressed spell marker into an active drag once movement passes the threshold.
        if self.pressedSpell and not self.draggedSpell and self.state == "setup" and self.hasMoved then
            self.tooltip:hide()
            self.draggedSpell           = self.pressedSpell
            self.draggedSpellOriginalCol = self.pressedSpell.col
            self.draggedSpellOriginalRow = self.pressedSpell.row
            -- Use the cell's CENTER so the sprite stays centered on the dragged cursor.
            local sx, sy = self.grid:getCellCenter(self.pressedSpell.col, self.pressedSpell.row)
            self.draggedSpellOffsetX = self.pressX - sx
            self.draggedSpellOffsetY = self.pressY - sy
            self.draggedSpell.dragX  = sx
            self.draggedSpell.dragY  = sy
            self.pressedSpell        = nil
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

        -- Update dragged spell marker position
        if self.draggedSpell then
            self.draggedSpell.dragX = x - self.draggedSpellOffsetX
            self.draggedSpell.dragY = y - self.draggedSpellOffsetY
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
                -- Spell markers take precedence so a placed marker remains repositionable
                -- even if a unit later occupies its cell.
                if self.state == "setup" then
                    local placement = self:findOwnSpellAt(col, row)
                    if placement then
                        self.tooltip:hide()
                        self.pressedSpell = placement
                        self.pressedUnit = nil
                        return
                    end
                end
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

        -- Spring squish for ready + reroll buttons (setup only)
        if self.state == "setup" then
            if self._readyBtnRect then
                local rb = self._readyBtnRect
                if x >= rb.x and x <= rb.x + rb.w and y >= rb.y and y <= rb.y + rb.h then
                    self._readySpring.pressed = true
                end
            end
            if self._rerollBtnRect then
                local rb = self._rerollBtnRect
                if x >= rb.x and x <= rb.x + rb.w and y >= rb.y and y <= rb.y + rb.h then
                    self._rerollSpring.pressed = true
                end
            end
        end

        -- Emote button spring squish (all non-finished states)
        if self.state ~= "finished" then
            if self._emoteBtnRect then
                local rb = self._emoteBtnRect
                if x >= rb.x and x <= rb.x + rb.w and y >= rb.y and y <= rb.y + rb.h then
                    self._emoteSpring.pressed = true
                end
            end
        end

        -- Close emote panel when pressing outside button + panel area
        if self._emotePanelOpen then
            local onBtn = self._emoteBtnRect and
                x >= self._emoteBtnRect.x and x <= self._emoteBtnRect.x + self._emoteBtnRect.w and
                y >= self._emoteBtnRect.y and y <= self._emoteBtnRect.y + self._emoteBtnRect.h
            local onPanel = false
            for _, r in ipairs(self._emotePanelRects) do
                if r and x >= r.x and x <= r.x + r.w and y >= r.y and y <= r.y + r.h then
                    onPanel = true; break
                end
            end
            if not onBtn and not onPanel then
                self:_closeEmotePanel()
            end
        end
    end

    -- Shared release logic (called from both mousereleased and touchreleased)
    function self:handleRelease(x, y)
        -- Tutorial bubble tap-to-advance (does not consume the event)
        if self.isTutorial and self.tutorialManager then
            self.tutorialManager:handleTap(x, y)
        end

        -- ── Ready + reroll + emote buttons ───────────────────────────────────
        self._readySpring.pressed  = false
        self._rerollSpring.pressed = false
        self._emoteSpring.pressed  = false
        if self.state == "setup" and self._readyBtnRect then
            local rb = self._readyBtnRect
            if x >= rb.x and x <= rb.x + rb.w and y >= rb.y and y <= rb.y + rb.h then
                if not (self.isOnline and self.localReady) then
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
                return
            end
        end

        -- ── Reroll button ─────────────────────────────────────────────────────
        if self.state == "setup" and self._rerollBtnRect then
            local rb = self._rerollBtnRect
            if x >= rb.x and x <= rb.x + rb.w and y >= rb.y and y <= rb.y + rb.h then
                if self.isSandbox or (not self.freeRerollUsed) or self.playerCoins >= self.rerollCost then
                    if not self.isSandbox then
                        if not self.freeRerollUsed then
                            self.freeRerollUsed = true  -- first reroll is free
                            AudioManager.playTap()
                        else
                            self.playerCoins = self.playerCoins - self.rerollCost
                            AudioManager.playSFX("reroll.mp3")
                        end
                    else
                        AudioManager.playTap()
                    end
                    if self.usingDeck then
                        if self.isSandbox and DeckManager.pileSize() < 3 then
                            DeckManager.returnCards(self.drawnCardTypes)
                            self.drawnCardTypes = {}
                            DeckManager.initDrawPile()
                            self.drawnCardTypes = DeckManager.drawCards(3)
                            self:_launchExitAndEnter(self.drawnCardTypes)
                        else
                            local newTypes = DeckManager.reshuffleAndDraw(self.drawnCardTypes, 3)
                            self.drawnCardTypes = newTypes
                            self:_launchExitAndEnter(newTypes)
                        end
                    else
                        self:dealSetupCards()
                    end
                end
                return
            end
        end

        -- ── Emote panel card selection ────────────────────────────────────────
        if self._emotePanelOpen and #self._emotePanelRects > 0 then
            for i, rect in ipairs(self._emotePanelRects) do
                if rect and x >= rect.x and x <= rect.x + rect.w and y >= rect.y and y <= rect.y + rect.h then
                    AudioManager.playTap()
                    self:_closeEmotePanel()  -- fly off remaining cards
                    self._emoteCooldown  = 5.0
                    self._myEmoteDisplay = { timer = 0, phase = "in", emoteIndex = i, scale = 0, alpha = 0 }
                    self:sendMsg({ type = "emote", emoteIndex = i })
                    return
                end
            end
        end

        -- ── Emote button toggle ───────────────────────────────────────────────
        if self.state ~= "finished" and self._emoteBtnRect then
            local rb = self._emoteBtnRect
            if x >= rb.x and x <= rb.x + rb.w and y >= rb.y and y <= rb.y + rb.h then
                -- Allow opening only when not on cooldown; always allow closing
                if self._emotePanelOpen or self._emoteCooldown <= 0 then
                    AudioManager.playTap()
                    if self._emotePanelOpen then
                        self:_closeEmotePanel()
                    else
                        self:_openEmotePanel()
                    end
                end
                return
            end
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

        -- ── Spell marker repositioning drag ───────────────────────────────────
        if self.draggedSpell then
            local col, row = self.grid:worldToGrid(x, y)
            local origCol  = self.draggedSpellOriginalCol
            local origRow  = self.draggedSpellOriginalRow
            local cellTaken = false
            if col and row then
                for _, p in ipairs(self.spellPlacements) do
                    if p ~= self.draggedSpell and p.owner == self.playerRole
                       and p.col == col and p.row == row then
                        cellTaken = true; break
                    end
                end
            end
            if col and row and self.grid:isValidCell(col, row) and not cellTaken then
                self.draggedSpell.col = col
                self.draggedSpell.row = row
                AudioManager.playSFX("place.mp3")
                self:sendMsg({type = "move_spell",
                              placementId = self.draggedSpell.placementId,
                              fromCol = origCol, fromRow = origRow,
                              toCol = col, toRow = row,
                              owner = self.draggedSpell.owner})
                print(string.format("Repositioned spell to [%d, %d]", col, row))
            else
                self.draggedSpell.col = origCol
                self.draggedSpell.row = origRow
                if cellTaken then print("Another spell already placed on this cell") end
            end
            self.draggedSpell.dragX = nil
            self.draggedSpell.dragY = nil
            self.draggedSpell           = nil
            self.draggedSpellOriginalCol = nil
            self.draggedSpellOriginalRow = nil
            return
        end

        -- ── Tap on spell marker → no-op (no tooltip yet for spells) ──────────
        if self.pressedSpell and not self.draggedSpell then
            self.pressedSpell = nil
            return
        end

        -- ── Unit repositioning drag ───────────────────────────────────────────
        if self.draggedUnit then
            local col, row = self.grid:worldToGrid(x, y)
            local origCol = self.draggedUnitOriginalCol
            local origRow = self.draggedUnitOriginalRow
            -- In online mode only allow repositioning within own zone
            local zoneOwner = self.isOnline and self.playerRole or nil
            local targetUnit = (col and row) and self.grid:getUnitAtCell(col, row) or nil
            local zoneOK = (col and row) and (zoneOwner == nil or self.grid:getOwner(row) == zoneOwner) or false
            local canSwap = targetUnit and not targetUnit.isDead
                            and targetUnit.owner == self.draggedUnit.owner
                            and zoneOK
            if canSwap then
                -- Swap: relocate the existing unit to the dragged unit's origin cell.
                self.grid:removeUnit(col, row)
                targetUnit.col = origCol
                targetUnit.row = origRow
                self.grid:placeUnit(origCol, origRow, targetUnit)
                self.draggedUnit.col = col
                self.draggedUnit.row = row
                self.grid:placeUnit(col, row, self.draggedUnit)
                AudioManager.playSFX("place.mp3")
                -- Sync: mirror both moves on the opponent client.
                self:sendMsg({type = "remove_unit", col = origCol, row = origRow})
                self:sendMsg({type = "remove_unit", col = col, row = row})
                self:sendMsg({type = "place_unit",
                              unitType = targetUnit.unitType,
                              col = origCol, row = origRow,
                              owner = targetUnit.owner,
                              level = targetUnit.level,
                              activeUpgrades = targetUnit.activeUpgrades})
                self:sendMsg({type = "place_unit",
                              unitType = self.draggedUnit.unitType,
                              col = col, row = row,
                              owner = self.draggedUnit.owner,
                              level = self.draggedUnit.level,
                              activeUpgrades = self.draggedUnit.activeUpgrades})
                print(string.format("Swapped units between [%d, %d] and [%d, %d]",
                                    origCol, origRow, col, row))
            elseif col and row and self.grid:canPlaceUnit(col, row, zoneOwner) then
                self.draggedUnit.col = col
                self.draggedUnit.row = row
                self.grid:placeUnit(col, row, self.draggedUnit)
                AudioManager.playSFX("place.mp3")
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
            -- Spell card: no zone restriction, no occupancy check; just charge cost and place a marker.
            if SpellRegistry.isSpell(self.draggedCard.unitType) then
                local spellType = self.draggedCard.unitType
                local cost      = UnitRegistry.unitCosts[spellType] or 0
                local alreadyPlaced = false
                local cellTaken     = false
                for _, p in ipairs(self.spellPlacements) do
                    if p.owner == self.playerRole then
                        if p.spellType == spellType then alreadyPlaced = true end
                        if col and row and p.col == col and p.row == row then cellTaken = true end
                    end
                end
                if not col or not row or not self.grid:isValidCell(col, row) then
                    self.draggedCard:snapBack()
                elseif alreadyPlaced then
                    print("Spell " .. spellType .. " already placed this round")
                    self.draggedCard:snapBack()
                elseif cellTaken then
                    print("Another spell already placed on this cell")
                    self.draggedCard:snapBack()
                elseif not self.isSandbox and self.playerCoins < cost then
                    print("Not enough coins for spell")
                    self.draggedCard:snapBack()
                else
                    if not self.isSandbox then self.playerCoins = self.playerCoins - cost end
                    local placementId = self:nextSpellPlacementId()
                    table.insert(self.spellPlacements, {
                        placementId = placementId,
                        spellType   = spellType,
                        col         = col,
                        row         = row,
                        owner       = self.playerRole,
                    })
                    AudioManager.playSFX("place.mp3")
                    for i, card in ipairs(self.cards) do
                        if card == self.draggedCard then
                            table.remove(self.cards, i); break
                        end
                    end
                    for j, u in ipairs(self.drawnCardTypes) do
                        if u == spellType then
                            table.remove(self.drawnCardTypes, j); break
                        end
                    end
                    self:sendMsg({type = "place_spell",
                                  placementId = placementId,
                                  spellType   = spellType,
                                  col = col, row = row,
                                  owner = self.playerRole})
                    print(string.format("Placed spell %s at [%d, %d]", spellType, col, row))
                end
                self.draggedCard:stopDrag()
                self.draggedCard = nil
                return
            end
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
                            AudioManager.playSFX("place.mp3")
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
            if self.state == "setup" then
                local placement = self:findOwnSpellAt(col, row)
                if placement then
                    self.tooltip:hide()
                    self.pressedSpell = placement
                    self.pressedUnit = nil
                    return
                end
            end
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

        -- Spring squish for ready + reroll buttons (setup only)
        if self.state == "setup" then
            if self._readyBtnRect then
                local rb = self._readyBtnRect
                if x >= rb.x and x <= rb.x + rb.w and y >= rb.y and y <= rb.y + rb.h then
                    self._readySpring.pressed = true
                end
            end
            if self._rerollBtnRect then
                local rb = self._rerollBtnRect
                if x >= rb.x and x <= rb.x + rb.w and y >= rb.y and y <= rb.y + rb.h then
                    self._rerollSpring.pressed = true
                end
            end
        end

        -- Emote button spring squish (all non-finished states)
        if self.state ~= "finished" then
            if self._emoteBtnRect then
                local rb = self._emoteBtnRect
                if x >= rb.x and x <= rb.x + rb.w and y >= rb.y and y <= rb.y + rb.h then
                    self._emoteSpring.pressed = true
                end
            end
        end

        -- Close emote panel when pressing outside button + panel area
        if self._emotePanelOpen then
            local onBtn = self._emoteBtnRect and
                x >= self._emoteBtnRect.x and x <= self._emoteBtnRect.x + self._emoteBtnRect.w and
                y >= self._emoteBtnRect.y and y <= self._emoteBtnRect.y + self._emoteBtnRect.h
            local onPanel = false
            for _, r in ipairs(self._emotePanelRects) do
                if r and x >= r.x and x <= r.x + r.w and y >= r.y and y <= r.y + r.h then
                    onPanel = true; break
                end
            end
            if not onBtn and not onPanel then
                self:_closeEmotePanel()
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
