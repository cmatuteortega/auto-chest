-- AutoChest – Matchmaking Lobby (Solar2D composer scene)
--
-- All game/network logic preserved from Love2D version.
-- love.graphics draw calls replaced with Solar2D display objects.
-- love.timer.getTime() replaced with system.getTimer()/1000.
-- ScreenManager.switch() replaced with composer.gotoScene().
--
-- TODO (rendering): The following blocks still need Solar2D display-object
--   conversion (search for TODO-RENDER):
--   • Ticker stripe scrolling text (setScissor → display group masking)
--   • Animated unit sprites with palette shader (BaseUnit.getPaletteShader)
--   • Cancel button spring animation (push/translate/rotate/scale → display group)

local composer     = require("composer")
local Constants    = require("src.constants")
local DeckManager  = require("src.deck_manager")
local UnitRegistry = require("src.unit_registry")
local BaseUnit     = require("src.base_unit")

local scene = composer.newScene()

-- ── Helpers ───────────────────────────────────────────────────────────────────

-- Replaces love.timer.getTime()
local function getTime()
    return system.getTimer() / 1000
end

local function makeRoundedButton(group, label, cx, cy, w, h, sc, fillColor, strokeColor)
    local btn = display.newGroup()
    group:insert(btn)
    btn.x, btn.y = cx, cy

    local bg = display.newRoundedRect(btn, 0, 0, w, h, 8 * sc)
    bg:setFillColor(unpack(fillColor))
    bg:setStrokeColor(unpack(strokeColor))
    bg.strokeWidth = 2 * sc

    local lbl = display.newText({
        parent   = btn,
        text     = label,
        x        = 0,
        y        = 0,
        font     = Fonts.large.name,
        fontSize = Fonts.large.size,
        align    = "center",
    })
    lbl:setFillColor(1, 1, 1)
    return btn, bg
end

-- ── Scene data (preserved game/network logic) ─────────────────────────────────

local S = {}   -- scene-local state, reset on each show()

