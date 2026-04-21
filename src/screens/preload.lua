-- AutoChest – Preload Splash
-- Loads sprites incrementally (one step per frame) while a progress bar draws,
-- and auto-authenticates in parallel. When both finish → menu.
-- Auth failures keep retrying silently (no name_entry fallback, to avoid
-- spawning duplicate profiles); only "no_device_profile" goes to name_entry,
-- since that is the legitimate new-user signup path.

local Screen       = require('lib.screen')
local Constants    = require('src.constants')
local UnitRegistry = require('src.unit_registry')
local sock         = require('lib.sock')
local json         = require('lib.json')
local config       = require('src.config')

local PreloadScreen = {}

function PreloadScreen.new()
    local self = Screen.new()

    function self:init()
        self.steps        = UnitRegistry.getLoadSteps()
        self.total        = #self.steps
        self.index        = 1
        self.spritesDone  = false
        self.warmup       = true

        self.authStatus     = "connecting"  -- connecting | authing | success | retrying | name_entry
        self.client         = nil
        self.elapsed        = 0
        self.TIMEOUT        = 5
        self.RETRY_DELAY    = 1.5
        self.retryTimer     = 0
        self.token          = nil
        self.storedUsername = nil
        self.authMode       = "device"
        self.advanced       = false

        local raw = love.filesystem.read("session.dat") or ""
        local ok, parsed = pcall(json.decode, raw)
        if ok and parsed and parsed.token then
            self.token          = parsed.token
            self.storedUsername = parsed.username
            self.authMode       = "token"
        else
            love.filesystem.remove("session.dat")
            self.authMode = "device"
        end

        self:connectToServer()
    end

    function self:close()
        if self.client and self.authStatus ~= "success" then
            pcall(function() self.client:disconnect() end)
        end
    end

    function self:scheduleRetry()
        if self.advanced then return end
        self.authStatus = "retrying"
        self.retryTimer = self.RETRY_DELAY
        self.elapsed    = 0
        if self.client then
            pcall(function() self.client:disconnect() end)
            self.client = nil
        end
    end

    function self:connectToServer()
        self.authStatus = "connecting"
        self.elapsed    = 0
        self.client = sock.newClient(config.SERVER_ADDRESS, config.SERVER_PORT)
        self.client:setSerialization(json.encode, json.decode)

        self.client:on("connect", function()
            self.authStatus = "authing"
            if self.authMode == "token" then
                self.client:send("reconnect_with_token", {
                    token     = self.token,
                    device_id = _G.DeviceId or ""
                })
            else
                self.client:send("login_with_device", {
                    device_id = _G.DeviceId or ""
                })
            end
        end)

        self.client:on("disconnect", function()
            if self.authStatus ~= "success" then
                self:scheduleRetry()
            end
        end)

        self.client:on("login_success", function(data)
            self.authStatus = "success"

            _G.PlayerData = {
                id              = data.player_id,
                username        = data.username,
                trophies        = data.trophies,
                coins           = data.coins,
                gold            = data.gold or 0,
                gems            = data.gems or 0,
                xp              = data.xp or 0,
                level           = data.level or 1,
                activeDeckIndex = data.active_deck_index,
                decks           = data.decks,
                token           = data.token,
                unlocks         = data.unlocks
            }
            _G.GameSocket = self.client

            if data.token and data.token ~= "" then
                love.filesystem.write("session.dat", json.encode({
                    token    = data.token,
                    username = data.username,
                }))
            end

            self:tryAdvance()
        end)

        self.client:on("login_failed", function(data)
            local reason = (data and data.reason) or "Login failed"

            if reason == "no_device_profile" then
                -- Brand-new device: legitimate signup flow.
                love.filesystem.remove("session.dat")
                self:gotoNameEntry()
            elseif self.authMode == "token" then
                -- Stale token; fall through to device-login, keep retrying from there.
                love.filesystem.remove("session.dat")
                self.token     = nil
                self.authMode  = "device"
                self.authStatus = "authing"
                self.elapsed   = 0
                self.client:send("login_with_device", {
                    device_id = _G.DeviceId or ""
                })
            else
                -- Generic failure (banned, server error, etc): keep trying.
                self:scheduleRetry()
            end
        end)

        self.client:connect()
        self.client:setTimeout(32, 5000, 60000)
    end

    function self:gotoNameEntry()
        if self.advanced then return end
        self.advanced = true
        if self.client then
            pcall(function() self.client:disconnect() end)
        end
        if not self.spritesDone then
            for i = self.index, self.total do
                local step = self.steps[i]
                if step then step() end
            end
            UnitRegistry.finalizeSprites()
            self.spritesDone = true
        end
        local ScreenManager = require('lib.screen_manager')
        ScreenManager.switch('name_entry')
    end

    function self:tryAdvance()
        if self.advanced then return end
        if self.spritesDone and self.authStatus == "success" then
            self.advanced = true
            local ScreenManager = require('lib.screen_manager')
            ScreenManager.switch('menu')
        end
    end

    function self:update(dt)
        if self.advanced then return end

        if self.client then
            self.client:update()
        end

        if self.authStatus == "retrying" then
            self.retryTimer = self.retryTimer - dt
            if self.retryTimer <= 0 then
                self:connectToServer()
            end
        elseif self.authStatus == "connecting" or self.authStatus == "authing" then
            self.elapsed = self.elapsed + dt
            if self.elapsed >= self.TIMEOUT then
                self:scheduleRetry()
            end
        end

        if not self.spritesDone then
            if self.warmup then
                self.warmup = false
            else
                local step = self.steps[self.index]
                if step then
                    step()
                    self.index = self.index + 1
                end
                if self.index > self.total then
                    UnitRegistry.finalizeSprites()
                    self.spritesDone = true
                    self:tryAdvance()
                end
            end
        end
    end

    function self:draw()
        local lg = love.graphics
        local W  = Constants.GAME_WIDTH
        local H  = Constants.GAME_HEIGHT
        local sc = Constants.SCALE

        lg.clear(Constants.COLORS.BACKGROUND)

        lg.setFont(Fonts.large)
        lg.setColor(1, 1, 1, 1)
        lg.printf("AutoChest", 0, H * 0.35, W, 'center')

        local barW  = W * 0.6
        local barH  = 16 * sc
        local barX  = (W - barW) / 2
        local barY  = H * 0.55
        local ratio = (self.index - 1) / math.max(1, self.total)
        if ratio < 0 then ratio = 0 end
        if ratio > 1 then ratio = 1 end

        lg.setColor(0.2, 0.25, 0.35, 1)
        lg.rectangle('fill', barX, barY, barW, barH)

        lg.setColor(0.5, 0.7, 1, 1)
        lg.rectangle('fill', barX, barY, barW * ratio, barH)

        lg.setColor(1, 1, 1, 1)
        lg.setLineWidth(2 * sc)
        lg.rectangle('line', barX, barY, barW, barH)

        lg.setFont(Fonts.small)
        lg.setColor(0.8, 0.8, 0.85, 1)
        lg.printf(string.format("%d%%", math.floor(ratio * 100 + 0.5)),
                  0, barY + barH + 10 * sc, W, 'center')
    end

    return self
end

return PreloadScreen
