-- AutoChest – Login Screen (Solar2D composer scene)
--
-- Replaces the Love2D Screen-based login.lua.
-- • Custom input fields replaced with native.newTextField (mobile keyboard built-in)
-- • love.graphics.* replaced with display objects
-- • sock.lua replaced with lib/tcp_client.lua (same public API)
-- • love.filesystem replaced with _G.readFile / _G.writeFile (set in main.lua)

local composer     = require("composer")
local Constants    = require("src.constants")
local config       = require("src.config")
local sock         = require("lib.tcp_client")   -- drop-in for lib/sock
local json         = require("lib.json")

local scene = composer.newScene()

-- ── Helpers ───────────────────────────────────────────────────────────────────

local function makeButton(group, label, x, y, w, h, font, enabled)
    local btn = display.newGroup()
    group:insert(btn)
    btn.x, btn.y = x + w / 2, y + h / 2

    local bg = display.newRoundedRect(btn, 0, 0, w, h, 8 * Constants.SCALE)
    if enabled then
        bg:setFillColor(0.15, 0.32, 0.65)
        bg:setStrokeColor(0.25, 0.45, 0.85)
    else
        bg:setFillColor(0.12, 0.12, 0.18)
        bg:setStrokeColor(0.22, 0.22, 0.30)
    end
    bg.strokeWidth = 2 * Constants.SCALE

    local lbl = display.newText({
        parent   = btn,
        text     = label,
        x        = 0,
        y        = 0,
        font     = font.name,
        fontSize = font.size,
    })
    lbl:setFillColor(enabled and 1 or 0.4, enabled and 1 or 0.4, enabled and 1 or (enabled and 1 or 0.45))

    return btn, bg, lbl
end

-- ── Scene lifecycle ───────────────────────────────────────────────────────────

function scene:create(event)
    local group = self.view
    local W     = Constants.GAME_WIDTH
    local H     = Constants.GAME_HEIGHT
    local sc    = Constants.SCALE

    -- Background
    local bg = display.newRect(group, W / 2, H / 2, W, H)
    local c  = Constants.COLORS.BACKGROUND
    bg:setFillColor(c[1], c[2], c[3])

    -- Title
    self._titleLbl = display.newText({
        parent   = group,
        text     = "AutoChest",
        x        = W / 2,
        y        = H * 0.13,
        font     = Fonts.large.name,
        fontSize = Fonts.large.size,
        align    = "center",
    })
    self._titleLbl:setFillColor(1, 1, 1)

    -- Status message
    self._statusLbl = display.newText({
        parent   = group,
        text     = "Connecting to server...",
        x        = W / 2,
        y        = H * 0.13 + Fonts.large.size + 20 * sc,
        font     = Fonts.small.name,
        fontSize = Fonts.small.size,
        align    = "center",
    })
    self._statusLbl:setFillColor(0.7, 0.7, 0.7)

    -- ── Input fields (native text fields handle the mobile keyboard) ──────────
    local fieldW  = 300 * sc
    local fieldH  = 50  * sc
    local fieldX  = W / 2 - fieldW / 2     -- left edge in content coords
    local startY  = H * 0.32
    local fieldGap = 36 * sc

    -- Username label
    display.newText({
        parent   = group,
        text     = "Username",
        x        = fieldX,
        y        = startY - Fonts.small.size - 8 * sc,
        font     = Fonts.small.name,
        fontSize = Fonts.small.size,
        align    = "left",
    }):setFillColor(0.65, 0.65, 0.7)

    -- Username field
    self._userField = native.newTextField(
        fieldX + fieldW / 2,            -- center x
        startY + fieldH / 2,            -- center y
        fieldW,
        fieldH
    )
    self._userField.font         = native.newFont(Fonts.small.name, Fonts.small.size)
    self._userField.placeholder  = ""
    self._userField.inputType    = "default"
    self._userField.hasBackground = false
    -- Visual background behind native field
    local userBg = display.newRoundedRect(group,
        fieldX + fieldW / 2, startY + fieldH / 2, fieldW, fieldH, 5 * sc)
    userBg:setFillColor(0.16, 0.16, 0.22)
    userBg:setStrokeColor(0.32, 0.32, 0.42)
    userBg.strokeWidth = 2 * sc
    -- Native field must be inserted AFTER background rect so it renders on top
    -- (Solar2D native objects are always above display objects)

    -- Password label
    local passY = startY + fieldH + fieldGap
    display.newText({
        parent   = group,
        text     = "Password",
        x        = fieldX,
        y        = passY - Fonts.small.size - 8 * sc,
        font     = Fonts.small.name,
        fontSize = Fonts.small.size,
        align    = "left",
    }):setFillColor(0.65, 0.65, 0.7)

    -- Password field
    self._passField = native.newTextField(
        fieldX + fieldW / 2,
        passY + fieldH / 2,
        fieldW,
        fieldH
    )
    self._passField.font         = native.newFont(Fonts.small.name, Fonts.small.size)
    self._passField.placeholder  = ""
    self._passField.inputType    = "password"
    self._passField.hasBackground = false
    local passBg = display.newRoundedRect(group,
        fieldX + fieldW / 2, passY + fieldH / 2, fieldW, fieldH, 5 * sc)
    passBg:setFillColor(0.16, 0.16, 0.22)
    passBg:setStrokeColor(0.32, 0.32, 0.42)
    passBg.strokeWidth = 2 * sc

    -- ── Buttons ───────────────────────────────────────────────────────────────
    local btnW   = 140 * sc
    local btnH   = 54  * sc
    local btnGap = 20  * sc
    local btnY   = passY + fieldH + 44 * sc
    local loginX    = W / 2 - btnW - btnGap / 2
    local registerX = W / 2 + btnGap / 2

    local loginBtn, loginBg, loginLbl = makeButton(
        group, "Login", loginX, btnY, btnW, btnH, Fonts.medium, false)
    local regBtn, regBg, regLbl = makeButton(
        group, "Register", registerX, btnY, btnW, btnH, Fonts.medium, false)

    self._loginBtn    = loginBtn
    self._loginBg     = loginBg
    self._loginLbl    = loginLbl
    self._regBtn      = regBtn
    self._regBg       = regBg
    self._regLbl      = regLbl
    self._btnY        = btnY
    self._btnW        = btnW
    self._btnH        = btnH
    self._loginX      = loginX
    self._registerX   = registerX
    self._fieldsVisible = false

    -- Hide fields until connected
    self._userField.isVisible = false
    self._passField.isVisible = false
    loginBtn.isVisible = false
    regBtn.isVisible   = false