local function initState(client, roomKey)
    S.client          = client
    S.roomKey         = roomKey or nil
    S.status          = "queueing"
    S.statusMsg       = "Finding match..."
    S.queueStartTime  = getTime()
    S.playerRole      = nil
    S.opponentName    = nil
    S.opponentTrophies = nil
    S.myTrophies      = _G.PlayerData and _G.PlayerData.trophies or 0
    S.matchTimer      = nil

    local sentences = {
        "Finding a worthy opponent...",
        "Waiting for the ideal match...",
        "Looking for a duel...",
        "Sharpening swords before the battle...",
        "Scouts are searching the realm...",
        "Summoning a rival commander...",
        "The arena awaits a challenger...",
        "Seeking someone brave enough to face you...",
    }
    S.waitingSentence = sentences[math.random(#sentences)]

    -- Deck preview animation state (logic unchanged from Love2D)
    S.unitOrder         = UnitRegistry.getAllUnitTypes()
    table.sort(S.unitOrder)
    S.sprites           = {}
    S.spriteTrimBottoms = {}
    S.dirSprites        = {}
    S.idleAnim          = {}
    S.attackAnim        = {}
    S.previewLayout     = {}
    for _, utype in ipairs(S.unitOrder) do
        local loaded = UnitRegistry.loadDirectionalSprites(utype)
        S.sprites[utype]           = loaded.front
        S.spriteTrimBottoms[utype] = loaded.frontTrimBottom
        S.dirSprites[utype]        = loaded
        S.idleAnim[utype]          = { frameIndex = 1, timer = 0 }
        S.attackAnim[utype]        = { active = false, progress = 0, duration = 0.45 }
    end

    -- Cancel button spring
    S.cancelSpring = { scale = 1.0, vel = 0.0, pressed = false }

    -- Ticker stripe
    S.tickerOffset  = 0
    S.tickerMsg     = "matchmaking  -  matchmaking  -  matchmaking  -  matchmaking  -  "
    S.tickerMsgPx   = 0

    buildPreviewLayout()
end

function buildPreviewLayout()
    S.previewLayout = {}
    local deck = DeckManager.getActiveDeck()
    if not deck then return end

    local units = {}
    for utype, count in pairs(deck.counts) do
        if count > 0 then table.insert(units, utype) end
    end
    table.sort(units)
    if #units == 0 then return end

    local occupied = {}
    local placed   = 0
    local function occupy(r, c)
        placed = placed + 1
        occupied[r * 10 + c] = true
        table.insert(S.previewLayout, { unitType = units[placed], col = c, row = r })
    end

    local vPos = { {4,3}, {3,2},{3,4}, {2,1},{2,5}, {1,1},{1,5} }
    for _, p in ipairs(vPos) do
        if placed >= #units then break end
        occupy(p[1], p[2])
    end
    if placed < #units then
        local function cardinalHit(r, c)
            return occupied[(r-1)*10+c] or occupied[(r+1)*10+c]
                or occupied[r*10+(c-1)] or occupied[r*10+(c+1)]
        end
        for r = 1, 4 do
            for c = 1, 5 do
                if placed >= #units then break end
                if not occupied[r*10+c] and not cardinalHit(r, c) then occupy(r, c) end
            end
        end
    end
    if placed < #units then
        local rem = {}
        for r = 1, 4 do
            for c = 1, 5 do
                if not occupied[r*10+c] then table.insert(rem, {r,c}) end
            end
        end
        for i = #rem, 2, -1 do
            local j = math.random(i); rem[i], rem[j] = rem[j], rem[i]
        end
        for _, p in ipairs(rem) do
            if placed >= #units then break end
            occupy(p[1], p[2])
        end
    end
end

local function getPreviewFrame(utype)
    local d = S.dirSprites[utype]
    if d and d.hasDirectionalSprites then
        local atk = S.attackAnim[utype]
        if atk.active and d.directional.hit and d.directional.hit[0] then
            local dirData = d.directional.hit[0]
            local count   = #dirData.frames
            local p       = atk.progress
            local idx
            if     count >= 3 then
                if     p < 1/3 then idx = 1
                elseif p < 2/3 then idx = 2
                else                idx = 3 end
            else
                idx = math.min(count, math.floor(p * count) + 1)
            end
            return dirData.frames[idx], dirData.trimBottom[idx]
        end
        local aio = d.directional.actionIdleOverride
        if aio and (aio[0] or aio[180]) then
            local ad  = aio[0] or aio[180]
            local idx = math.min(S.idleAnim[utype].frameIndex, #ad.frames)
            return ad.frames[idx], ad.trimBottom[idx] or 0
        end
        if d.directional.idle and d.directional.idle[0] then
            local dirData = d.directional.idle[0]
            return dirData.frames[S.idleAnim[utype].frameIndex], dirData.trimBottom[S.idleAnim[utype].frameIndex]
        end
    end
    return S.sprites[utype], S.spriteTrimBottoms[utype] or 0
end

-- ── Network callbacks ─────────────────────────────────────────────────────────

local function registerNetworkCallbacks()
    S.client:on("queue_joined", function()
        S.status    = "queueing"
        S.statusMsg = "Finding match..."
    end)
    S.client:on("private_queue_joined", function()
        S.status    = "queueing"
        S.statusMsg = "Waiting for friend..."
    end)
    S.client:on("queue_left", function() end)
    S.client:on("match_found", function(data)
        S.playerRole       = data.role
        S.opponentName     = data.opponent_name
        S.opponentTrophies = data.opponent_trophies
        S.myTrophies       = data.my_trophies
        S.status           = "matched"
        S.statusMsg        = "Match found!"
        S.matchTimer       = 1.2
        scene:_refreshStatus()
    end)
    S.client:on("opponent_disconnected", function()
        S.status    = "error"
        S.statusMsg = "Opponent disconnected"
        scene:_refreshStatus()
    end)
    S.client:on("error", function(data)
        if data.reason == "Not authenticated" and _G.PlayerData and _G.PlayerData.token then
            S.status    = "reconnecting"
            S.statusMsg = "Reconnecting..."
            S.client:send("reconnect_with_token", {
                token     = _G.PlayerData.token,
                device_id = _G.DeviceId or ""
            })
        else
            S.status    = "error"
            S.statusMsg = data.reason or "Error occurred"
            scene:_refreshStatus()
        end
    end)
    S.client:on("login_success", function(data)
        if S.status == "reconnecting" then
            _G.PlayerData.trophies = data.trophies
            S.myTrophies           = data.trophies
            S.status               = "queueing"
            joinQueue()
        end
    end)
end

function joinQueue()
    if not S.client then
        S.status    = "error"
        S.statusMsg = "No connection"
        return
    end
    if S.roomKey then
        S.client:send("private_queue_join", {
            player_id = _G.PlayerData.id,
            room_key  = S.roomKey,
        })
    else
        S.client:send("queue_join", {
            player_id = _G.PlayerData.id,
            trophies  = _G.PlayerData.trophies,
        })
    end
end

local function leaveQueue()
    if S.client then
        local msg = S.roomKey and "private_queue_leave" or "queue_leave"
        S.client:send(msg, {})
    end
end

-- ── update (game logic — fully preserved) ────────────────────────────────────

local function onUpdate(event)
    local dt = event.time / 1000 - (S._lastTime or event.time / 1000)
    S._lastTime = event.time / 1000

    -- Poll network
    if S.client then
        local ok, err = pcall(function() S.client:update() end)
        if not ok then
            print("[LOBBY] Socket error: " .. tostring(err))
            S.client      = nil
            _G.GameSocket = nil
            composer.gotoScene("src.screens.login", { effect = "fade", time = 300 })
            return
        end
    end

    -- Transition to game after match
    if S.matchTimer then
        S.matchTimer = S.matchTimer - dt
        if S.matchTimer <= 0 then
            S.matchTimer = nil
            _G.PlayerData.trophies = S.myTrophies
            _G.OpponentData = { name = S.opponentName, trophies = S.opponentTrophies }
            Constants.PERSPECTIVE = S.playerRole
            composer.gotoScene("src.screens.game", {
                effect = "fade",
                time   = 300,
                params = {
                    isOnline   = true,
                    playerRole = S.playerRole,
                    socket     = S.client,
                    isSandbox  = false,
                    isTutorial = false,
                },
            })
        end
    end

    -- Idle / attack animation logic (unchanged)
    local DEFAULT_IDLE_FRAME_DUR  = 0.12 * 2
    local IDLE_FRAME_DUR_OVERRIDE = { marrow = 0.18 }
    for _, utype in ipairs(S.unitOrder) do
        local d = S.dirSprites[utype]
        if d and d.hasDirectionalSprites and d.directional.idle and d.directional.idle[0] then
            local frames   = d.directional.idle[0].frames
            local anim     = S.idleAnim[utype]
            local frameDur = IDLE_FRAME_DUR_OVERRIDE[utype] or DEFAULT_IDLE_FRAME_DUR
            anim.timer = anim.timer + dt
            if anim.timer >= frameDur then
                anim.timer      = anim.timer - frameDur
                anim.frameIndex = (anim.frameIndex % #frames) + 1
            end
        end
        local atk = S.attackAnim[utype]
        if atk.active then
            atk.progress = atk.progress + dt / atk.duration
            if atk.progress >= 1 then atk.active = false; atk.progress = 0 end
        end
    end

    -- Cancel button spring (k=480, d=18)
    local sp     = S.cancelSpring
    local target = sp.pressed and 0.93 or 1.0
    local accel  = -480 * (sp.scale - target) - 18 * sp.vel
    sp.vel       = sp.vel   + accel * dt
    sp.scale     = sp.scale + sp.vel  * dt
    sp.scale     = math.max(0.85, math.min(1.12, sp.scale))
    if scene._cancelBtn then
        scene._cancelBtn.xScale = sp.scale
        scene._cancelBtn.yScale = sp.scale
    end

    -- Ticker scroll
    local tickerMsg = (S.status == "matched")
        and "match found!  -  match found!  -  match found!  -  match found!  -  "
        or  "matchmaking  -  matchmaking  -  matchmaking  -  matchmaking  -  "
    if tickerMsg ~= S.tickerMsg then
        S.tickerMsg    = tickerMsg
        S.tickerOffset = 0
    end
    local tickerSpeed = 60 * Constants.SCALE
    S.tickerOffset = S.tickerOffset + tickerSpeed * dt

    -- TODO-RENDER: update ticker text scroll position on display objects

    -- Update status label text
    scene:_refreshStatus()
end

-- ── Scene lifecycle ───────────────────────────────────────────────────────────

function scene:create(event)
    local group = self.view
    local W     = Constants.GAME_WIDTH
    local H     = Constants.GAME_HEIGHT
    local sc    = Constants.SCALE
    local cx    = W / 2

    -- Background
    local bgCol = Constants.COLORS.BACKGROUND
    local bg    = display.newRect(group, cx, H / 2, W, H)
    bg:setFillColor(bgCol[1], bgCol[2], bgCol[3])

    -- ── Ticker stripe ─────────────────────────────────────────────────────────
    -- TODO-RENDER: Implement scrolling text ticker with display group masking.
    -- Placeholder static bar for now.
    local stripeY = math.floor(75 * sc + Constants.MENU_CONTENT_PUSH)
    local stripeH = math.floor(36 * sc)
    local stripe  = display.newRect(group, cx, stripeY + stripeH / 2, W, stripeH)
    stripe:setFillColor(0.031, 0.078, 0.118)

    self._tickerLbl = display.newText({
        parent   = group,
        text     = "matchmaking",
        x        = cx,
        y        = stripeY + stripeH / 2,
        font     = Fonts.small.name,
        fontSize = Fonts.small.size,
        align    = "center",
    })
    self._tickerLbl:setFillColor(0.965, 0.839, 0.741)

    -- ── Deck preview grid ─────────────────────────────────────────────────────
    local cellSize   = Constants.CELL_SIZE
    local gridW      = 5 * cellSize
    local gridH      = 4 * cellSize
    local gridX      = math.floor((W - gridW) / 2)
    local contentTop = 100 * sc + Constants.MENU_CONTENT_PUSH
    local barH       = 90 * sc
    local btnAreaY   = (H - barH) * 0.62
    local gridY      = math.floor(contentTop + (btnAreaY - contentTop - gridH) / 2)

    -- Chess pattern cells
    local CDARK  = Constants.COLORS.CHESS_DARK
    local CLIGHT = Constants.COLORS.CHESS_LIGHT
    local gridGroup = display.newGroup()
    group:insert(gridGroup)
    for row = 1, 4 do
        for col = 1, 5 do
            local cx2 = gridX + (col - 1) * cellSize + cellSize / 2
            local cy2 = gridY + (row - 1) * cellSize + cellSize / 2
            local cell = display.newRect(gridGroup, cx2, cy2, cellSize, cellSize)
            local c    = (row + col) % 2 == 0 and CDARK or CLIGHT
            cell:setFillColor(c[1], c[2], c[3])
        end
    end
    -- Grid border
    local border = display.newRect(gridGroup, gridX + gridW/2, gridY + gridH/2, gridW, gridH)
    border:setFillColor(0, 0, 0, 0)
    border:setStrokeColor(0.125, 0.224, 0.310)
    border.strokeWidth = math.max(1, math.floor(sc))

    -- TODO-RENDER: Animated unit sprites (require palette shader → Solar2D kernel).
    -- See src/base_unit.lua getPaletteShader() for the GLSL to port.
    self._gridGroup  = gridGroup
    self._gridX      = gridX
    self._gridY      = gridY
    self._gridW      = gridW
    self._gridH      = gridH
    self._cellSize   = cellSize

    -- "No deck" label (hidden if deck has units)
    self._noDeckLbl = display.newText({
        parent   = group,
        text     = "Equip a deck to preview",
        x        = gridX + gridW / 2,
        y        = gridY + gridH / 2,
        font     = Fonts.small.name,
        fontSize = Fonts.small.size,
        align    = "center",
    })
    self._noDeckLbl:setFillColor(0.306, 0.286, 0.373)

    -- ── Status labels ─────────────────────────────────────────────────────────
    local infoY = gridY + gridH + 28 * sc
    self._waitLbl = display.newText({
        parent   = group,
        text     = "",
        x        = cx,
        y        = infoY,
        font     = Fonts.small.name,
        fontSize = Fonts.small.size,
        align    = "center",
    })
    self._waitLbl:setFillColor(0.6, 0.6, 0.7)

    self._oppNameLbl = display.newText({
        parent   = group,
        text     = "",
        x        = cx,
        y        = infoY + Fonts.small.size + 10 * sc,
        font     = Fonts.large.name,
        fontSize = Fonts.large.size,
        align    = "center",
    })
    self._oppNameLbl:setFillColor(1, 1, 1)

    self._oppTrophyLbl = display.newText({
        parent   = group,
        text     = "",
        x        = cx,
        y        = infoY + Fonts.small.size + 10 * sc + Fonts.large.size + 8 * sc,
        font     = Fonts.small.name,
        fontSize = Fonts.small.size,
        align    = "center",
    })
    self._oppTrophyLbl:setFillColor(0.9, 0.85, 0.3)

    -- ── Cancel button ─────────────────────────────────────────────────────────
    local btnW    = math.floor(200 * sc)
    local btnH    = math.floor(72  * sc)
    local deckBot = gridY + gridH
    local btnCY   = math.floor(deckBot + (H - deckBot - btnH) / 2)

    local cancelBtn, cancelBg = makeRoundedButton(
        group, "Cancel",
        cx, btnCY,
        btnW, btnH, sc,
        {0.600, 0.459, 0.467},
        {0.700, 0.559, 0.567}
    )
    self._cancelBtn = cancelBtn
    self._cancelBtnCY = btnCY
    self._cancelBtnW  = btnW
    self._cancelBtnH  = btnH

    cancelBtn:addEventListener("touch", function(e)
        if e.phase == "began" then
            S.cancelSpring.pressed = true
        elseif e.phase == "ended" or e.phase == "cancelled" then
            S.cancelSpring.pressed = false
            if e.phase == "ended" then
                leaveQueue()
                composer.gotoScene("src.screens.menu", { effect = "fade", time = 300 })
            end
        end
        return true
    end)

    -- ── Bottom info strip ─────────────────────────────────────────────────────
    self._bottomLbl = display.newText({
        parent   = group,
        text     = "",
        x        = cx,
        y        = H - math.max(50 * sc, Constants.SAFE_INSET_BOTTOM + 24 * sc),
        font     = Fonts.tiny.name,
        fontSize = Fonts.tiny.size,
        align    = "center",
    })
    self._bottomLbl:setFillColor(0.4, 0.4, 0.4, 0.5)
end

function scene:show(event)
    if event.phase ~= "did" then return end

    local params = event.params or {}
    initState(params.client or _G.GameSocket, params.roomKey)
    registerNetworkCallbacks()
    joinQueue()

    -- Reset timer baseline
    S._lastTime = system.getTimer() / 1000

    self._frameListener = Runtime:addEventListener("enterFrame", onUpdate)
    self:_refreshStatus()
end

function scene:hide(event)
    if event.phase ~= "will" then return end
    Runtime:removeEventListener("enterFrame", self._frameListener)
end

function scene:destroy(event)
    if S.status == "queueing" then leaveQueue() end
end

-- ── UI refresh helper ─────────────────────────────────────────────────────────

function scene:_refreshStatus()
    if not self._waitLbl then return end

    local W  = Constants.GAME_WIDTH
    local sc = Constants.SCALE

    if S.status == "queueing" then
        self._waitLbl.text = S.waitingSentence
        self._waitLbl:setFillColor(0.6, 0.6, 0.7)
        self._oppNameLbl.text   = ""
        self._oppTrophyLbl.text = ""
        self._tickerLbl.text    = "matchmaking"
        self._tickerLbl:setFillColor(0.965, 0.839, 0.741)
        if self._cancelBtn then self._cancelBtn.isVisible = true end

        local elapsed   = getTime() - S.queueStartTime
        local range     = 100 + math.min(math.floor(elapsed / 5) * 50, 400)
        local lo        = math.max(0, S.myTrophies - range)
        local hi        = S.myTrophies + range
        self._bottomLbl.text = string.format(
            "%d trophies  ·  searching %d – %d", S.myTrophies, lo, hi)

    elseif S.status == "matched" then
        self._waitLbl.text      = "Match Found!"
        self._oppNameLbl.text   = "vs " .. (S.opponentName or "")
        self._oppTrophyLbl.text = (S.opponentTrophies or 0) .. " trophies"
        self._tickerLbl.text    = "match found!"
        self._tickerLbl:setFillColor(0.9, 0.85, 0.3)
        if self._cancelBtn then self._cancelBtn.isVisible = false end
        self._bottomLbl.text = "Starting game..."

    elseif S.status == "error" then
        self._waitLbl.text = S.statusMsg
        self._waitLbl:setFillColor(1, 0.4, 0.4)
        self._bottomLbl.text = ""
    end

    -- No-deck label visibility
    if self._noDeckLbl then
        self._noDeckLbl.isVisible = (#S.previewLayout == 0)
    end
end

scene:addEventListener("create",  scene)
scene:addEventListener("show",    scene)
scene:addEventListener("hide",    scene)
scene:addEventListener("destroy", scene)

return scene
