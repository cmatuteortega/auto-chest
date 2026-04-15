-- AutoChest – Loading / Auto-Auth Screen (Solar2D composer scene)
-- Reads saved session token, connects to server, and auto-authenticates.
-- On success: sets _G.PlayerData + _G.GameSocket, navigates to menu.
-- On failure/timeout: deletes token and falls back to login screen.

local composer  = require("composer")
local Constants = require("src.constants")
local config    = require("src.config")
local sock      = require("lib.tcp_client")
local json      = require("lib.json")

local scene = composer.newScene()
local S     = {}

-- ── Helpers ───────────────────────────────────────────────────────────────────

local function fallbackToLogin(reason)
    if S._failed then return end   -- guard against double-trigger
    S._failed   = true
    S.status    = "failed"
    S.statusMsg = reason or "Login failed"
    _G.deleteFile("session.dat")
    timer.performWithDelay(1000, function()
        composer.gotoScene("src.screens.login", {effect = "fade", time = 300})
    end)
end

local function connectToServer()
    S.client = sock.newClient(config.SERVER_ADDRESS, config.SERVER_PORT)

    S.client:on("connect", function()
        S.status    = "authing"
        S.statusMsg = "Authenticating..."
        S.client:send("reconnect_with_token", {
            token     = S.token,
            device_id = _G.DeviceId or ""
        })
    end)

    S.client:on("disconnect", function()
        if S.status ~= "success" then
            fallbackToLogin("Disconnected from server")
        end
    end)

    S.client:on("login_success", function(data)
        S.status = "success"

        _G.PlayerData = {
            id              = data.player_id,
            username        = data.username,
            trophies        = data.trophies,
            coins           = data.coins,
            gold            = data.gold   or 0,
            gems            = data.gems   or 0,
            xp              = data.xp     or 0,
            level           = data.level  or 1,
            activeDeckIndex = data.active_deck_index,
            decks           = data.decks,
            token           = data.token,
            unlocks         = data.unlocks,
        }
        _G.GameSocket = S.client

        -- Persist refreshed token
        local encoded = json.encode({token = data.token, username = data.username})
        _G.writeFile("session.dat", encoded)

        composer.gotoScene("src.screens.menu", {effect = "fade", time = 300})
    end)

    S.client:on("login_failed", function(data)
        fallbackToLogin(data.reason or "Session expired")
    end)

    S.client:connect()
end

-- ── Update loop ───────────────────────────────────────────────────────────────

local function onUpdate(event)
    if S.client then
        local ok, err = pcall(function() S.client:update() end)
        if not ok then
            print("[LOADING] client:update error: " .. tostring(err))
        end
    end

    local now = event.time / 1000
    local dt  = now - (S._lastTime or now)
    S._lastTime = now

    if S.status == "connecting" or S.status == "authing" then
        S.elapsed = S.elapsed + dt
        if S.elapsed >= S.TIMEOUT then
            fallbackToLogin("Connection timed out")
            return
        end
    end

    -- Dots animation
    S.dotTimer = S.dotTimer + dt
    if S.dotTimer >= 0.4 then
        S.dotTimer = 0
        S.dotCount = (S.dotCount + 1) % 4
    end

    -- TODO-RENDER: update spinner rotation (getTime() * math.pi), status label, dots
end

-- ── Input ─────────────────────────────────────────────────────────────────────

local function onTouch(event)
    if event.phase == "ended" then
        local x, y = event.x, event.y
        if S._switchRect then
            local r = S._switchRect
            if x >= r.x and x <= r.x + r.w and y >= r.y and y <= r.y + r.h then
                _G.deleteFile("session.dat")
                if S.client then pcall(function() S.client:disconnect() end) end
                composer.gotoScene("src.screens.login", {effect = "fade", time = 300})
                return true
            end
        end
    end
    return false
end

-- ── Composer lifecycle ────────────────────────────────────────────────────────

function scene:create(event)
    local group = self.view
    -- Placeholder background (TODO-RENDER: dark background matching login)
    local bg = display.newRect(group,
                               display.contentCenterX, display.contentCenterY,
                               display.contentWidth,   display.contentHeight)
    bg:setFillColor(0.031, 0.078, 0.118)
    -- TODO-RENDER: "AutoChest" title, spinner arc, username label, status text
end

function scene:show(event)
    if event.phase ~= "did" then return end

    S = {
        status         = "connecting",
        statusMsg      = "Connecting...",
        client         = nil,
        elapsed        = 0,
        TIMEOUT        = 5,
        dotTimer       = 0,
        dotCount       = 0,
        _switchRect    = nil,
        token          = nil,
        storedUsername = nil,
        _lastTime      = system.getTimer() / 1000,
        _failed        = false,
    }

    -- Parse session.dat (JSON {token, username})
    local raw = _G.readFile("session.dat") or ""
    local ok, parsed = pcall(json.decode, raw)
    if ok and parsed and parsed.token then
        S.token          = parsed.token
        S.storedUsername = parsed.username
    else
        -- Corrupt or old-format session — go straight to login
        _G.deleteFile("session.dat")
        composer.gotoScene("src.screens.login", {effect = "fade", time = 300})
        return
    end

    Runtime:addEventListener("enterFrame", onUpdate)
    Runtime:addEventListener("touch",      onTouch)
    connectToServer()
end

function scene:hide(event)
    if event.phase ~= "will" then return end
    Runtime:removeEventListener("enterFrame", onUpdate)
    Runtime:removeEventListener("touch",      onTouch)
    if S.client and S.status ~= "success" then
        pcall(function() S.client:disconnect() end)
    end
end

function scene:destroy(event)
    -- nothing to clean up beyond hide
end

scene:addEventListener("create",  scene)
scene:addEventListener("show",    scene)
scene:addEventListener("hide",    scene)
scene:addEventListener("destroy", scene)

return scene
