-- AutoChest – Menu Screen (Solar2D composer scene)
-- TODO-RENDER: all draw functions are stubbed. Logic, sockets, and input are intact.
-- Follow lobby.lua pattern: S = local state, onUpdate = enterFrame listener.

local composer      = require("composer")
local Constants     = require("src.constants")
local BaseUnit      = require("src.base_unit")
local UnitRegistry  = require("src.unit_registry")
local DeckManager   = require("src.deck_manager")
local SocketManager = require("src.socket_manager")
local json          = require("lib.json")

local S = {}
local scene = composer.newScene()

local function getTime() return system.getTimer() / 1000 end

-- ── Forward declarations ──────────────────────────────────────────────────────

local initState, registerSocketHandlers, removeSocketHandlers, startReconnect
local buildPreviewLayout, getPreviewFrame
local saveChestTimer, loadChestTimer, saveTradeTimer, loadTradeTimer
local generateTradeSlots, pickWeightedCard, loadChestSprites
local startExitAnim, tryJoinPrivateRoom
local handlePress, handleMove, handleRelease

-- ── Weighted card pool ────────────────────────────────────────────────────────

local RARITY_WEIGHTS = {
    owned  = { common = 8, rare = 4, epic = 2 },
    locked = { common = 3, rare = 1, epic = 0 },
}

