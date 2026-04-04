-- AutoChest – Login Screen
-- Handles player authentication and connects to the game server

local Screen    = require('lib.screen')
local Constants = require('src.constants')
local config    = require('src.config')
local sock      = require('lib.sock')
local json      = require('lib.json')

local LoginScreen = {}

function LoginScreen.new()
    local self = Screen.new()

    -- ── init ────────────────────────────────────────────────────────────────

    function self:init()
        -- Input fields
        self.usernameText = ""
        self.passwordText = ""
        self.activeField = "username"  -- "username", "password", or nil

        -- Status
        self.status = "connecting"  -- connecting, ready, error
        self.statusMessage = "Connecting to server..."

        -- Network
        self.client = nil
        self.playerData = nil  -- {id, username, trophies, coins, deck, token}

        -- Cursor animation
        self.cursorTimer = 0
        self.cursorVisible = true

        -- Hit rects (rebuilt each draw)
        self._usernameRect = nil
        self._passwordRect = nil
        self._loginBtnRect = nil
        self._registerBtnRect = nil

        -- Connect to server
        self:connectToServer()

        love.keyboard.setKeyRepeat(true)
    end

    function self:close()
        love.keyboard.setKeyRepeat(false)
        love.keyboard.setTextInput(false)  -- Close mobile keyboard
        -- Only disconnect if not logged in successfully
        if self.client and self.status ~= "logged_in" then
            self.client:disconnect()
        end
    end

    function self:connectToServer()
        self.client = sock.newClient(config.SERVER_ADDRESS, config.SERVER_PORT)
        self.client:setSerialization(json.encode, json.decode)

        self.client:on("connect", function()
            self.status = "ready"
            self.statusMessage = "Connected. Please log in."
        end)

        self.client:on("disconnect", function()
            if self.status ~= "logged_in" then
                self.status = "error"
                self.statusMessage = "Disconnected from server"
            end
        end)

        self.client:on("login_success", function(data)
            print("[LOGIN] gold=" .. tostring(data.gold) .. " gems=" .. tostring(data.gems))
            self.playerData = {
                id = data.player_id,
                username = data.username,
                trophies = data.trophies,
                coins = data.coins,
                gold = data.gold or 0,
                gems = data.gems or 0,
                xp = data.xp or 0,
                level = data.level or 1,
                activeDeckIndex = data.active_deck_index,
                decks = data.decks,
                token = data.token
            }
            self.status = "logged_in"
            self.statusMessage = "Login successful!"

            -- Persist session as JSON {token, username} for auto-login on next launch
            if data.token and data.token ~= "" then
                love.filesystem.write("session.dat", json.encode({
                    token    = data.token,
                    username = data.username,
                }))
            end

            -- Store player data and socket globally for other screens
            _G.PlayerData = self.playerData
            _G.GameSocket = self.client

            -- Wait a moment then switch to menu
            love.timer.sleep(0.5)
            local ScreenManager = require('lib.screen_manager')
            ScreenManager.switch('menu')
        end)

        self.client:on("login_failed", function(data)
            self.status = "error"
            self.statusMessage = data.reason or "Login failed"
        end)

        self.client:on("register_success", function(data)
            self.status = "ready"
            self.statusMessage = "Registration successful! Please log in."
            self.usernameText = ""
            self.passwordText = ""
        end)

        self.client:on("register_failed", function(data)
            self.status = "error"
            self.statusMessage = data.reason or "Registration failed"
        end)

        self.client:connect()
        -- Generous timeout so brief interruptions (notification, quick app switch) don't kill the socket
        self.client:setTimeout(32, 5000, 60000)
    end

    -- ── update ──────────────────────────────────────────────────────────────

    function self:update(dt)
        if self.client then
            self.client:update()
        end

        -- Cursor blink
        self.cursorTimer = self.cursorTimer + dt
        if self.cursorTimer >= 0.5 then
            self.cursorTimer = 0
            self.cursorVisible = not self.cursorVisible
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

    local function textCY(font, boxY, boxH)
        return math.floor(boxY + (boxH - (font:getAscent() - font:getDescent())) / 2)
    end

    -- ── draw ────────────────────────────────────────────────────────────────

    function self:draw()
        local lg = love.graphics
        local W  = Constants.GAME_WIDTH
        local H  = Constants.GAME_HEIGHT
        local sc = Constants.SCALE
        local cx = W / 2

        lg.clear(Constants.COLORS.BACKGROUND)

        -- Title
        lg.setFont(Fonts.large)
        lg.setColor(1, 1, 1, 1)
        lg.printf("AutoChest", 0, H * 0.10, W, 'center')

        -- Status message
        lg.setFont(Fonts.small)
        if self.status == "error" then
            lg.setColor(1, 0.4, 0.4, 1)
        elseif self.status == "connecting" then
            lg.setColor(0.7, 0.7, 0.7, 1)
        else
            lg.setColor(0.6, 1, 0.6, 1)
        end
        lg.printf(self.statusMessage, 0, H * 0.10 + Fonts.large:getHeight() + 20 * sc, W, 'center')

        -- Only show input fields if connected
        if self.status ~= "connecting" and self.status ~= "logged_in" then
            local fieldW   = 300 * sc
            local fieldH   = 50 * sc
            local fieldX   = cx - fieldW / 2
            local labelGap = 8 * sc   -- space between label and field above it
            local fieldGap = 36 * sc  -- space between bottom of one field and label of next
            local textPad  = 12 * sc

            local startY = H * 0.32

            -- ── Username ──────────────────────────────────────────────────────
            local usernameY = startY
            lg.setFont(Fonts.small)
            lg.setColor(0.65, 0.65, 0.7, 1)
            lg.print("Username", fieldX, usernameY - Fonts.small:getHeight() - labelGap)

            local active = (self.activeField == "username")
            lg.setColor(active and {0.22, 0.22, 0.32, 1} or {0.16, 0.16, 0.22, 1})
            roundedRect(fieldX, usernameY, fieldW, fieldH, 5, sc)
            lg.setColor(active and {0.5, 0.5, 0.8, 1} or {0.32, 0.32, 0.42, 1})
            roundedRectLine(fieldX, usernameY, fieldW, fieldH, 5, sc, 2 * sc)

            lg.setFont(Fonts.small)
            lg.setColor(1, 1, 1, 1)
            local textY = textCY(Fonts.small, usernameY, fieldH)
            lg.print(self.usernameText, fieldX + textPad, textY)

            if active and self.cursorVisible then
                local tw = Fonts.small:getWidth(self.usernameText)
                lg.setColor(1, 1, 1, 0.85)
                lg.rectangle('fill', fieldX + textPad + tw + 1, textY + 2 * sc,
                             2 * sc, Fonts.small:getHeight() - 4 * sc)
            end

            self._usernameRect = {x = fieldX, y = usernameY, w = fieldW, h = fieldH}

            -- ── Password ──────────────────────────────────────────────────────
            local passwordY = usernameY + fieldH + fieldGap
            lg.setFont(Fonts.small)
            lg.setColor(0.65, 0.65, 0.7, 1)
            lg.print("Password", fieldX, passwordY - Fonts.small:getHeight() - labelGap)

            active = (self.activeField == "password")
            lg.setColor(active and {0.22, 0.22, 0.32, 1} or {0.16, 0.16, 0.22, 1})
            roundedRect(fieldX, passwordY, fieldW, fieldH, 5, sc)
            lg.setColor(active and {0.5, 0.5, 0.8, 1} or {0.32, 0.32, 0.42, 1})
            roundedRectLine(fieldX, passwordY, fieldW, fieldH, 5, sc, 2 * sc)

            lg.setFont(Fonts.small)
            lg.setColor(1, 1, 1, 1)
            local maskedPassword = string.rep("*", #self.passwordText)
            textY = textCY(Fonts.small, passwordY, fieldH)
            lg.print(maskedPassword, fieldX + textPad, textY)

            if active and self.cursorVisible then
                local tw = Fonts.small:getWidth(maskedPassword)
                lg.setColor(1, 1, 1, 0.85)
                lg.rectangle('fill', fieldX + textPad + tw + 1, textY + 2 * sc,
                             2 * sc, Fonts.small:getHeight() - 4 * sc)
            end

            self._passwordRect = {x = fieldX, y = passwordY, w = fieldW, h = fieldH}

            -- ── Buttons ───────────────────────────────────────────────────────
            local btnW = 140 * sc
            local btnH = 54 * sc
            local btnGap = 20 * sc
            local btnY = passwordY + fieldH + 44 * sc
            local loginX    = cx - btnW - btnGap / 2
            local registerX = cx + btnGap / 2

            local canLogin = #self.usernameText > 0 and #self.passwordText > 0

            -- Login button
            if canLogin then
                lg.setColor(0.15, 0.32, 0.65, 1)
                roundedRect(loginX, btnY, btnW, btnH, 8, sc)
                lg.setColor(0.25, 0.45, 0.85, 1)
                roundedRectLine(loginX, btnY, btnW, btnH, 8, sc, 2 * sc)
            else
                lg.setColor(0.12, 0.12, 0.18, 1)
                roundedRect(loginX, btnY, btnW, btnH, 8, sc)
                lg.setColor(0.22, 0.22, 0.30, 1)
                roundedRectLine(loginX, btnY, btnW, btnH, 8, sc, 2 * sc)
            end
            lg.setFont(Fonts.medium)
            lg.setColor(canLogin and {1, 1, 1, 1} or {0.4, 0.4, 0.45, 1})
            lg.printf("Login", loginX, textCY(Fonts.medium, btnY, btnH), btnW, 'center')
            self._loginBtnRect = canLogin and {x = loginX, y = btnY, w = btnW, h = btnH} or nil

            -- Register button
            if canLogin then
                lg.setColor(0.15, 0.45, 0.25, 1)
                roundedRect(registerX, btnY, btnW, btnH, 8, sc)
                lg.setColor(0.25, 0.65, 0.40, 1)
                roundedRectLine(registerX, btnY, btnW, btnH, 8, sc, 2 * sc)
            else
                lg.setColor(0.12, 0.12, 0.18, 1)
                roundedRect(registerX, btnY, btnW, btnH, 8, sc)
                lg.setColor(0.22, 0.22, 0.30, 1)
                roundedRectLine(registerX, btnY, btnW, btnH, 8, sc, 2 * sc)
            end
            lg.setFont(Fonts.medium)
            lg.setColor(canLogin and {1, 1, 1, 1} or {0.4, 0.4, 0.45, 1})
            lg.printf("Register", registerX, textCY(Fonts.medium, btnY, btnH), btnW, 'center')
            self._registerBtnRect = canLogin and {x = registerX, y = btnY, w = btnW, h = btnH} or nil
        end
    end

    -- ── input ───────────────────────────────────────────────────────────────

    function self:mousepressed(x, y, button)
        if button ~= 1 then return end

        -- Check field taps
        if self._usernameRect then
            local r = self._usernameRect
            if x >= r.x and x <= r.x + r.w and y >= r.y and y <= r.y + r.h then
                self.activeField = "username"
                self.status = "ready"
                -- Open mobile keyboard
                love.keyboard.setTextInput(true, r.x, r.y, r.w, r.h)
                return
            end
        end
        if self._passwordRect then
            local r = self._passwordRect
            if x >= r.x and x <= r.x + r.w and y >= r.y and y <= r.y + r.h then
                self.activeField = "password"
                self.status = "ready"
                -- Open mobile keyboard
                love.keyboard.setTextInput(true, r.x, r.y, r.w, r.h)
                return
            end
        end

        -- Check button taps
        if self._loginBtnRect then
            local r = self._loginBtnRect
            if x >= r.x and x <= r.x + r.w and y >= r.y and y <= r.y + r.h then
                AudioManager.playTap()
                -- Close keyboard before login
                love.keyboard.setTextInput(false)
                self:doLogin()
                return
            end
        end
        if self._registerBtnRect then
            local r = self._registerBtnRect
            if x >= r.x and x <= r.x + r.w and y >= r.y and y <= r.y + r.h then
                AudioManager.playTap()
                -- Close keyboard before register
                love.keyboard.setTextInput(false)
                self:doRegister()
                return
            end
        end

        -- Tap elsewhere deactivates and closes keyboard
        self.activeField = nil
        love.keyboard.setTextInput(false)
    end

    function self:touchpressed(_, x, y)
        self:mousepressed(x, y, 1)
    end

    function self:textinput(t)
        if not self.activeField then return end

        if self.activeField == "username" then
            -- Only allow alphanumeric and underscore for username
            if t:match("^[%w_]+$") then
                self.usernameText = self.usernameText .. t
            end
        elseif self.activeField == "password" then
            self.passwordText = self.passwordText .. t
        end
    end

    function self:keypressed(key)
        if key == "escape" then
            self.activeField = nil
            love.keyboard.setTextInput(false)
            return
        end

        if not self.activeField then return end

        if key == "backspace" then
            if self.activeField == "username" then
                self.usernameText = self.usernameText:sub(1, -2)
            elseif self.activeField == "password" then
                self.passwordText = self.passwordText:sub(1, -2)
            end
        elseif key == "tab" then
            -- Switch fields - update keyboard position for mobile
            if self.activeField == "username" and self._passwordRect then
                self.activeField = "password"
                local r = self._passwordRect
                love.keyboard.setTextInput(true, r.x, r.y, r.w, r.h)
            elseif self._usernameRect then
                self.activeField = "username"
                local r = self._usernameRect
                love.keyboard.setTextInput(true, r.x, r.y, r.w, r.h)
            end
        elseif key == "return" or key == "kpenter" then
            -- Submit login and close keyboard
            if #self.usernameText > 0 and #self.passwordText > 0 then
                love.keyboard.setTextInput(false)
                self:doLogin()
            end
        end
    end

    function self:doLogin()
        if not self.client or self.status == "connecting" then return end

        self.status = "connecting"
        self.statusMessage = "Logging in..."
        self.client:send("login", {
            username  = self.usernameText,
            password  = self.passwordText,
            device_id = _G.DeviceId or ""
        })
    end

    function self:doRegister()
        if not self.client or self.status == "connecting" then return end

        self.status = "connecting"
        self.statusMessage = "Creating account..."
        self.client:send("register", {
            username  = self.usernameText,
            password  = self.passwordText,
            device_id = _G.DeviceId or ""
        })
    end

    return self
end

return LoginScreen
