-- AutoChest – Main Menu Screen
-- 3-panel swipeable card navigation: Collection | Play Online | Shop

local Screen         = require('lib.screen')
local Constants      = require('src.constants')
local UnitRegistry   = require('src.unit_registry')
local DeckManager    = require('src.deck_manager')
local SocketManager  = require('src.socket_manager')

local MenuScreen = {}

function MenuScreen.new()
    local self = Screen.new()

    -- ── init ────────────────────────────────────────────────────────────────

    function self:init()
        local W = Constants.GAME_WIDTH

        -- Panel state (1=Collection, 2=Decks, 3=Battle, 4=Shop, 5=Ranking); start on Battle
        self.NUM_PANELS   = 5
        self.currentPanel = 3
        self.panelOffset  = -(2 * W)   -- visual X offset of the strip
        self.targetOffset = -(2 * W)
        self.LERP_SPEED   = 14

        -- Swipe detection
        self.pressX      = 0
        self.pressY      = 0
        self.isPressed   = false  -- true only while button/touch is held
        self.isDragging  = false
        self.hasMoved    = false
        self.SWIPE_THRESH = 10   -- px before committing to horizontal drag
        self.SNAP_THRESH  = 60   -- px release delta to switch panel

        -- (IP input removed - now using authentication)

        -- Collection sub-view ("grid" or "detail")
        self.collectionView    = "grid"
        self.detailUnit        = nil   -- unitType string when in detail view
        self._backButtonRect   = nil
        self._detailSpriteRect = nil
        self._detailRotAngle   = 1    -- 1-6 index into ROTATION_ANGLES
        self._detailDragX      = nil  -- non-nil while dragging sprite

        -- Deck builder state
        DeckManager.load()
        -- If no active deck set yet, default to slot 1 and persist it
        if not DeckManager._data.activeDeckIndex then
            DeckManager.setActive(1)
        end
        self.selectedDeckSlot = DeckManager._data.activeDeckIndex
        self._deckSlotRects   = {}
        self._deckCardRects   = {}
        self._deckSortRect    = nil
        self._deckActiveRect  = nil
        self._deckSortByCost  = false
        self.previewLayout    = {}
        -- Deck detail sub-view ("grid" or "detail")
        self.deckView         = "grid"
        self.deckDetailUnit   = nil

        -- Load front sprites for collection display (sorted for stable ordering).
        -- Use loadSprites so we also get frontTrimBottom for baseline alignment.
        self.unitOrder        = UnitRegistry.getAllUnitTypes()
        table.sort(self.unitOrder)
        self.sprites          = {}
        self.spriteTrimBottoms = {}
        -- Directional sprites for play-panel idle animation (keyed by unitType)
        self.dirSprites = {}
        -- Per-unit idle animation state: {frameIndex, timer}
        self.idleAnim   = {}
        -- Per-unit attack animation state for play-panel tap: {active, progress, duration}
        self.attackAnim = {}
        -- Hit rects for tappable units on the play-panel preview grid
        self._previewUnitRects = {}
        for _, utype in ipairs(self.unitOrder) do
            local loaded = UnitRegistry.loadDirectionalSprites(utype)
            self.sprites[utype]           = loaded.front
            self.spriteTrimBottoms[utype] = loaded.frontTrimBottom
            self.dirSprites[utype]        = loaded
            self.idleAnim[utype]          = { frameIndex = 1, timer = 0 }
            self.attackAnim[utype]        = { active = false, progress = 0, duration = 0.45 }
        end
        self:buildPreviewLayout()

        -- Bottom tab bar icons (order matches panel indices)
        self.uiIcons = {}
        for i, name in ipairs({ 'collection', 'decks', 'battle', 'shop', 'ranking' }) do
            local img = love.graphics.newImage('src/assets/ui/' .. name .. '.png')
            img:setFilter('nearest', 'nearest')
            self.uiIcons[i] = img
        end

        -- Currency strip icons
        self.gemIcon  = love.graphics.newImage('src/assets/ui/gem.png')
        self.goldIcon = love.graphics.newImage('src/assets/ui/gold.png')
        self.gemIcon:setFilter('nearest', 'nearest')
        self.goldIcon:setFilter('nearest', 'nearest')
        -- Tab raise animation values: 0 = flat, 1 = fully popped
        self.tabRaiseAnim = { 0, 0, 1, 0, 0 }  -- panel 3 (Battle) starts active

        -- Settings overlay
        self.showSettings        = false
        self._settingsBtnRect    = nil
        self._settingsLogoutRect = nil
        self._settingsMusicRect  = nil
        self._settingsSFXRect    = nil
        self._settingsGodModeRect = nil
        self._settingsTitleRect   = nil
        self._settingsTitleTaps   = 0
        self._settingsTitleLastTap = 0
        self._showGodModeRow     = false

        -- Reward reveal state
        self._rewardState     = "idle"   -- "idle", "pending", "revealing"
        self._rewardAnimTimer = 0
        self._rewardUnit      = nil
        self._rewardType      = nil      -- "card" or "new_unit"
        self._rewardLevel     = nil
        self._xpBarRect       = nil

        -- Hit-rect caches (rebuilt each draw, stored in screen coords)
        self._collectionCards = {}
        self._ipFieldRect     = nil
        self._playBtnRect     = nil
        self._sandboxBtnRect  = nil
        self._tabRects        = {}

        -- Shop state
        self._shopGemBtns  = {}  -- hit rects for gem purchase buttons
        self._shopGoldBtns = {}  -- hit rects for gold purchase buttons
        self.shopNotice    = nil
        self.shopNoticeTimer = 0

        -- Reconnection state
        self._reconnectHandle = nil
        self._reconnecting    = false

        -- Socket callback refs (for cleanup)
        self._cb_currencyUpdate = nil
        self._cb_shopError      = nil
        self._cb_disconnect     = nil
        self._cb_decksSynced    = nil

        -- Register socket handlers
        self:registerSocketHandlers()

        love.keyboard.setKeyRepeat(true)

        -- Start background music when player lands on menu
        AudioManager.playMusic()
        AudioManager.setBattleMode(false)

        -- Scrolling ticker stripe (one message at a time, with pause between).
        -- Add more strings here to have them appear in the ticker.
        self._tickerMessages   = {
            "This is a test",
            "This is not a test",
            "Okay maybe this IS a test",
            "Build your deck. Crush your enemies.",
            "Units respawn every round. Plan accordingly.",
            "Losing gives you bonus coins. Stay in the fight.",
        }
        self._tickerCurrentMsg = nil
        self._tickerLastIdx    = nil   -- prevents back-to-back repeats
        self._tickerMsgPx      = 0
        self._tickerOffset     = 0
        self._tickerState      = "waiting"
        self._tickerWaitTimer  = 1.0

        -- Button spring physics (Balatro squish/bounce)
        self._playSpring = { scale = 1.0, vel = 0.0, pressed = false }
        self._sbtnSpring = { scale = 1.0, vel = 0.0, pressed = false }

        -- Online player count
        self._onlineCount     = nil  -- nil until first response
        self._onlinePollTimer = 30   -- start at max so first poll fires immediately
    end

    function self:registerSocketHandlers()
        if not _G.GameSocket then
            print("[MENU] WARNING: _G.GameSocket is nil, no handlers registered")
            return
        end

        self._cb_currencyUpdate = _G.GameSocket:on("currency_update", function(data)
            print("[MENU] currency_update received gold=" .. tostring(data.gold) .. " gems=" .. tostring(data.gems))
            if _G.PlayerData then
                if data.gold    ~= nil then _G.PlayerData.gold    = data.gold    end
                if data.gems    ~= nil then _G.PlayerData.gems    = data.gems    end
                if data.xp      ~= nil then _G.PlayerData.xp      = data.xp      end
                if data.level   ~= nil then _G.PlayerData.level   = data.level   end
                if data.unlocks ~= nil then _G.PlayerData.unlocks = data.unlocks end
            end
        end)

        self._cb_shopError = _G.GameSocket:on("shop_error", function(data)
            self.shopNotice = data.reason or "Purchase failed"
            self.shopNoticeTimer = 2.5
        end)

        self._cb_disconnect = _G.GameSocket:on("disconnect", function()
            print("[MENU] Socket disconnected, will reconnect on next action")
        end)

        self._cb_forcedLogout = _G.GameSocket:on("forced_logout", function(data)
            print("[MENU] Forced logout: " .. tostring(data and data.reason))
            love.filesystem.remove("session.dat")
            _G.GameSocket = nil
            _G.PlayerData = nil
            local ScreenManager = require('lib.screen_manager')
            ScreenManager.switch('login')
        end)

        self._cb_decksSynced = _G.GameSocket:on("decks_synced", function()
            self:buildPreviewLayout()
        end)

        self._cb_onlineCount = _G.GameSocket:on("online_count", function(data)
            self._onlineCount = data.count
        end)

        self._cb_rewardClaimed = _G.GameSocket:on("reward_claimed", function(data)
            -- Server confirms claim; sync pending_rewards
            if _G.PlayerData and _G.PlayerData.unlocks then
                _G.PlayerData.unlocks.pending_rewards = data.pending_rewards or {}
            end
        end)
    end

    function self:removeSocketHandlers()
        if _G.GameSocket then
            if self._cb_currencyUpdate then _G.GameSocket:removeCallback(self._cb_currencyUpdate) end
            if self._cb_shopError      then _G.GameSocket:removeCallback(self._cb_shopError) end
            if self._cb_disconnect     then _G.GameSocket:removeCallback(self._cb_disconnect) end
            if self._cb_forcedLogout   then _G.GameSocket:removeCallback(self._cb_forcedLogout) end
            if self._cb_decksSynced    then _G.GameSocket:removeCallback(self._cb_decksSynced) end
            if self._cb_onlineCount    then _G.GameSocket:removeCallback(self._cb_onlineCount) end
            if self._cb_rewardClaimed  then _G.GameSocket:removeCallback(self._cb_rewardClaimed) end
        end
        self._cb_currencyUpdate = nil
        self._cb_shopError      = nil
        self._cb_disconnect     = nil
        self._cb_forcedLogout   = nil
        self._cb_decksSynced    = nil
        self._cb_onlineCount    = nil
        self._cb_rewardClaimed  = nil
    end

    function self:startReconnect()
        if self._reconnecting then return end
        self._reconnecting = true
        print("[MENU] Starting socket reconnection...")
        self._reconnectHandle = SocketManager.reconnect(
            function()  -- onSuccess
                print("[MENU] Reconnected successfully")
                self._reconnecting    = false
                self._reconnectHandle = nil
                self:registerSocketHandlers()
            end,
            function(reason)  -- onFailure
                print("[MENU] Reconnect failed: " .. tostring(reason))
                self._reconnecting    = false
                self._reconnectHandle = nil
                love.filesystem.remove("session.dat")
                _G.GameSocket = nil
                _G.PlayerData = nil
                local ScreenManager = require('lib.screen_manager')
                ScreenManager.switch('login')
            end
        )
    end

    function self:focus(hasFocus)
        if hasFocus then
            -- Returning from background: check socket health
            if _G.GameSocket and not _G.GameSocket:isConnected() and not self._reconnecting then
                print("[MENU] Socket lost while backgrounded, reconnecting...")
                self:startReconnect()
            end
        end
    end

    function self:close()
        love.keyboard.setKeyRepeat(false)
        self:removeSocketHandlers()
    end

    function self:buildPreviewLayout()
        self.previewLayout = {}
        local deck = DeckManager.getActiveDeck()
        if not deck then return end

        -- One entry per unit type that has at least 1 card
        local units = {}
        for utype, count in pairs(deck.counts) do
            if count > 0 then
                table.insert(units, utype)
            end
        end
        if #units == 0 then return end

        -- All 20 positions (4 rows × 5 cols), Fisher-Yates shuffled
        local positions = {}
        for r = 1, 4 do
            for c = 1, 5 do
                table.insert(positions, { col = c, row = r })
            end
        end
        for i = #positions, 2, -1 do
            local j = math.random(i)
            positions[i], positions[j] = positions[j], positions[i]
        end

        local n = math.min(#units, #positions)
        for i = 1, n do
            table.insert(self.previewLayout, {
                unitType = units[i],
                col      = positions[i].col,
                row      = positions[i].row,
            })
        end
    end

    -- ── update ──────────────────────────────────────────────────────────────

    function self:update(dt)
        dt = math.min(dt, 1/30)  -- cap spikes from app backgrounding
        -- Keep socket connection alive, or reconnect if dead
        if self._reconnecting and self._reconnectHandle then
            SocketManager.updateReconnect(self._reconnectHandle, dt)
        elseif _G.GameSocket then
            if _G.GameSocket:isConnected() then
                local ok, err = pcall(function() _G.GameSocket:update() end)
                if not ok then
                    print("[MENU] Socket error, reconnecting: " .. tostring(err))
                    _G.GameSocket = nil
                    self:startReconnect()
                end
            elseif not self._reconnecting then
                self:startReconnect()
            end
        end

        -- Online count polling (every 30s)
        if _G.GameSocket and _G.GameSocket:isConnected() then
            self._onlinePollTimer = self._onlinePollTimer + dt
            if self._onlinePollTimer >= 30 then
                self._onlinePollTimer = 0
                _G.GameSocket:send("get_online_count", {})
            end
        end

        -- Shop notice timer
        if self.shopNoticeTimer > 0 then
            self.shopNoticeTimer = self.shopNoticeTimer - dt
            if self.shopNoticeTimer <= 0 then
                self.shopNotice    = nil
                self.shopNoticeTimer = 0
            end
        end

        -- Reward reveal state machine
        if self._rewardState == "idle" then
            local unlocks = _G.PlayerData and _G.PlayerData.unlocks
            if unlocks and unlocks.pending_rewards and #unlocks.pending_rewards > 0 then
                local reward = unlocks.pending_rewards[1]
                self._rewardState     = "pending"
                self._rewardUnit      = reward.unit
                self._rewardType      = reward.type   -- "card" or "new_unit"
                self._rewardLevel     = reward.level
                self._rewardShakeTime = 0
            end
        elseif self._rewardState == "pending" then
            self._rewardShakeTime = (self._rewardShakeTime or 0) + dt
        elseif self._rewardState == "revealing" then
            self._rewardAnimTimer = self._rewardAnimTimer + dt
        end

        -- Advance idle and attack animations for play-panel preview
        local DEFAULT_IDLE_FRAME_DUR = 0.12 * 2  -- matches animFrameDuration * 2 from base_unit
        local IDLE_FRAME_DUR_OVERRIDE = { marrow = 0.18 }  -- per-unit overrides (matches idleFrameDuration in unit files)
        for _, utype in ipairs(self.unitOrder) do
            local d = self.dirSprites[utype]
            -- Idle frame cycling
            if d and d.hasDirectionalSprites and d.directional.idle and d.directional.idle[0] then
                local frames   = d.directional.idle[0].frames
                local anim     = self.idleAnim[utype]
                local frameDur = IDLE_FRAME_DUR_OVERRIDE[utype] or DEFAULT_IDLE_FRAME_DUR
                anim.timer = anim.timer + dt
                if anim.timer >= frameDur then
                    anim.timer = anim.timer - frameDur
                    anim.frameIndex = (anim.frameIndex % #frames) + 1
                end
            end
            -- Attack animation (triggered by tapping a unit on the preview grid)
            local atk = self.attackAnim[utype]
            if atk.active then
                atk.progress = atk.progress + dt / atk.duration
                if atk.progress >= 1 then
                    atk.active   = false
                    atk.progress = 0
                end
            end
        end

        -- Lerp panel strip toward target
        local diff = self.targetOffset - self.panelOffset
        if math.abs(diff) < 0.5 then
            self.panelOffset = self.targetOffset
        else
            local step = diff * self.LERP_SPEED * dt
            self.panelOffset = self.panelOffset + step
        end

        -- Animate tab raise (active tab pops up, others flatten)
        for i = 1, self.NUM_PANELS do
            local target = (i == self.currentPanel) and 1 or 0
            local d = target - self.tabRaiseAnim[i]
            if math.abs(d) < 0.01 then
                self.tabRaiseAnim[i] = target
            else
                self.tabRaiseAnim[i] = self.tabRaiseAnim[i] + d * 12 * dt
            end
        end

        -- Ticker: one message scrolls across, then pauses before the next
        local tickerW = Constants.GAME_WIDTH
        local tickerSpeed = 60 * Constants.SCALE
        local TICKER_PAUSE = 2.5   -- seconds of blank between messages

        if self._tickerState == "scrolling" then
            self._tickerOffset = self._tickerOffset + tickerSpeed * dt
            if self._tickerOffset >= tickerW + self._tickerMsgPx then
                self._tickerState     = "waiting"
                self._tickerWaitTimer = TICKER_PAUSE
            end
        elseif self._tickerState == "waiting" then
            self._tickerWaitTimer = self._tickerWaitTimer - dt
            if self._tickerWaitTimer <= 0 then
                local msgs = self._tickerMessages
                local idx  = math.random(#msgs)
                -- avoid showing the same message twice in a row
                if #msgs > 1 then
                    while idx == self._tickerLastIdx do
                        idx = math.random(#msgs)
                    end
                end
                self._tickerLastIdx    = idx
                self._tickerCurrentMsg = msgs[idx]
                self._tickerMsgPx      = Fonts.small:getWidth(self._tickerCurrentMsg)
                self._tickerOffset     = 0
                self._tickerState      = "scrolling"
            end
        end

        -- Button spring physics (underdamped: k=480, d=18 → overshoot ~1.05)
        local function updateSpring(sp, dt2)
            local target = sp.pressed and 0.93 or 1.0
            local accel  = -480 * (sp.scale - target) - 18 * sp.vel
            sp.vel   = sp.vel   + accel * dt2
            sp.scale = sp.scale + sp.vel  * dt2
            sp.scale = math.max(0.85, math.min(1.12, sp.scale))
        end
        updateSpring(self._playSpring, dt)
        updateSpring(self._sbtnSpring, dt)
    end

    -- Returns the current preview frame + trimBottom for a unit type.
    -- Attack animation takes priority over idle; falls back to static front sprite.
    function self:getPreviewFrame(utype)
        local d = self.dirSprites[utype]
        if d and d.hasDirectionalSprites then
            -- Attack animation takes priority
            local atk = self.attackAnim[utype]
            if atk.active and d.directional.hit and d.directional.hit[0] then
                local dirData = d.directional.hit[0]
                local count   = #dirData.frames
                local p       = atk.progress
                local idx
                if count >= 3 then
                    if     p < 1/3 then idx = 1
                    elseif p < 2/3 then idx = 2
                    else                idx = 3 end
                else
                    idx = math.min(count, math.floor(p * count) + 1)
                end
                return dirData.frames[idx], dirData.trimBottom[idx]
            end
            -- Action units: use action/idle override sprite (animated)
            local aio = d.directional.actionIdleOverride
            if aio and (aio[0] or aio[180]) then
                local ad  = aio[0] or aio[180]
                local idx = math.min(self.idleAnim[utype].frameIndex, #ad.frames)
                return ad.frames[idx], ad.trimBottom[idx] or 0
            end
            -- Idle
            if d.directional.idle and d.directional.idle[0] then
                local dirData = d.directional.idle[0]
                local idx     = self.idleAnim[utype].frameIndex
                return dirData.frames[idx], dirData.trimBottom[idx]
            end
        end
        return self.sprites[utype], self.spriteTrimBottoms[utype] or 0
    end

    -- ── ticker stripe ────────────────────────────────────────────────────────

    function self:drawTickerStripe(W, sc)
        local lg      = love.graphics
        local stripeY = math.floor(75 * sc)
        local stripeH = math.floor(36 * sc)

        -- Background
        lg.setColor(0.031, 0.078, 0.118, 1)
        lg.rectangle('fill', 0, stripeY, W, stripeH)

        -- Separator lines
        lg.setColor(0.125, 0.224, 0.310, 1)
        lg.setLineWidth(math.max(1, math.floor(sc)))
        lg.line(0, stripeY, W, stripeY)
        lg.line(0, stripeY + stripeH, W, stripeY + stripeH)

        -- Draw current message scrolling right-to-left (messages & timing driven by update)
        if self._tickerCurrentMsg and self._tickerState == "scrolling" then
            lg.setScissor(0, stripeY, W, stripeH)
            lg.setFont(Fonts.small)
            lg.setColor(0.965, 0.839, 0.741, 1)
            local textY = math.floor(stripeY + (stripeH - (Fonts.small:getAscent() - Fonts.small:getDescent())) / 2)
            lg.print(self._tickerCurrentMsg, math.floor(W - self._tickerOffset), textY)
            lg.setScissor()
        end
    end

    -- ── draw helpers ────────────────────────────────────────────────────────

    local function roundedRect(x, y, w, h, r, sc)
        love.graphics.rectangle('fill', x, y, w, h, r * sc, r * sc)
    end

    local function roundedRectLine(x, y, w, h, r, sc, lw)
        love.graphics.setLineWidth(lw or 2)
        love.graphics.rectangle('line', x, y, w, h, r * sc, r * sc)
    end

    -- Vertically centre text in a box using actual glyph bounds (excludes leading)
    local function textCY(font, boxY, boxH)
        return math.floor(boxY + (boxH - (font:getAscent() - font:getDescent())) / 2)
    end

    function self:drawCollectionCard(cx, cy, cardW, cardH, utype, sc)
        local lg = love.graphics
        local rarity = UnitRegistry.rarity[utype] or "common"

        -- Rarity border colours using system palette
        local borderR, borderG, borderB
        if rarity == "epic" then
            borderR, borderG, borderB = 0.765, 0.639, 0.541  -- tan/copper
        elseif rarity == "rare" then
            borderR, borderG, borderB = 0.600, 0.459, 0.467  -- muted rose
        else
            borderR, borderG, borderB = 0.125, 0.224, 0.310  -- steel-blue (common)
        end

        -- Background + border
        lg.setColor(0.059, 0.165, 0.247, 1)
        roundedRect(cx, cy, cardW, cardH, 6, sc)
        lg.setColor(borderR, borderG, borderB, 1)
        roundedRectLine(cx, cy, cardW, cardH, 6, sc, 2 * sc)
        -- Inner top bevel highlight
        lg.setColor(borderR, borderG, borderB, 0.5)
        lg.setLineWidth(math.max(1, math.floor(sc)))
        lg.line(cx + 4 * sc, cy + 1, cx + cardW - 4 * sc, cy + 1)

        -- Unit name
        lg.setFont(Fonts.small)
        lg.setColor(1, 1, 1, 1)
        local name = utype:sub(1,1):upper() .. utype:sub(2)
        lg.printf(name, cx, cy + 10 * sc, cardW, 'center')

        -- Cost badge (bottom-right, inside card)
        local cost = UnitRegistry.unitCosts[utype] or "?"
        local costStr = tostring(cost)
        local badgeW = 20 * sc
        local badgeH = 18 * sc
        local badgeX = cx + cardW - badgeW - 5 * sc
        local badgeY = cy + cardH - badgeH - 5 * sc
        lg.setColor(0.031, 0.078, 0.118, 1)
        roundedRect(badgeX, badgeY, badgeW, badgeH, 4, sc)
        lg.setColor(0.765, 0.639, 0.541, 1)
        roundedRectLine(badgeX, badgeY, badgeW, badgeH, 4, sc, math.max(1, math.floor(1.5 * sc)))
        lg.setFont(Fonts.tiny)
        lg.setColor(0.965, 0.839, 0.741, 1)
        lg.printf(costStr, badgeX, badgeY + (badgeH - Fonts.tiny:getHeight()) / 2, badgeW, 'center')

        -- Front sprite (integer scale, bottom-anchored to card baseline)
        -- Action units: use action/idle override sprite instead of default front
        local img, trimBottom
        local _d = self.dirSprites[utype]
        local _aio = _d and _d.directional and _d.directional.actionIdleOverride
        if _aio and (_aio[0] or _aio[180]) then
            local _ad = _aio[0] or _aio[180]
            img        = _ad.frames[1]
            trimBottom = _ad.trimBottom[1] or 0
        else
            img        = self.sprites[utype]
            trimBottom = self.spriteTrimBottoms[utype] or 0
        end
        local iw, ih = img:getDimensions()
        local sprSc      = math.max(1, math.floor(4 * sc))
        local BOTTOM_MARGIN = 3
        local sx = math.floor(cx + (cardW - iw * sprSc) / 2)
        local sy = math.floor(cy + cardH - (ih - trimBottom + BOTTOM_MARGIN) * sprSc)
        lg.setColor(1, 1, 1, 1)
        lg.draw(img, sx, sy, 0, sprSc, sprSc)

        -- Tap hint
        --lg.setFont(Fonts.tiny)
        --lg.setColor(0.45, 0.45, 0.55, 1)
        --lg.printf("tap for info", cx, cy + cardH - 18 * sc, cardW, 'center')
    end

    function self:drawEmptyCard(cx, cy, cardW, cardH, sc)
        local lg = love.graphics
        lg.setColor(0.031, 0.078, 0.118, 1)
        roundedRect(cx, cy, cardW, cardH, 6, sc)
        lg.setColor(0.306, 0.286, 0.373, 0.6)
        roundedRectLine(cx, cy, cardW, cardH, 6, sc, 2 * sc)
        lg.setFont(Fonts.medium)
        lg.setColor(0.306, 0.286, 0.373, 1)
        lg.printf("?", cx, textCY(Fonts.medium, cy, cardH), cardW, "center")
    end

    function self:drawLockedCard(cx, cy, cardW, cardH, utype, sc)
        local lg = love.graphics
        -- Card background
        lg.setColor(0.031, 0.078, 0.118, 1)
        roundedRect(cx, cy, cardW, cardH, 6, sc)
        -- Dim border
        lg.setColor(0.180, 0.200, 0.240, 1)
        roundedRectLine(cx, cy, cardW, cardH, 6, sc, 2 * sc)

        -- Silhouette sprite (same layout as drawCollectionCard)
        local _d   = self.dirSprites[utype]
        local _aio = _d and _d.directional and _d.directional.actionIdleOverride
        local img, trimBottom
        if _aio and (_aio[0] or _aio[180]) then
            local _ad  = _aio[0] or _aio[180]
            img        = _ad.frames[1]
            trimBottom = _ad.trimBottom[1] or 0
        else
            img        = self.sprites[utype]
            trimBottom = self.spriteTrimBottoms[utype] or 0
        end
        if img then
            local iw, ih = img:getDimensions()
            local sprSc      = math.max(1, math.floor(4 * sc))
            local BOTTOM_MARGIN = 3
            local sx = math.floor(cx + (cardW - iw * sprSc) / 2)
            local sy = math.floor(cy + cardH - (ih - trimBottom + BOTTOM_MARGIN) * sprSc)
            -- Dark silhouette tint
            lg.setColor(0.03, 0.04, 0.06, 1)
            lg.draw(img, sx, sy, 0, sprSc, sprSc)
        end

        -- "?" label at top (name area)
        lg.setFont(Fonts.small)
        lg.setColor(0.306, 0.286, 0.373, 1)
        lg.printf("?", cx, cy + 10 * sc, cardW, 'center')
    end

    function self:drawGroupHeader(x, y, w, h, name, sc)
        local lg = love.graphics
        -- Base fill
        lg.setColor(0.059, 0.165, 0.247, 1)
        lg.rectangle("fill", x, y, w, h, 4 * sc, 4 * sc)
        -- Left accent bar
        lg.setColor(0.765, 0.639, 0.541, 1)
        lg.rectangle("fill", x, y, 4 * sc, h, 2 * sc, 2 * sc)
        -- Top bevel highlight
        lg.setColor(0.125, 0.224, 0.310, 0.5)
        lg.setLineWidth(math.max(1, math.floor(sc)))
        lg.line(x, y + 1, x + w, y + 1)
        -- Bottom shadow
        lg.setColor(0.031, 0.078, 0.118, 0.8)
        lg.line(x, y + h - 1, x + w, y + h - 1)
        -- Group name
        lg.setFont(Fonts.medium)
        lg.setColor(0.965, 0.839, 0.741, 1)
        lg.print(name, x + 14 * sc, textCY(Fonts.medium, y, h))
    end

    function self:drawCollectionDetailPage(ox, W, H, sc)
        local lg    = love.graphics
        local utype = self.detailUnit
        if not utype then return end

        local info    = UnitRegistry.getUnitDisplayInfo(utype)
        local passive = UnitRegistry.passiveDescriptions[utype] or ""
        local textW   = W - math.floor(64 * sc)
        local textX   = ox + math.floor(32 * sc)

        -- ── Back button (below ticker stripe bottom at 111*sc) ──
        local btnH = math.floor(40 * sc)
        local btnY = math.floor(118 * sc)
        local btnX = ox + math.floor(16 * sc)
        lg.setFont(Fonts.small)
        lg.setColor(0.965, 0.839, 0.741, 1)
        lg.print("\xe2\x86\x90 Back", btnX, textCY(Fonts.small, btnY, btnH))
        self._backButtonRect = { x = btnX + self.panelOffset, y = btnY, w = math.floor(100 * sc), h = btnH }

        -- ── Text content (top to bottom, starting below back button) ──
        local curY = btnY + btnH + math.floor(8 * sc)

        -- Unit name
        local name = utype:sub(1,1):upper() .. utype:sub(2)
        lg.setFont(Fonts.medium)
        lg.setColor(1, 1, 1, 1)
        lg.printf(name, ox, curY, W, 'center')
        curY = curY + Fonts.medium:getHeight() + math.floor(5 * sc)

        -- Stats row
        lg.setFont(Fonts.tiny)
        lg.setColor(0.965, 0.839, 0.741, 1)
        local s = string.format("HP %d  ATK %d  SPD %.1f  RNG %d  [%s]",
            info.hp, info.atk, info.spd, info.rng, info.unitClass)
        lg.printf(s, textX, curY, textW, 'center')
        curY = curY + Fonts.tiny:getHeight() + math.floor(7 * sc)

        -- Separator
        lg.setColor(0.306, 0.286, 0.373, 1)
        lg.setLineWidth(math.max(1, math.floor(sc)))
        lg.line(textX, curY, ox + W - math.floor(32 * sc), curY)
        curY = curY + math.floor(7 * sc)

        -- Passive description
        local _, pLines = Fonts.tiny:getWrap(passive, textW)
        lg.setFont(Fonts.tiny)
        lg.setColor(0.765, 0.639, 0.541, 1)
        lg.printf(passive, textX, curY, textW, 'left')
        curY = curY + math.max(1, #pLines) * Fonts.tiny:getHeight() + math.floor(8 * sc)

        -- Upgrades header
        lg.setFont(Fonts.small)
        lg.setColor(0.965, 0.839, 0.741, 1)
        lg.printf("Upgrades", textX, curY, textW, 'left')
        curY = curY + Fonts.small:getHeight() + math.floor(4 * sc)

        -- Upgrade rows
        lg.setFont(Fonts.tiny)
        for i, upg in ipairs(info.upgrades) do
            lg.setColor(0.965, 0.839, 0.741, 1)
            lg.printf(i .. ". " .. upg.name, textX + math.floor(6 * sc), curY, textW, 'left')
            curY = curY + Fonts.tiny:getHeight() + math.floor(2 * sc)
            lg.setColor(0.765, 0.639, 0.541, 1)
            lg.printf("   " .. upg.description, textX + math.floor(6 * sc), curY, textW, 'left')
            curY = curY + Fonts.tiny:getHeight() + math.floor(4 * sc)
        end

        -- ── Bottom sprite zone ──
        local barH        = math.floor(90 * sc)
        local spriteZoneH = math.floor(160 * sc)
        local spriteZoneY = H - barH - spriteZoneH

        local sprSc = math.max(1, math.floor(12 * sc))

        local d = self.dirSprites[utype]
        if d and d.hasDirectionalSprites then
            -- ── Animated unit: single rotatable sprite ──
            local ROTATION_ANGLES = {0, 45, 90, 135, 180, 225, 270, 315}
            local angle = ROTATION_ANGLES[self._detailRotAngle]
            local img, trimBottom
            if angle == 0 then
                -- Front: action units use their action/idle override; others use animated idle
                local aio = d.directional.actionIdleOverride
                if aio and (aio[0] or aio[180]) then
                    local ad       = aio[0] or aio[180]
                    local frameIdx = self.idleAnim[utype].frameIndex
                    local idx      = math.min(frameIdx, #ad.frames)
                    img        = ad.frames[idx]
                    trimBottom = ad.trimBottom[idx] or 0
                else
                    local idleData = d.directional.idle[0]
                    local frameIdx = self.idleAnim[utype].frameIndex
                    frameIdx = math.min(frameIdx, #idleData.frames)
                    img        = idleData.frames[frameIdx]
                    trimBottom = idleData.trimBottom[frameIdx] or 0
                end
            else
                -- Other angles: use first walk frame
                local walkData = d.directional.walk[angle] or d.directional.walk[0]
                img        = walkData.frames[1]
                trimBottom = walkData.trimBottom[1] or 0
            end
            local iw, ih    = img:getDimensions()
            local baselineY = spriteZoneY + spriteZoneH - math.floor(24 * sc)
            local imgX      = math.floor(ox + (W - iw * sprSc) / 2)
            local imgY      = math.floor(baselineY - (ih - trimBottom) * sprSc)
            -- Draw bg animation behind the unit sprite (same baseline, same trimBottom)
            local bgFrames = d.bgAnimFrames
            if bgFrames then
                local fps      = 8
                local frameIdx = math.floor(love.timer.getTime() * fps) % #bgFrames + 1
                local bgImg    = bgFrames[frameIdx]
                local bw, bh   = bgImg:getDimensions()
                local bgX = math.floor(ox + (W - bw * sprSc) / 2)
                local bgY = math.floor(baselineY - (bh - trimBottom) * sprSc)
                lg.setColor(1, 1, 1, 1)
                lg.draw(bgImg, bgX, bgY, 0, sprSc, sprSc)
            end
            lg.setColor(1, 1, 1, 1)
            lg.draw(img, imgX, imgY, 0, sprSc, sprSc)

            -- Store sprite zone as drag rect
            self._detailSpriteRect = { x = ox, y = spriteZoneY, w = W, h = spriteZoneH }
        else
            -- ── Legacy unit: front + back side by side ──
            local frontImg   = self.sprites[utype]
            local frontTrim  = self.spriteTrimBottoms[utype] or 0
            local backImg    = d and d.back or frontImg
            local backTrim   = (d and d.backTrimBottom) or frontTrim
            local fw, fh     = frontImg:getDimensions()
            local bw, bh     = backImg:getDimensions()

            local gap    = math.floor(20 * sc)
            local totalW = fw * sprSc + gap + bw * sprSc
            local startX = math.floor(ox + (W - totalW) / 2)

            -- Baseline: bottom of the zone minus small margin
            local baselineY = spriteZoneY + spriteZoneH - math.floor(24 * sc)

            -- Front sprite (bottom-aligned)
            local fImgX = startX
            local fImgY = baselineY - (fh - frontTrim) * sprSc
            lg.setColor(1, 1, 1, 1)
            lg.draw(frontImg, fImgX, fImgY, 0, sprSc, sprSc)

            -- Back sprite (bottom-aligned)
            local bImgX = startX + fw * sprSc + gap
            local bImgY = baselineY - (bh - backTrim) * sprSc
            lg.draw(backImg, bImgX, bImgY, 0, sprSc, sprSc)

            self._detailSpriteRect = nil
        end
    end

    function self:drawCollectionPanel(ox, W, H, sc)
        if self.collectionView == "detail" then
            self:drawCollectionDetailPage(ox, W, H, sc)
            return
        end

        local cols   = 4
        local cardW  = 100 * sc
        local cardH  = 130 * sc
        local gapX   = 12  * sc
        local gapY   = 14  * sc
        local headerH = 40 * sc
        local groupGap = 10 * sc
        local totalW = cols * cardW + (cols - 1) * gapX
        local startX = ox + (W - totalW) / 2
        local startY = 160 * sc

        self._collectionCards = {}
        local currentY = startY
        local cardIndex = 0

        local unlocks = _G.PlayerData and _G.PlayerData.unlocks

        for _, group in ipairs(UnitRegistry.groups) do
            self:drawGroupHeader(startX, currentY, totalW, headerH, group.name, sc)
            currentY = currentY + headerH + 6 * sc

            for j, utype in ipairs(group.units) do
                local col = (j - 1) % cols
                local row = math.floor((j - 1) / cols)
                local cx  = startX + col * (cardW + gapX)
                local cy  = currentY + row * (cardH + gapY)
                local owned = unlocks and unlocks.cards and (unlocks.cards[utype] or 0) or nil
                local isLocked = (not _G.GodMode) and owned ~= nil and owned == 0
                if isLocked then
                    self:drawLockedCard(cx, cy, cardW, cardH, utype, sc)
                else
                    self:drawCollectionCard(cx, cy, cardW, cardH, utype, sc)
                    cardIndex = cardIndex + 1
                    self._collectionCards[cardIndex] = {
                        x = cx + self.panelOffset,
                        y = cy,
                        w = cardW,
                        h = cardH,
                        utype = utype
                    }
                end
            end

            local numRows = math.ceil(#group.units / cols)
            local remainder = #group.units % cols
            if remainder ~= 0 then
                for k = remainder + 1, cols do
                    local col = k - 1
                    local row = numRows - 1
                    local cx  = startX + col * (cardW + gapX)
                    local cy  = currentY + row * (cardH + gapY)
                    self:drawEmptyCard(cx, cy, cardW, cardH, sc)
                end
            end
            currentY = currentY + numRows * (cardH + gapY) + groupGap
        end
    end

    function self:drawPlayPanel(ox, W, H, sc)
        local lg       = love.graphics
        local cx       = ox + W / 2
        local cellSize    = Constants.CELL_SIZE
        local gridW       = 5 * cellSize
        local gridH       = 4 * cellSize
        local gridX       = ox + (W - gridW) / 2
        local btnY        = H * 0.62
        local contentTop  = 100 * sc
        local gridY       = math.floor(contentTop + (btnY - contentTop - gridH) / 2)

        -- Checkerboard cells
        local CDARK  = Constants.COLORS.CHESS_DARK
        local CLIGHT = Constants.COLORS.CHESS_LIGHT
        for row = 1, 4 do
            for col = 1, 5 do
                local cx2 = gridX + (col - 1) * cellSize
                local cy2 = gridY + (row - 1) * cellSize
                lg.setColor((row + col) % 2 == 0 and CDARK or CLIGHT)
                lg.rectangle('fill', cx2, cy2, cellSize, cellSize)
            end
        end

        -- Grid border
        lg.setColor(0.125, 0.224, 0.310, 1)
        lg.setLineWidth(math.max(1, math.floor(sc)))
        lg.rectangle('line', gridX, gridY, gridW, gridH)

        -- Unit sprites (idle/attack animated; hit rects stored for tap detection)
        local sprSc = cellSize / 16
        self._previewUnitRects = {}
        for _, entry in ipairs(self.previewLayout) do
            local img, trimBottom = self:getPreviewFrame(entry.unitType)
            if img then
                local iw, ih = img:getDimensions()
                local cx2 = gridX + (entry.col - 1) * cellSize
                local cy2 = gridY + (entry.row - 1) * cellSize
                -- Draw persistent bg animation (e.g. clavicula fire) behind the unit sprite
                local bgFrames = self.dirSprites[entry.unitType] and self.dirSprites[entry.unitType].bgAnimFrames
                if bgFrames then
                    local fps      = 8
                    local frameIdx = math.floor(love.timer.getTime() * fps) % #bgFrames + 1
                    local bgImg    = bgFrames[frameIdx]
                    local bw, bh   = bgImg:getDimensions()
                    -- Same formula as the unit sprite: use the sprite's trimBottom so bottoms align
                    local BOTTOM_MARGIN = 3
                    local bgOffX = math.floor(cx2 + (cellSize - bw * sprSc) / 2)
                    local bgOffY = math.floor(cy2 + cellSize - (bh - trimBottom + BOTTOM_MARGIN) * sprSc)
                    lg.setColor(1, 1, 1, 1)
                    lg.draw(bgImg, bgOffX, bgOffY, 0, sprSc, sprSc)
                end
                local BOTTOM_MARGIN = 3
                local sx = math.floor(cx2 + (cellSize - iw * sprSc) / 2)
                local sy = math.floor(cy2 + cellSize - (ih - trimBottom + BOTTOM_MARGIN) * sprSc)
                lg.setColor(1, 1, 1, 1)
                lg.draw(img, sx, sy, 0, sprSc, sprSc)
                table.insert(self._previewUnitRects, {
                    x = cx2 + self.panelOffset, y = cy2, w = cellSize, h = cellSize,
                    utype = entry.unitType
                })
            end
        end

        -- Empty deck hint
        if #self.previewLayout == 0 then
            lg.setFont(Fonts.small)
            lg.setColor(0.306, 0.286, 0.373, 1)
            lg.printf("Equip a deck to preview", gridX,
                gridY + gridH / 2 - Fonts.small:getHeight() / 2, gridW, 'center')
        end

        -- Buttons
        local btnW     = 240 * sc
        local playH    = 112 * sc
        local sbtnH    = 28  * sc   -- half height
        local btnX     = cx - btnW / 2
        local maxFloat = math.floor(6 * sc)
        local shadowH  = math.floor(6 * sc)

        -- Online count label above PLAY button
        local countLabel = self._onlineCount and ("Players online: " .. self._onlineCount) or "Players online: ..."
        lg.setFont(Fonts.small)
        lg.setColor(0.965, 0.839, 0.741, 0.85)
        lg.printf(countLabel, btnX, btnY - Fonts.small:getHeight() - 8 * sc, btnW, 'center')

        -- PLAY button: Balatro float + shadow + idle bob/rotation
        local t        = love.timer.getTime()
        local idleBob  = math.sin(t * 1.8) * 2 * sc        -- gentle vertical drift
        local idleRot  = math.sin(t * 1.3) * 0.012        -- ~0.7 deg, barely perceptible
        local s        = self._playSpring.scale
        local floatOff = math.floor(maxFloat * math.max(0, (s - 0.93) / 0.07))
        local drawY    = btnY - floatOff + math.floor(idleBob)

        -- Shadow (static at anchor — button floats above it)
        lg.setColor(0.031, 0.078, 0.118, 1)
        roundedRect(btnX + math.floor(2 * sc), btnY + shadowH, btnW, playH, 8, sc)

        -- Button face: pivot at center, rotate then scale
        local pivX = btnX + btnW / 2
        local pivY = drawY + playH / 2
        local bx   = -btnW  / 2   -- local-space left
        local by   = -playH / 2   -- local-space top
        lg.push()
        lg.translate(pivX, pivY)
        lg.rotate(idleRot)
        lg.scale(s, s)
        lg.setColor(0.765, 0.639, 0.541, 1)
        roundedRect(bx, by, btnW, playH, 8, sc)
        lg.setColor(0.965, 0.839, 0.741, 1)
        roundedRectLine(bx, by, btnW, playH, 8, sc, 2 * sc)
        lg.setFont(Fonts.large)
        lg.setColor(1, 1, 1, 1)
        lg.printf("PLAY", bx, textCY(Fonts.large, by, playH), btnW, 'center')
        lg.pop()
        -- Hit rect covers full float range
        self._playBtnRect = { x = btnX + self.panelOffset, y = btnY - maxFloat, w = btnW, h = playH + maxFloat }

        -- SANDBOX button (same float+shadow pattern, smaller)
        local sbtnY  = btnY + playH + shadowH + 14 * sc
        local ss     = self._sbtnSpring.scale
        local sfloat = math.floor(maxFloat * math.max(0, (ss - 0.93) / 0.07))
        local sdrawY = sbtnY - sfloat

        lg.setColor(0.031, 0.078, 0.118, 1)
        roundedRect(btnX + math.floor(2 * sc), sbtnY + shadowH, btnW, sbtnH, 8, sc)

        local spivX = btnX + btnW / 2
        local spivY = sdrawY + sbtnH / 2
        lg.push()
        lg.translate(spivX, spivY)
        lg.scale(ss, ss)
        lg.translate(-spivX, -spivY)
        lg.setColor(0.600, 0.459, 0.467, 1)
        roundedRect(btnX, sdrawY, btnW, sbtnH, 8, sc)
        lg.setColor(0.600, 0.459, 0.467, 1)
        roundedRectLine(btnX, sdrawY, btnW, sbtnH, 8, sc, 2 * sc)
        lg.setFont(Fonts.small)
        lg.setColor(1, 1, 1, 1)
        lg.printf("SANDBOX", btnX, textCY(Fonts.small, sdrawY, sbtnH), btnW, 'center')
        lg.pop()
        self._sandboxBtnRect = { x = btnX + self.panelOffset, y = sbtnY - maxFloat, w = btnW, h = sbtnH + maxFloat }
    end

    function self:drawDecksPanel(ox, W, H, sc)
        local lg = love.graphics

        if self.deckView == "detail" then
            self.detailUnit = self.deckDetailUnit
            self:drawCollectionDetailPage(ox, W, H, sc)
            return
        end

        -- ── Deck slot tabs ────────────────────────────────────────────────────
        local tabAreaW  = W - 40 * sc
        local tabW      = tabAreaW / 5
        local tabH      = 44 * sc
        local tabY      = 138 * sc
        local tabStartX = ox + 20 * sc

        self._deckSlotRects = {}
        for i = 1, 5 do
            local tx = tabStartX + (i - 1) * tabW
            if i == self.selectedDeckSlot then
                lg.setColor(0.059, 0.165, 0.247, 1)
                roundedRect(tx, tabY, tabW - 4 * sc, tabH, 5, sc)
                lg.setColor(0.125, 0.224, 0.310, 1)
                roundedRectLine(tx, tabY, tabW - 4 * sc, tabH, 5, sc, 2 * sc)
            else
                lg.setColor(0.031, 0.078, 0.118, 1)
                roundedRect(tx, tabY, tabW - 4 * sc, tabH, 5, sc)
                lg.setColor(0.306, 0.286, 0.373, 1)
                roundedRectLine(tx, tabY, tabW - 4 * sc, tabH, 5, sc, 1 * sc)
            end
            lg.setFont(Fonts.small)
            lg.setColor(0.965, 0.839, 0.741, 1)
            lg.printf("D" .. i, tx, textCY(Fonts.small, tabY, tabH), tabW - 4 * sc, 'center')
            if DeckManager._data.activeDeckIndex == i then
                lg.setColor(0.765, 0.639, 0.541, 1)
                love.graphics.circle('fill', tx + tabW - 10 * sc, tabY + 8 * sc, 5 * sc)
            end
            self._deckSlotRects[i] = {
                x = tx + self.panelOffset,
                y = tabY,
                w = tabW - 4 * sc,
                h = tabH
            }
        end

        -- ── Sort + Total row ───────────────────────────────────────────────────
        local total    = DeckManager.getTotalCount(self.selectedDeckSlot)
        local barY     = tabY + tabH + 8 * sc
        local barH     = 40 * sc
        local barX     = ox + 20 * sc
        local barW     = W - 40 * sc
        local btnW     = 90 * sc

        -- SORT toggle button
        local sortX = barX
        if self._deckSortByCost then
            lg.setColor(0.306, 0.286, 0.373, 1)
            roundedRect(sortX, barY, btnW, barH, 5, sc)
            lg.setColor(0.506, 0.384, 0.443, 1)
            roundedRectLine(sortX, barY, btnW, barH, 5, sc, 2 * sc)
            lg.setFont(Fonts.small)
            lg.setColor(0.965, 0.839, 0.741, 1)
            lg.printf("Cost", sortX, textCY(Fonts.small, barY, barH), btnW, 'center')
        else
            lg.setColor(0.059, 0.165, 0.247, 1)
            roundedRect(sortX, barY, btnW, barH, 5, sc)
            lg.setColor(0.306, 0.286, 0.373, 1)
            roundedRectLine(sortX, barY, btnW, barH, 5, sc, 2 * sc)
            lg.setFont(Fonts.small)
            lg.setColor(0.765, 0.639, 0.541, 1)
            lg.printf("Default", sortX, textCY(Fonts.small, barY, barH), btnW, 'center')
        end
        self._deckSortRect = { x = sortX + self.panelOffset, y = barY, w = btnW, h = barH }

        -- Total counter (fills remaining space)
        local counterX = barX + btnW + 4 * sc
        local counterW = barW - btnW - 4 * sc
        lg.setFont(Fonts.small)
        lg.setColor(total >= 20 and {0.600, 0.459, 0.467, 1} or {0.765, 0.639, 0.541, 1})
        lg.printf(total .. " / 20", counterX, textCY(Fonts.small, barY, barH), counterW, 'center')

        -- ── Unit card grid ────────────────────────────────────────────────────
        local cols   = 4
        local cardW  = 108 * sc
        local cardH  = 138 * sc
        local gapX   = 8   * sc
        local gapY   = 10  * sc
        local totalW = cols * cardW + (cols - 1) * gapX
        local startX = ox + (W - totalW) / 2
        local startY = barY + barH + 12 * sc
        local stripH = 32 * sc

        local deck = DeckManager.getDeck(self.selectedDeckSlot)

        -- Build unit list in collection order, filtered to unlocked units
        local sortedUnits = {}
        local unlocks = _G.PlayerData and _G.PlayerData.unlocks
        for _, group in ipairs(UnitRegistry.groups) do
            for _, utype in ipairs(group.units) do
                local owned = unlocks and unlocks.cards and unlocks.cards[utype] or 0
                if _G.GodMode or not unlocks or not unlocks.cards or owned > 0 then
                    table.insert(sortedUnits, { utype = utype, count = deck.counts[utype] or 0, owned = owned })
                end
            end
        end
        if self._deckSortByCost then
            table.sort(sortedUnits, function(a, b)
                local ca = UnitRegistry.unitCosts[a.utype] or 99
                local cb = UnitRegistry.unitCosts[b.utype] or 99
                if ca ~= cb then return ca < cb end
                return a.utype < b.utype
            end)
        end

        self._deckCardRects = {}

        for i, entry in ipairs(sortedUnits) do
            local utype = entry.utype
            local count = entry.count
            local col   = (i - 1) % cols
            local row   = math.floor((i - 1) / cols)
            local cx    = startX + col * (cardW + gapX)
            local cy    = startY + row * (cardH + gapY)

            -- Card background
            lg.setColor(0.059, 0.165, 0.247, 1)
            roundedRect(cx, cy, cardW, cardH, 6, sc)
            -- Border: tan if has cards, dim if not
            if count > 0 then
                lg.setColor(0.765, 0.639, 0.541, 1)
            else
                lg.setColor(0.306, 0.286, 0.373, 1)
            end
            roundedRectLine(cx, cy, cardW, cardH, 6, sc, 2 * sc)

            -- Unit name
            lg.setFont(Fonts.small)
            lg.setColor(0.9, 0.9, 0.9, 1)
            local name = utype:sub(1,1):upper() .. utype:sub(2)
            lg.printf(name, cx, cy + 6 * sc, cardW, 'center')

            -- Cost badge (bottom-right, inside card above strip)
            local cost = UnitRegistry.unitCosts[utype] or "?"
            local costStr = tostring(cost)
            local badgeW = 20 * sc
            local badgeH = 18 * sc
            local badgeX = cx + cardW - badgeW - 5 * sc
            local badgeY = cy + cardH - stripH - badgeH - 5 * sc
            lg.setColor(0.031, 0.078, 0.118, 1)
            roundedRect(badgeX, badgeY, badgeW, badgeH, 4, sc)
            lg.setColor(0.765, 0.639, 0.541, 1)
            roundedRectLine(badgeX, badgeY, badgeW, badgeH, 4, sc, math.max(1, math.floor(1.5 * sc)))
            lg.setFont(Fonts.tiny)
            lg.setColor(0.965, 0.839, 0.741, 1)
            lg.printf(costStr, badgeX, badgeY + (badgeH - Fonts.tiny:getHeight()) / 2, badgeW, 'center')

            -- Sprite (bottom-anchored above bottom strip)
            -- Action units: use action/idle override sprite instead of default front
            local _d2 = self.dirSprites[utype]
            local _aio2 = _d2 and _d2.directional and _d2.directional.actionIdleOverride
            local img, _deckTrimBottom
            if _aio2 and (_aio2[0] or _aio2[180]) then
                local _ad2 = _aio2[0] or _aio2[180]
                img            = _ad2.frames[1]
                _deckTrimBottom = _ad2.trimBottom[1] or 0
            else
                img            = self.sprites[utype]
                _deckTrimBottom = self.spriteTrimBottoms[utype] or 0
            end
            if img then
                local iw, ih     = img:getDimensions()
                local trimBottom = _deckTrimBottom
                local sprSc      = math.max(1, math.floor(4 * sc))
                local BOTTOM_MARGIN = 3
                local sx = math.floor(cx + (cardW - iw * sprSc) / 2)
                local spriteBase = cy + cardH - stripH - BOTTOM_MARGIN * sc
                local sy = math.floor(spriteBase - (ih - trimBottom) * sprSc)
                lg.setColor(1, 1, 1, 1)
                lg.draw(img, sx, sy, 0, sprSc, sprSc)
            end

            -- Bottom strip background
            local stripY = cy + cardH - stripH
            lg.setColor(0.031, 0.078, 0.118, 1)
            love.graphics.rectangle('fill', cx + 2 * sc, stripY, cardW - 4 * sc, stripH - 2 * sc)

            -- [-] label (left 30%)
            local minusW = math.floor(cardW * 0.30)
            lg.setFont(Fonts.medium)
            if count > 0 then
                lg.setColor(0.965, 0.839, 0.741, 1)
            else
                lg.setColor(0.306, 0.286, 0.373, 1)
            end
            lg.printf("-", cx, textCY(Fonts.medium, stripY, stripH), minusW, 'center')

            -- count (center 40%)
            local centerW = math.floor(cardW * 0.40)
            local centerX = cx + minusW
            lg.setFont(Fonts.medium)
            lg.setColor(1, 1, 1, 1)
            lg.printf(tostring(count), centerX, textCY(Fonts.medium, stripY, stripH), centerW, 'center')

            -- [+] label (right 30%)
            local plusW = cardW - minusW - centerW
            local plusX = cx + minusW + centerW
            local canAdd = total < 20
            if canAdd and not _G.GodMode and entry.owned and entry.owned > 0 then
                canAdd = count < entry.owned
            end
            if canAdd then
                lg.setColor(0.965, 0.839, 0.741, 1)
            else
                lg.setColor(0.306, 0.286, 0.373, 1)
            end
            lg.printf("+", plusX, textCY(Fonts.medium, stripY, stripH), plusW, 'center')

            -- Hit rect (screen space)
            self._deckCardRects[i] = {
                utype  = utype,
                cardX  = cx + self.panelOffset,
                cardY  = cy,
                cardW  = cardW,
                cardH  = cardH,
                minusX = cx + self.panelOffset,
                minusW = minusW,
                plusX  = cx + minusW + centerW + self.panelOffset,
                plusW  = plusW,
                stripY = stripY,
                stripH = stripH,
            }
        end
    end

    function self:drawRankingPanel(ox, W, H)
        local lg = love.graphics
        lg.setFont(Fonts.medium)
        lg.setColor(0.4, 0.4, 0.45, 1)
        lg.printf("Coming Soon", ox, H * 0.42, W, 'center')
    end

    function self:drawShopPanel(ox, W, H)
        local lg = love.graphics
        lg.setFont(Fonts.medium)
        lg.setColor(0.6, 0.6, 0.6, 1)
        lg.printf("Work in progress", ox, H * 0.45, W, 'center')
    end

    function self:drawBottomBar(W, H, sc)
        local lg    = love.graphics
        local BAR_H = 100 * sc
        local barY  = H - BAR_H
        local tabW  = W / self.NUM_PANELS
        local labels = { "Collection", "Decks", "Battle", "Shop", "Ranking" }

        -- Bar background
        lg.setColor(0.031, 0.078, 0.118, 1)
        lg.rectangle('fill', 0, barY, W, BAR_H)
        -- Top border line (2px, pixel-art crisp)
        lg.setColor(0.306, 0.286, 0.373, 1)
        lg.setLineWidth(2)
        lg.line(0, barY, W, barY)

        self._tabRects = {}

        for i = 1, self.NUM_PANELS do
            local raise    = self.tabRaiseAnim[i]
            local isActive = (i == self.currentPanel)
            local tabCx    = (i - 0.5) * tabW

            -- Raised pixel-art card (flush, no gaps between tabs)
            if raise > 0.01 then
                local popUp = 28 * sc * raise
                local cardX = math.floor((i - 1) * tabW)
                local nextX = math.floor(i * tabW)
                local cardW = nextX - cardX
                local cardY = math.floor(barY - popUp)
                local cardH = math.floor(BAR_H + popUp)
                local brd   = math.max(2, math.floor(3 * sc))

                -- Fill
                lg.setColor(0.059, 0.165, 0.247, 1)
                lg.rectangle('fill', cardX, cardY, cardW, cardH)

                -- Outer border (bright, pixel-art frame)
                lg.setColor(0.125, 0.224, 0.310, 1)
                lg.setLineWidth(brd)
                lg.rectangle('line', cardX + brd/2, cardY + brd/2,
                             cardW - brd, cardH - brd)

                -- Inner top-left highlight (bevel light)
                lg.setColor(0.125, 0.224, 0.310, 0.5)
                lg.setLineWidth(math.max(1, math.floor(sc)))
                local b1 = brd + math.max(1, math.floor(sc))
                lg.line(cardX + b1, cardY + cardH - b1,
                        cardX + b1, cardY + b1,
                        cardX + cardW - b1, cardY + b1)

                -- Inner bottom-right shadow (bevel dark)
                lg.setColor(0.031, 0.078, 0.118, 1)
                lg.line(cardX + b1, cardY + cardH - b1,
                        cardX + cardW - b1, cardY + cardH - b1,
                        cardX + cardW - b1, cardY + b1)
            end

            -- Icon: integer pixel scale; 2× larger when active
            local img = self.uiIcons[i]
            if img then
                local iw        = img:getWidth()
                local basePixSc = math.max(2, math.floor(48 * sc / iw))
                local pixSc     = math.max(basePixSc, math.floor(basePixSc * (1 + math.min(raise, 0.99))))
                local ix = math.floor(tabCx - iw * pixSc / 2)
                -- Icon pops above the card when active (intentionally overflows card top)
                local iy = math.floor(barY + 6 * sc - 56 * sc * raise)
                lg.setColor(isActive and {1, 1, 1, 1} or {0.306, 0.286, 0.373, 1})
                lg.draw(img, ix, iy, 0, pixSc, pixSc)
            end

            -- Label stays at original position
            lg.setFont(Fonts.tiny)
            lg.setColor(1, 1, 1, 0.35 + 0.65 * raise)
            local labelY = barY + 62 * sc - 12 * sc * raise
            lg.printf(labels[i], tabCx - tabW / 2, labelY, tabW, 'center')

            -- Hit rect
            self._tabRects[i] = {
                x = (i - 1) * tabW,
                y = barY - 30 * sc,
                w = tabW,
                h = BAR_H + 30 * sc,
            }
        end
    end

    function self:drawDetailOverlay(W, H, sc)
        local lg    = love.graphics
        local utype = self.detailUnit
        if not utype then return end

        local img        = self.sprites[utype]
        local iw, ih     = img:getDimensions()
        local trimBottom = self.spriteTrimBottoms[utype] or 0
        local info       = UnitRegistry.getUnitDisplayInfo(utype)
        local passive    = UnitRegistry.passiveDescriptions[utype] or ""
        local sprSc      = math.max(1, math.floor(5 * sc))

        -- Panel width + text area
        local panW  = math.floor(W * 0.84)
        local textW = panW - math.floor(32 * sc)
        local brd   = math.max(1, math.floor(2 * sc))

        -- Pre-compute content height so panel fits content exactly
        local _, pLines = Fonts.tiny:getWrap(passive, textW)
        local vPad = math.floor(14 * sc)
        local contentH =
            (ih - trimBottom) * sprSc                                   +
            math.floor(7 * sc)                                          + -- sprite → name gap
            Fonts.medium:getHeight() + math.floor(5 * sc)              + -- name
            Fonts.tiny:getHeight()   + math.floor(7 * sc)              + -- stats
            math.floor(7 * sc)                                          + -- separator
            math.max(1, #pLines) * Fonts.tiny:getHeight()
                + math.floor(8 * sc)                                    + -- passive
            Fonts.small:getHeight() + math.floor(4 * sc)               + -- "Upgrades" header
            #info.upgrades * (2 * Fonts.tiny:getHeight()
                + math.floor(6 * sc))                                     -- upgrade rows

        local panH = contentH + vPad * 2
        -- Guard: never taller than 88% of screen
        panH = math.min(panH, math.floor(H * 0.88))
        local panX = math.floor((W - panW) / 2)
        local panY = math.floor((H - panH) / 2)

        -- Dim backdrop
        lg.setColor(0, 0, 0, 0.65)
        lg.rectangle('fill', 0, 0, W, H)

        -- Panel fill
        lg.setColor(0.059, 0.165, 0.247, 1)
        roundedRect(panX, panY, panW, panH, 5, sc)

        -- Outer border
        lg.setColor(0.125, 0.224, 0.310, 1)
        roundedRectLine(panX, panY, panW, panH, 5, sc, brd)

        -- Bevel: top-left highlight
        local hl = brd + math.max(1, math.floor(sc))
        lg.setColor(0.125, 0.224, 0.310, 0.5)
        lg.setLineWidth(math.max(1, math.floor(sc)))
        lg.line(panX + hl, panY + panH - hl,
                panX + hl, panY + hl,
                panX + panW - hl, panY + hl)
        -- Bevel: bottom-right shadow
        lg.setColor(0.031, 0.078, 0.118, 0.8)
        lg.line(panX + hl, panY + panH - hl,
                panX + panW - hl, panY + panH - hl,
                panX + panW - hl, panY + hl)

        -- Sprite (centred horizontally, top of content area)
        local imgX = math.floor(panX + (panW - iw * sprSc) / 2)
        local imgY = math.floor(panY + vPad)
        lg.setColor(1, 1, 1, 1)
        lg.draw(img, imgX, imgY, 0, sprSc, sprSc)

        local textX = panX + math.floor(16 * sc)
        local curY  = imgY + (ih - trimBottom) * sprSc + math.floor(7 * sc)

        -- Unit name
        local name = utype:sub(1,1):upper() .. utype:sub(2)
        lg.setFont(Fonts.medium)
        lg.setColor(1, 1, 1, 1)
        lg.printf(name, panX, curY, panW, 'center')
        curY = curY + Fonts.medium:getHeight() + math.floor(5 * sc)

        -- Stats row
        local info2 = info  -- already fetched above
        lg.setFont(Fonts.tiny)
        lg.setColor(0.965, 0.839, 0.741, 1)
        local s = string.format("HP %d  ATK %d  SPD %.1f  RNG %d  [%s]",
            info2.hp, info2.atk, info2.spd, info2.rng, info2.unitClass)
        lg.printf(s, textX, curY, textW, 'center')
        curY = curY + Fonts.tiny:getHeight() + math.floor(7 * sc)

        -- Separator
        lg.setColor(0.306, 0.286, 0.373, 1)
        lg.setLineWidth(math.max(1, math.floor(sc)))
        lg.line(textX, curY, panX + panW - math.floor(16 * sc), curY)
        curY = curY + math.floor(7 * sc)

        -- Passive description
        lg.setFont(Fonts.tiny)
        lg.setColor(0.765, 0.639, 0.541, 1)
        lg.printf(passive, textX, curY, textW, 'left')
        curY = curY + math.max(1, #pLines) * Fonts.tiny:getHeight() + math.floor(8 * sc)

        -- Upgrades header
        lg.setFont(Fonts.small)
        lg.setColor(0.965, 0.839, 0.741, 1)
        lg.printf("Upgrades", textX, curY, textW, 'left')
        curY = curY + Fonts.small:getHeight() + math.floor(4 * sc)

        -- Upgrade rows
        lg.setFont(Fonts.tiny)
        for i, upg in ipairs(info2.upgrades) do
            lg.setColor(0.965, 0.839, 0.741, 1)
            lg.printf(i .. ". " .. upg.name, textX + math.floor(6 * sc), curY, textW, 'left')
            curY = curY + Fonts.tiny:getHeight() + math.floor(2 * sc)
            lg.setColor(0.765, 0.639, 0.541, 1)
            lg.printf("   " .. upg.description, textX + math.floor(6 * sc), curY, textW, 'left')
            curY = curY + Fonts.tiny:getHeight() + math.floor(4 * sc)
        end
    end

    -- ── draw ────────────────────────────────────────────────────────────────

    function self:draw()
        local lg   = love.graphics
        local W    = Constants.GAME_WIDTH
        local H    = Constants.GAME_HEIGHT
        local sc   = Constants.SCALE

        lg.clear(Constants.COLORS.BACKGROUND)

        -- Clip panel strip above the bottom bar
        local barH = 90 * sc
        lg.setScissor(0, 0, W, H - barH)
        lg.push()
        lg.translate(math.floor(self.panelOffset), 0)

        self:drawCollectionPanel(0,       W, H - barH, sc)
        self:drawDecksPanel(     W,       W, H - barH, sc)
        self:drawPlayPanel(      2 * W,   W, H - barH, sc)
        self:drawShopPanel(      3 * W,   W, H - barH)
        self:drawRankingPanel(   4 * W,   W, H - barH)

        lg.pop()
        lg.setScissor()

        -- Scrolling ticker stripe (screen space, fixed above panel content)
        self:drawTickerStripe(W, sc)

        -- Top-left header: player name + trophies + XP bar + settings button
        if _G.PlayerData then
            local vPad   = math.floor(5 * sc)
            local edgeX  = math.floor(8 * sc)

            -- Strip height based on Fonts.small
            lg.setFont(Fonts.small)
            local numLineH = Fonts.small:getHeight()
            local stripH   = numLineH + vPad * 2
            local stripY   = math.floor(8 * sc)
            local xCur     = edgeX

            -- Player name
            lg.setFont(Fonts.medium)
            local nameStr = _G.PlayerData.username or ""
            local nameW   = Fonts.medium:getWidth(nameStr)
            local nameY   = textCY(Fonts.medium, stripY, stripH)
            lg.setColor(1, 1, 1, 1)
            lg.print(nameStr, xCur, nameY)

            -- Trophies below name, slightly indented
            lg.setFont(Fonts.tiny)
            lg.setColor(0.9, 0.85, 0.3, 0.9)
            lg.print(tostring(_G.PlayerData.trophies or 0) .. " trophies",
                     xCur + math.floor(4 * sc),
                     stripY + stripH + math.floor(1 * sc))

            xCur = xCur + nameW + math.floor(12 * sc)

            -- Settings "+" button (top-right corner)
            local sbW = stripH
            local sbX = W - sbW - edgeX
            local sbY = stripY
            local sbR = math.max(1, math.floor(3 * sc))
            lg.setColor(0.059, 0.165, 0.247, 1)
            lg.rectangle('fill', sbX, sbY, sbW, sbW, sbR, sbR)
            lg.setColor(0.125, 0.224, 0.310, 1)
            lg.setLineWidth(math.max(1, math.floor(sc)))
            lg.rectangle('line', sbX, sbY, sbW, sbW, sbR, sbR)
            lg.setFont(Fonts.small)
            lg.setColor(0.965, 0.839, 0.741, 1)
            lg.printf("+", sbX, textCY(Fonts.small, sbY, sbW), sbW, 'center')
            self._settingsBtnRect = { x = sbX, y = sbY, w = sbW, h = sbW }

            -- XP bar: same height as settings button, fills gap between name and settings button
            local barGap = math.floor(8 * sc)
            local barX   = xCur
            local barW   = sbX - barGap - barX
            if barW > 0 then
                local plevel = _G.PlayerData.level or 1
                local pxp    = _G.PlayerData.xp    or 0
                local xpNeed = 30 + math.floor((plevel - 1) / 10) * 5
                local barR   = math.max(1, math.floor(3 * sc))
                local fillW  = math.floor(barW * math.min(pxp / xpNeed, 1))
                local isPending = (self._rewardState == "pending")

                -- Shake offset: initial burst decays, then a gentle idle pulse
                local shakeX = 0
                if isPending then
                    local t = self._rewardShakeTime or 0
                    -- Burst: amplitude 4px decaying to 0 over 0.6s
                    local burst = 4 * sc * math.exp(-t * 6) * math.sin(t * 60)
                    -- Idle pulse: amplitude 1.5px, period ~1.4s, starts after burst fades
                    local idle  = 1.5 * sc * math.sin(t * 4.5) * math.min(t / 0.6, 1)
                    shakeX = math.floor(burst + idle)
                end

                -- Background (same dark as settings button bg)
                lg.setColor(0.059, 0.165, 0.247, 1)
                lg.rectangle('fill', barX + shakeX, stripY, barW, stripH, barR, barR)
                -- Fill: tan (#c3a38a) when pending reward, else normal purple
                if isPending then
                    lg.setColor(0.765, 0.639, 0.541, 1)
                    lg.rectangle('fill', barX + shakeX, stripY, barW, stripH, barR, barR)
                elseif fillW > 0 then
                    lg.setColor(0.306, 0.286, 0.373, 1)
                    lg.rectangle('fill', barX + shakeX, stripY, fillW, stripH, barR, barR)
                end
                -- Outline
                lg.setColor(0.125, 0.224, 0.310, 1)
                lg.setLineWidth(math.max(1, math.floor(sc)))
                lg.rectangle('line', barX + shakeX, stripY, barW, stripH, barR, barR)

                -- Label: reward text when pending, else "Level X"
                lg.setFont(Fonts.small)
                if isPending then
                    lg.setColor(0.059, 0.059, 0.078, 1)
                    local rewardLabel = (self._rewardType == "new_unit") and "New unlock!" or "New card!"
                    lg.printf(rewardLabel, barX + shakeX, textCY(Fonts.small, stripY, stripH), barW, 'center')
                else
                    lg.setColor(0.965, 0.839, 0.741, 1)
                    lg.printf("Level " .. plevel, barX, textCY(Fonts.small, stripY, stripH), barW, 'center')
                end

                self._xpBarRect = { x = barX, y = stripY, w = barW, h = stripH }
            end
        end

        -- Bottom tab bar (screen space)
        self:drawBottomBar(W, H, sc)

        -- (detail view is now drawn inline within drawCollectionPanel)

        -- Settings overlay
        if self.showSettings then
            -- Dim backdrop
            lg.setColor(0, 0, 0, 0.65)
            lg.rectangle('fill', 0, 0, W, H)

            -- Panel geometry
            local panW  = math.floor(240 * sc)
            local panH  = math.floor(self._showGodModeRow and 280 or 240) * sc
            local panX  = math.floor((W - panW) / 2)
            local panY  = math.floor((H - panH) / 2)
            local brd   = math.max(1, math.floor(2 * sc))

            -- Panel fill
            lg.setColor(0.059, 0.165, 0.247, 1)
            roundedRect(panX, panY, panW, panH, 5, sc)

            -- Outer border
            lg.setColor(0.125, 0.224, 0.310, 1)
            roundedRectLine(panX, panY, panW, panH, 5, sc, brd)

            -- Bevel: top-left highlight
            local hl = brd + math.max(1, math.floor(sc))
            lg.setColor(0.125, 0.224, 0.310, 0.5)
            lg.setLineWidth(math.max(1, math.floor(sc)))
            lg.line(panX + hl, panY + panH - hl,
                    panX + hl, panY + hl,
                    panX + panW - hl, panY + hl)

            -- Bevel: bottom-right shadow
            lg.setColor(0.031, 0.078, 0.118, 0.8)
            lg.line(panX + hl, panY + panH - hl,
                    panX + panW - hl, panY + panH - hl,
                    panX + panW - hl, panY + hl)

            -- Vertical offset so the 196-unit content block is centred in panH
            local contentH = math.floor(196 * sc)
            local offY     = math.floor((panH - contentH) / 2)

            -- Title (medium font, same weight as panel headers elsewhere)
            local hdrH = math.floor(40 * sc)
            lg.setFont(Fonts.medium)
            lg.setColor(0.965, 0.839, 0.741, 1)
            lg.printf("SETTINGS", panX, textCY(Fonts.medium, panY + offY, hdrH), panW, 'center')
            self._settingsTitleRect = { x = panX, y = panY + offY, w = panW, h = hdrH }

            -- Divider under title
            lg.setColor(0.306, 0.286, 0.373, 1)
            lg.setLineWidth(math.max(1, math.floor(sc)))
            lg.line(panX + math.floor(12 * sc), panY + offY + hdrH,
                    panX + panW - math.floor(12 * sc), panY + offY + hdrH)

            -- Toggle row helper: label left, game-style button right
            local function drawToggleRow(label, enabled, rowY)
                local rowH  = math.floor(38 * sc)
                local btnW  = math.floor(64 * sc)
                local btnH  = math.floor(28 * sc)
                local btnX  = panX + panW - math.floor(16 * sc) - btnW
                local btnY  = rowY + math.floor((rowH - btnH) / 2)
                -- Label
                lg.setFont(Fonts.small)
                lg.setColor(0.765, 0.639, 0.541, 1)
                lg.print(label, panX + math.floor(16 * sc), textCY(Fonts.small, rowY, rowH))
                -- Button fill
                if enabled then
                    lg.setColor(0.059, 0.165, 0.247, 1)
                else
                    lg.setColor(0.031, 0.078, 0.118, 1)
                end
                roundedRect(btnX, btnY, btnW, btnH, 4, sc)
                -- Button border
                if enabled then
                    lg.setColor(0.125, 0.224, 0.310, 1)
                else
                    lg.setColor(0.306, 0.286, 0.373, 1)
                end
                roundedRectLine(btnX, btnY, btnW, btnH, 4, sc, math.max(1, math.floor(sc)))
                -- Button text
                lg.setFont(Fonts.small)
                if enabled then
                    lg.setColor(0.965, 0.839, 0.741, 1)
                else
                    lg.setColor(0.306, 0.286, 0.373, 1)
                end
                lg.printf(enabled and "ON" or "OFF", btnX, textCY(Fonts.small, btnY, btnH), btnW, 'center')
                return { x = btnX, y = btnY, w = btnW, h = btnH }
            end

            local row1Y = panY + offY + math.floor(46 * sc)
            local row2Y = panY + offY + math.floor(90 * sc)
            self._settingsMusicRect = drawToggleRow("Music", AudioManager.musicEnabled, row1Y)
            self._settingsSFXRect   = drawToggleRow("SFX",   AudioManager.sfxEnabled,   row2Y)

            -- Hidden God Mode row (revealed by tapping SETTINGS title 5 times)
            self._settingsGodModeRect = nil
            if self._showGodModeRow then
                local row3Y = panY + offY + math.floor(134 * sc)
                self._settingsGodModeRect = drawToggleRow("God Mode", _G.GodMode == true, row3Y)
            end

            -- Divider above logout
            local divY = panY + offY + math.floor(self._showGodModeRow and 182 or 138) * sc
            lg.setColor(0.306, 0.286, 0.373, 1)
            lg.setLineWidth(math.max(1, math.floor(sc)))
            lg.line(panX + math.floor(12 * sc), divY,
                    panX + panW - math.floor(12 * sc), divY)

            -- Logout button (full-width minus margins)
            local lbW = panW - math.floor(32 * sc)
            local lbH = math.floor(34 * sc)
            local lbX = panX + math.floor(16 * sc)
            local lbY = divY + math.floor(8 * sc)
            lg.setColor(0.031, 0.078, 0.118, 1)
            roundedRect(lbX, lbY, lbW, lbH, 4, sc)
            lg.setColor(0.600, 0.459, 0.467, 1)
            roundedRectLine(lbX, lbY, lbW, lbH, 4, sc, math.max(1, math.floor(sc)))
            lg.setFont(Fonts.small)
            lg.setColor(0.765, 0.639, 0.541, 1)
            lg.printf("Logout", lbX, textCY(Fonts.small, lbY, lbH), lbW, 'center')
            self._settingsLogoutRect = { x = lbX, y = lbY, w = lbW, h = lbH }
        end

        -- Reward reveal overlay
        if self._rewardState == "revealing" and self._rewardUnit then
            local t = self._rewardAnimTimer
            -- Dim backdrop
            local backdropAlpha = math.min(t / 0.2, 0.7)
            lg.setColor(0, 0, 0, backdropAlpha)
            lg.rectangle('fill', 0, 0, W, H)

            -- Card geometry
            local cardW = math.floor(160 * sc)
            local cardH = math.floor(220 * sc)
            local cardX = math.floor((W - cardW) / 2)
            local cardY = math.floor((H - cardH) / 2 - 20 * sc)

            -- Animation phases
            local scale, rotation = 0, 0
            if t < 0.3 then
                -- Phase 1: scale 0→1.1, rotation -15°→0°
                local p = t / 0.3
                scale    = 1.1 * p
                rotation = math.rad(-15) * (1 - p)
            elseif t < 0.5 then
                -- Phase 2: scale 1.1→1.0 (bounce settle)
                local p = (t - 0.3) / 0.2
                scale    = 1.1 - 0.1 * p
                rotation = 0
            else
                -- Phase 3: hold steady
                scale    = 1.0
                rotation = 0
            end

            -- Determine rarity for border color
            local rewardUnit = self._rewardUnit
            local rarityColor = {0.765, 0.639, 0.541, 1} -- common/starter = tan
            for _, tier in ipairs(UnitRegistry.rarityTiers) do
                for _, u in ipairs(tier.units) do
                    if u == rewardUnit then
                        if tier.tier == "rare" then
                            rarityColor = {0.267, 0.533, 0.8, 1}   -- #4488cc
                        elseif tier.tier == "epic" then
                            rarityColor = {0.6, 0.267, 0.8, 1}     -- #9944cc
                        end
                    end
                end
            end

            -- Draw card with transform
            lg.push()
            lg.translate(cardX + cardW / 2, cardY + cardH / 2)
            lg.rotate(rotation)
            lg.scale(scale, scale)
            lg.translate(-cardW / 2, -cardH / 2)

            -- Golden glow for new_unit rewards
            if self._rewardType == "new_unit" and t > 0.3 then
                local glowAlpha = math.min((t - 0.3) / 0.3, 0.4)
                lg.setColor(1, 0.85, 0.3, glowAlpha)
                local gm = math.floor(8 * sc)
                roundedRect(-gm, -gm, cardW + gm * 2, cardH + gm * 2, 10, sc)
            end

            -- Card background
            lg.setColor(0.059, 0.165, 0.247, 1)
            roundedRect(0, 0, cardW, cardH, 8, sc)

            -- Card border (rarity color)
            lg.setColor(rarityColor)
            roundedRectLine(0, 0, cardW, cardH, 8, sc, math.max(2, math.floor(3 * sc)))

            -- Layout constants
            local topPad    = math.floor(cardH * 0.06)
            local nameH     = Fonts.medium:getHeight()
            local badgeH    = Fonts.small:getHeight()
            local bottomPad = math.floor(cardH * 0.05)
            local nameY     = cardH - bottomPad - badgeH - math.floor(6 * sc) - nameH
            local badgeY    = cardH - bottomPad - badgeH

            -- Unit sprite: fill available space between top pad and name, vertically centered
            local img = self.sprites[rewardUnit]
            if img then
                local iw, ih    = img:getDimensions()
                local trimBottom = self.spriteTrimBottoms[rewardUnit] or 0
                local sprSc     = math.max(1, math.floor(6 * sc))
                local sprW      = iw * sprSc
                local sprH      = (ih - trimBottom) * sprSc
                local zoneH     = nameY - topPad - math.floor(8 * sc)
                -- Scale down if sprite is taller than the zone
                if sprH > zoneH then
                    local fit = zoneH / sprH
                    sprSc  = math.max(1, math.floor(sprSc * fit))
                    sprW   = iw * sprSc
                    sprH   = (ih - trimBottom) * sprSc
                end
                local sx = math.floor((cardW - sprW) / 2)
                local sy = math.floor(topPad + (zoneH - sprH) / 2)
                lg.setColor(1, 1, 1, 1)
                lg.draw(img, sx, sy, 0, sprSc, sprSc)
            end

            -- Unit name
            lg.setFont(Fonts.medium)
            lg.setColor(1, 1, 1, 1)
            local unitName = rewardUnit:sub(1,1):upper() .. rewardUnit:sub(2)
            lg.printf(unitName, 0, nameY, cardW, 'center')

            -- Badge: "NEW!" or "+1"
            local badgeText = (self._rewardType == "new_unit") and "NEW!" or "+1"
            lg.setFont(Fonts.small)
            if self._rewardType == "new_unit" then
                lg.setColor(1, 0.85, 0.3, 1)
            else
                lg.setColor(0.6, 1, 0.6, 1)
            end
            lg.printf(badgeText, 0, badgeY, cardW, 'center')

            lg.pop()

            -- "Tap to continue" after 1.5s
            if t > 1.5 then
                lg.setFont(Fonts.tiny)
                lg.setColor(0.7, 0.7, 0.7, 0.5 + 0.5 * math.sin(t * 3))
                lg.printf("Tap to continue", 0, cardY + cardH + math.floor(20 * sc), W, 'center')
            end
        end
    end

    -- ── input ───────────────────────────────────────────────────────────────

    function self:handlePress(x, y)
        self.isPressed  = true
        self.pressX     = x
        self.pressY     = y
        self.hasMoved   = false
        self.isDragging = false

        -- Overlays absorb all presses
        if self.showDetail or self.showSettings or self._rewardState == "revealing" then return end

        -- Collection detail: start sprite rotation drag
        if self.currentPanel == 1 and self.collectionView == "detail" then
            local r = self._detailSpriteRect
            if r and x >= r.x and x <= r.x + r.w and y >= r.y and y <= r.y + r.h then
                self._detailDragX = x
            end
        end

        -- Deck detail: start sprite rotation drag
        if self.currentPanel == 2 and self.deckView == "detail" then
            local r = self._detailSpriteRect
            if r and x >= r.x and x <= r.x + r.w and y >= r.y and y <= r.y + r.h then
                self._detailDragX = x
            end
        end

        -- Spring press: activate squish on button contact
        if self.currentPanel == 3 then
            local btn = self._playBtnRect
            if btn and x >= btn.x and x <= btn.x + btn.w and
                       y >= btn.y and y <= btn.y + btn.h then
                self._playSpring.pressed = true
            end
            local sbtn = self._sandboxBtnRect
            if sbtn and x >= sbtn.x and x <= sbtn.x + sbtn.w and
                        y >= sbtn.y and y <= sbtn.y + sbtn.h then
                self._sbtnSpring.pressed = true
            end
        end
    end

    function self:handleMove(x, y)
        if not self.isPressed then return end
        if self.showDetail or self.showSettings or self._rewardState == "revealing" then return end

        -- Collection detail: sprite rotation drag
        if self._detailDragX ~= nil then
            local STEP_PX = math.max(1, math.floor(60 * Constants.SCALE))
            local delta = x - self._detailDragX
            if math.abs(delta) >= STEP_PX then
                local dir = delta < 0 and 1 or -1  -- swipe left = rotate right (next angle)
                self._detailRotAngle = ((self._detailRotAngle + dir - 1) % 8) + 1
                self._detailDragX = x  -- reset anchor to current position so every step costs STEP_PX
            end
            return
        end

        local dx = x - self.pressX
        local dy = y - self.pressY

        if not self.isDragging then
            if math.abs(dx) > self.SWIPE_THRESH and math.abs(dx) > math.abs(dy) then
                self.isDragging = true
                self.hasMoved   = true
            end
        end

        if self.isDragging then
            local W    = Constants.GAME_WIDTH
            local base = -(self.currentPanel - 1) * W
            local raw  = base + dx
            -- Rubber-band at edges
            local minOff = -(self.NUM_PANELS - 1) * W
            local maxOff = 0
            if raw > maxOff then
                raw = maxOff + (raw - maxOff) * 0.25
            elseif raw < minOff then
                raw = minOff + (raw - minOff) * 0.25
            end
            self.panelOffset = raw
        end
    end

    function self:handleRelease(x, y)
        self.isPressed = false
        self._playSpring.pressed = false
        self._sbtnSpring.pressed = false
        self._detailDragX = nil
        local dx = x - self.pressX

        -- Reward reveal overlay: tap to dismiss after 1.5s
        if self._rewardState == "revealing" then
            if self._rewardAnimTimer > 1.5 then
                AudioManager.playTap()
                -- Send claim_reward to server
                if _G.GameSocket and _G.GameSocket:isConnected() then
                    _G.GameSocket:send("claim_reward", {})
                end
                -- Remove first pending reward locally
                local unlocks = _G.PlayerData and _G.PlayerData.unlocks
                if unlocks and unlocks.pending_rewards then
                    table.remove(unlocks.pending_rewards, 1)
                end
                -- Check if more pending
                if unlocks and unlocks.pending_rewards and #unlocks.pending_rewards > 0 then
                    local reward = unlocks.pending_rewards[1]
                    self._rewardState     = "pending"
                    self._rewardUnit      = reward.unit
                    self._rewardType      = reward.type
                    self._rewardLevel     = reward.level
                    self._rewardAnimTimer = 0
                else
                    self._rewardState     = "idle"
                    self._rewardUnit      = nil
                    self._rewardType      = nil
                    self._rewardLevel     = nil
                    self._rewardAnimTimer = 0
                end
            end
            return
        end

        -- Settings overlay
        if self.showSettings then
            -- Hidden title tap counter (5 taps reveals God Mode row)
            if self._settingsTitleRect then
                local r = self._settingsTitleRect
                if x >= r.x and x <= r.x + r.w and y >= r.y and y <= r.y + r.h then
                    local now = love.timer.getTime()
                    if now - (self._settingsTitleLastTap or 0) < 1.5 then
                        self._settingsTitleTaps = (self._settingsTitleTaps or 0) + 1
                    else
                        self._settingsTitleTaps = 1
                    end
                    self._settingsTitleLastTap = now
                    if self._settingsTitleTaps >= 3 then
                        self._showGodModeRow = true
                        self._settingsTitleTaps = 0
                    end
                    return
                end
            end
            -- God Mode toggle
            if self._settingsGodModeRect then
                local r = self._settingsGodModeRect
                if x >= r.x and x <= r.x + r.w and y >= r.y and y <= r.y + r.h then
                    _G.GodMode = not _G.GodMode
                    AudioManager.playTap()
                    return
                end
            end
            -- Music toggle
            if self._settingsMusicRect then
                local r = self._settingsMusicRect
                if x >= r.x and x <= r.x + r.w and y >= r.y and y <= r.y + r.h then
                    AudioManager.setMusic(not AudioManager.musicEnabled)
                    return
                end
            end
            -- SFX toggle
            if self._settingsSFXRect then
                local r = self._settingsSFXRect
                if x >= r.x and x <= r.x + r.w and y >= r.y and y <= r.y + r.h then
                    AudioManager.setSFX(not AudioManager.sfxEnabled)
                    AudioManager.playTap()
                    return
                end
            end
            -- Logout button inside overlay
            if self._settingsLogoutRect then
                local r = self._settingsLogoutRect
                if x >= r.x and x <= r.x + r.w and y >= r.y and y <= r.y + r.h then
                    love.filesystem.remove("session.dat")
                    if _G.GameSocket then
                        _G.GameSocket:disconnect()
                        _G.GameSocket = nil
                    end
                    _G.PlayerData = nil
                    local ScreenManager = require('lib.screen_manager')
                    ScreenManager.switch('login')
                    return
                end
            end
            -- Tap anywhere else closes overlay
            self.showSettings = false
            return
        end

        -- Settings "+" button
        if self._settingsBtnRect then
            local r = self._settingsBtnRect
            if x >= r.x and x <= r.x + r.w and y >= r.y and y <= r.y + r.h then
                self.showSettings = true
                return
            end
        end

        -- XP bar tap: start reveal when pending
        if self._rewardState == "pending" and self._xpBarRect then
            local r = self._xpBarRect
            if x >= r.x and x <= r.x + r.w and y >= r.y and y <= r.y + r.h then
                AudioManager.playTap()
                self._rewardState     = "revealing"
                self._rewardAnimTimer = 0
                return
            end
        end

        -- Swipe committed
        if self.isDragging then
            local W = Constants.GAME_WIDTH
            if dx < -self.SNAP_THRESH and self.currentPanel < self.NUM_PANELS then
                self.currentPanel = self.currentPanel + 1
            elseif dx > self.SNAP_THRESH and self.currentPanel > 1 then
                self.currentPanel = self.currentPanel - 1
            end
            self.targetOffset = -(self.currentPanel - 1) * W
            self.isDragging   = false
            -- Leaving Collection panel: reset sub-view to grid
            if self.currentPanel ~= 1 then
                self.collectionView = "grid"
                self._detailRotAngle = 1
                self._detailDragX = nil
            end
            -- Leaving Decks panel: reset deck detail sub-view
            if self.currentPanel ~= 2 then
                self.deckView = "grid"
                self.deckDetailUnit = nil
            end
            return
        end

        -- Tap: bottom tab icons
        for i, rect in ipairs(self._tabRects) do
            if x >= rect.x and x <= rect.x + rect.w and y >= rect.y and y <= rect.y + rect.h then
                AudioManager.playTap()
                if i == 1 and self.currentPanel == 1 then
                    -- Re-tap Collection tab: return to grid view
                    self.collectionView = "grid"
                    self.detailUnit = nil
                    self._detailRotAngle = 1
                    self._detailDragX = nil
                elseif i == 2 and self.currentPanel == 2 then
                    -- Re-tap Decks tab: return to grid view
                    self.deckView = "grid"
                    self.deckDetailUnit = nil
                    self._detailRotAngle = 1
                    self._detailDragX = nil
                elseif i ~= self.currentPanel then
                    self.currentPanel = i
                    self.targetOffset = -(i - 1) * Constants.GAME_WIDTH
                    -- Leaving Collection: reset its sub-view
                    if i ~= 1 then
                        self.collectionView = "grid"
                        self._detailRotAngle = 1
                        self._detailDragX = nil
                    end
                    -- Leaving Decks: reset deck detail sub-view
                    if i ~= 2 then
                        self.deckView = "grid"
                        self.deckDetailUnit = nil
                    end
                end
                return
            end
        end

        -- Collection detail view: back button tap (swallow all other taps in detail view)
        if self.currentPanel == 1 and self.collectionView == "detail" then
            local b = self._backButtonRect
            if b and x >= b.x and x <= b.x + b.w and y >= b.y and y <= b.y + b.h then
                self.collectionView = "grid"
                self.detailUnit = nil
                self._detailRotAngle = 1
                self._detailDragX = nil
            end
            return
        end

        -- Deck detail view: back button tap (swallow all other taps in detail view)
        if self.currentPanel == 2 and self.deckView == "detail" then
            local b = self._backButtonRect
            if b and x >= b.x and x <= b.x + b.w and y >= b.y and y <= b.y + b.h then
                self.deckView = "grid"
                self.deckDetailUnit = nil
                self._detailRotAngle = 1
                self._detailDragX = nil
            end
            return
        end

        -- Tap: play-panel preview units → trigger attack animation
        if self.currentPanel == 3 then
            for _, rect in ipairs(self._previewUnitRects) do
                if x >= rect.x and x <= rect.x + rect.w and
                   y >= rect.y and y <= rect.y + rect.h then
                    local atk = self.attackAnim[rect.utype]
                    atk.active   = true
                    atk.progress = 0
                    return
                end
            end
        end

        -- Tap: collection cards
        if self.currentPanel == 1 then
            for _, card in ipairs(self._collectionCards) do
                if x >= card.x and x <= card.x + card.w and
                   y >= card.y and y <= card.y + card.h then
                    self.detailUnit = card.utype
                    self.collectionView = "detail"
                    return
                end
            end
        end

        -- Tap: deck builder
        if self.currentPanel == 2 then
            -- Deck slot tabs
            for i, rect in ipairs(self._deckSlotRects) do
                if x >= rect.x and x <= rect.x + rect.w and
                   y >= rect.y and y <= rect.y + rect.h then
                    AudioManager.playTap()
                    self.selectedDeckSlot = i
                    DeckManager.setActive(i)
                    self:buildPreviewLayout()
                    return
                end
            end
            -- Sort toggle button
            local sr = self._deckSortRect
            if sr and x >= sr.x and x <= sr.x + sr.w and
                      y >= sr.y and y <= sr.y + sr.h then
                AudioManager.playTap()
                self._deckSortByCost = not self._deckSortByCost
                return
            end
            -- Card minus/plus strips and card body taps
            for _, cr in ipairs(self._deckCardRects) do
                if y >= cr.stripY and y <= cr.stripY + cr.stripH then
                    -- Tap on bottom strip: +/- controls
                    if x >= cr.minusX and x <= cr.minusX + cr.minusW then
                        AudioManager.playTap()
                        DeckManager.adjustCount(self.selectedDeckSlot, cr.utype, -1)
                        if self.selectedDeckSlot == DeckManager._data.activeDeckIndex then
                            self:buildPreviewLayout()
                        end
                        return
                    elseif x >= cr.plusX and x <= cr.plusX + cr.plusW then
                        AudioManager.playTap()
                        DeckManager.adjustCount(self.selectedDeckSlot, cr.utype, 1)
                        if self.selectedDeckSlot == DeckManager._data.activeDeckIndex then
                            self:buildPreviewLayout()
                        end
                        return
                    end
                elseif x >= cr.cardX and x <= cr.cardX + cr.cardW and
                       y >= cr.cardY and y <= cr.cardY + cr.cardH then
                    -- Tap on card body (above strip): open detail view
                    AudioManager.playTap()
                    self.deckDetailUnit = cr.utype
                    self.deckView = "detail"
                    self._detailRotAngle = 1
                    return
                end
            end
        end

        -- Tap: shop buttons
        if self.currentPanel == 4 then
            -- Gem purchase buttons (placeholder)
            for _, btn in ipairs(self._shopGemBtns) do
                if x >= btn.x and x <= btn.x + btn.w and
                   y >= btn.y and y <= btn.y + btn.h then
                    if _G.GameSocket then
                        _G.GameSocket:send("gem_purchase", {package = btn.key})
                    end
                    self.shopNotice = "Purchase simulated! +" .. btn.gems .. " gems added."
                    self.shopNoticeTimer = 3.0
                    return
                end
            end
            -- Gold purchase buttons
            for _, btn in ipairs(self._shopGoldBtns) do
                if x >= btn.x and x <= btn.x + btn.w and
                   y >= btn.y and y <= btn.y + btn.h then
                    if not btn.canAfford then
                        self.shopNotice = "Not enough gems!"
                        self.shopNoticeTimer = 2.5
                        return
                    end
                    if _G.GameSocket then
                        _G.GameSocket:send("shop_purchase", {item = btn.key})
                    end
                    return
                end
            end
        end

        -- Tap: Play Online button
        if self.currentPanel == 3 then
            local btn = self._playBtnRect
            if btn and x >= btn.x and x <= btn.x + btn.w and
                       y >= btn.y and y <= btn.y + btn.h then
                AudioManager.playTap()
                if _G.GameSocket and _G.GameSocket:isConnected() then
                    self:removeSocketHandlers()
                    local ScreenManager = require('lib.screen_manager')
                    ScreenManager.switch('lobby', _G.GameSocket)
                elseif _G.GameSocket then
                    -- Socket exists but dead — reconnect first
                    self:startReconnect()
                else
                    -- Not logged in, go to login screen
                    local ScreenManager = require('lib.screen_manager')
                    ScreenManager.switch('login')
                end
                return
            end
            local sbtn = self._sandboxBtnRect
            if sbtn and x >= sbtn.x and x <= sbtn.x + sbtn.w and
                        y >= sbtn.y and y <= sbtn.y + sbtn.h then
                AudioManager.playTap()
                local ScreenManager = require('lib.screen_manager')
                ScreenManager.switch('game', false, 1, false, true)
                return
            end
        end
    end

    function self:mousepressed(x, y, button)
        if button == 1 then self:handlePress(x, y) end
    end
    function self:mousemoved(x, y)
        self:handleMove(x, y)
    end
    function self:mousereleased(x, y, button)
        if button == 1 then self:handleRelease(x, y) end
    end

    function self:keypressed(key)
        if key == "escape" then
            if self.showDetail then
                self.showDetail = false
                self.detailUnit = nil
            end
            return
        end
    end

    return self
end

return MenuScreen