end

function scene:show(event)
    if event.phase ~= "did" then return end

    self._status = "connecting"
    self:_connectToServer()

    -- Poll network every frame
    self._frameListener = Runtime:addEventListener("enterFrame", function()
        if self._client then self._client:update() end
    end)

    -- Watch text fields to enable/disable buttons
    local function onFieldEdit(e)
        self:_updateButtonState()
    end
    self._userField:addEventListener("userInput", onFieldEdit)
    self._passField:addEventListener("userInput", onFieldEdit)

    -- Touch listener for buttons
    self._touchListener = Runtime:addEventListener("touch", function(e)
        if e.phase ~= "ended" then return end
        self:_handleTouch(e.x, e.y)
    end)
end

function scene:hide(event)
    if event.phase ~= "will" then return end

    Runtime:removeEventListener("enterFrame", self._frameListener)
    Runtime:removeEventListener("touch", self._touchListener)

    -- Hide native fields (they float above composer scenes)
    self._userField.isVisible = false
    self._passField.isVisible = false
    native.setKeyboardFocus(nil)
end

function scene:destroy(event)
    if self._client and self._status ~= "logged_in" then
        self._client:disconnect()
    end
    if self._userField then self._userField:removeSelf(); self._userField = nil end
    if self._passField then self._passField:removeSelf(); self._passField = nil end
end

-- ── Network ───────────────────────────────────────────────────────────────────

