-- AutoChest – Online Lobby Screen
-- Connects to the relay server, waits for an opponent, then launches GameScreen.

local Screen    = require('lib.screen')
local Constants = require('src.constants')
local sock      = require('lib.sock')
local json      = require('lib.json')

local LobbyScreen = {}

-- ── Constants ──────────────────────────────────────────────────────────────

local DEFAULT_IP   = "127.0.0.1"
local DEFAULT_PORT = 12345

-- ── Screen factory ─────────────────────────────────────────────────────────

function LobbyScreen.new()
    local self = Screen.new()

    -- ── init ────────────────────────────────────────────────────────────────

    function self:init()
        self.client     = nil
        self.status     = "idle"   -- idle | connecting | waiting | matched | error
        self.statusMsg  = "Ingresa la IP del servidor y conecta."
        self.errorMsg   = ""
        self.playerRole = nil

        -- IP text-input state
        self.ipText      = DEFAULT_IP
        self.inputActive = false

        -- Cursor blink
        self.cursorTimer   = 0
        self.cursorVisible = true

        love.keyboard.setKeyRepeat(true)
        print("LobbyScreen initialized")
    end

    -- ── Network helpers ──────────────────────────────────────────────────────

    function self:connect()
        if self.status == "connecting" or self.status == "waiting" then return end

        local ip = self.ipText == "" and DEFAULT_IP or self.ipText
        self.client = sock.newClient(ip, DEFAULT_PORT)
        self.client:setSerialization(json.encode, json.decode)

        self.client:on("connect", function()
            self.status    = "waiting"
            self.statusMsg = "Conectado. Esperando oponente…"
            print("Connected to relay server")
        end)

        self.client:on("waiting", function(data)
            self.status    = "waiting"
            self.statusMsg = "Eres P1. Esperando que P2 se conecte…"
        end)

        self.client:on("match_found", function(data)
            self.playerRole = data.role
            self.status     = "matched"
            self.statusMsg  = "¡Oponente encontrado! Eres P" .. data.role .. ". Cargando…"
            print("Match found, role = " .. data.role)

            -- Small delay so the status message is visible, then switch screens
            self.matchTimer = 0.8
        end)

        self.client:on("opponent_disconnected", function()
            self.status    = "idle"
            self.statusMsg = "El oponente se desconectó."
            self:disconnectClean()
        end)

        self.status    = "connecting"
        self.statusMsg = "Conectando a " .. ip .. "…"
        self.client:connect()
    end

    function self:disconnectClean()
        if self.client then
            pcall(function() self.client:disconnect() end)
            self.client = nil
        end
        self.status = "idle"
    end

    -- ── Update ───────────────────────────────────────────────────────────────

    function self:update(dt)
        -- Cursor blink
        self.cursorTimer = self.cursorTimer + dt
        if self.cursorTimer >= 0.5 then
            self.cursorTimer   = 0
            self.cursorVisible = not self.cursorVisible
        end

        -- Poll network
        if self.client then
            self.client:update()
        end

        -- Transition to game after match found
        if self.matchTimer then
            self.matchTimer = self.matchTimer - dt
            if self.matchTimer <= 0 then
                self.matchTimer = nil
                local ScreenManager = require('lib.screen_manager')
                ScreenManager.switch('game', true, self.playerRole, self.client)
            end
        end
    end

    -- ── Draw ─────────────────────────────────────────────────────────────────

    function self:draw()
        local lg = love.graphics
        local cx = Constants.GAME_WIDTH  / 2
        local cy = Constants.GAME_HEIGHT / 2
        local sc = Constants.SCALE

        -- Title
        lg.setFont(Fonts.large)
        lg.setColor(1, 1, 1, 1)
        lg.printf("AutoChest Online", 0, cy - 220 * sc, Constants.GAME_WIDTH, "center")

        lg.setFont(Fonts.small)
        lg.setColor(0.6, 0.6, 0.6, 1)
        lg.printf("1v1 Multijugador", 0, cy - 175 * sc, Constants.GAME_WIDTH, "center")

        -- ── IP input field ────────────────────────────────────────────────
        local fieldW = 260 * sc
        local fieldH = 40  * sc
        local fieldX = cx - fieldW / 2
        local fieldY = cy - 90 * sc

        lg.setFont(Fonts.medium)
        lg.setColor(0.2, 0.2, 0.25, 1)
        lg.rectangle("fill", fieldX, fieldY, fieldW, fieldH, 6 * sc, 6 * sc)

        if self.inputActive then
            lg.setColor(0.4, 0.6, 1, 1)
        else
            lg.setColor(0.4, 0.4, 0.5, 1)
        end
        lg.setLineWidth(2)
        lg.rectangle("line", fieldX, fieldY, fieldW, fieldH, 6 * sc, 6 * sc)

        -- Field label
        lg.setFont(Fonts.tiny)
        lg.setColor(0.6, 0.6, 0.7, 1)
        lg.print("IP del servidor:", fieldX, fieldY - 20 * sc)

        -- Field text + cursor
        lg.setFont(Fonts.small)
        lg.setColor(1, 1, 1, 1)
        local displayText = self.ipText
        if self.inputActive and self.cursorVisible then
            displayText = displayText .. "|"
        end
        lg.print(displayText, fieldX + 10 * sc, fieldY + (fieldH - Fonts.small:getHeight()) / 2)

        -- ── Connect button ────────────────────────────────────────────────
        local btnW = 200 * sc
        local btnH = 50  * sc
        local btnX = cx - btnW / 2
        local btnY = cy - 20 * sc

        local canConnect = (self.status == "idle" or self.status == "error")
        if canConnect then
            lg.setColor(0.2, 0.6, 0.2, 1)
        else
            lg.setColor(0.3, 0.3, 0.3, 1)
        end
        lg.rectangle("fill", btnX, btnY, btnW, btnH, 8 * sc, 8 * sc)

        lg.setFont(Fonts.medium)
        lg.setColor(1, 1, 1, 1)
        local btnLabel = canConnect and "CONECTAR" or "..."
        lg.printf(btnLabel, btnX, btnY + (btnH - Fonts.medium:getHeight()) / 2, btnW, "center")

        -- ── Status text ───────────────────────────────────────────────────
        local statusColor = {1, 1, 1, 1}
        if self.status == "error"   then statusColor = {1, 0.4, 0.4, 1} end
        if self.status == "matched" then statusColor = {0.4, 1, 0.4, 1} end
        if self.status == "waiting" then statusColor = {1, 0.9, 0.4, 1} end

        lg.setFont(Fonts.small)
        lg.setColor(statusColor)
        lg.printf(self.statusMsg, 0, cy + 60 * sc, Constants.GAME_WIDTH, "center")

        -- ── Back button ───────────────────────────────────────────────────
        if self.status == "idle" or self.status == "error" then
            lg.setFont(Fonts.tiny)
            lg.setColor(0.5, 0.5, 0.5, 1)
            lg.printf("← Volver al menú (Esc)", 0, cy + 120 * sc, Constants.GAME_WIDTH, "center")
        end

        -- Spinner dots while connecting / waiting
        if self.status == "connecting" or self.status == "waiting" then
            local dots = string.rep(".", math.floor(love.timer.getTime() * 2) % 4)
            lg.setFont(Fonts.small)
            lg.setColor(0.7, 0.7, 0.7, 0.8)
            lg.printf(dots, 0, cy + 95 * sc, Constants.GAME_WIDTH, "center")
        end
    end

    -- ── Input ─────────────────────────────────────────────────────────────────

    function self:_connectButtonHit(x, y)
        local cx   = Constants.GAME_WIDTH  / 2
        local cy   = Constants.GAME_HEIGHT / 2
        local sc   = Constants.SCALE
        local btnW = 200 * sc
        local btnH = 50  * sc
        local btnX = cx - btnW / 2
        local btnY = cy - 20 * sc
        return x >= btnX and x <= btnX + btnW and y >= btnY and y <= btnY + btnH
    end

    function self:_ipFieldHit(x, y)
        local cx     = Constants.GAME_WIDTH  / 2
        local cy     = Constants.GAME_HEIGHT / 2
        local sc     = Constants.SCALE
        local fieldW = 260 * sc
        local fieldH = 40  * sc
        local fieldX = cx - fieldW / 2
        local fieldY = cy - 90 * sc
        return x >= fieldX and x <= fieldX + fieldW and y >= fieldY and y <= fieldY + fieldH
    end

    function self:mousepressed(x, y, button)
        if button ~= 1 then return end

        if self:_ipFieldHit(x, y) then
            self.inputActive = true
            return
        end

        self.inputActive = false

        if self:_connectButtonHit(x, y) then
            if self.status == "idle" or self.status == "error" then
                self:connect()
            end
        end
    end

    function self:touchpressed(id, x, y)
        self:mousepressed(x, y, 1)
    end

    function self:mousereleased(x, y, button) end
    function self:touchreleased(id, x, y) end
    function self:mousemoved(x, y, dx, dy) end
    function self:touchmoved(id, x, y, dx, dy) end

    function self:textinput(t)
        if not self.inputActive then return end
        self.ipText = self.ipText .. t
    end

    function self:keypressed(key)
        if key == "escape" then
            self:disconnectClean()
            local ScreenManager = require('lib.screen_manager')
            ScreenManager.switch('menu')
            return
        end

        if not self.inputActive then return end

        if key == "backspace" then
            self.ipText = self.ipText:sub(1, -2)
        elseif key == "return" or key == "kpenter" then
            self.inputActive = false
            if self.status == "idle" or self.status == "error" then
                self:connect()
            end
        end
    end

    function self:close()
        love.keyboard.setKeyRepeat(false)
        -- If we matched and handed the socket to GameScreen, don't disconnect it.
        if self.status ~= "matched" then
            self:disconnectClean()
        end
    end

    return self
end

return LobbyScreen
