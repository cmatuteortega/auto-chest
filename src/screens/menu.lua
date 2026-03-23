-- AutoChest – Main Menu Screen
-- 3-panel swipeable card navigation: Collection | Play Online | Shop

local Screen       = require('lib.screen')
local Constants    = require('src.constants')
local UnitRegistry = require('src.unit_registry')
local DeckManager  = require('src.deck_manager')

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

        -- (IP input removed - now using authentication)

        -- Unit detail overlay
        self.showDetail = false
        self.detailUnit = nil   -- unitType string

        -- Deck builder state
        DeckManager.load()
        self.selectedDeckSlot = 1
        self._deckSlotRects   = {}
        self._deckCardRects   = {}
        self._deckSaveRect    = nil
        self._deckActiveRect  = nil
        self._saveFeedback    = 0
        self.previewLayout    = {}

        -- Load front sprites for collection display (sorted for stable ordering).
        -- Use loadSprites so we also get frontTrimBottom for baseline alignment.
        self.unitOrder        = UnitRegistry.getAllUnitTypes()
        table.sort(self.unitOrder)
        self.sprites          = {}
        self.spriteTrimBottoms = {}
        -- Directional sprites for play-panel idle animation (keyed by unitType)
        self.dirSprites = {}
        -- Per-unit idle animation state: {frameIndex, timer}
        self.idleAnim   = {}
        for _, utype in ipairs(self.unitOrder) do
            local loaded = UnitRegistry.loadDirectionalSprites(utype)
            self.sprites[utype]           = loaded.front
            self.spriteTrimBottoms[utype] = loaded.frontTrimBottom
            self.dirSprites[utype]        = loaded
            self.idleAnim[utype]          = { frameIndex = 1, timer = 0 }
        end
        self:buildPreviewLayout()

        -- Bottom tab bar icons (order matches panel indices)
        self.uiIcons = {}
        for i, name in ipairs({ 'collection', 'decks', 'battle', 'shop', 'ranking' }) do
            local img = love.graphics.newImage('src/assets/ui/' .. name .. '.png')
            img:setFilter('nearest', 'nearest')
            self.uiIcons[i] = img
        end

        -- Currency strip icons
        self.gemIcon  = love.graphics.newImage('src/assets/ui/gem.png')
        self.goldIcon = love.graphics.newImage('src/assets/ui/gold.png')
        self.gemIcon:setFilter('nearest', 'nearest')
        self.goldIcon:setFilter('nearest', 'nearest')
        -- Tab raise animation values: 0 = flat, 1 = fully popped
        self.tabRaiseAnim = { 0, 0, 1, 0, 0 }  -- panel 3 (Battle) starts active

        -- Settings overlay
        self.showSettings        = false
        self._settingsBtnRect    = nil
        self._settingsLogoutRect = nil
        self._settingsMusicRect  = nil
        self._settingsSFXRect    = nil

        -- Hit-rect caches (rebuilt each draw, stored in screen coords)
        self._collectionCards = {}
        self._ipFieldRect     = nil
        self._playBtnRect     = nil
        self._sandboxBtnRect  = nil
        self._tabRects        = {}

        -- Shop state
        self._shopGemBtns  = {}  -- hit rects for gem purchase buttons
        self._shopGoldBtns = {}  -- hit rects for gold purchase buttons
        self.shopNotice    = nil
        self.shopNoticeTimer = 0

        -- Register socket handlers once (not per-frame)
        if _G.GameSocket then
            _G.GameSocket:on("currency_update", function(data)
                print("[MENU] currency_update received gold=" .. tostring(data.gold) .. " gems=" .. tostring(data.gems))
                if _G.PlayerData then
                    if data.gold ~= nil then _G.PlayerData.gold = data.gold end
                    if data.gems ~= nil then _G.PlayerData.gems = data.gems end
                end
            end)

            _G.GameSocket:on("shop_error", function(data)
                self.shopNotice = data.reason or "Purchase failed"
                self.shopNoticeTimer = 2.5
            end)
        else
            print("[MENU] WARNING: _G.GameSocket is nil at init, no handlers registered")
        end

        love.keyboard.setKeyRepeat(true)

        -- Start background music when player lands on menu
        AudioManager.playMusic()
        AudioManager.setBattleMode(false)
    end

    function self:close()
        love.keyboard.setKeyRepeat(false)
    end

    function self:buildPreviewLayout()
        self.previewLayout = {}
        local deck = DeckManager.getActiveDeck()
        if not deck then return end

        -- One entry per unit type that has at least 1 card
        local units = {}
        for utype, count in pairs(deck.counts) do
            if count > 0 then
                table.insert(units, utype)
            end
        end
        if #units == 0 then return end

        -- All 20 positions (4 rows × 5 cols), Fisher-Yates shuffled
        local positions = {}
        for r = 1, 4 do
            for c = 1, 5 do
                table.insert(positions, { col = c, row = r })
            end
        end
        for i = #positions, 2, -1 do
            local j = math.random(i)
            positions[i], positions[j] = positions[j], positions[i]
        end

        local n = math.min(#units, #positions)
        for i = 1, n do
            table.insert(self.previewLayout, {
                unitType = units[i],
                col      = positions[i].col,
                row      = positions[i].row,
            })
        end
    end

    -- ── update ──────────────────────────────────────────────────────────────

    function self:update(dt)
        -- Keep socket connection alive
        if _G.GameSocket then
            _G.GameSocket:update()
        end

        -- Save feedback timer
        if self._saveFeedback > 0 then
            self._saveFeedback = self._saveFeedback - dt
        end

        -- Shop notice timer
        if self.shopNoticeTimer > 0 then
            self.shopNoticeTimer = self.shopNoticeTimer - dt
            if self.shopNoticeTimer <= 0 then
                self.shopNotice    = nil
                self.shopNoticeTimer = 0
            end
        end

        -- Advance idle animation for play-panel preview (uses the same 2× slower cadence as in-game)
        local IDLE_FRAME_DUR = 0.12 * 2  -- matches animFrameDuration * 2 from base_unit
        for _, utype in ipairs(self.unitOrder) do
            local d = self.dirSprites[utype]
            if d and d.hasDirectionalSprites and d.directional.idle and d.directional.idle[0] then
                local frames = d.directional.idle[0].frames
                local anim   = self.idleAnim[utype]
                anim.timer = anim.timer + dt
                if anim.timer >= IDLE_FRAME_DUR then
                    anim.timer = anim.timer - IDLE_FRAME_DUR
                    anim.frameIndex = (anim.frameIndex % #frames) + 1
                end
            end
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

    -- Returns the current idle animation frame + trimBottom for a unit type.
    -- Falls back to the static front sprite when no directional sprites exist.
    function self:getIdleFrame(utype)
        local d = self.dirSprites[utype]
        if d and d.hasDirectionalSprites and d.directional.idle and d.directional.idle[0] then
            local dirData = d.directional.idle[0]
            local idx     = self.idleAnim[utype].frameIndex
            return dirData.frames[idx], dirData.trimBottom[idx]
        end
        return self.sprites[utype], self.spriteTrimBottoms[utype] or 0
    end

    -- ── draw helpers ────────────────────────────────────────────────────────

    local function roundedRect(x, y, w, h, r, sc)
        love.graphics.rectangle('fill', x, y, w, h, r * sc, r * sc)
    end

    local function roundedRectLine(x, y, w, h, r, sc, lw)
        love.graphics.setLineWidth(lw or 2)
        love.graphics.rectangle('line', x, y, w, h, r * sc, r * sc)
    end

    -- Vertically centre text in a box using actual glyph bounds (excludes leading)
    local function textCY(font, boxY, boxH)
        return math.floor(boxY + (boxH - (font:getAscent() - font:getDescent())) / 2)
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

        -- Front sprite (integer scale, bottom-anchored to card baseline)
        local img        = self.sprites[utype]
        local iw, ih     = img:getDimensions()
        local trimBottom = self.spriteTrimBottoms[utype] or 0
        local sprSc      = math.max(1, math.floor(4 * sc))
        local BOTTOM_MARGIN = 3
        local sx = math.floor(cx + (cardW - iw * sprSc) / 2)
        local sy = math.floor(cy + cardH - (ih - trimBottom + BOTTOM_MARGIN) * sprSc)
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
        lg.printf("Collection", ox, 82 * sc, W, 'center')

        local cols   = 4
        local cardW  = 100 * sc
        local cardH  = 130 * sc
        local gapX   = 12  * sc
        local gapY   = 14  * sc
        local totalW = cols * cardW + (cols - 1) * gapX
        local startX = ox + (W - totalW) / 2
        local startY = 160 * sc

        -- cards laid out in rows of 4
        self._collectionCards = {}
        for i, utype in ipairs(self.unitOrder) do
            local col = (i - 1) % cols
            local row = math.floor((i - 1) / cols)
            local cx  = startX + col * (cardW + gapX)
            local cy  = startY + row * (cardH + gapY)
            self:drawCollectionCard(cx, cy, cardW, cardH, utype, sc)
            self._collectionCards[i] = {
                x = cx + self.panelOffset,
                y = cy,
                w = cardW,
                h = cardH,
                utype = utype
            }
        end
    end

    function self:drawPlayPanel(ox, W, H, sc)
        local lg       = love.graphics
        local cx       = ox + W / 2
        local cellSize    = Constants.CELL_SIZE
        local gridW       = 5 * cellSize
        local gridH       = 4 * cellSize
        local gridX       = ox + (W - gridW) / 2
        local titleY      = 82 * sc
        local btnY        = H * 0.70
        local titleBottom = titleY + Fonts.large:getHeight()
        local gridY       = math.floor(titleBottom + (btnY - titleBottom - gridH) / 2)

        -- Title
        lg.setFont(Fonts.large)
        lg.setColor(1, 1, 1, 1)
        lg.printf("AutoChest", ox, titleY, W, 'center')

        -- Checkerboard cells
        local CDARK  = Constants.COLORS.CHESS_DARK
        local CLIGHT = Constants.COLORS.CHESS_LIGHT
        for row = 1, 4 do
            for col = 1, 5 do
                local cx2 = gridX + (col - 1) * cellSize
                local cy2 = gridY + (row - 1) * cellSize
                lg.setColor((row + col) % 2 == 0 and CDARK or CLIGHT)
                lg.rectangle('fill', cx2, cy2, cellSize, cellSize)
            end
        end

        -- Grid border
        lg.setColor(0.22, 0.35, 0.50, 1)
        lg.setLineWidth(math.max(1, math.floor(sc)))
        lg.rectangle('line', gridX, gridY, gridW, gridH)

        -- Unit sprites (idle-animated if directional sprites are available)
        local sprSc = cellSize / 16
        for _, entry in ipairs(self.previewLayout) do
            local img, trimBottom = self:getIdleFrame(entry.unitType)
            if img then
                local iw, ih     = img:getDimensions()
                local cx2 = gridX + (entry.col - 1) * cellSize
                local cy2 = gridY + (entry.row - 1) * cellSize
                local BOTTOM_MARGIN = 3
                local sx  = math.floor(cx2 + (cellSize - iw * sprSc) / 2)
                local sy  = math.floor(cy2 + cellSize - (ih - trimBottom + BOTTOM_MARGIN) * sprSc)
                lg.setColor(1, 1, 1, 1)
                lg.draw(img, sx, sy, 0, sprSc, sprSc)
            end
        end

        -- Empty deck hint
        if #self.previewLayout == 0 then
            lg.setFont(Fonts.small)
            lg.setColor(0.45, 0.50, 0.60, 1)
            lg.printf("Equip a deck to preview", gridX,
                gridY + gridH / 2 - Fonts.small:getHeight() / 2, gridW, 'center')
        end

        -- Buttons
        local btnW = 240 * sc
        local btnH = 56  * sc
        local btnX = cx - btnW / 2

        lg.setColor(0.15, 0.32, 0.65, 1)
        roundedRect(btnX, btnY, btnW, btnH, 8, sc)
        lg.setColor(0.25, 0.45, 0.85, 1)
        roundedRectLine(btnX, btnY, btnW, btnH, 8, sc, 2 * sc)
        lg.setFont(Fonts.medium)
        lg.setColor(1, 1, 1, 1)
        lg.printf("PLAY ONLINE", btnX, textCY(Fonts.medium, btnY, btnH), btnW, 'center')
        self._playBtnRect = { x = btnX + self.panelOffset, y = btnY, w = btnW, h = btnH }

        local sbtnY = btnY + btnH + 14 * sc
        lg.setColor(0.45, 0.28, 0.08, 1)
        roundedRect(btnX, sbtnY, btnW, btnH, 8, sc)
        lg.setColor(0.70, 0.48, 0.15, 1)
        roundedRectLine(btnX, sbtnY, btnW, btnH, 8, sc, 2 * sc)
        lg.setFont(Fonts.medium)
        lg.setColor(1, 1, 1, 1)
        lg.printf("SANDBOX", btnX, textCY(Fonts.medium, sbtnY, btnH), btnW, 'center')
        self._sandboxBtnRect = { x = btnX + self.panelOffset, y = sbtnY, w = btnW, h = btnH }
    end

    function self:drawDecksPanel(ox, W, H, sc)
        local lg = love.graphics

        -- Title
        lg.setFont(Fonts.large)
        lg.setColor(1, 1, 1, 1)
        lg.printf("Decks", ox, 82 * sc, W, 'center')

        -- ── Deck slot tabs ────────────────────────────────────────────────────
        local tabAreaW  = W - 40 * sc
        local tabW      = tabAreaW / 5
        local tabH      = 44 * sc
        local tabY      = 138 * sc
        local tabStartX = ox + 20 * sc

        self._deckSlotRects = {}
        for i = 1, 5 do
            local tx = tabStartX + (i - 1) * tabW
            if i == self.selectedDeckSlot then
                lg.setColor(0.18, 0.20, 0.30, 1)
                roundedRect(tx, tabY, tabW - 4 * sc, tabH, 5, sc)
                lg.setColor(0.45, 0.48, 0.70, 1)
                roundedRectLine(tx, tabY, tabW - 4 * sc, tabH, 5, sc, 2 * sc)
            else
                lg.setColor(0.12, 0.12, 0.18, 1)
                roundedRect(tx, tabY, tabW - 4 * sc, tabH, 5, sc)
                lg.setColor(0.28, 0.28, 0.40, 1)
                roundedRectLine(tx, tabY, tabW - 4 * sc, tabH, 5, sc, 1 * sc)
            end
            lg.setFont(Fonts.small)
            lg.setColor(0.85, 0.85, 0.90, 1)
            lg.printf("D" .. i, tx, textCY(Fonts.small, tabY, tabH), tabW - 4 * sc, 'center')
            if DeckManager._data.activeDeckIndex == i then
                lg.setColor(0.9, 0.85, 0.2, 1)
                love.graphics.circle('fill', tx + tabW - 10 * sc, tabY + 8 * sc, 5 * sc)
            end
            self._deckSlotRects[i] = {
                x = tx + self.panelOffset,
                y = tabY,
                w = tabW - 4 * sc,
                h = tabH
            }
        end

        -- ── Save + Total + Equip row ───────────────────────────────────────────
        local total    = DeckManager.getTotalCount(self.selectedDeckSlot)
        local isActive = DeckManager._data.activeDeckIndex == self.selectedDeckSlot
        local barY     = tabY + tabH + 8 * sc
        local barH     = 40 * sc
        local barX     = ox + 20 * sc
        local barW     = W - 40 * sc
        local btnW     = 90 * sc

        -- SAVE button
        local saveX = barX
        if self._saveFeedback > 0 then
            lg.setColor(0.10, 0.36, 0.16, 1)
            roundedRect(saveX, barY, btnW, barH, 5, sc)
            lg.setColor(0.22, 0.68, 0.34, 1)
            roundedRectLine(saveX, barY, btnW, barH, 5, sc, 2 * sc)
            lg.setFont(Fonts.small)
            lg.setColor(0.6, 1, 0.7, 1)
            lg.printf("Saved!", saveX, textCY(Fonts.small, barY, barH), btnW, 'center')
        else
            lg.setColor(0.16, 0.16, 0.24, 1)
            roundedRect(saveX, barY, btnW, barH, 5, sc)
            lg.setColor(0.32, 0.32, 0.48, 1)
            roundedRectLine(saveX, barY, btnW, barH, 5, sc, 2 * sc)
            lg.setFont(Fonts.small)
            lg.setColor(0.85, 0.85, 0.90, 1)
            lg.printf("Save", saveX, textCY(Fonts.small, barY, barH), btnW, 'center')
        end
        self._deckSaveRect = { x = saveX + self.panelOffset, y = barY, w = btnW, h = barH }

        -- Total counter (center)
        local counterX = barX + btnW + 4 * sc
        local counterW = barW - 2 * (btnW + 4 * sc)
        lg.setFont(Fonts.small)
        lg.setColor(total >= 20 and {1, 0.4, 0.4, 1} or {0.7, 0.7, 0.75, 1})
        lg.printf(total .. " / 20", counterX, textCY(Fonts.small, barY, barH), counterW, 'center')

        -- EQUIP button
        local equipX = barX + barW - btnW
        if total == 0 then
            lg.setColor(0.16, 0.16, 0.22, 1)
            roundedRect(equipX, barY, btnW, barH, 5, sc)
            lg.setColor(0.26, 0.26, 0.36, 1)
            roundedRectLine(equipX, barY, btnW, barH, 5, sc, 2 * sc)
            lg.setFont(Fonts.small)
            lg.setColor(0.38, 0.38, 0.44, 1)
            lg.printf("Equip", equipX, textCY(Fonts.small, barY, barH), btnW, 'center')
            self._deckActiveRect = nil
        elseif isActive then
            lg.setColor(0.10, 0.38, 0.18, 1)
            roundedRect(equipX, barY, btnW, barH, 5, sc)
            lg.setColor(0.22, 0.68, 0.36, 1)
            roundedRectLine(equipX, barY, btnW, barH, 5, sc, 2 * sc)
            lg.setFont(Fonts.small)
            lg.setColor(0.7, 1, 0.75, 1)
            lg.printf("Equip ✓", equipX, textCY(Fonts.small, barY, barH), btnW, 'center')
            self._deckActiveRect = { x = equipX + self.panelOffset, y = barY, w = btnW, h = barH }
        else
            lg.setColor(0.10, 0.22, 0.50, 1)
            roundedRect(equipX, barY, btnW, barH, 5, sc)
            lg.setColor(0.22, 0.42, 0.82, 1)
            roundedRectLine(equipX, barY, btnW, barH, 5, sc, 2 * sc)
            lg.setFont(Fonts.small)
            lg.setColor(1, 1, 1, 1)
            lg.printf("Equip", equipX, textCY(Fonts.small, barY, barH), btnW, 'center')
            self._deckActiveRect = { x = equipX + self.panelOffset, y = barY, w = btnW, h = barH }
        end

        -- ── Unit card grid ────────────────────────────────────────────────────
        local cols   = 4
        local cardW  = 108 * sc
        local cardH  = 138 * sc
        local gapX   = 8   * sc
        local gapY   = 10  * sc
        local totalW = cols * cardW + (cols - 1) * gapX
        local startX = ox + (W - totalW) / 2
        local startY = barY + barH + 12 * sc
        local stripH = 32 * sc

        local deck = DeckManager.getDeck(self.selectedDeckSlot)

        -- Build sorted unit list: count>0 first (desc), then alpha
        local sortedUnits = {}
        for _, utype in ipairs(self.unitOrder) do
            table.insert(sortedUnits, { utype = utype, count = deck.counts[utype] or 0 })
        end
        table.sort(sortedUnits, function(a, b)
            if a.count ~= b.count then return a.count > b.count end
            return a.utype < b.utype
        end)

        self._deckCardRects = {}

        for i, entry in ipairs(sortedUnits) do
            local utype = entry.utype
            local count = entry.count
            local col   = (i - 1) % cols
            local row   = math.floor((i - 1) / cols)
            local cx    = startX + col * (cardW + gapX)
            local cy    = startY + row * (cardH + gapY)

            -- Card background
            lg.setColor(0.14, 0.14, 0.20, 1)
            roundedRect(cx, cy, cardW, cardH, 6, sc)
            -- Border: gold if selected, dim if not
            if count > 0 then
                lg.setColor(0.75, 0.65, 0.15, 1)
            else
                lg.setColor(0.26, 0.26, 0.38, 1)
            end
            roundedRectLine(cx, cy, cardW, cardH, 6, sc, 2 * sc)

            -- Unit name
            lg.setFont(Fonts.small)
            lg.setColor(0.9, 0.9, 0.9, 1)
            local name = utype:sub(1,1):upper() .. utype:sub(2)
            lg.printf(name, cx, cy + 6 * sc, cardW, 'center')

            -- Sprite (bottom-anchored above bottom strip)
            local img = self.sprites[utype]
            if img then
                local iw, ih     = img:getDimensions()
                local trimBottom = self.spriteTrimBottoms[utype] or 0
                local sprSc      = math.max(1, math.floor(4 * sc))
                local BOTTOM_MARGIN = 3
                local sx = math.floor(cx + (cardW - iw * sprSc) / 2)
                local spriteBase = cy + cardH - stripH - BOTTOM_MARGIN * sc
                local sy = math.floor(spriteBase - (ih - trimBottom) * sprSc)
                lg.setColor(1, 1, 1, 1)
                lg.draw(img, sx, sy, 0, sprSc, sprSc)
            end

            -- Bottom strip background
            local stripY = cy + cardH - stripH
            lg.setColor(0.10, 0.10, 0.16, 1)
            love.graphics.rectangle('fill', cx + 2 * sc, stripY, cardW - 4 * sc, stripH - 2 * sc)

            -- [-] label (left 30%)
            local minusW = math.floor(cardW * 0.30)
            lg.setFont(Fonts.medium)
            if count > 0 then
                lg.setColor(0.9, 0.9, 0.9, 1)
            else
                lg.setColor(0.35, 0.35, 0.40, 1)
            end
            lg.printf("-", cx, textCY(Fonts.medium, stripY, stripH), minusW, 'center')

            -- count (center 40%)
            local centerW = math.floor(cardW * 0.40)
            local centerX = cx + minusW
            lg.setFont(Fonts.medium)
            lg.setColor(1, 1, 1, 1)
            lg.printf(tostring(count), centerX, textCY(Fonts.medium, stripY, stripH), centerW, 'center')

            -- [+] label (right 30%)
            local plusW = cardW - minusW - centerW
            local plusX = cx + minusW + centerW
            if total < 20 then
                lg.setColor(0.9, 0.9, 0.9, 1)
            else
                lg.setColor(0.35, 0.35, 0.40, 1)
            end
            lg.printf("+", plusX, textCY(Fonts.medium, stripY, stripH), plusW, 'center')

            -- Hit rect (screen space)
            self._deckCardRects[i] = {
                utype  = utype,
                minusX = cx + self.panelOffset,
                minusW = minusW,
                plusX  = cx + minusW + centerW + self.panelOffset,
                plusW  = plusW,
                stripY = stripY,
                stripH = stripH,
            }
        end
    end

    function self:drawRankingPanel(ox, W, H, sc)
        local lg = love.graphics
        lg.setFont(Fonts.large)
        lg.setColor(1, 1, 1, 1)
        lg.printf("Ranking", ox, 82 * sc, W, 'center')
        lg.setFont(Fonts.medium)
        lg.setColor(0.4, 0.4, 0.45, 1)
        lg.printf("Coming Soon", ox, H * 0.42, W, 'center')
    end

    function self:drawShopPanel(ox, W, H, sc)
        local lg = love.graphics

        -- Title
        lg.setFont(Fonts.large)
        lg.setColor(1, 1, 1, 1)
        lg.printf("Shop", ox, 82 * sc, W, 'center')

        -- Layout constants
        local gapX    = 10 * sc
        local gapY    = 16 * sc
        local padX    = 14 * sc
        local btnH    = 36  * sc
        local cardPad = 10  * sc  -- inner top/bottom padding
        local cardW   = math.floor((W - 2 * padX - 2 * gapX) / 3)
        local startX  = ox + padX

        -- Compute card height from actual font metrics so nothing clips
        local labelH  = Fonts.medium:getHeight()
        local amountH = Fonts.large:getHeight()
        local subH    = Fonts.small:getHeight()
        local cardH   = cardPad + labelH + 6 * sc + amountH + 6 * sc + subH + 8 * sc + btnH + cardPad

        local curY = 126 * sc

        -- ── Helper: draw one shop card ────────────────────────────────────────
        local function drawCard(i, cy, bgCol, borderCol, labelCol, labelTxt, amountTxt, subCol, subTxt, btnEnabled)
            local cx = startX + (i - 1) * (cardW + gapX)

            lg.setColor(bgCol)
            roundedRect(cx, cy, cardW, cardH, 6, sc)
            lg.setColor(borderCol)
            roundedRectLine(cx, cy, cardW, cardH, 6, sc, 2 * sc)

            local yLabel  = cy + cardPad
            local yAmount = yLabel  + labelH + 6 * sc
            local yPrice  = yAmount + amountH + 6 * sc
            local yBtn    = cy + cardH - cardPad - btnH

            lg.setFont(Fonts.medium)
            lg.setColor(labelCol)
            lg.printf(labelTxt, cx, yLabel, cardW, 'center')

            lg.setFont(Fonts.large)
            lg.setColor(1, 1, 1, 1)
            lg.printf(amountTxt, cx, yAmount, cardW, 'center')

            lg.setFont(Fonts.small)
            lg.setColor(subCol)
            lg.printf(subTxt, cx, yPrice, cardW, 'center')

            local bx = cx + 6 * sc
            local bw = cardW - 12 * sc
            if btnEnabled then
                lg.setColor(borderCol[1] * 0.5, borderCol[2] * 0.5, borderCol[3] * 0.5, 1)
                roundedRect(bx, yBtn, bw, btnH, 5, sc)
                lg.setColor(borderCol)
                roundedRectLine(bx, yBtn, bw, btnH, 5, sc, 2 * sc)
                lg.setFont(Fonts.small)
                lg.setColor(1, 1, 1, 1)
            else
                lg.setColor(0.14, 0.14, 0.18, 1)
                roundedRect(bx, yBtn, bw, btnH, 5, sc)
                lg.setColor(0.28, 0.28, 0.36, 1)
                roundedRectLine(bx, yBtn, bw, btnH, 5, sc, 2 * sc)
                lg.setFont(Fonts.small)
                lg.setColor(0.40, 0.40, 0.45, 1)
            end
            lg.printf("Buy", bx, textCY(Fonts.small, yBtn, btnH), bw, 'center')

            return { x = bx + self.panelOffset, y = yBtn, w = bw, h = btnH }
        end

        -- ── Section: Buy Gems ────────────────────────────────────────────────
        lg.setFont(Fonts.small)
        lg.setColor(0.65, 0.55, 1.0, 1)
        lg.printf("Buy Gems  (real money – coming soon)", ox, curY, W, 'center')
        curY = curY + subH + 8 * sc

        local gemPackages = {
            { gems = 10,  price = "€1.00",  key = "gems_10"  },
            { gems = 50,  price = "€3.50",  key = "gems_50"  },
            { gems = 100, price = "€10.00", key = "gems_100" },
        }

        self._shopGemBtns = {}
        for i, pkg in ipairs(gemPackages) do
            local btn = drawCard(i, curY,
                {0.12, 0.10, 0.22, 1}, {0.55, 0.38, 0.90, 1},
                {0.70, 0.50, 1.00, 1}, "GEMS",
                tostring(pkg.gems),
                {0.75, 0.75, 0.80, 1}, pkg.price,
                true)
            btn.key   = pkg.key
            btn.gems  = pkg.gems
            btn.price = pkg.price
            self._shopGemBtns[i] = btn
        end
        curY = curY + cardH + gapY

        -- ── Section: Buy Gold ────────────────────────────────────────────────
        lg.setFont(Fonts.small)
        lg.setColor(0.90, 0.75, 0.20, 1)
        lg.printf("Buy Gold  (spend gems)", ox, curY, W, 'center')
        curY = curY + subH + 8 * sc

        local goldPackages = {
            { gold = 1000,  gems = 10,  key = "gold_1000"  },
            { gold = 5000,  gems = 50,  key = "gold_5000"  },
            { gold = 10000, gems = 100, key = "gold_10000" },
        }

        local playerGems = (_G.PlayerData and _G.PlayerData.gems) or 0
        self._shopGoldBtns = {}
        for i, pkg in ipairs(goldPackages) do
            local canAfford = playerGems >= pkg.gems
            local goldText  = (pkg.gold >= 1000) and (math.floor(pkg.gold / 1000) .. "K") or tostring(pkg.gold)
            local btn = drawCard(i, curY,
                {0.14, 0.12, 0.06, 1}, {0.75, 0.60, 0.15, 1},
                {0.90, 0.75, 0.20, 1}, "GOLD",
                goldText,
                {0.65, 0.55, 1.00, 1}, pkg.gems .. " gems",
                canAfford)
            btn.key        = pkg.key
            btn.canAfford  = canAfford
            self._shopGoldBtns[i] = btn
        end

        -- ── Notice ────────────────────────────────────────────────────────────
        if self.shopNotice then
            lg.setFont(Fonts.small)
            lg.setColor(1, 0.85, 0.3, 1)
            lg.printf(self.shopNotice, ox, curY + cardH + 8 * sc, W, 'center')
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

        local img        = self.sprites[utype]
        local iw, ih     = img:getDimensions()
        local trimBottom = self.spriteTrimBottoms[utype] or 0
        local info       = UnitRegistry.getUnitDisplayInfo(utype)
        local passive    = UnitRegistry.passiveDescriptions[utype] or ""
        local sprSc      = math.max(1, math.floor(5 * sc))

        -- Panel width + text area
        local panW  = math.floor(W * 0.84)
        local textW = panW - math.floor(32 * sc)
        local brd   = math.max(1, math.floor(2 * sc))

        -- Pre-compute content height so panel fits content exactly
        local _, pLines = Fonts.tiny:getWrap(passive, textW)
        local vPad = math.floor(14 * sc)
        local contentH =
            (ih - trimBottom) * sprSc                                   +
            math.floor(7 * sc)                                          + -- sprite → name gap
            Fonts.medium:getHeight() + math.floor(5 * sc)              + -- name
            Fonts.tiny:getHeight()   + math.floor(7 * sc)              + -- stats
            math.floor(7 * sc)                                          + -- separator
            math.max(1, #pLines) * Fonts.tiny:getHeight()
                + math.floor(8 * sc)                                    + -- passive
            Fonts.small:getHeight() + math.floor(4 * sc)               + -- "Upgrades" header
            #info.upgrades * (2 * Fonts.tiny:getHeight()
                + math.floor(6 * sc))                                     -- upgrade rows

        local panH = contentH + vPad * 2
        -- Guard: never taller than 88% of screen
        panH = math.min(panH, math.floor(H * 0.88))
        local panX = math.floor((W - panW) / 2)
        local panY = math.floor((H - panH) / 2)

        -- Dim backdrop
        lg.setColor(0, 0, 0, 0.65)
        lg.rectangle('fill', 0, 0, W, H)

        -- Panel fill
        lg.setColor(0.14, 0.15, 0.22, 1)
        roundedRect(panX, panY, panW, panH, 5, sc)

        -- Outer border
        lg.setColor(0.42, 0.44, 0.62, 1)
        roundedRectLine(panX, panY, panW, panH, 5, sc, brd)

        -- Bevel: top-left highlight
        local hl = brd + math.max(1, math.floor(sc))
        lg.setColor(0.55, 0.57, 0.78, 0.45)
        lg.setLineWidth(math.max(1, math.floor(sc)))
        lg.line(panX + hl, panY + panH - hl,
                panX + hl, panY + hl,
                panX + panW - hl, panY + hl)
        -- Bevel: bottom-right shadow
        lg.setColor(0.04, 0.04, 0.08, 0.6)
        lg.line(panX + hl, panY + panH - hl,
                panX + panW - hl, panY + panH - hl,
                panX + panW - hl, panY + hl)

        -- Sprite (centred horizontally, top of content area)
        local imgX = math.floor(panX + (panW - iw * sprSc) / 2)
        local imgY = math.floor(panY + vPad)
        lg.setColor(1, 1, 1, 1)
        lg.draw(img, imgX, imgY, 0, sprSc, sprSc)

        local textX = panX + math.floor(16 * sc)
        local curY  = imgY + (ih - trimBottom) * sprSc + math.floor(7 * sc)

        -- Unit name
        local name = utype:sub(1,1):upper() .. utype:sub(2)
        lg.setFont(Fonts.medium)
        lg.setColor(1, 1, 1, 1)
        lg.printf(name, panX, curY, panW, 'center')
        curY = curY + Fonts.medium:getHeight() + math.floor(5 * sc)

        -- Stats row
        local info2 = info  -- already fetched above
        lg.setFont(Fonts.tiny)
        lg.setColor(0.65, 0.78, 1, 1)
        local s = string.format("HP %d  ATK %d  SPD %.1f  RNG %d  [%s]",
            info2.hp, info2.atk, info2.spd, info2.rng, info2.unitClass)
        lg.printf(s, textX, curY, textW, 'center')
        curY = curY + Fonts.tiny:getHeight() + math.floor(7 * sc)

        -- Separator
        lg.setColor(0.30, 0.32, 0.48, 1)
        lg.setLineWidth(math.max(1, math.floor(sc)))
        lg.line(textX, curY, panX + panW - math.floor(16 * sc), curY)
        curY = curY + math.floor(7 * sc)

        -- Passive description
        lg.setFont(Fonts.tiny)
        lg.setColor(0.72, 0.74, 0.80, 1)
        lg.printf(passive, textX, curY, textW, 'left')
        curY = curY + math.max(1, #pLines) * Fonts.tiny:getHeight() + math.floor(8 * sc)

        -- Upgrades header
        lg.setFont(Fonts.small)
        lg.setColor(1, 0.85, 0.38, 1)
        lg.printf("Upgrades", textX, curY, textW, 'left')
        curY = curY + Fonts.small:getHeight() + math.floor(4 * sc)

        -- Upgrade rows
        lg.setFont(Fonts.tiny)
        for i, upg in ipairs(info2.upgrades) do
            lg.setColor(1, 0.85, 0.38, 1)
            lg.printf(i .. ". " .. upg.name, textX + math.floor(6 * sc), curY, textW, 'left')
            curY = curY + Fonts.tiny:getHeight() + math.floor(2 * sc)
            lg.setColor(0.72, 0.74, 0.80, 1)
            lg.printf("   " .. upg.description, textX + math.floor(6 * sc), curY, textW, 'left')
            curY = curY + Fonts.tiny:getHeight() + math.floor(4 * sc)
        end
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

        -- Top-left header: player name + trophies, then gem/gold strips
        if _G.PlayerData then
            local hPad    = math.floor(8  * sc)
            local vPad    = math.floor(5  * sc)
            local iconGap = math.floor(4  * sc)
            local lw      = math.max(1, math.floor(sc))

            -- Strip height based on Fonts.small (number text inside strips)
            lg.setFont(Fonts.small)
            local numLineH = Fonts.small:getHeight()
            local stripH   = numLineH + vPad * 2
            local stripY   = math.floor(8 * sc)
            local xCur     = math.floor(8 * sc)

            -- Player name in Fonts.medium, vertically centred against strip row
            lg.setFont(Fonts.medium)
            local nameStr  = _G.PlayerData.username or ""
            local nameW    = Fonts.medium:getWidth(nameStr)
            local nameY    = textCY(Fonts.medium, stripY, stripH)
            lg.setColor(1, 1, 1, 1)
            lg.print(nameStr, xCur, nameY)

            -- Trophies below name, slightly indented
            lg.setFont(Fonts.tiny)
            lg.setColor(0.9, 0.85, 0.3, 0.9)
            lg.print(tostring(_G.PlayerData.trophies or 0) .. " trophies",
                     xCur + math.floor(4 * sc),
                     stripY + stripH + math.floor(1 * sc))

            xCur = xCur + nameW + math.floor(12 * sc)

            -- Scale icon to integer multiple of its 6px height
            local iconPixSc = math.max(1, math.floor(numLineH / 6))

            local strips = {
                { icon = self.goldIcon, value = _G.PlayerData.gold or 0 },
                { icon = self.gemIcon,  value = _G.PlayerData.gems or 0 },
            }

            for _, s in ipairs(strips) do
                local iw     = s.icon:getWidth()  * iconPixSc
                local ih     = s.icon:getHeight() * iconPixSc
                local numStr = tostring(s.value)
                lg.setFont(Fonts.small)
                local numW   = Fonts.small:getWidth(numStr)
                local stripW = hPad + iw + iconGap + numW + hPad

                -- White outline, slightly rounded
                lg.setColor(1, 1, 1, 0.9)
                lg.setLineWidth(lw)
                local r = math.max(1, math.floor(3 * sc))
                lg.rectangle('line', xCur, stripY, stripW, stripH, r, r)

                -- Icon (integer scale, vertically centred)
                local iy = math.floor(stripY + (stripH - ih) / 2)
                lg.setColor(1, 1, 1, 1)
                lg.draw(s.icon, xCur + hPad, iy, 0, iconPixSc, iconPixSc)

                -- Number
                lg.setColor(1, 1, 1, 1)
                lg.print(numStr, xCur + hPad + iw + iconGap, textCY(Fonts.small, stripY, stripH))

                xCur = xCur + stripW + math.floor(6 * sc)
            end

            -- Settings "+" button (top-right corner, SUIT-style)
            local sbW = stripH   -- square button
            local sbX = W - sbW - math.floor(8 * sc)
            local sbY = stripY
            local sbR = math.max(1, math.floor(3 * sc))
            lg.setColor(0.22, 0.22, 0.26, 1)
            lg.rectangle('fill', sbX, sbY, sbW, sbW, sbR, sbR)
            lg.setColor(0.55, 0.55, 0.60, 1)
            lg.setLineWidth(math.max(1, math.floor(sc)))
            lg.rectangle('line', sbX, sbY, sbW, sbW, sbR, sbR)
            lg.setFont(Fonts.small)
            lg.setColor(0.9, 0.9, 0.9, 1)
            lg.printf("+", sbX, textCY(Fonts.small, sbY, sbW), sbW, 'center')
            self._settingsBtnRect = { x = sbX, y = sbY, w = sbW, h = sbW }
        end

        -- Bottom tab bar (screen space)
        self:drawBottomBar(W, H, sc)

        -- Detail overlay (screen space, topmost)
        if self.showDetail then
            self:drawDetailOverlay(W, H, sc)
        end

        -- Settings overlay
        if self.showSettings then
            -- Dim backdrop
            lg.setColor(0, 0, 0, 0.65)
            lg.rectangle('fill', 0, 0, W, H)

            -- Panel geometry
            local panW  = math.floor(240 * sc)
            local panH  = math.floor(240 * sc)
            local panX  = math.floor((W - panW) / 2)
            local panY  = math.floor((H - panH) / 2)
            local brd   = math.max(1, math.floor(2 * sc))

            -- Panel fill
            lg.setColor(0.14, 0.15, 0.22, 1)
            roundedRect(panX, panY, panW, panH, 5, sc)

            -- Outer border (blue-grey, matches active tab)
            lg.setColor(0.42, 0.44, 0.62, 1)
            roundedRectLine(panX, panY, panW, panH, 5, sc, brd)

            -- Bevel: top-left highlight
            local hl = brd + math.max(1, math.floor(sc))
            lg.setColor(0.55, 0.57, 0.78, 0.45)
            lg.setLineWidth(math.max(1, math.floor(sc)))
            lg.line(panX + hl, panY + panH - hl,
                    panX + hl, panY + hl,
                    panX + panW - hl, panY + hl)

            -- Bevel: bottom-right shadow
            lg.setColor(0.04, 0.04, 0.08, 0.6)
            lg.line(panX + hl, panY + panH - hl,
                    panX + panW - hl, panY + panH - hl,
                    panX + panW - hl, panY + hl)

            -- Vertical offset so the 196-unit content block is centred in panH
            local contentH = math.floor(196 * sc)
            local offY     = math.floor((panH - contentH) / 2)

            -- Title (medium font, same weight as panel headers elsewhere)
            local hdrH = math.floor(40 * sc)
            lg.setFont(Fonts.medium)
            lg.setColor(0.88, 0.90, 1.0, 1)
            lg.printf("SETTINGS", panX, textCY(Fonts.medium, panY + offY, hdrH), panW, 'center')

            -- Divider under title
            lg.setColor(0.35, 0.37, 0.55, 1)
            lg.setLineWidth(math.max(1, math.floor(sc)))
            lg.line(panX + math.floor(12 * sc), panY + offY + hdrH,
                    panX + panW - math.floor(12 * sc), panY + offY + hdrH)

            -- Toggle row helper: label left, game-style button right
            local function drawToggleRow(label, enabled, rowY)
                local rowH  = math.floor(38 * sc)
                local btnW  = math.floor(64 * sc)
                local btnH  = math.floor(28 * sc)
                local btnX  = panX + panW - math.floor(16 * sc) - btnW
                local btnY  = rowY + math.floor((rowH - btnH) / 2)
                -- Label
                lg.setFont(Fonts.small)
                lg.setColor(0.78, 0.80, 0.90, 1)
                lg.print(label, panX + math.floor(16 * sc), textCY(Fonts.small, rowY, rowH))
                -- Button fill
                if enabled then
                    lg.setColor(0.17, 0.21, 0.40, 1)
                else
                    lg.setColor(0.10, 0.10, 0.14, 1)
                end
                roundedRect(btnX, btnY, btnW, btnH, 4, sc)
                -- Button border
                if enabled then
                    lg.setColor(0.45, 0.48, 0.72, 1)
                else
                    lg.setColor(0.26, 0.26, 0.34, 1)
                end
                roundedRectLine(btnX, btnY, btnW, btnH, 4, sc, math.max(1, math.floor(sc)))
                -- Button text
                lg.setFont(Fonts.small)
                if enabled then
                    lg.setColor(0.72, 0.78, 1.0, 1)
                else
                    lg.setColor(0.32, 0.32, 0.40, 1)
                end
                lg.printf(enabled and "ON" or "OFF", btnX, textCY(Fonts.small, btnY, btnH), btnW, 'center')
                return { x = btnX, y = btnY, w = btnW, h = btnH }
            end

            local row1Y = panY + offY + math.floor(46 * sc)
            local row2Y = panY + offY + math.floor(90 * sc)
            self._settingsMusicRect = drawToggleRow("Music", AudioManager.musicEnabled, row1Y)
            self._settingsSFXRect   = drawToggleRow("SFX",   AudioManager.sfxEnabled,   row2Y)

            -- Divider above logout
            local divY = panY + offY + math.floor(138 * sc)
            lg.setColor(0.28, 0.30, 0.44, 1)
            lg.setLineWidth(math.max(1, math.floor(sc)))
            lg.line(panX + math.floor(12 * sc), divY,
                    panX + panW - math.floor(12 * sc), divY)

            -- Logout button (full-width minus margins)
            local lbW = panW - math.floor(32 * sc)
            local lbH = math.floor(34 * sc)
            local lbX = panX + math.floor(16 * sc)
            local lbY = divY + math.floor(8 * sc)
            lg.setColor(0.20, 0.09, 0.09, 1)
            roundedRect(lbX, lbY, lbW, lbH, 4, sc)
            lg.setColor(0.52, 0.20, 0.20, 1)
            roundedRectLine(lbX, lbY, lbW, lbH, 4, sc, math.max(1, math.floor(sc)))
            lg.setFont(Fonts.small)
            lg.setColor(0.88, 0.52, 0.52, 1)
            lg.printf("Logout", lbX, textCY(Fonts.small, lbY, lbH), lbW, 'center')
            self._settingsLogoutRect = { x = lbX, y = lbY, w = lbW, h = lbH }
        end
    end

    -- ── input ───────────────────────────────────────────────────────────────

    function self:handlePress(x, y)
        self.isPressed  = true
        self.pressX     = x
        self.pressY     = y
        self.hasMoved   = false
        self.isDragging = false

        -- Overlays absorb all presses
        if self.showDetail or self.showSettings then return end
    end

    function self:handleMove(x, y)
        if not self.isPressed then return end
        if self.showDetail or self.showSettings then return end

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

        -- Settings overlay
        if self.showSettings then
            -- Music toggle
            if self._settingsMusicRect then
                local r = self._settingsMusicRect
                if x >= r.x and x <= r.x + r.w and y >= r.y and y <= r.y + r.h then
                    AudioManager.setMusic(not AudioManager.musicEnabled)
                    return
                end
            end
            -- SFX toggle
            if self._settingsSFXRect then
                local r = self._settingsSFXRect
                if x >= r.x and x <= r.x + r.w and y >= r.y and y <= r.y + r.h then
                    AudioManager.setSFX(not AudioManager.sfxEnabled)
                    AudioManager.playTap()
                    return
                end
            end
            -- Logout button inside overlay
            if self._settingsLogoutRect then
                local r = self._settingsLogoutRect
                if x >= r.x and x <= r.x + r.w and y >= r.y and y <= r.y + r.h then
                    love.filesystem.remove("session.dat")
                    if _G.GameSocket then
                        _G.GameSocket:disconnect()
                        _G.GameSocket = nil
                    end
                    _G.PlayerData = nil
                    local ScreenManager = require('lib.screen_manager')
                    ScreenManager.switch('login')
                    return
                end
            end
            -- Tap anywhere else closes overlay
            self.showSettings = false
            return
        end

        -- Settings "+" button
        if self._settingsBtnRect then
            local r = self._settingsBtnRect
            if x >= r.x and x <= r.x + r.w and y >= r.y and y <= r.y + r.h then
                self.showSettings = true
                return
            end
        end

        -- Detail overlay: tap anywhere to close
        if self.showDetail then
            self.showDetail = false
            self.detailUnit = nil
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
                AudioManager.playTap()
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

        -- Tap: deck builder
        if self.currentPanel == 2 then
            -- Deck slot tabs
            for i, rect in ipairs(self._deckSlotRects) do
                if x >= rect.x and x <= rect.x + rect.w and
                   y >= rect.y and y <= rect.y + rect.h then
                    self.selectedDeckSlot = i
                    return
                end
            end
            -- Save button
            local sv = self._deckSaveRect
            if sv and x >= sv.x and x <= sv.x + sv.w and
                      y >= sv.y and y <= sv.y + sv.h then
                AudioManager.playTap()
                DeckManager.save()
                self._saveFeedback = 1.5
                self:buildPreviewLayout()
                return
            end
            -- Equip button
            local ar = self._deckActiveRect
            if ar and x >= ar.x and x <= ar.x + ar.w and
                      y >= ar.y and y <= ar.y + ar.h then
                AudioManager.playTap()
                DeckManager.setActive(self.selectedDeckSlot)
                self:buildPreviewLayout()
                return
            end
            -- Card minus/plus strips
            for _, cr in ipairs(self._deckCardRects) do
                if y >= cr.stripY and y <= cr.stripY + cr.stripH then
                    if x >= cr.minusX and x <= cr.minusX + cr.minusW then
                        AudioManager.playTap()
                        DeckManager.adjustCount(self.selectedDeckSlot, cr.utype, -1)
                        return
                    elseif x >= cr.plusX and x <= cr.plusX + cr.plusW then
                        AudioManager.playTap()
                        DeckManager.adjustCount(self.selectedDeckSlot, cr.utype, 1)
                        return
                    end
                end
            end
        end

        -- Tap: shop buttons
        if self.currentPanel == 4 then
            -- Gem purchase buttons (placeholder)
            for _, btn in ipairs(self._shopGemBtns) do
                if x >= btn.x and x <= btn.x + btn.w and
                   y >= btn.y and y <= btn.y + btn.h then
                    if _G.GameSocket then
                        _G.GameSocket:send("gem_purchase", {package = btn.key})
                    end
                    self.shopNotice = "Purchase simulated! +" .. btn.gems .. " gems added."
                    self.shopNoticeTimer = 3.0
                    return
                end
            end
            -- Gold purchase buttons
            for _, btn in ipairs(self._shopGoldBtns) do
                if x >= btn.x and x <= btn.x + btn.w and
                   y >= btn.y and y <= btn.y + btn.h then
                    if not btn.canAfford then
                        self.shopNotice = "Not enough gems!"
                        self.shopNoticeTimer = 2.5
                        return
                    end
                    if _G.GameSocket then
                        _G.GameSocket:send("shop_purchase", {item = btn.key})
                    end
                    return
                end
            end
        end

        -- Tap: Play Online button
        if self.currentPanel == 3 then
            local btn = self._playBtnRect
            if btn and x >= btn.x and x <= btn.x + btn.w and
                       y >= btn.y and y <= btn.y + btn.h then
                AudioManager.playTap()
                if _G.GameSocket then
                    local ScreenManager = require('lib.screen_manager')
                    ScreenManager.switch('lobby', _G.GameSocket)
                else
                    -- Not logged in, go to login screen
                    local ScreenManager = require('lib.screen_manager')
                    ScreenManager.switch('login')
                end
                return
            end
            local sbtn = self._sandboxBtnRect
            if sbtn and x >= sbtn.x and x <= sbtn.x + sbtn.w and
                        y >= sbtn.y and y <= sbtn.y + sbtn.h then
                AudioManager.playTap()
                local ScreenManager = require('lib.screen_manager')
                ScreenManager.switch('game', false, 1, false, true)
                return
            end
        end
    end

    function self:mousepressed(x, y, button)
        if button == 1 then self:handlePress(x, y) end
    end
    function self:mousemoved(x, y)
        self:handleMove(x, y)
    end
    function self:mousereleased(x, y, button)
        if button == 1 then self:handleRelease(x, y) end
    end

    function self:keypressed(key)
        if key == "escape" then
            if self.showDetail then
                self.showDetail = false
                self.detailUnit = nil
            end
            return
        end
    end

    return self
end

return MenuScreen
