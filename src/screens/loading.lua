-- AutoChest – Loading / Auto-Auth Screen
-- Reads saved session token, connects to server, and auto-authenticates.
-- On success: sets globals and switches to menu.
-- On failure/timeout: deletes token and falls back to login screen.

local Screen    = require('lib.screen')
local Constants = require('src.constants')
local config    = require('src.config')
local sock      = require('lib.sock')
local json      = require('lib.json')

local LoadingScreen = {}

function LoadingScreen.new()
    local self = Screen.new()

    function self:init()
        -- Always initialize state first (update/draw may fire before screen switch completes)
        self.status    = "connecting"
        self.statusMsg = "Connecting..."
        self.client    = nil
        self.elapsed   = 0
        self.TIMEOUT   = 5
        self.dotTimer  = 0
        self.dotCount  = 0
        self._switchRect = nil
        self.token          = nil
        self.storedUsername  = nil

        -- Parse session.dat as JSON {token, username}
        local raw = love.filesystem.read("session.dat") or ""
        local ok, parsed = pcall(json.decode, raw)
        if ok and parsed and parsed.token then
            self.token          = parsed.token
            self.storedUsername  = parsed.username
        else
            -- Invalid or old-format session file — force re-login
            love.filesystem.remove("session.dat")
            local ScreenManager = require('lib.screen_manager')
            ScreenManager.switch('login')
            return
        end

        self:connectToServer()
    end

    function self:close()
        if self.client and self.status ~= "success" then
            self.client:disconnect()
        end
    end

    function self:connectToServer()
        self.client = sock.newClient(config.SERVER_ADDRESS, config.SERVER_PORT)
        self.client:setSerialization(json.encode, json.decode)

        self.client:on("connect", function()
            self.status    = "authing"
            self.statusMsg = "Authenticating..."
            self.client:send("reconnect_with_token", {
                token     = self.token,
                device_id = _G.DeviceId or ""
            })
        end)

        self.client:on("disconnect", function()
            if self.status ~= "success" then
                self:fallbackToLogin("Disconnected from server")
            end
        end)

        self.client:on("login_success", function(data)
            self.status = "success"

            _G.PlayerData = {
                id              = data.player_id,
                username        = data.username,
                trophies        = data.trophies,
                coins           = data.coins,
                gold            = data.gold or 0,
                gems            = data.gems or 0,
                activeDeckIndex = data.active_deck_index,
                decks           = data.decks,
                token           = data.token
            }
            _G.GameSocket = self.client

            local ScreenManager = require('lib.screen_manager')
            ScreenManager.switch('menu')
        end)

        self.client:on("login_failed", function(data)
            love.filesystem.remove("session.dat")
            self:fallbackToLogin(data.reason or "Session expired")
        end)

        self.client:connect()
        self.client:setTimeout(32, 5000, 60000)
    end

    function self:fallbackToLogin(reason)
        self.status    = "failed"
        self.statusMsg = reason
        love.timer.sleep(1.0)
        local ScreenManager = require('lib.screen_manager')
        ScreenManager.switch('login')
    end

    function self:update(dt)
        if self.client then
            self.client:update()
        end

        if self.status == "connecting" or self.status == "authing" then
            self.elapsed = self.elapsed + dt
            if self.elapsed >= self.TIMEOUT then
                love.filesystem.remove("session.dat")
                self:fallbackToLogin("Connection timed out")
                return
            end
        end

        self.dotTimer = self.dotTimer + dt
        if self.dotTimer >= 0.4 then
            self.dotTimer = 0
            self.dotCount = (self.dotCount + 1) % 4
        end
    end

    -- Touch/click handling for "Switch Account" button
    function self:mousepressed(x, y)
        self._pressX = x
        self._pressY = y
    end

    function self:mousereleased(x, y)
        if self._switchRect then
            local r = self._switchRect
            if x >= r.x and x <= r.x + r.w and y >= r.y and y <= r.y + r.h then
                love.filesystem.remove("session.dat")
                if self.client then
                    pcall(function() self.client:disconnect() end)
                end
                local ScreenManager = require('lib.screen_manager')
                ScreenManager.switch('login')
                return
            end
        end
    end

    function self:touchpressed(_, x, y)  self:mousepressed(x, y) end
    function self:touchreleased(_, x, y) self:mousereleased(x, y) end

    function self:draw()
        local lg = love.graphics
        local W  = Constants.GAME_WIDTH
        local H  = Constants.GAME_HEIGHT
        local sc = Constants.SCALE

        lg.clear(Constants.COLORS.BACKGROUND)

        lg.setFont(Fonts.large)
        lg.setColor(1, 1, 1, 1)
        lg.printf("AutoChest", 0, H * 0.10, W, 'center')

        if self.status == "connecting" or self.status == "authing" then
            local angle    = love.timer.getTime() * math.pi
            local spinnerR = 40 * sc
            local cx, cy   = W / 2, H * 0.45

            lg.push()
            lg.translate(cx, cy)
            lg.rotate(angle)
            lg.setColor(0.5, 0.7, 1, 1)
            lg.setLineWidth(4 * sc)
            lg.arc('line', 'open', 0, 0, spinnerR, 0, math.pi * 1.5)
            lg.pop()
        end

        -- "Continuing as [username]" label
        if self.storedUsername and (self.status == "connecting" or self.status == "authing") then
            lg.setFont(Fonts.small)
            lg.setColor(0.7, 0.7, 0.75, 1)
            lg.printf("Continuing as " .. self.storedUsername, 0, H * 0.34, W, 'center')

            -- "Not you? Switch Account" tappable text
            lg.setFont(Fonts.tiny)
            lg.setColor(0.5, 0.65, 1, 1)
            local switchText = "Not you? Switch Account"
            local tw = Fonts.tiny:getWidth(switchText)
            local th = Fonts.tiny:getHeight()
            local tx = math.floor((W - tw) / 2)
            local ty = math.floor(H * 0.38)
            lg.print(switchText, tx, ty)
            self._switchRect = {x = tx, y = ty, w = tw, h = th}
        else
            self._switchRect = nil
        end

        local dots = string.rep(".", self.dotCount)
        lg.setFont(Fonts.medium)
        if self.status == "failed" then
            lg.setColor(1, 0.4, 0.4, 1)
        else
            lg.setColor(0.8, 0.8, 0.85, 1)
        end
        lg.printf(self.statusMsg .. dots, 0, H * 0.56, W, 'center')
    end

    return self
end

return LoadingScreen
