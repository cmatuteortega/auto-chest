-- AutoChest – Main Menu Screen
-- 3-panel swipeable card navigation: Collection | Play Online | Shop

local Screen       = require('lib.screen')
local Constants    = require('src.constants')
local UnitRegistry = require('src.unit_registry')

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

        -- IP input (Play Online panel)
        self.ipText       = "127.0.0.1"
        self.inputActive  = false
        self.cursorTimer  = 0
        self.cursorVisible = true

        -- Unit detail overlay
        self.showDetail = false
        self.detailUnit = nil   -- unitType string

        -- Load front sprites for collection display
        self.unitOrder = { "knight", "boney", "samurai", "marrow" }
        self.sprites   = {}
        for _, utype in ipairs(self.unitOrder) do
            local img = love.graphics.newImage(UnitRegistry.spritePaths[utype].front)
            img:setFilter('nearest', 'nearest')
            self.sprites[utype] = img
        end

        -- Bottom tab bar icons (order matches panel indices)
        self.uiIcons = {}
        for i, name in ipairs({ 'collection', 'decks', 'battle', 'shop', 'ranking' }) do
            local img = love.graphics.newImage('src/assets/ui/' .. name .. '.png')
            img:setFilter('nearest', 'nearest')
            self.uiIcons[i] = img
        end
        -- Tab raise animation values: 0 = flat, 1 = fully popped
        self.tabRaiseAnim = { 0, 0, 1, 0, 0 }  -- panel 3 (Battle) starts active

        -- Hit-rect caches (rebuilt each draw, stored in screen coords)
        self._collectionCards = {}
        self._ipFieldRect     = nil
        self._playBtnRect     = nil
        self._detailBackBtn   = nil
        self._tabRects        = {}

        love.keyboard.setKeyRepeat(true)
    end

    function self:close()
        love.keyboard.setKeyRepeat(false)
    end

    -- ── update ──────────────────────────────────────────────────────────────

    function self:update(dt)
        -- Cursor blink
        self.cursorTimer = self.cursorTimer + dt
        if self.cursorTimer >= 0.5 then
            self.cursorTimer   = 0
            self.cursorVisible = not self.cursorVisible
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
    end

    -- ── draw helpers ────────────────────────────────────────────────────────

    local function roundedRect(x, y, w, h, r, sc)
        love.graphics.rectangle('fill', x, y, w, h, r * sc, r * sc)
    end

    local function roundedRectLine(x, y, w, h, r, sc, lw)
        love.graphics.setLineWidth(lw or 2)
        love.graphics.rectangle('line', x, y, w, h, r * sc, r * sc)
    end

    function self:drawCollectionCard(cx, cy, cardW, cardH, utype, sc)
        local lg = love.graphics

        -- Background + border
        lg.setColor(0.18, 0.18, 0.26, 1)
        roundedRect(cx, cy, cardW, cardH, 6, sc)
        lg.setColor(0.38, 0.38, 0.52, 1)
        roundedRectLine(cx, cy, cardW, cardH, 6, sc, 2 * sc)

        -- Unit name
        lg.setFont(Fonts.small)
        lg.setColor(0.9, 0.9, 0.9, 1)
        local name = utype:sub(1,1):upper() .. utype:sub(2)
        lg.printf(name, cx, cy + 8 * sc, cardW, 'center')

        -- Front sprite (integer scale, centred)
        local img    = self.sprites[utype]
        local iw, ih = img:getDimensions()
        local sprSc  = math.max(1, math.floor(4 * sc))
        local sx     = math.floor(cx + (cardW - iw * sprSc) / 2)
        local sy     = math.floor(cy + (cardH - ih * sprSc) / 2 + 6 * sc)
        lg.setColor(1, 1, 1, 1)
        lg.draw(img, sx, sy, 0, sprSc, sprSc)

        -- Tap hint
        --lg.setFont(Fonts.tiny)
        --lg.setColor(0.45, 0.45, 0.55, 1)
        --lg.printf("tap for info", cx, cy + cardH - 18 * sc, cardW, 'center')
    end

    function self:drawCollectionPanel(ox, W, H, sc)
        local lg = love.graphics

        lg.setFont(Fonts.large)
        lg.setColor(1, 1, 1, 1)
        lg.printf("Collection", ox, 52 * sc, W, 'center')

        local cols   = 4
        local cardW  = 100 * sc
        local cardH  = 130 * sc
        local gapX   = 12  * sc
        local totalW = cols * cardW + (cols - 1) * gapX
        local startX = ox + (W - totalW) / 2
        local startY = 130 * sc

        -- 4 unit cards in a single row
        self._collectionCards = {}
        for i, utype in ipairs(self.unitOrder) do
            local cx = startX + (i - 1) * (cardW + gapX)
            self:drawCollectionCard(cx, startY, cardW, cardH, utype, sc)
            self._collectionCards[i] = {
                x = cx + self.panelOffset,
                y = startY,
                w = cardW,
                h = cardH,
                utype = utype
            }
        end
    end

    function self:drawPlayPanel(ox, W, H, sc)
        local lg = love.graphics
        local cx = ox + W / 2

        -- Title
        lg.setFont(Fonts.large)
        lg.setColor(1, 1, 1, 1)
        lg.printf("AutoChest", ox, H * 0.22, W, 'center')

        -- Subtitle
        lg.setFont(Fonts.medium)
        lg.setColor(0.6, 0.6, 0.65, 1)
        lg.printf("1v1 Autobattler", ox, H * 0.22 + Fonts.large:getHeight() + 10 * sc, W, 'center')

        -- Server label
        local fieldW = 280 * sc
        local fieldH = 42  * sc
        local fieldX = cx - fieldW / 2
        local fieldY = H * 0.48

        lg.setFont(Fonts.small)
        lg.setColor(0.65, 0.65, 0.7, 1)
        lg.printf("Server", fieldX, fieldY - Fonts.small:getHeight() - 6 * sc, fieldW, 'left')

        -- IP input field
        local active = self.inputActive
        lg.setColor(active and {0.22, 0.22, 0.32, 1} or {0.16, 0.16, 0.22, 1})
        roundedRect(fieldX, fieldY, fieldW, fieldH, 5, sc)
        lg.setColor(active and {0.5, 0.5, 0.8, 1} or {0.32, 0.32, 0.42, 1})
        roundedRectLine(fieldX, fieldY, fieldW, fieldH, 5, sc, 2 * sc)

        local textPad = 10 * sc
        local textY   = fieldY + (fieldH - Fonts.small:getHeight()) / 2
        lg.setFont(Fonts.small)
        lg.setColor(1, 1, 1, 1)
        lg.print(self.ipText, fieldX + textPad, textY)

        -- Cursor
        if active and self.cursorVisible then
            local tw = Fonts.small:getWidth(self.ipText)
            lg.setColor(1, 1, 1, 0.85)
            local cx2 = fieldX + textPad + tw + 1
            lg.rectangle('fill', cx2, textY + 2 * sc, 2 * sc, Fonts.small:getHeight() - 4 * sc)
        end

        -- Store field rect in screen coords
        self._ipFieldRect = {
            x = fieldX + self.panelOffset,
            y = fieldY,
            w = fieldW,
            h = fieldH
        }

        -- PLAY ONLINE button
        local btnW = 240 * sc
        local btnH = 56  * sc
        local btnX = cx - btnW / 2
        local btnY = fieldY + fieldH + 28 * sc

        lg.setColor(0.15, 0.32, 0.65, 1)
        roundedRect(btnX, btnY, btnW, btnH, 8, sc)
        lg.setColor(0.25, 0.45, 0.85, 1)
        roundedRectLine(btnX, btnY, btnW, btnH, 8, sc, 2 * sc)
        lg.setFont(Fonts.medium)
        lg.setColor(1, 1, 1, 1)
        lg.printf("PLAY ONLINE", btnX, btnY + (btnH - Fonts.medium:getHeight()) / 2, btnW, 'center')

        self._playBtnRect = {
            x = btnX + self.panelOffset,
            y = btnY,
            w = btnW,
            h = btnH
        }
    end

    function self:drawDecksPanel(ox, W, H, sc)
        local lg = love.graphics
        lg.setFont(Fonts.large)
        lg.setColor(1, 1, 1, 1)
        lg.printf("Decks", ox, 52 * sc, W, 'center')
        lg.setFont(Fonts.medium)
        lg.setColor(0.4, 0.4, 0.45, 1)
        lg.printf("Coming Soon", ox, H * 0.42, W, 'center')
    end

    function self:drawRankingPanel(ox, W, H, sc)
        local lg = love.graphics
        lg.setFont(Fonts.large)
        lg.setColor(1, 1, 1, 1)
        lg.printf("Ranking", ox, 52 * sc, W, 'center')
        lg.setFont(Fonts.medium)
        lg.setColor(0.4, 0.4, 0.45, 1)
        lg.printf("Coming Soon", ox, H * 0.42, W, 'center')
    end

    function self:drawShopPanel(ox, W, H, sc)
        local lg = love.graphics

        lg.setFont(Fonts.large)
        lg.setColor(1, 1, 1, 1)
        lg.printf("Shop", ox, 52 * sc, W, 'center')

        lg.setFont(Fonts.medium)
        lg.setColor(0.4, 0.4, 0.45, 1)
        lg.printf("Coming Soon", ox, H * 0.42, W, 'center')

        -- Empty placeholder cards
        local cardW  = 110 * sc
        local cardH  = 140 * sc
        local gapX   = 24  * sc
        local gapY   = 18  * sc
        local cols   = 2
        local totalW = cols * cardW + gapX
        local startX = ox + (W - totalW) / 2
        local startY = 130 * sc

        for i = 1, 4 do
            local col = (i - 1) % 2
            local row = math.floor((i - 1) / 2)
            local cx  = startX + col * (cardW + gapX)
            local cy  = startY + row * (cardH + gapY)
            lg.setColor(0.12, 0.12, 0.16, 1)
            roundedRect(cx, cy, cardW, cardH, 6, sc)
            lg.setColor(0.2, 0.2, 0.26, 1)
            roundedRectLine(cx, cy, cardW, cardH, 6, sc, 2 * sc)
        end
    end

    function self:drawBottomBar(W, H, sc)
        local lg    = love.graphics
        local BAR_H = 100 * sc
        local barY  = H - BAR_H
        local tabW  = W / self.NUM_PANELS
        local labels = { "Collection", "Decks", "Battle", "Shop", "Ranking" }

        -- Bar background
        lg.setColor(0.10, 0.10, 0.15, 1)
        lg.rectangle('fill', 0, barY, W, BAR_H)
        -- Top border line (2px, pixel-art crisp)
        lg.setColor(0.32, 0.32, 0.45, 1)
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
                lg.setColor(0.18, 0.20, 0.30, 1)
                lg.rectangle('fill', cardX, cardY, cardW, cardH)

                -- Outer border (bright, pixel-art frame)
                lg.setColor(0.45, 0.48, 0.70, 1)
                lg.setLineWidth(brd)
                lg.rectangle('line', cardX + brd/2, cardY + brd/2,
                             cardW - brd, cardH - brd)

                -- Inner top-left highlight (bevel light)
                lg.setColor(0.60, 0.62, 0.85, 1)
                lg.setLineWidth(math.max(1, math.floor(sc)))
                local b1 = brd + math.max(1, math.floor(sc))
                lg.line(cardX + b1, cardY + cardH - b1,
                        cardX + b1, cardY + b1,
                        cardX + cardW - b1, cardY + b1)

                -- Inner bottom-right shadow (bevel dark)
                lg.setColor(0.08, 0.08, 0.14, 1)
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
                lg.setColor(isActive and {1, 1, 1, 1} or {0.38, 0.38, 0.46, 1})
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

        -- Dim backdrop
        lg.setColor(0, 0, 0, 0.78)
        lg.rectangle('fill', 0, 0, W, H)

        -- Panel card
        local panW = W * 0.84
        local panH = H * 0.74
        local panX = (W - panW) / 2
        local panY = (H - panH) / 2

        lg.setColor(0.11, 0.11, 0.17, 1)
        roundedRect(panX, panY, panW, panH, 10, sc)
        lg.setColor(0.38, 0.38, 0.55, 1)
        roundedRectLine(panX, panY, panW, panH, 10, sc, 2 * sc)

        -- Large sprite
        local img    = self.sprites[utype]
        local iw, ih = img:getDimensions()
        local sprSc  = math.max(1, math.floor(7 * sc))
        local imgX   = math.floor(panX + (panW - iw * sprSc) / 2)
        local imgY   = math.floor(panY + 18 * sc)
        lg.setColor(1, 1, 1, 1)
        lg.draw(img, imgX, imgY, 0, sprSc, sprSc)

        local textX = panX + 18 * sc
        local textW = panW - 36 * sc
        local curY  = imgY + ih * sprSc + 12 * sc

        -- Unit name
        local name = utype:sub(1,1):upper() .. utype:sub(2)
        lg.setFont(Fonts.medium)
        lg.setColor(1, 1, 1, 1)
        lg.printf(name, panX, curY, panW, 'center')
        curY = curY + Fonts.medium:getHeight() + 8 * sc

        -- Pull all display data directly from the unit class
        local info = UnitRegistry.getUnitDisplayInfo(utype)

        -- Stats row
        lg.setFont(Fonts.tiny)
        lg.setColor(0.7, 0.8, 1, 1)
        local s = string.format("HP %d  ATK %d  SPD %.1f  RNG %d  [%s]",
            info.hp, info.atk, info.spd, info.rng, info.unitClass)
        lg.printf(s, textX, curY, textW, 'center')
        curY = curY + Fonts.tiny:getHeight() + 10 * sc

        -- Separator
        lg.setColor(0.3, 0.3, 0.42, 1)
        lg.setLineWidth(1 * sc)
        lg.line(textX, curY, panX + panW - 18 * sc, curY)
        curY = curY + 10 * sc

        -- Passive description
        lg.setFont(Fonts.tiny)
        lg.setColor(0.72, 0.72, 0.75, 1)
        local passive = UnitRegistry.passiveDescriptions[utype] or ""
        lg.printf(passive, textX, curY, textW, 'left')
        local _, pLines = Fonts.tiny:getWrap(passive, textW)
        curY = curY + #pLines * Fonts.tiny:getHeight() + 14 * sc

        -- Upgrades section
        lg.setFont(Fonts.small)
        lg.setColor(1, 0.85, 0.38, 1)
        lg.printf("Upgrades", textX, curY, textW, 'left')
        curY = curY + Fonts.small:getHeight() + 5 * sc

        lg.setFont(Fonts.tiny)
        for i, upg in ipairs(info.upgrades) do
            lg.setColor(1, 0.85, 0.38, 1)
            lg.printf(i .. ". " .. upg.name, textX + 8 * sc, curY, textW, 'left')
            curY = curY + Fonts.tiny:getHeight() + 2 * sc
            lg.setColor(0.75, 0.75, 0.78, 1)
            lg.printf("    " .. upg.description, textX + 8 * sc, curY, textW, 'left')
            curY = curY + Fonts.tiny:getHeight() + 6 * sc
        end

        -- Back button
        local bbW = 150 * sc
        local bbH = 42  * sc
        local bbX = (W - bbW) / 2
        local bbY = panY + panH - bbH - 12 * sc

        lg.setColor(0.22, 0.22, 0.32, 1)
        roundedRect(bbX, bbY, bbW, bbH, 6, sc)
        lg.setColor(0.42, 0.42, 0.55, 1)
        roundedRectLine(bbX, bbY, bbW, bbH, 6, sc, 2 * sc)
        lg.setFont(Fonts.small)
        lg.setColor(1, 1, 1, 1)
        lg.printf("Back", bbX, bbY + (bbH - Fonts.small:getHeight()) / 2, bbW, 'center')

        self._detailBackBtn = { x = bbX, y = bbY, w = bbW, h = bbH }
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
        self:drawShopPanel(      3 * W,   W, H - barH, sc)
        self:drawRankingPanel(   4 * W,   W, H - barH, sc)

        lg.pop()
        lg.setScissor()

        -- Bottom tab bar (screen space)
        self:drawBottomBar(W, H, sc)

        -- Detail overlay (screen space, topmost)
        if self.showDetail then
            self:drawDetailOverlay(W, H, sc)
        end
    end

    -- ── input ───────────────────────────────────────────────────────────────

    function self:handlePress(x, y)
        self.isPressed  = true
        self.pressX     = x
        self.pressY     = y
        self.hasMoved   = false
        self.isDragging = false

        -- Overlay absorbs all presses
        if self.showDetail then return end

        -- IP field tap (only on Play panel)
        if self.currentPanel == 3 and self._ipFieldRect then
            local f = self._ipFieldRect
            if x >= f.x and x <= f.x + f.w and y >= f.y and y <= f.y + f.h then
                self.inputActive = true
                return
            end
        end
        self.inputActive = false
    end

    function self:handleMove(x, y)
        if not self.isPressed then return end
        if self.showDetail then return end

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
        local dx = x - self.pressX

        -- Detail overlay: check back button
        if self.showDetail then
            local bb = self._detailBackBtn
            if bb and x >= bb.x and x <= bb.x + bb.w and y >= bb.y and y <= bb.y + bb.h then
                self.showDetail = false
                self.detailUnit = nil
            end
            return
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
            return
        end

        -- Tap: bottom tab icons
        for i, rect in ipairs(self._tabRects) do
            if x >= rect.x and x <= rect.x + rect.w and y >= rect.y and y <= rect.y + rect.h then
                if i ~= self.currentPanel then
                    self.currentPanel = i
                    self.targetOffset = -(i - 1) * Constants.GAME_WIDTH
                end
                return
            end
        end

        -- Tap: collection cards
        if self.currentPanel == 1 then
            for _, card in ipairs(self._collectionCards) do
                if x >= card.x and x <= card.x + card.w and
                   y >= card.y and y <= card.y + card.h then
                    self.detailUnit = card.utype
                    self.showDetail = true
                    return
                end
            end
        end

        -- Tap: Play Online button
        if self.currentPanel == 3 then
            local btn = self._playBtnRect
            if btn and x >= btn.x and x <= btn.x + btn.w and
                       y >= btn.y and y <= btn.y + btn.h then
                local ScreenManager = require('lib.screen_manager')
                local ip = (self.ipText ~= "" and self.ipText) or "127.0.0.1"
                ScreenManager.switch('lobby', ip)
                return
            end
        end
    end

    function self:mousepressed(x, y, button)
        if button == 1 then self:handlePress(x, y) end
    end
    function self:touchpressed(_, x, y)
        self:handlePress(x, y)
    end
    function self:mousemoved(x, y)
        self:handleMove(x, y)
    end
    function self:touchmoved(_, x, y)
        self:handleMove(x, y)
    end
    function self:mousereleased(x, y, button)
        if button == 1 then self:handleRelease(x, y) end
    end
    function self:touchreleased(_, x, y)
        self:handleRelease(x, y)
    end

    function self:textinput(t)
        if not self.inputActive then return end
        self.ipText = self.ipText .. t
    end

    function self:keypressed(key)
        if key == "escape" then
            if self.showDetail then
                self.showDetail = false
                self.detailUnit = nil
            else
                self.inputActive = false
            end
            return
        end
        if not self.inputActive then return end
        if key == "backspace" then
            self.ipText = self.ipText:sub(1, -2)
        elseif key == "return" or key == "kpenter" then
            self.inputActive = false
        end
    end

    return self
end

return MenuScreen