local function buildCardPool()
    local cards  = (_G.PlayerData and _G.PlayerData.unlocks and _G.PlayerData.unlocks.cards) or {}
    local rarity = UnitRegistry.rarity or {}
    local all    = UnitRegistry.getAllUnitTypes()
    local pool   = {}
    for _, unitType in ipairs(all) do
        local owned = cards[unitType] or 0
        local r     = rarity[unitType] or "common"
        local w
        if owned >= 4 then
            w = 0
        elseif owned > 0 then
            w = (RARITY_WEIGHTS.owned[r]  or 3)
        else
            w = (RARITY_WEIGHTS.locked[r] or 0)
        end
        if w > 0 then pool[#pool + 1] = { unit = unitType, weight = w } end
    end
    return pool
end

local function weightedPick(pool)
    local total = 0
    for _, e in ipairs(pool) do total = total + e.weight end
    if total <= 0 then return nil end
    local r   = math.random() * total
    local acc = 0
    for idx, e in ipairs(pool) do
        acc = acc + e.weight
        if r <= acc then table.remove(pool, idx); return e.unit end
    end
    local last = pool[#pool]
    if last then table.remove(pool, #pool); return last.unit end
end

-- ── Initialisation ────────────────────────────────────────────────────────────

initState = function(entering)
    local W = Constants.GAME_WIDTH

    S.NUM_PANELS   = 5
    S.currentPanel = 3
    S.panelOffset  = -(2 * W)
    S.targetOffset = -(2 * W)
    S.LERP_SPEED   = 14

    S.pressX       = 0
    S.pressY       = 0
    S.isPressed    = false
    S.isDragging   = false
    S.hasMoved     = false
    S.SWIPE_THRESH = 10
    S.SNAP_THRESH  = 60

    S.collectionView    = "grid"
    S.detailUnit        = nil
    S._backButtonRect   = nil
    S._detailSpriteRect = nil
    S._detailRotAngle   = 1
    S._detailDragX      = nil
    S.collectionScrollY    = 0
    S.collectionScrollMax  = 0
    S._collectionScrollVel = 0
    S._collectionScrollDragY = nil

    DeckManager.load()
    if not DeckManager._data.activeDeckIndex then DeckManager.setActive(1) end
    S.selectedDeckSlot = DeckManager._data.activeDeckIndex
    S._deckSlotRects   = {}
    S._deckCardRects   = {}
    S._deckSortRect    = nil
    S._deckActiveRect  = nil
    S._deckSortByCost  = false
    S.previewLayout    = {}
    S.deckView         = "grid"
    S.deckDetailUnit   = nil
    S.deckScrollY      = 0
    S.deckScrollMax    = 0
    S._deckScrollVel   = 0
    S._deckScrollDragY = nil

    S.unitOrder         = UnitRegistry.getAllUnitTypes()
    table.sort(S.unitOrder)
    S.sprites           = {}
    S.spriteTrimBottoms = {}
    S.dirSprites        = {}
    S.idleAnim          = {}
    S.attackAnim        = {}
    S._previewUnitRects = {}
    for _, utype in ipairs(S.unitOrder) do
        local loaded = UnitRegistry.loadDirectionalSprites(utype)
        S.sprites[utype]           = loaded.front
        S.spriteTrimBottoms[utype] = loaded.frontTrimBottom
        S.dirSprites[utype]        = loaded
        S.idleAnim[utype]          = { frameIndex = 1, timer = 0 }
        S.attackAnim[utype]        = { active = false, progress = 0, duration = 0.45 }
    end
    buildPreviewLayout()

    -- Tab bar icons (store paths — TODO-RENDER: create display objects in scene:create)
    S.uiIconPaths = {}
    for i, name in ipairs({'collection','decks','battle','ranking','shop'}) do
        S.uiIconPaths[i] = 'src/assets/ui/' .. name .. '.png'
    end
    S.gemIconPath  = 'src/assets/ui/gem.png'
    S.goldIconPath = 'src/assets/ui/gold.png'

    S.tabRaiseAnim = { 0, 0, 1, 0, 0 }

    S.showSettings         = false
    S._settingsBtnRect     = nil
    S._settingsLogoutRect  = nil
    S._settingsMusicRect   = nil
    S._settingsSFXRect     = nil
    S._settingsGodModeRect = nil
    S._settingsTitleRect   = nil
    S._settingsPanelRect   = nil
    S._settingsTitleTaps   = 0
    S._settingsTitleLastTap = 0
    S._showGodModeRow      = false

    S._rewardState     = "idle"
    S._rewardAnimTimer = 0
    S._rewardUnit      = nil
    S._rewardType      = nil
    S._rewardLevel     = nil
    S._xpBarRect       = nil

    S._collectionCards = {}
    S._ipFieldRect     = nil
    S._playBtnRect     = nil
    S._sandboxBtnRect  = nil
    S._tabRects        = {}

    S._shopGemBtns  = {}
    S._shopGoldBtns = {}
    S.shopNotice    = nil
    S.shopNoticeTimer = 0

    S._chestState       = "waiting"
    S._chestTimer       = 0
    S._chestAnimTimer   = 0
    S._chestAnimFrame   = 1
    S._chestSaveThrottle = 0
    S._chestHitFlash    = 0
    S._chestTapCount    = 0
    S._chestTapTimer    = 0
    S._chestSprites     = nil
    S._chestBtnRect     = nil
    S._chestSkipRect    = nil
    S._paletteShader    = nil  -- TODO-RENDER: graphics.defineEffect for palette swap
    loadChestTimer()

    S._tradeSlots        = {}
    S._tradeTimer        = 0
    S._tradeSaveThrottle = 0
    S._tradeCardRects    = {}
    loadTradeTimer()

    S._reconnectHandle = nil
    S._reconnecting    = false

    S._cb_currencyUpdate = nil
    S._cb_shopError      = nil
    S._cb_disconnect     = nil
    S._cb_forcedLogout   = nil
    S._cb_decksSynced    = nil
    S._cb_onlineCount    = nil
    S._cb_rewardClaimed  = nil
    S._cb_cardAwarded    = nil
    S._cb_leaderboard    = nil

    registerSocketHandlers()

    if entering then
        S._exitAnim = { active = true, progress = 1, duration = 0.28, callback = nil, direction = -1 }
    else
        S._exitAnim = { active = false, progress = 0, duration = 0.28, callback = nil, direction = 1 }
    end

    AudioManager.playMusic()
    AudioManager.setBattleMode(false)

    S._tickerMessages   = {
        "This is a test",
        "This is not a test",
        "Okay maybe this IS a test",
        "Build your deck. Crush your enemies.",
        "Units respawn every round. Plan accordingly.",
        "Losing gives you bonus coins. Stay in the fight.",
    }
    S._tickerCurrentMsg = nil
    S._tickerLastIdx    = nil
    S._tickerMsgPx      = 0
    S._tickerOffset     = 0
    S._tickerState      = "waiting"
    S._tickerWaitTimer  = 1.0

    S._playSpring     = { scale = 1.0, vel = 0.0, pressed = false }
    S._sbtnSpring     = { scale = 1.0, vel = 0.0, pressed = false }
    S._joinSpring     = { scale = 1.0, vel = 0.0, pressed = false }
    S._settingsSpring = { scale = 1.0, vel = 0.0, pressed = false }
    S._tradeBtnSprings = {
        { scale = 1.0, vel = 0.0, pressed = false },
        { scale = 1.0, vel = 0.0, pressed = false },
        { scale = 1.0, vel = 0.0, pressed = false },
    }

    S._onlineCount     = nil
    S._onlinePollTimer = 30

    S._leaderboard        = nil
    S._leaderboardLoading = false
    S._leaderboardFetched = false

    S._roomKeyText    = ""
    S._roomKeyActive  = false
    S._roomKeyRect    = nil
    S._roomKeyJoinRect = nil
    S._cursorTimer    = 0

    S._lastTime = nil
end

-- ── Socket handlers ───────────────────────────────────────────────────────────

registerSocketHandlers = function()
    if not _G.GameSocket then
        print("[MENU] WARNING: _G.GameSocket is nil, no handlers registered")
        return
    end

    S._cb_currencyUpdate = _G.GameSocket:on("currency_update", function(data)
        print("[MENU] currency_update gold=" .. tostring(data.gold) .. " gems=" .. tostring(data.gems))
        if _G.PlayerData then
            if data.gold    ~= nil then _G.PlayerData.gold    = data.gold    end
            if data.gems    ~= nil then _G.PlayerData.gems    = data.gems    end
            if data.xp      ~= nil then _G.PlayerData.xp      = data.xp      end
            if data.level   ~= nil then _G.PlayerData.level   = data.level   end
            if data.unlocks ~= nil then _G.PlayerData.unlocks = data.unlocks end
        end
    end)

    S._cb_shopError = _G.GameSocket:on("shop_error", function(data)
        S.shopNotice      = data.reason or "Purchase failed"
        S.shopNoticeTimer = 2.5
    end)

    S._cb_disconnect = _G.GameSocket:on("disconnect", function()
        print("[MENU] Socket disconnected, will reconnect on next action")
    end)

    S._cb_forcedLogout = _G.GameSocket:on("forced_logout", function(data)
        print("[MENU] Forced logout: " .. tostring(data and data.reason))
        _G.deleteFile("session.dat")
        _G.GameSocket = nil
        _G.PlayerData = nil
        composer.gotoScene("src.screens.login", {effect = "fade", time = 300})
    end)

    S._cb_decksSynced = _G.GameSocket:on("decks_synced", function()
        buildPreviewLayout()
    end)

    S._cb_onlineCount = _G.GameSocket:on("online_count", function(data)
        S._onlineCount = data.count
    end)

    S._cb_rewardClaimed = _G.GameSocket:on("reward_claimed", function(data)
        if _G.PlayerData and _G.PlayerData.unlocks then
            _G.PlayerData.unlocks.pending_rewards = data.pending_rewards or {}
        end
    end)

    S._cb_cardAwarded = _G.GameSocket:on("card_awarded", function(data)
        if _G.PlayerData then
            if data.unlocks then _G.PlayerData.unlocks = data.unlocks end
            if data.gold    then _G.PlayerData.gold    = data.gold    end
        end
    end)

    S._cb_leaderboard = _G.GameSocket:on("leaderboard_data", function(data)
        S._leaderboard        = data.players
        S._leaderboardLoading = false
    end)
end

removeSocketHandlers = function()
    if _G.GameSocket then
        if S._cb_currencyUpdate then _G.GameSocket:removeCallback(S._cb_currencyUpdate) end
        if S._cb_shopError      then _G.GameSocket:removeCallback(S._cb_shopError) end
        if S._cb_disconnect     then _G.GameSocket:removeCallback(S._cb_disconnect) end
        if S._cb_forcedLogout   then _G.GameSocket:removeCallback(S._cb_forcedLogout) end
        if S._cb_decksSynced    then _G.GameSocket:removeCallback(S._cb_decksSynced) end
        if S._cb_onlineCount    then _G.GameSocket:removeCallback(S._cb_onlineCount) end
        if S._cb_rewardClaimed  then _G.GameSocket:removeCallback(S._cb_rewardClaimed) end
        if S._cb_cardAwarded    then _G.GameSocket:removeCallback(S._cb_cardAwarded) end
        if S._cb_leaderboard    then _G.GameSocket:removeCallback(S._cb_leaderboard) end
    end
    S._cb_currencyUpdate = nil; S._cb_shopError     = nil
    S._cb_disconnect     = nil; S._cb_forcedLogout  = nil
    S._cb_decksSynced    = nil; S._cb_onlineCount   = nil
    S._cb_rewardClaimed  = nil; S._cb_cardAwarded   = nil
    S._cb_leaderboard    = nil
end

startReconnect = function()
    if S._reconnecting then return end
    S._reconnecting = true
    print("[MENU] Starting socket reconnection...")
    S._reconnectHandle = SocketManager.reconnect(
        function()
            print("[MENU] Reconnected successfully")
            S._reconnecting    = false
            S._reconnectHandle = nil
            registerSocketHandlers()
        end,
        function(reason)
            print("[MENU] Reconnect failed: " .. tostring(reason))
            S._reconnecting    = false
            S._reconnectHandle = nil
            _G.deleteFile("session.dat")
            _G.GameSocket = nil
            _G.PlayerData = nil
            composer.gotoScene("src.screens.login", {effect = "fade", time = 300})
        end
    )
end

startExitAnim = function(callback)
    S._exitAnim.active    = true
    S._exitAnim.progress  = 0
    S._exitAnim.direction = 1
    S._exitAnim.callback  = callback
end

tryJoinPrivateRoom = function()
    local key = S._roomKeyText:match("^%s*(.-)%s*$")
    if #key < 1 then return end
    if not (_G.GameSocket and _G.GameSocket:isConnected()) then return end
    S._roomKeyActive = false
    if scene._roomKeyField then native.setKeyboardFocus(nil) end
    removeSocketHandlers()
    local sock = _G.GameSocket
    startExitAnim(function()
        composer.gotoScene("src.screens.lobby", {params = {client = sock, roomKey = key}})
    end)
end

-- ── Preview layout ────────────────────────────────────────────────────────────

buildPreviewLayout = function()
    S.previewLayout = {}
    local deck = DeckManager.getActiveDeck()
    if not deck then return end

    local units = {}
    for utype, count in pairs(deck.counts) do
        if count > 0 then table.insert(units, utype) end
    end
    if #units == 0 then return end

    local positions = {}
    for r = 1, 4 do
        for c = 1, 5 do table.insert(positions, {col = c, row = r}) end
    end
    for i = #positions, 2, -1 do
        local j = math.random(i)
        positions[i], positions[j] = positions[j], positions[i]
    end

    local n = math.min(#units, #positions)
    for i = 1, n do
        table.insert(S.previewLayout, {
            unitType = units[i],
            col      = positions[i].col,
            row      = positions[i].row,
        })
    end
end

getPreviewFrame = function(utype)
    local d = S.dirSprites[utype]
    if d and d.hasDirectionalSprites then
        local atk = S.attackAnim[utype]
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
        local aio = d.directional.actionIdleOverride
        if aio and (aio[0] or aio[180]) then
            local ad  = aio[0] or aio[180]
            local idx = math.min(S.idleAnim[utype].frameIndex, #ad.frames)
            return ad.frames[idx], ad.trimBottom[idx] or 0
        end
        if d.directional.idle and d.directional.idle[0] then
            local dirData = d.directional.idle[0]
            local idx     = S.idleAnim[utype].frameIndex
            return dirData.frames[idx], dirData.trimBottom[idx]
        end
    end
    return S.sprites[utype], S.spriteTrimBottoms[utype] or 0
end

-- ── Chest / trade persistence ─────────────────────────────────────────────────

loadChestSprites = function()
    if S._chestSprites then return end
    -- TODO-RENDER: load chest sprites via display objects, not love.graphics.newImage
    -- For now, store paths only so the state machine can run
    local s = {
        closed  = { image = nil, trimBottom = 0, path = 'src/assets/Chest/Chest.png' },
        hit     = { image = nil, trimBottom = 0, path = 'src/assets/Chest/HitChest.png' },
        open    = { image = nil, trimBottom = 0, path = 'src/assets/Chest/ChestOpen.png' },
        opening = {},
        broken  = {},
    }
    for i = 1, 16 do s.opening[i] = { image = nil, trimBottom = 0, path = 'src/assets/Chest/Open(GoldLoot)' .. i .. '.png' } end
    for i = 1, 6  do s.broken[i]  = { image = nil, trimBottom = 0, path = 'src/assets/Chest/Broken' .. i .. '.png'         } end
    S._chestSprites  = s
    -- TODO-RENDER: S._paletteShader = graphics.defineEffect(...)
end

saveChestTimer = function()
    local data = json.encode({ saved_at = os.time(), elapsed = S._chestTimer })
    _G.writeFile('chest_timer.json', data)
end

loadChestTimer = function()
    local CHEST_DURATION = 86400
    if not _G.fileExists('chest_timer.json') then
        S._chestTimer = 0; S._chestState = "waiting"; return
    end
    local raw = _G.readFile('chest_timer.json')
    local ok, saved = pcall(json.decode, raw)
    if not ok or not saved then
        S._chestTimer = 0; S._chestState = "waiting"; return
    end
    local elapsed = (saved.elapsed or 0) + (os.time() - (saved.saved_at or 0))
    if elapsed >= CHEST_DURATION then
        S._chestTimer = CHEST_DURATION; S._chestState = "ready"
    else
        S._chestTimer = math.max(0, elapsed); S._chestState = "waiting"
    end
end

saveTradeTimer = function()
    _G.writeFile('trade_timer.json', json.encode({
        saved_at = os.time(),
        elapsed  = S._tradeTimer,
        slots    = S._tradeSlots,
    }))
end

loadTradeTimer = function()
    if not _G.fileExists('trade_timer.json') then
        S._tradeTimer = 86400; S._tradeSlots = {}; return
    end
    local raw = _G.readFile('trade_timer.json')
    local ok, saved = pcall(json.decode, raw)
    if not ok or not saved then
        S._tradeTimer = 86400; S._tradeSlots = {}; return
    end
    local elapsed = (saved.elapsed or 0) + (os.time() - (saved.saved_at or 0))
    if elapsed >= 86400 then
        S._tradeTimer = 86400; S._tradeSlots = {}
    else
        S._tradeTimer = math.max(0, elapsed)
        S._tradeSlots = saved.slots or {}
    end
end

pickWeightedCard = function()
    local pool   = buildCardPool()
    local picked = weightedPick(pool)
    if not picked then
        local all = UnitRegistry.getAllUnitTypes()
        picked = all[math.random(#all)]
    end
    return picked
end

generateTradeSlots = function()
    local pool = buildCardPool()
    S._tradeSlots = {}
    for _ = 1, 3 do
        if #pool == 0 then break end
        local picked = weightedPick(pool)
        if picked then S._tradeSlots[#S._tradeSlots + 1] = picked end
    end
    S._tradeTimer = 0
    saveTradeTimer()
end

-- ── Update ────────────────────────────────────────────────────────────────────

local function onUpdate(event)
    local now = event.time / 1000
    local dt  = math.min(now - (S._lastTime or now), 1 / 30)
    S._lastTime = now

    -- Exit/enter transition animation
    if S._exitAnim.active then
        local dir = S._exitAnim.direction or 1
        S._exitAnim.progress = S._exitAnim.progress + dir * dt / S._exitAnim.duration
        if dir == 1 then
            S._exitAnim.progress = math.min(1, S._exitAnim.progress)
            if S._exitAnim.progress >= 1 and S._exitAnim.callback then
                local cb = S._exitAnim.callback
                S._exitAnim.callback = nil
                if cb then cb() end
                return
            end
        else
            S._exitAnim.progress = math.max(0, S._exitAnim.progress)
            if S._exitAnim.progress <= 0 then S._exitAnim.active = false end
        end
    end

    -- Socket keepalive / reconnect
    if S._reconnecting and S._reconnectHandle then
        SocketManager.updateReconnect(S._reconnectHandle, dt)
    elseif _G.GameSocket then
        if _G.GameSocket:isConnected() then
            local ok, err = pcall(function() _G.GameSocket:update() end)
            if not ok then
                print("[MENU] Socket error, reconnecting: " .. tostring(err))
                _G.GameSocket = nil
                startReconnect()
            end
        elseif not S._reconnecting then
            startReconnect()
        end
    end

    -- Leaderboard fetch when ranking panel active
    if S.currentPanel == 4 then
        if not S._leaderboardFetched and _G.GameSocket and _G.GameSocket:isConnected() then
            S._leaderboardFetched = true
            S._leaderboardLoading = true
            _G.GameSocket:send("get_leaderboard", {})
        end
    else
        S._leaderboardFetched = false
    end

    S._cursorTimer = (S._cursorTimer or 0) + dt

    -- Online count polling (every 30s)
    if _G.GameSocket and _G.GameSocket:isConnected() then
        S._onlinePollTimer = S._onlinePollTimer + dt
        if S._onlinePollTimer >= 30 then
            S._onlinePollTimer = 0
            _G.GameSocket:send("get_online_count", {})
        end
    end

    -- Shop notice timer
    if S.shopNoticeTimer > 0 then
        S.shopNoticeTimer = S.shopNoticeTimer - dt
        if S.shopNoticeTimer <= 0 then S.shopNotice = nil; S.shopNoticeTimer = 0 end
    end

    -- Daily chest update
    if S._chestHitFlash > 0 then S._chestHitFlash = S._chestHitFlash - dt end
    if S._chestTapCount > 0 then
        S._chestTapTimer = S._chestTapTimer + dt
        if S._chestTapTimer > 0.4 then S._chestTapCount = 0; S._chestTapTimer = 0 end
    end

    local CHEST_DURATION = 86400
    local OPEN_FRAME_DT  = 0.06
    if S._chestState == "waiting" or S._chestState == "broken" then
        S._chestTimer = S._chestTimer + dt
        if S._chestTimer >= CHEST_DURATION then
            S._chestTimer = CHEST_DURATION; S._chestState = "ready"
            saveChestTimer()
        else
            S._chestSaveThrottle = (S._chestSaveThrottle or 0) + dt
            if S._chestSaveThrottle >= 5 then S._chestSaveThrottle = 0; saveChestTimer() end
        end
        if S._chestState == "broken" then
            S._chestAnimTimer = S._chestAnimTimer + dt
            S._chestAnimFrame = math.floor(S._chestAnimTimer / 0.1) % 6 + 1
        end
    elseif S._chestState == "open" then
        if S._chestAnimFrame <= 16 then
            S._chestAnimTimer = S._chestAnimTimer + dt
            local frame = math.floor(S._chestAnimTimer / OPEN_FRAME_DT) + 1
            if frame > 16 then
                S._chestAnimFrame = 17
                local unitType = pickWeightedCard()
                if _G.PlayerData and _G.PlayerData.unlocks then
                    local u = _G.PlayerData.unlocks
                    u.cards = u.cards or {}
                    u.cards[unitType] = (u.cards[unitType] or 0) + 1
                    u.pending_rewards = u.pending_rewards or {}
                    table.insert(u.pending_rewards, {unit = unitType, type = "card"})
                end
                if _G.GameSocket then _G.GameSocket:send("award_card", {unit = unitType}) end
                S._chestTimer = 0; S._chestState = "waiting"
                S._chestAnimTimer = 0; S._chestAnimFrame = 1
                saveChestTimer()
            else
                S._chestAnimFrame = frame
            end
        end
    end

    -- Card trade timer
    if S._tradeTimer < 86400 then
        S._tradeTimer = S._tradeTimer + dt
        if S._tradeTimer >= 86400 then
            S._tradeTimer = 86400; S._tradeSlots = {}
            saveTradeTimer()
        else
            S._tradeSaveThrottle = (S._tradeSaveThrottle or 0) + dt
            if S._tradeSaveThrottle >= 5 then S._tradeSaveThrottle = 0; saveTradeTimer() end
        end
    end

    -- Deck scroll momentum
    if S._deckScrollVel ~= 0 and S.currentPanel == 2 and S.deckView == "grid" and not S._deckScrollDragY then
        S.deckScrollY = S.deckScrollY + S._deckScrollVel * dt
        S.deckScrollY = math.max(0, math.min(S.deckScrollMax, S.deckScrollY))
        S._deckScrollVel = S._deckScrollVel * (1 - math.min(1, 10 * dt))
        if math.abs(S._deckScrollVel) < 1 then S._deckScrollVel = 0 end
    end

    -- Collection scroll momentum
    if S._collectionScrollVel ~= 0 and S.currentPanel == 1 and S.collectionView == "grid" and not S._collectionScrollDragY then
        S.collectionScrollY = S.collectionScrollY + S._collectionScrollVel * dt
        S.collectionScrollY = math.max(0, math.min(S.collectionScrollMax, S.collectionScrollY))
        S._collectionScrollVel = S._collectionScrollVel * (1 - math.min(1, 10 * dt))
        if math.abs(S._collectionScrollVel) < 1 then S._collectionScrollVel = 0 end
    end

    -- Reward reveal state machine
    if S._rewardState == "idle" then
        local unlocks = _G.PlayerData and _G.PlayerData.unlocks
        if unlocks and unlocks.pending_rewards and #unlocks.pending_rewards > 0 then
            local reward    = unlocks.pending_rewards[1]
            S._rewardState  = "pending"
            S._rewardUnit   = reward.unit
            S._rewardType   = reward.type
            S._rewardLevel  = reward.level
            S._rewardShakeTime = 0
        end
    elseif S._rewardState == "pending" then
        S._rewardShakeTime = (S._rewardShakeTime or 0) + dt
    elseif S._rewardState == "revealing" then
        S._rewardAnimTimer = S._rewardAnimTimer + dt
    end

    -- Idle/attack animations for play-panel preview
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

    -- Lerp panel strip
    local diff = S.targetOffset - S.panelOffset
    if math.abs(diff) < 0.5 then
        S.panelOffset = S.targetOffset
    else
        S.panelOffset = S.panelOffset + diff * S.LERP_SPEED * dt
    end

    -- Tab raise animation
    for i = 1, S.NUM_PANELS do
        local target = (i == S.currentPanel) and 1 or 0
        local d = target - S.tabRaiseAnim[i]
        if math.abs(d) < 0.01 then
            S.tabRaiseAnim[i] = target
        else
            S.tabRaiseAnim[i] = S.tabRaiseAnim[i] + d * 12 * dt
        end
    end

    -- Ticker
    local tickerW    = Constants.GAME_WIDTH
    local tickerSpeed = 60 * Constants.SCALE
    local TICKER_PAUSE = 2.5
    if S._tickerState == "scrolling" then
        S._tickerOffset = S._tickerOffset + tickerSpeed * dt
        if S._tickerOffset >= tickerW + S._tickerMsgPx then
            S._tickerState = "waiting"; S._tickerWaitTimer = TICKER_PAUSE
        end
    elseif S._tickerState == "waiting" then
        S._tickerWaitTimer = S._tickerWaitTimer - dt
        if S._tickerWaitTimer <= 0 then
            local msgs = S._tickerMessages
            local idx  = math.random(#msgs)
            if #msgs > 1 then
                while idx == S._tickerLastIdx do idx = math.random(#msgs) end
            end
            S._tickerLastIdx    = idx
            S._tickerCurrentMsg = msgs[idx]
            -- Approximate width without love.graphics font object
            local sz = Fonts.small and Fonts.small.size or 12
            S._tickerMsgPx  = #S._tickerCurrentMsg * sz * 0.6
            S._tickerOffset = 0
            S._tickerState  = "scrolling"
        end
    end

    -- Button spring physics
    local function updateSpring(sp)
        local target = sp.pressed and 0.93 or 1.0
        local accel  = -480 * (sp.scale - target) - 18 * sp.vel
        sp.vel   = sp.vel   + accel * dt
        sp.scale = sp.scale + sp.vel  * dt
        sp.scale = math.max(0.85, math.min(1.12, sp.scale))
    end
    updateSpring(S._playSpring); updateSpring(S._sbtnSpring)
    updateSpring(S._joinSpring); updateSpring(S._settingsSpring)
    for i = 1, 3 do updateSpring(S._tradeBtnSprings[i]) end

    -- Update approximate hit-rects for buttons (TODO-RENDER: move inside draw stubs)
    local W  = Constants.GAME_WIDTH
    local H  = Constants.GAME_HEIGHT
    local sc = Constants.SCALE

    -- Tab bar hit-rects (always valid)
    local BAR_H = 100 * sc + Constants.SAFE_INSET_BOTTOM
    local barY  = H - BAR_H
    local tabW  = W / S.NUM_PANELS
    S._tabRects = {}
    for i = 1, S.NUM_PANELS do
        S._tabRects[i] = { x = (i-1)*tabW, y = barY, w = tabW, h = BAR_H }
    end

    -- Battle panel: Play Online + Sandbox buttons (approximate positions for testing)
    if S.currentPanel == 3 then
        local panX = S.panelOffset + 2 * W  -- offset of panel 3 in the strip
        local btnW  = math.floor(W * 0.55)
        local btnH  = math.floor(44 * sc)
        local btnX  = panX + (W - btnW) / 2
        local btnY  = H * 0.45
        S._playBtnRect    = { x = btnX, y = btnY,         w = btnW, h = btnH }
        S._sandboxBtnRect = { x = btnX, y = btnY + btnH + math.floor(20*sc), w = btnW, h = btnH }
    end
end

-- ── Draw stubs (TODO-RENDER) ──────────────────────────────────────────────────

local function drawTickerStripe(W, sc)
    -- TODO-RENDER: animated ticker stripe (setScissor → display group mask)
end

local function drawCollectionCard(cx, cy, cardW, cardH, utype, sc)
    -- TODO-RENDER: card background, border, unit name, cost badge, sprite, owned count
end

local function drawLockedCard(cx, cy, cardW, cardH, sc)
    -- TODO-RENDER: locked card placeholder
end

local function drawEmptyCard(cx, cy, cardW, cardH, sc)
    -- TODO-RENDER: empty card placeholder
end

local function drawGroupHeader(startX, hdrY, totalW, hdrH, label, sc)
    -- TODO-RENDER: section header with label
end

local function drawCollectionDetailPage(W, H, sc)
    -- TODO-RENDER: full-page detail overlay for a unit
end

local function drawCollectionPanel(ox, W, H, sc)
    -- TODO-RENDER: collection grid / detail view
    -- Hit-rects updated here in the render pass
    S._collectionCards   = {}  -- populated during render
    S.collectionScrollMax = 0  -- computed during render
end

local function drawDecksPanel(ox, W, H, sc)
    -- TODO-RENDER: deck builder — slot tabs, card grid, +/- buttons, save/equip buttons
    S._deckSlotRects = {}
    S._deckCardRects = {}
    S.deckScrollMax  = 0
end

local function drawBattlePanel(ox, W, H, sc)
    -- TODO-RENDER: preview grid, play button, sandbox button, online count
    -- Hit-rects set in onUpdate for approximate testing
end

local function drawRankingPanel(ox, W, H, sc)
    -- TODO-RENDER: leaderboard table, private room key input, JOIN button
    S._roomKeyRect     = nil
    S._roomKeyJoinRect = nil
end

local function drawShopPanel(ox, W, H, sc)
    -- TODO-RENDER: daily chest, card trade slots
    -- Hit-rects set to nil until render pass provides real positions
    S._chestBtnRect  = nil
    S._chestSkipRect = nil
    S._tradeCardRects = {}
end

local function drawRewardReveal(W, H, sc)
    -- TODO-RENDER: full-screen reward reveal overlay
    S._xpBarRect = nil
end

local function drawSettingsOverlay(W, H, sc)
    -- TODO-RENDER: settings panel (music toggle, SFX toggle, logout, god mode)
    -- Approximate hit-rects for settings button (top-right corner)
    local btnSz = math.floor(32 * Constants.SCALE)
    S._settingsBtnRect = {
        x = W - btnSz - math.floor(8 * Constants.SCALE),
        y = math.floor(8 * Constants.SCALE) + Constants.SAFE_INSET_TOP,
        w = btnSz, h = btnSz
    }
    S._settingsPanelRect   = nil
    S._settingsLogoutRect  = nil
    S._settingsMusicRect   = nil
    S._settingsSFXRect     = nil
    S._settingsGodModeRect = nil
    S._settingsTitleRect   = nil
end

local function drawBottomBar(W, H, sc)
    -- TODO-RENDER: tab bar with icons and labels
    -- Tab rects are set in onUpdate; nothing extra needed here
end

local function draw()
    -- TODO-RENDER: call all panel draw functions with correct ox offsets
    -- Panel strip layout: panelOffset drives ox for each of 5 panels
    local W  = Constants.GAME_WIDTH
    local H  = Constants.GAME_HEIGHT
    local sc = Constants.SCALE

    -- Always update stub hit-rects
    drawSettingsOverlay(W, H, sc)
    if S.currentPanel == 3 then drawBattlePanel(0, W, H, sc) end
    if S.currentPanel == 5 then drawShopPanel(0, W, H, sc) end
    if S._rewardState == "revealing" then drawRewardReveal(W, H, sc) end
end

-- ── Input ─────────────────────────────────────────────────────────────────────

handlePress = function(x, y)
    if S._exitAnim.active then return end
    S.isPressed  = true
    S.pressX     = x
    S.pressY     = y
    S.hasMoved   = false
    S.isDragging = false

    if S._settingsBtnRect then
        local r = S._settingsBtnRect
        if x >= r.x and x <= r.x + r.w and y >= r.y and y <= r.y + r.h then
            S._settingsSpring.pressed = true
        end
    end

    if S.showDetail or S.showSettings or S._rewardState == "revealing" then return end

    if S.currentPanel == 1 and S.collectionView == "detail" then
        local r = S._detailSpriteRect
        if r and x >= r.x and x <= r.x + r.w and y >= r.y and y <= r.y + r.h then
            S._detailDragX = x
        end
    end

    if S.currentPanel == 2 and S.deckView == "detail" then
        local r = S._detailSpriteRect
        if r and x >= r.x and x <= r.x + r.w and y >= r.y and y <= r.y + r.h then
            S._detailDragX = x
        end
    end

    if S.currentPanel == 5 and S._chestState == "waiting" and S._chestBtnRect then
        local r = S._chestBtnRect
        if x >= r.x and x <= r.x + r.w and y >= r.y and y <= r.y + r.h then
            S._chestHitFlash = 0.12
            S._chestTapCount = S._chestTapCount + 1
            S._chestTapTimer = 0
            if S._chestTapCount >= 3 then
                S._chestState = "broken"; S._chestAnimTimer = 0
                S._chestAnimFrame = 1; S._chestTapCount = 0
            end
        end
    end

    if S.currentPanel == 5 then
        for _, r in ipairs(S._tradeCardRects) do
            if x >= r.x and x <= r.x + r.w and y >= r.y and y <= r.y + r.h then
                S._tradeBtnSprings[r.slotIndex].pressed = true
            end
        end
    end

    if S.currentPanel == 3 then
        local btn = S._playBtnRect
        if btn and x >= btn.x and x <= btn.x + btn.w and y >= btn.y and y <= btn.y + btn.h then
            S._playSpring.pressed = true
        end
        local sbtn = S._sandboxBtnRect
        if sbtn and x >= sbtn.x and x <= sbtn.x + sbtn.w and y >= sbtn.y and y <= sbtn.y + sbtn.h then
            S._sbtnSpring.pressed = true
        end
    end
    if S.currentPanel == 4 and S._roomKeyText ~= "" then
        local jbtn = S._roomKeyJoinRect
        if jbtn and x >= jbtn.x and x <= jbtn.x + jbtn.w and y >= jbtn.y and y <= jbtn.y + jbtn.h then
            S._joinSpring.pressed = true
        end
    end
end

handleMove = function(x, y)
    if not S.isPressed then return end
    if S.showDetail or S.showSettings or S._rewardState == "revealing" then return end

    if S._detailDragX ~= nil then
        local STEP_PX = math.max(1, math.floor(60 * Constants.SCALE))
        local delta = x - S._detailDragX
        if math.abs(delta) >= STEP_PX then
            local dir = delta < 0 and 1 or -1
            S._detailRotAngle = ((S._detailRotAngle + dir - 1) % 8) + 1
            S._detailDragX = x
        end
        return
    end

    local dx = x - S.pressX
    local dy = y - S.pressY

    if S.currentPanel == 1 and S.collectionView == "grid" then
        if S._collectionScrollDragY ~= nil then
            local delta = S._collectionScrollDragY - y
            S._collectionScrollVel  = delta / math.max(1/60, 1/60)
            S.collectionScrollY     = math.max(0, math.min(S.collectionScrollMax, S.collectionScrollY + delta))
            S._collectionScrollDragY = y
            return
        elseif not S.isDragging and math.abs(dy) > S.SWIPE_THRESH and math.abs(dy) > math.abs(dx) then
            S._collectionScrollDragY = y; S._collectionScrollVel = 0
            S.hasMoved = true; return
        end
    end

    if S.currentPanel == 2 and S.deckView == "grid" then
        if S._deckScrollDragY ~= nil then
            local delta = S._deckScrollDragY - y
            S._deckScrollVel  = delta / math.max(1/60, 1/60)
            S.deckScrollY     = math.max(0, math.min(S.deckScrollMax, S.deckScrollY + delta))
            S._deckScrollDragY = y
            return
        elseif not S.isDragging and math.abs(dy) > S.SWIPE_THRESH and math.abs(dy) > math.abs(dx) then
            S._deckScrollDragY = y; S._deckScrollVel = 0
            S.hasMoved = true; return
        end
    end

    if not S.isDragging then
        if math.abs(dx) > S.SWIPE_THRESH and math.abs(dx) > math.abs(dy) then
            S.isDragging = true; S.hasMoved = true
        end
    end

    if S.isDragging then
        local W    = Constants.GAME_WIDTH
        local base = -(S.currentPanel - 1) * W
        local raw  = base + dx
        local minOff = -(S.NUM_PANELS - 1) * W
        local maxOff = 0
        if raw > maxOff then
            raw = maxOff + (raw - maxOff) * 0.25
        elseif raw < minOff then
            raw = minOff + (raw - minOff) * 0.25
        end
        S.panelOffset = raw
    end
end

handleRelease = function(x, y)
    S.isPressed = false
    S._playSpring.pressed     = false; S._sbtnSpring.pressed     = false
    S._joinSpring.pressed     = false; S._settingsSpring.pressed = false
    for i = 1, 3 do S._tradeBtnSprings[i].pressed = false end
    S._detailDragX = nil
    if S._collectionScrollDragY ~= nil then S._collectionScrollDragY = nil; S.hasMoved = true end
    if S._deckScrollDragY       ~= nil then S._deckScrollDragY       = nil; S.hasMoved = true end
    local dx = x - S.pressX

    -- Reward reveal overlay
    if S._rewardState == "revealing" then
        if S._rewardAnimTimer > 1.5 then
            AudioManager.playTap()
            if _G.GameSocket and _G.GameSocket:isConnected() then
                _G.GameSocket:send("claim_reward", {})
            end
            local unlocks = _G.PlayerData and _G.PlayerData.unlocks
            if unlocks and unlocks.pending_rewards then
                table.remove(unlocks.pending_rewards, 1)
            end
            if unlocks and unlocks.pending_rewards and #unlocks.pending_rewards > 0 then
                local reward        = unlocks.pending_rewards[1]
                S._rewardState      = "revealing"
                S._rewardUnit       = reward.unit
                S._rewardType       = reward.type
                S._rewardLevel      = reward.level
                S._rewardAnimTimer  = 0
            else
                S._rewardState = "idle"; S._rewardUnit = nil
                S._rewardType  = nil;   S._rewardLevel = nil
                S._rewardAnimTimer = 0
            end
        end
        return
    end

    -- Settings overlay
    if S.showSettings then
        if S._settingsTitleRect then
            local r = S._settingsTitleRect
            if x >= r.x and x <= r.x + r.w and y >= r.y and y <= r.y + r.h then
                local now = getTime()
                if now - (S._settingsTitleLastTap or 0) < 1.5 then
                    S._settingsTitleTaps = (S._settingsTitleTaps or 0) + 1
                else
                    S._settingsTitleTaps = 1
                end
                S._settingsTitleLastTap = now
                if S._settingsTitleTaps >= 3 then
                    S._showGodModeRow = true; S._settingsTitleTaps = 0
                end
                return
            end
        end
        if S._settingsGodModeRect then
            local r = S._settingsGodModeRect
            if x >= r.x and x <= r.x + r.w and y >= r.y and y <= r.y + r.h then
                _G.GodMode = not _G.GodMode; AudioManager.playTap(); return
            end
        end
        if S._settingsMusicRect then
            local r = S._settingsMusicRect
            if x >= r.x and x <= r.x + r.w and y >= r.y and y <= r.y + r.h then
                AudioManager.setMusic(not AudioManager.musicEnabled); return
            end
        end
        if S._settingsSFXRect then
            local r = S._settingsSFXRect
            if x >= r.x and x <= r.x + r.w and y >= r.y and y <= r.y + r.h then
                AudioManager.setSFX(not AudioManager.sfxEnabled); AudioManager.playTap(); return
            end
        end
        if S._settingsLogoutRect then
            local r = S._settingsLogoutRect
            if x >= r.x and x <= r.x + r.w and y >= r.y and y <= r.y + r.h then
                _G.deleteFile("session.dat")
                if _G.GameSocket then _G.GameSocket:disconnect(); _G.GameSocket = nil end
                _G.PlayerData = nil
                composer.gotoScene("src.screens.login", {effect = "fade", time = 300})
                return
            end
        end
        if S._settingsPanelRect then
            local r = S._settingsPanelRect
            if x < r.x or x > r.x + r.w or y < r.y or y > r.y + r.h then
                S.showSettings = false
            end
        end
        return
    end

    -- Settings "+" button
    if S._settingsBtnRect then
        local r = S._settingsBtnRect
        if x >= r.x and x <= r.x + r.w and y >= r.y and y <= r.y + r.h then
            S.showSettings = true; return
        end
    end

    -- XP bar tap
    if S._rewardState == "pending" and S._xpBarRect then
        local r = S._xpBarRect
        if x >= r.x and x <= r.x + r.w and y >= r.y and y <= r.y + r.h then
            AudioManager.playTap()
            S._rewardState = "revealing"; S._rewardAnimTimer = 0
            return
        end
    end

    -- Shop panel: chest + trade
    if S.currentPanel == 5 then
        if _G.GodMode and S._chestSkipRect and S._chestState == "waiting" then
            local r = S._chestSkipRect
            if x >= r.x and x <= r.x + r.w and y >= r.y and y <= r.y + r.h then
                S._chestTimer = 86400; S._chestState = "ready"
                saveChestTimer(); AudioManager.playTap(); return
            end
        end
        if S._chestState == "ready" and S._chestBtnRect then
            local r = S._chestBtnRect
            if x >= r.x and x <= r.x + r.w and y >= r.y and y <= r.y + r.h then
                S._chestState = "open"; S._chestAnimTimer = 0; S._chestAnimFrame = 1
                AudioManager.playTap(); return
            end
        end
        for _, r in ipairs(S._tradeCardRects) do
            local i = r.slotIndex
            if x >= r.x and x <= r.x + r.w and y >= r.y and y <= r.y + r.h then
                local gold = (_G.PlayerData and _G.PlayerData.gold) or 0
                if gold >= 100 then
                    local unitType = S._tradeSlots[i]
                    _G.PlayerData.gold = gold - 100
                    if _G.PlayerData.unlocks and unitType then
                        local u = _G.PlayerData.unlocks
                        u.cards = u.cards or {}
                        u.cards[unitType] = (u.cards[unitType] or 0) + 1
                        u.pending_rewards = u.pending_rewards or {}
                        table.insert(u.pending_rewards, {unit = unitType, type = "card"})
                    end
                    if _G.GameSocket and unitType then
                        _G.GameSocket:send("award_card", {unit = unitType, cost = 100})
                    end
                    S._tradeSlots[i] = false
                    saveTradeTimer(); AudioManager.playTap()
                else
                    S.shopNotice = "Not enough gold!"; S.shopNoticeTimer = 2.0
                end
                return
            end
        end
        -- Gem purchase
        for _, btn in ipairs(S._shopGemBtns) do
            if x >= btn.x and x <= btn.x + btn.w and y >= btn.y and y <= btn.y + btn.h then
                if _G.GameSocket and _G.GameSocket:isConnected() then
                    _G.GameSocket:send("gem_purchase", {package = btn.key})
                end
                return
            end
        end
        for _, btn in ipairs(S._shopGoldBtns) do
            if x >= btn.x and x <= btn.x + btn.w and y >= btn.y and y <= btn.y + btn.h then
                if _G.GameSocket and _G.GameSocket:isConnected() then
                    _G.GameSocket:send("shop_purchase", {item = btn.key})
                end
                return
            end
        end
    end

    -- Swipe committed
    if S.isDragging then
        local W = Constants.GAME_WIDTH
        if dx < -S.SNAP_THRESH and S.currentPanel < S.NUM_PANELS then
            S.currentPanel = S.currentPanel + 1
        elseif dx > S.SNAP_THRESH and S.currentPanel > 1 then
            S.currentPanel = S.currentPanel - 1
        end
        S.targetOffset = -(S.currentPanel - 1) * W
        S.isDragging   = false
        if S.currentPanel ~= 4 and S._chestState == "broken" then
            S._chestState = "waiting"; S._chestAnimTimer = 0; S._chestAnimFrame = 1
        end
        S._chestTapCount = 0
        if S.currentPanel ~= 1 then
            S.collectionView = "grid"; S._detailRotAngle = 1
            S._detailDragX = nil;     S.collectionScrollY = 0
        end
        if S.currentPanel ~= 2 then
            S.deckView = "grid"; S.deckDetailUnit = nil; S.deckScrollY = 0
        end
        return
    end

    -- Tab bar taps
    for i, rect in ipairs(S._tabRects) do
        if x >= rect.x and x <= rect.x + rect.w and y >= rect.y and y <= rect.y + rect.h then
            AudioManager.playTap()
            if i == 1 and S.currentPanel == 1 then
                S.collectionView = "grid"; S.detailUnit = nil
                S._detailRotAngle = 1; S._detailDragX = nil; S.collectionScrollY = 0
            elseif i == 2 and S.currentPanel == 2 then
                S.deckView = "grid"; S.deckDetailUnit = nil
                S.deckScrollY = 0; S._detailRotAngle = 1; S._detailDragX = nil
            elseif i ~= S.currentPanel then
                S.currentPanel = i
                S.targetOffset = -(i - 1) * Constants.GAME_WIDTH
                if i ~= 4 and S._chestState == "broken" then
                    S._chestState = "waiting"; S._chestAnimTimer = 0; S._chestAnimFrame = 1
                end
                S._chestTapCount = 0
                if i ~= 1 then S.collectionView = "grid"; S._detailRotAngle = 1; S._detailDragX = nil; S.collectionScrollY = 0 end
                if i ~= 2 then S.deckView = "grid"; S.deckDetailUnit = nil; S.deckScrollY = 0 end
            end
            return
        end
    end

    -- Collection detail back button
    if S.currentPanel == 1 and S.collectionView == "detail" then
        local b = S._backButtonRect
        if b and x >= b.x and x <= b.x + b.w and y >= b.y and y <= b.y + b.h then
            S.collectionView = "grid"; S.detailUnit = nil
            S._detailRotAngle = 1; S._detailDragX = nil; S.collectionScrollY = 0
        end
        return
    end

    -- Deck detail back button
    if S.currentPanel == 2 and S.deckView == "detail" then
        local b = S._backButtonRect
        if b and x >= b.x and x <= b.x + b.w and y >= b.y and y <= b.y + b.h then
            S.deckView = "grid"; S.deckDetailUnit = nil
            S.deckScrollY = 0; S._detailRotAngle = 1; S._detailDragX = nil
        end
        return
    end

    -- Play-panel preview unit taps → attack anim
    if S.currentPanel == 3 then
        for _, rect in ipairs(S._previewUnitRects) do
            if x >= rect.x and x <= rect.x + rect.w and
               y >= rect.y and y <= rect.y + rect.h then
                local atk = S.attackAnim[rect.utype]
                atk.active = true; atk.progress = 0
                return
            end
        end
    end

    -- Collection card taps
    if S.currentPanel == 1 and not S.hasMoved then
        for _, card in ipairs(S._collectionCards) do
            if x >= card.x and x <= card.x + card.w and
               y >= card.y and y <= card.y + card.h then
                S.detailUnit = card.utype; S.collectionView = "detail"; return
            end
        end
    end

    -- Deck builder taps
    if S.currentPanel == 2 then
        for i, rect in ipairs(S._deckSlotRects) do
            if x >= rect.x and x <= rect.x + rect.w and
               y >= rect.y and y <= rect.y + rect.h then
                AudioManager.playTap()
                S.selectedDeckSlot = i
                DeckManager.setActive(i)
                buildPreviewLayout()
                return
            end
        end
        for _, r in ipairs(S._deckCardRects) do
            if x >= r.x and x <= r.x + r.w and y >= r.y and y <= r.y + r.h then
                if r.action == "increase" then
                    local deck = DeckManager.getActiveDeck()
                    local total = 0
                    if deck then for _, c in pairs(deck.counts) do total = total + c end end
                    if total < 20 then
                        DeckManager.adjustCount(r.utype, 1)
                        DeckManager.save()
                        AudioManager.playTap()
                    end
                elseif r.action == "decrease" then
                    DeckManager.adjustCount(r.utype, -1)
                    DeckManager.save()
                    AudioManager.playTap()
                elseif r.action == "detail" and not S.hasMoved then
                    S.deckDetailUnit = r.utype
                    S.deckView = "detail"
                end
                return
            end
        end
        if S._deckSortRect then
            local r = S._deckSortRect
            if x >= r.x and x <= r.x + r.w and y >= r.y and y <= r.y + r.h then
                S._deckSortByCost = not S._deckSortByCost
                AudioManager.playTap(); return
            end
        end
        if S._deckActiveRect then
            local r = S._deckActiveRect
            if x >= r.x and x <= r.x + r.w and y >= r.y and y <= r.y + r.h then
                DeckManager.setActive(S.selectedDeckSlot)
                DeckManager.save()
                buildPreviewLayout()
                AudioManager.playTap(); return
            end
        end
    end

    -- Ranking: private room JOIN button
    if S.currentPanel == 4 then
        if S._roomKeyJoinRect then
            local r = S._roomKeyJoinRect
            if x >= r.x and x <= r.x + r.w and y >= r.y and y <= r.y + r.h then
                tryJoinPrivateRoom(); return
            end
        end
        if S._roomKeyRect then
            local r = S._roomKeyRect
            if x >= r.x and x <= r.x + r.w and y >= r.y and y <= r.y + r.h then
                S._roomKeyActive = true
                if scene._roomKeyField then native.setKeyboardFocus(scene._roomKeyField) end
                return
            end
        end
        -- Tap outside room key field: dismiss keyboard
        S._roomKeyActive = false
        if scene._roomKeyField then native.setKeyboardFocus(nil) end
    end

    -- Play Online button
    if S.currentPanel == 3 then
        local btn = S._playBtnRect
        if btn and x >= btn.x and x <= btn.x + btn.w and y >= btn.y and y <= btn.y + btn.h then
            AudioManager.playTap()
            if _G.GameSocket and _G.GameSocket:isConnected() then
                removeSocketHandlers()
                local sock = _G.GameSocket
                startExitAnim(function()
                    composer.gotoScene("src.screens.lobby", {params = {client = sock}})
                end)
            elseif _G.GameSocket then
                startReconnect()
            else
                startExitAnim(function()
                    composer.gotoScene("src.screens.login", {effect = "fade", time = 300})
                end)
            end
            return
        end
        local sbtn = S._sandboxBtnRect
        if sbtn and x >= sbtn.x and x <= sbtn.x + sbtn.w and y >= sbtn.y and y <= sbtn.y + sbtn.h then
            AudioManager.playTap()
            startExitAnim(function()
                composer.gotoScene("src.screens.game", {
                    params = {isOnline = false, playerRole = 1, isSandbox = false, isTutorial = true}
                })
            end)
            return
        end
    end
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
        if _G.GameSocket and not _G.GameSocket:isConnected() and not S._reconnecting then
            print("[MENU] Socket lost while backgrounded, reconnecting...")
            startReconnect()
        end
    end
end

-- ── Room key text field input ─────────────────────────────────────────────────

local function onRoomKeyInput(event)
    if event.phase == "editing" then
        local text = event.text or ""
        -- Filter to alphanumeric, uppercase, max 12 chars
        local filtered = text:upper():gsub("[^%w]", ""):sub(1, 12)
        S._roomKeyText = filtered
        if event.target then event.target.text = filtered end
    elseif event.phase == "submitted" then
        tryJoinPrivateRoom()
    end
end

-- ── Composer scene lifecycle ──────────────────────────────────────────────────

function scene:create(event)
    local group = self.view

    -- Placeholder background (TODO-RENDER: scrolling panel strip)
    local bg = display.newRect(group, display.contentCenterX, display.contentCenterY,
                               display.contentWidth, display.contentHeight)
    bg:setFillColor(0.031, 0.078, 0.118)

    -- Placeholder bottom bar (TODO-RENDER: tab icons + raised active tab)
    local sc     = Constants.SCALE
    local barH   = 100 * sc + (Constants.SAFE_INSET_BOTTOM or 0)
    local barBg  = display.newRect(group, display.contentCenterX,
                                   display.contentHeight - barH / 2,
                                   display.contentWidth, barH)
    barBg:setFillColor(0.031, 0.078, 0.118)
    self._barBg = barBg

    -- Room key text field (hidden until ranking panel, tapped on the key slot)
    local field = native.newTextField(
        display.contentCenterX,
        display.contentHeight * 0.55,
        200 * sc, 40 * sc
    )
    field.isVisible       = false
    field.inputType       = "keyboard"
    field.returnKey       = "go"
    field:addEventListener("userInput", onRoomKeyInput)
    self._roomKeyField = field
end

function scene:show(event)
    if event.phase ~= "did" then return end
    local p       = event.params or {}
    local entering = p.entering
    initState(entering)
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
    if self._roomKeyField then
        native.setKeyboardFocus(nil)
        self._roomKeyField.isVisible = false
    end
end

function scene:destroy(event)
    removeSocketHandlers()
    if self._roomKeyField then
        self._roomKeyField:removeEventListener("userInput", onRoomKeyInput)
        display.remove(self._roomKeyField)
        self._roomKeyField = nil
    end
end

scene:addEventListener("create",  scene)
scene:addEventListener("show",    scene)
scene:addEventListener("hide",    scene)
scene:addEventListener("destroy", scene)

return scene
