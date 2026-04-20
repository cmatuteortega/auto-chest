-- AutoChest – Name Entry Screen
-- First-time onboarding: collect the player's display name and auto-register
-- the device. Runs once per device (re-entry is handled idempotently by the
-- server — submitting a name for a device that already has a profile reuses it).

local Screen    = require('lib.screen')
local Constants = require('src.constants')
local config    = require('src.config')
local sock      = require('lib.sock')
local json      = require('lib.json')

local MAX_NAME_LEN = 16

local NameEntryScreen = {}

function NameEntryScreen.new()
    local self = Screen.new()

    function self:init()
        self.nameText = ""
        self.activeField = "name"

        self.status = "connecting"
        self.statusMessage = "Connecting to server..."

        self.client = nil

        self.cursorTimer = 0
        self.cursorVisible = true

        self._nameRect = nil
        self._playBtnRect = nil

        self:connectToServer()

        love.keyboard.setKeyRepeat(true)
    end

    function self:close()
        love.keyboard.setKeyRepeat(false)
        love.keyboard.setTextInput(false)
        if self.client and self.status ~= "logged_in" then
            self.client:disconnect()
        end
    end

    function self:connectToServer()
        self.client = sock.newClient(config.SERVER_ADDRESS, config.SERVER_PORT)
        self.client:setSerialization(json.encode, json.decode)

        self.client:on("connect", function()
            self.status = "ready"
            self.statusMessage = "What's your name?"
        end)

        self.client:on("disconnect", function()
            if self.status ~= "logged_in" then
                self.status = "error"
                self.statusMessage = "Disconnected from server"
            end
        end)

        self.client:on("login_success", function(data)
            self.status = "logged_in"
            self.statusMessage = "Welcome, " .. tostring(data.username) .. "!"

            if data.token and data.token ~= "" then
                love.filesystem.write("session.dat", json.encode({
                    token    = data.token,
                    username = data.username,
                }))
            end

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

            love.timer.sleep(0.4)
            local ScreenManager = require('lib.screen_manager')
            ScreenManager.switch('menu')
        end)

        self.client:on("register_failed", function(data)
            self.status = "error"
            self.statusMessage = (data and data.reason) or "Registration failed"
        end)

        self.client:connect()
        self.client:setTimeout(32, 5000, 60000)
    end

    function self:update(dt)
        if self.client then
            self.client:update()
        end

        self.cursorTimer = self.cursorTimer + dt
        if self.cursorTimer >= 0.5 then
            self.cursorTimer = 0
            self.cursorVisible = not self.cursorVisible
        end
    end

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

    function self:draw()
        local lg = love.graphics
        local W  = Constants.GAME_WIDTH
        local H  = Constants.GAME_HEIGHT
        local sc = Constants.SCALE
        local cx = W / 2

        lg.clear(Constants.COLORS.BACKGROUND)

        lg.setFont(Fonts.large)
        lg.setColor(1, 1, 1, 1)
        lg.printf("AutoChest", 0, H * 0.10, W, 'center')

        lg.setFont(Fonts.small)
        if self.status == "error" then
            lg.setColor(1, 0.4, 0.4, 1)
        elseif self.status == "connecting" then
            lg.setColor(0.7, 0.7, 0.7, 1)
        else
            lg.setColor(0.6, 1, 0.6, 1)
        end
        lg.printf(self.statusMessage, 0, H * 0.10 + Fonts.large:getHeight() + 20 * sc, W, 'center')

        if self.status ~= "connecting" and self.status ~= "logged_in" then
            local fieldW   = 300 * sc
            local fieldH   = 50 * sc
            local fieldX   = cx - fieldW / 2
            local labelGap = 8 * sc
            local textPad  = 12 * sc

            local nameY = H * 0.38
            lg.setFont(Fonts.small)
            lg.setColor(0.65, 0.65, 0.7, 1)
            lg.print("Name", fieldX, nameY - Fonts.small:getHeight() - labelGap)

            local active = (self.activeField == "name")
            lg.setColor(active and {0.22, 0.22, 0.32, 1} or {0.16, 0.16, 0.22, 1})
            roundedRect(fieldX, nameY, fieldW, fieldH, 5, sc)
            lg.setColor(active and {0.5, 0.5, 0.8, 1} or {0.32, 0.32, 0.42, 1})
            roundedRectLine(fieldX, nameY, fieldW, fieldH, 5, sc, 2 * sc)

            lg.setFont(Fonts.small)
            lg.setColor(1, 1, 1, 1)
            local textY = textCY(Fonts.small, nameY, fieldH)
            lg.print(self.nameText, fieldX + textPad, textY)

            if active and self.cursorVisible then
                local tw = Fonts.small:getWidth(self.nameText)
                lg.setColor(1, 1, 1, 0.85)
                lg.rectangle('fill', fieldX + textPad + tw + 1, textY + 2 * sc,
                             2 * sc, Fonts.small:getHeight() - 4 * sc)
            end

            self._nameRect = {x = fieldX, y = nameY, w = fieldW, h = fieldH}

            local btnW = 180 * sc
            local btnH = 54 * sc
            local btnX = cx - btnW / 2
            local btnY = nameY + fieldH + 44 * sc

            local canSubmit = #self.nameText > 0

            if canSubmit then
                lg.setColor(0.15, 0.45, 0.25, 1)
                roundedRect(btnX, btnY, btnW, btnH, 8, sc)
                lg.setColor(0.25, 0.65, 0.40, 1)
                roundedRectLine(btnX, btnY, btnW, btnH, 8, sc, 2 * sc)
            else
                lg.setColor(0.12, 0.12, 0.18, 1)
                roundedRect(btnX, btnY, btnW, btnH, 8, sc)
                lg.setColor(0.22, 0.22, 0.30, 1)
                roundedRectLine(btnX, btnY, btnW, btnH, 8, sc, 2 * sc)
            end
            lg.setFont(Fonts.medium)
            lg.setColor(canSubmit and {1, 1, 1, 1} or {0.4, 0.4, 0.45, 1})
            lg.printf("Play!", btnX, textCY(Fonts.medium, btnY, btnH), btnW, 'center')
            self._playBtnRect = canSubmit and {x = btnX, y = btnY, w = btnW, h = btnH} or nil
        end
    end

    function self:mousepressed(x, y, button)
        if button ~= 1 then return end

        if self._nameRect then
            local r = self._nameRect
            if x >= r.x and x <= r.x + r.w and y >= r.y and y <= r.y + r.h then
                self.activeField = "name"
                self.status = "ready"
                love.keyboard.setTextInput(true, r.x, r.y, r.w, r.h)
                return
            end
        end

        if self._playBtnRect then
            local r = self._playBtnRect
            if x >= r.x and x <= r.x + r.w and y >= r.y and y <= r.y + r.h then
                AudioManager.playTap()
                love.keyboard.setTextInput(false)
                self:doSubmit()
                return
            end
        end

        self.activeField = nil
        love.keyboard.setTextInput(false)
    end

    function self:touchpressed(_, x, y)
        self:mousepressed(x, y, 1)
    end

    function self:textinput(t)
        if self.activeField ~= "name" then return end
        if #self.nameText >= MAX_NAME_LEN then return end
        if t:match("^[%w_]+$") then
            self.nameText = self.nameText .. t
        end
    end

    function self:keypressed(key)
        if key == "escape" then
            self.activeField = nil
            love.keyboard.setTextInput(false)
            return
        end

        if self.activeField ~= "name" then return end

        if key == "backspace" then
            self.nameText = self.nameText:sub(1, -2)
        elseif key == "return" or key == "kpenter" then
            if #self.nameText > 0 then
                love.keyboard.setTextInput(false)
                self:doSubmit()
            end
        end
    end

    function self:doSubmit()
        if not self.client or self.status == "connecting" then return end

        self.status = "connecting"
        self.statusMessage = "Creating your profile..."
        self.client:send("register_device", {
            username  = self.nameText,
            device_id = _G.DeviceId or ""
        })
    end

    return self
end

return NameEntryScreen
