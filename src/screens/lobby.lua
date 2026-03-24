-- AutoChest – Matchmaking Lobby Screen
-- Auto-joins queue, waits for match, then launches GameScreen.

local Screen    = require('lib.screen')
local Constants = require('src.constants')

local LobbyScreen = {}

function LobbyScreen.new()
    local self = Screen.new()

    -- ── init ────────────────────────────────────────────────────────────────

    function self:init(client)
        self.client = client  -- Authenticated socket from login/menu
        self.status = "queueing"  -- queueing | matched | error
        self.statusMsg = "Finding match..."
        self.queueStartTime = love.timer.getTime()
        self.playerRole = nil
        self.opponentName = nil
        self.opponentTrophies = nil
        self.myTrophies = _G.PlayerData and _G.PlayerData.trophies or 0

        -- Cancel button hit rect
        self._cancelBtnRect = nil

        -- Match delay timer
        self.matchTimer = nil

        -- Register network callbacks
        self:registerNetworkCallbacks()

        -- Auto-join queue
        self:joinQueue()

        print("LobbyScreen: Auto-joining matchmaking queue")
    end

    function self:registerNetworkCallbacks()
        self._cb_queueJoined = self.client:on("queue_joined", function()
            self.status = "queueing"
            self.statusMsg = "Finding match..."
            print("Queue joined")
        end)

        self._cb_queueLeft = self.client:on("queue_left", function()
            print("Queue left")
        end)

        self._cb_matchFound = self.client:on("match_found", function(data)
            self.playerRole = data.role
            self.opponentName = data.opponent_name
            self.opponentTrophies = data.opponent_trophies
            self.myTrophies = data.my_trophies
            self.status = "matched"
            self.statusMsg = "Match found!"
            print("Match found: vs " .. self.opponentName .. " (" .. self.opponentTrophies .. " trophies)")

            -- Show match info briefly before launching
            self.matchTimer = 1.2
        end)

        self._cb_oppDisconn = self.client:on("opponent_disconnected", function()
            self.status = "error"
            self.statusMsg = "Opponent disconnected"
        end)

        self._cb_error = self.client:on("error", function(data)
            if data.reason == "Not authenticated" and _G.PlayerData and _G.PlayerData.token then
                -- Session dropped — silently reconnect using stored token
                self.status = "reconnecting"
                self.statusMsg = "Reconnecting..."
                self.client:send("reconnect_with_token", {token = _G.PlayerData.token})
            else
                self.status = "error"
                self.statusMsg = data.reason or "Error occurred"
            end
        end)

        self._cb_loginSuccess = self.client:on("login_success", function(data)
            if self.status == "reconnecting" then
                -- Session restored — update trophies and re-join queue
                _G.PlayerData.trophies = data.trophies
                self.myTrophies = data.trophies
                self.status = "queueing"
                self:joinQueue()
            end
        end)
    end

    function self:joinQueue()
        if not self.client then
            self.status = "error"
            self.statusMsg = "No connection"
            return
        end

        self.client:send("queue_join", {
            player_id = _G.PlayerData.id,
            trophies = _G.PlayerData.trophies
        })
    end

    function self:leaveQueue()
        if self.client then
            self.client:send("queue_leave", {})
        end
    end

    -- ── Update ───────────────────────────────────────────────────────────────

    function self:update(dt)
        -- Poll network
        if self.client then
            self.client:update()
        end

        -- Transition to game after match found
        if self.matchTimer then
            self.matchTimer = self.matchTimer - dt
            if self.matchTimer <= 0 then
                self.matchTimer = nil

                -- Update player trophies globally (server sent latest)
                _G.PlayerData.trophies = self.myTrophies

                -- Store opponent info globally for game screen
                _G.OpponentData = {
                    name = self.opponentName,
                    trophies = self.opponentTrophies
                }

                -- Update perspective constant
                Constants.PERSPECTIVE = self.playerRole

                local ScreenManager = require('lib.screen_manager')
                ScreenManager.switch('game', true, self.playerRole, self.client)
            end
        end
    end

    -- ── Draw ─────────────────────────────────────────────────────────────────

    local function roundedRect(x, y, w, h, r, sc)
        love.graphics.rectangle('fill', x, y, w, h, r * sc, r * sc)
    end

    local function roundedRectLine(x, y, w, h, r, sc, lw)
        love.graphics.setLineWidth(lw or 2)
        love.graphics.rectangle('line', x, y, w, h, r * sc, r * sc)
    end

    function self:draw()
        local lg = love.graphics
        local W = Constants.GAME_WIDTH
        local H = Constants.GAME_HEIGHT
        local sc = Constants.SCALE
        local cx = W / 2
        local cy = H / 2

        lg.clear(Constants.COLORS.BACKGROUND)

        -- Title
        lg.setFont(Fonts.large)
        lg.setColor(1, 1, 1, 1)
        lg.printf("Matchmaking", 0, cy - 200 * sc, W, 'center')

        -- Status indicator
        if self.status == "queueing" then
            -- Animated spinner
            local elapsed = love.timer.getTime() - self.queueStartTime
            local angle = elapsed * math.pi  -- Rotate over time
            local spinnerR = 40 * sc

            lg.push()
            lg.translate(cx, cy - 60 * sc)
            lg.rotate(angle)
            lg.setColor(0.5, 0.7, 1, 1)
            lg.setLineWidth(4 * sc)
            lg.arc('line', 'open', 0, 0, spinnerR, 0, math.pi * 1.5)
            lg.pop()

            -- Status text
            lg.setFont(Fonts.medium)
            lg.setColor(1, 1, 1, 1)
            lg.printf(self.statusMsg, 0, cy + 10 * sc, W, 'center')

            -- Animated dots
            local dots = string.rep(".", math.floor(elapsed * 2) % 4)
            lg.setFont(Fonts.medium)
            lg.setColor(0.7, 0.7, 0.7, 0.8)
            lg.printf(dots, 0, cy + 40 * sc, W, 'center')

            -- Queue time
            lg.setFont(Fonts.small)
            lg.setColor(0.6, 0.6, 0.7, 1)
            local queueTime = math.floor(elapsed)
            lg.printf(string.format("Time in queue: %ds", queueTime), 0, cy + 80 * sc, W, 'center')

            -- Trophy count and matchmaking range
            lg.setFont(Fonts.tiny)
            lg.setColor(0.9, 0.85, 0.3, 1)
            lg.printf("Your trophies: " .. self.myTrophies, 0, cy + 110 * sc, W, 'center')

            -- Matchmaking range (expands over time)
            local baseRange = 100
            local expandStep = 50
            local expandInterval = 5
            local maxRange = 500
            local expandAmount = math.min(math.floor(queueTime / expandInterval) * expandStep, maxRange - baseRange)
            local currentRange = baseRange + expandAmount
            local minTrophies = math.max(0, self.myTrophies - currentRange)
            local maxTrophies = self.myTrophies + currentRange

            lg.setFont(Fonts.tiny)
            lg.setColor(0.5, 0.8, 1, 0.9)
            lg.printf(string.format("Searching range: %d - %d (±%d)", minTrophies, maxTrophies, currentRange), 0, cy + 130 * sc, W, 'center')

            -- Debug: Player ID
            if _G.PlayerData then
                lg.setColor(0.5, 0.5, 0.5, 0.6)
                lg.printf("ID: " .. _G.PlayerData.id .. " | User: " .. _G.PlayerData.username, 0, cy + 150 * sc, W, 'center')
            end

        elseif self.status == "matched" then
            -- Match found! Show checkmark
            lg.setColor(0.4, 1, 0.4, 1)
            lg.setLineWidth(6 * sc)
            local checkSc = 60 * sc
            lg.line(cx - checkSc/2, cy - 70 * sc, cx - checkSc/4, cy - 50 * sc)
            lg.line(cx - checkSc/4, cy - 50 * sc, cx + checkSc/2, cy - 90 * sc)

            lg.setFont(Fonts.large)
            lg.setColor(0.4, 1, 0.4, 1)
            lg.printf("Match Found!", 0, cy - 10 * sc, W, 'center')

            -- Opponent info
            lg.setFont(Fonts.medium)
            lg.setColor(1, 1, 1, 1)
            lg.printf("vs " .. self.opponentName, 0, cy + 40 * sc, W, 'center')

            lg.setFont(Fonts.small)
            lg.setColor(0.9, 0.85, 0.3, 1)
            lg.printf(self.opponentTrophies .. " trophies", 0, cy + 75 * sc, W, 'center')

            lg.setFont(Fonts.tiny)
            lg.setColor(0.6, 0.6, 0.7, 1)
            lg.printf("Starting game...", 0, cy + 110 * sc, W, 'center')

        elseif self.status == "error" then
            lg.setFont(Fonts.medium)
            lg.setColor(1, 0.4, 0.4, 1)
            lg.printf(self.statusMsg, 0, cy, W, 'center')
        end

        -- Cancel button (only while queueing)
        if self.status == "queueing" then
            local btnW = 180 * sc
            local btnH = 50 * sc
            local btnX = cx - btnW / 2
            local btnY = cy + 160 * sc

            lg.setColor(0.45, 0.28, 0.08, 1)
            roundedRect(btnX, btnY, btnW, btnH, 8, sc)
            lg.setColor(0.70, 0.48, 0.15, 1)
            roundedRectLine(btnX, btnY, btnW, btnH, 8, sc, 2 * sc)

            lg.setFont(Fonts.medium)
            lg.setColor(1, 1, 1, 1)
            lg.printf("Cancel", btnX, btnY + (btnH - Fonts.medium:getHeight()) / 2, btnW, 'center')

            self._cancelBtnRect = {x = btnX, y = btnY, w = btnW, h = btnH}
        else
            self._cancelBtnRect = nil
        end
    end

    -- ── Input ─────────────────────────────────────────────────────────────────

    function self:mousepressed(x, y, button)
        if button ~= 1 then return end
        if self._cancelBtnRect then
            local r = self._cancelBtnRect
            self._cancelPressedInside = x >= r.x and x <= r.x + r.w and y >= r.y and y <= r.y + r.h
        end
    end

    function self:mousereleased(x, y, button)
        if button ~= 1 then return end
        if self._cancelPressedInside and self._cancelBtnRect then
            local r = self._cancelBtnRect
            if x >= r.x and x <= r.x + r.w and y >= r.y and y <= r.y + r.h then
                self._cancelPressedInside = false
                self:leaveQueue()
                local ScreenManager = require('lib.screen_manager')
                ScreenManager.switch('menu')
                return
            end
        end
        self._cancelPressedInside = false
    end

    function self:touchpressed(_, x, y)
        self:mousepressed(x, y, 1)
    end

    function self:touchreleased(_, x, y)
        self:mousereleased(x, y, 1)
    end

    function self:keypressed(key)
        if key == "escape" then
            self:leaveQueue()
            local ScreenManager = require('lib.screen_manager')
            ScreenManager.switch('menu')
        end
    end

    function self:close()
        -- Unregister all socket callbacks so they don't accumulate across sessions
        if self.client then
            local cbs = {self._cb_queueJoined, self._cb_queueLeft, self._cb_matchFound,
                         self._cb_oppDisconn, self._cb_error, self._cb_loginSuccess}
            for _, cb in ipairs(cbs) do
                if cb then self.client:removeCallback(cb) end
            end
        end

        -- Leave queue if still queueing
        if self.status == "queueing" then
            self:leaveQueue()
        end

        -- Don't disconnect socket if matched (handed to GameScreen)
        if self.status == "matched" then
            print("LobbyScreen: Passing socket to GameScreen")
        end
    end

    return self
end

return LobbyScreen