function scene:_connectToServer()
    self._client = sock.newClient(config.SERVER_ADDRESS, config.SERVER_PORT)
    self._client:setSerialization(json.encode, json.decode)

    self._client:on("connect", function()
        self._status = "ready"
        self:_setStatus("Connected. Please log in.", 0.6, 1, 0.6)
        self:_showFields(true)
    end)

    self._client:on("disconnect", function()
        if self._status ~= "logged_in" then
            self._status = "error"
            self:_setStatus("Disconnected from server", 1, 0.4, 0.4)
        end
    end)

    self._client:on("connect_failed", function(data)
        self._status = "error"
        self:_setStatus("Cannot reach server", 1, 0.4, 0.4)
    end)

    self._client:on("login_success", function(data)
        self._status = "logged_in"
        self:_setStatus("Login successful!", 0.6, 1, 0.6)

        local playerData = {
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

        -- Persist session token
        if data.token and data.token ~= "" then
            _G.writeFile("session.dat", json.encode({
                token    = data.token,
                username = data.username,
            }))
        end

        _G.PlayerData  = playerData
        _G.GameSocket  = self._client

        -- Brief pause then navigate to menu
        timer.performWithDelay(500, function()
            composer.gotoScene("src.screens.menu", { effect = "fade", time = 300 })
        end)
    end)

    self._client:on("login_failed", function(data)
        self._status = "error"
        self:_setStatus(data.reason or "Login failed", 1, 0.4, 0.4)
    end)

    self._client:on("register_success", function()
        self._status = "ready"
        self:_setStatus("Account created! Please log in.", 0.6, 1, 0.6)
        self._userField.text = ""
        self._passField.text = ""
        self:_updateButtonState()
    end)

    self._client:on("register_failed", function(data)
        self._status = "error"
        self:_setStatus(data.reason or "Registration failed", 1, 0.4, 0.4)
    end)

    self._client:connect()
end

-- ── UI helpers ────────────────────────────────────────────────────────────────

function scene:_setStatus(msg, r, g, b)
    if self._statusLbl then
        self._statusLbl.text = msg
        self._statusLbl:setFillColor(r, g, b)
    end
end

function scene:_showFields(visible)
    self._fieldsVisible = visible
    self._userField.isVisible = visible
    self._passField.isVisible = visible
    self._loginBtn.isVisible  = visible
    self._regBtn.isVisible    = visible
end

function scene:_updateButtonState()
    local user = self._userField.text or ""
    local pass = self._passField.text or ""
    local enabled = #user > 0 and #pass > 0

    if enabled then
        self._loginBg:setFillColor(0.15, 0.32, 0.65)
        self._loginBg:setStrokeColor(0.25, 0.45, 0.85)
        self._loginLbl:setFillColor(1, 1, 1)
        self._regBg:setFillColor(0.15, 0.45, 0.25)
        self._regBg:setStrokeColor(0.25, 0.65, 0.40)
        self._regLbl:setFillColor(1, 1, 1)
    else
        self._loginBg:setFillColor(0.12, 0.12, 0.18)
        self._loginBg:setStrokeColor(0.22, 0.22, 0.30)
        self._loginLbl:setFillColor(0.4, 0.4, 0.45)
        self._regBg:setFillColor(0.12, 0.12, 0.18)
        self._regBg:setStrokeColor(0.22, 0.22, 0.30)
        self._regLbl:setFillColor(0.4, 0.4, 0.45)
    end
    self._canSubmit = enabled
end

function scene:_handleTouch(x, y)
    if not self._fieldsVisible or not self._canSubmit then return end

    -- Dismiss keyboard first
    native.setKeyboardFocus(nil)

    local function hitTest(btn)
        -- btn.x/y is the center of the button group in content coords
        local hw = self._btnW / 2
        local hh = self._btnH / 2
        return x >= btn.x - hw and x <= btn.x + hw
           and y >= btn.y - hh and y <= btn.y + hh
    end

    if hitTest(self._loginBtn) then
        AudioManager.playTap()
        self:_doLogin()
    elseif hitTest(self._regBtn) then
        AudioManager.playTap()
        self:_doRegister()
    end
end

function scene:_doLogin()
    if not self._client or self._status == "connecting" then return end
    self._status = "connecting"
    self:_setStatus("Logging in...", 0.7, 0.7, 0.7)
    self._client:send("login", {
        username  = self._userField.text,
        password  = self._passField.text,
        device_id = _G.DeviceId or "",
    })
end

function scene:_doRegister()
    if not self._client or self._status == "connecting" then return end
    self._status = "connecting"
    self:_setStatus("Creating account...", 0.7, 0.7, 0.7)
    self._client:send("register", {
        username  = self._userField.text,
        password  = self._passField.text,
        device_id = _G.DeviceId or "",
    })
end

-- ── Register lifecycle events ─────────────────────────────────────────────────
scene:addEventListener("create",  scene)
scene:addEventListener("show",    scene)
scene:addEventListener("hide",    scene)
scene:addEventListener("destroy", scene)

return scene
