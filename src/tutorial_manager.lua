-- TutorialManager: drives the first-time tutorial overlay and AI opponent.
-- Attached to a GameScreen instance when isTutorial == true.
-- All detection is polling-based (checked in update) to avoid modifying game logic.

local Constants    = require('src.constants')
local UnitRegistry = require('src.unit_registry')

local TutorialManager = {}
TutorialManager.__index = TutorialManager

-- ── Step definitions ─────────────────────────────────────────────────────────
local STEPS = {
    -- 1
    { text = "Welcome to AutoChest!\nThe bottom half is YOUR battlefield.\nThe top half belongs to your opponent." },
    -- 2
    { text = "Drag a card from your hand\nand drop it onto your side to place a unit." },
    -- 3  (auto-advances when tooltip opens)
    { text = "Tap any of your units to reveal\nits stats and abilities." },
    -- 4  (shown once tooltip was opened)
    { text = "You can upgrade units — drag another card\nof the same type onto an existing unit,\nor tap the upgrade button in the tooltip." },
    -- 5
    { text = "Reposition units by dragging them\nwithin your half of the battlefield." },
    -- 6
    { text = "Press READY when you're set!\nThen watch your units fight automatically." },
    -- 7  (auto-dismisses after 2.5 s)
    { text = "Battle has begun!\nYour units fight on their own — sit back and watch." },
    -- 8  (final — shown on finished state)
    { text = "Well done! That's the basics.\nLet's set up your account to play online!" },
}

-- ── AI placement schedule (canonical grid coords, P2 zone = rows 1-4) ────────
local AI_ACTIONS = {
    { time = 2.0, unitType = "boney",  col = 2, row = 2 },
    { time = 3.2, unitType = "boney",  col = 4, row = 2 },
    { time = 4.5, unitType = "marrow", col = 3, row = 1 },
}

-- ── Constructor ───────────────────────────────────────────────────────────────
function TutorialManager.new(game)
    local self = setmetatable({}, TutorialManager)
    self.game = game
    self.step = 1

    -- AI state
    self.aiTimer       = 0
    self.aiActionIndex = 1
    self.aiDone        = false

    -- Step 7 auto-dismiss timer
    self.step7Timer = 0

    -- Bubble panel rect (populated in draw; used for tap detection)
    self.panelX = 0
    self.panelY = 0
    self.panelW = 0
    self.panelH = 0

    -- Track whether tooltip has been opened (for step 3 → 4 transition)
    self.tooltipSeenThisStep = false

    return self
end

-- ── AI helper ─────────────────────────────────────────────────────────────────
function TutorialManager:doAIPlace(unitType, col, row)
    local game        = self.game
    local unitSprites = game.sprites[unitType]
    if not unitSprites then return end
    -- Don't place if cell already occupied
    if game.grid:getUnitAtCell(col, row) then return end
    local unit = UnitRegistry.createUnit(unitType, row, col, 2, unitSprites)
    game.grid:placeUnit(col, row, unit)
end

-- ── update ────────────────────────────────────────────────────────────────────
function TutorialManager:update(dt)
    local game = self.game

    -- ── AI placement (runs during setup regardless of current tutorial step) ──
    if game.state == "setup" and not self.aiDone then
        self.aiTimer = self.aiTimer + dt
        while self.aiActionIndex <= #AI_ACTIONS do
            local action = AI_ACTIONS[self.aiActionIndex]
            if self.aiTimer >= action.time then
                self:doAIPlace(action.unitType, action.col, action.row)
                self.aiActionIndex = self.aiActionIndex + 1
            else
                break
            end
        end
        if self.aiActionIndex > #AI_ACTIONS then
            self.aiDone = true
        end
    end

    -- ── Step auto-advancement ─────────────────────────────────────────────────

    -- Step 2 → 3: player placed their first unit
    if self.step == 2 then
        local units = game.grid:getAllUnits()
        for _, u in ipairs(units) do
            if u.owner == 1 then
                self.step = 3
                self.tooltipSeenThisStep = false
                break
            end
        end
    end

    -- Step 3 → 4: tooltip was opened for a P1 unit
    if self.step == 3 and game.tooltip.visible and game.tooltip.unit and game.tooltip.unit.owner == 1 then
        if not self.tooltipSeenThisStep then
            self.tooltipSeenThisStep = true
            self.step = 4
        end
    end

    -- Step 6 → 7: battle has started
    if self.step == 6 and (game.state == "pre_battle" or game.state == "battle") then
        self.step = 7
        self.step7Timer = 0
    end

    -- Step 7: auto-dismiss after 2.5 s of battle
    if self.step == 7 and game.state == "battle" then
        self.step7Timer = self.step7Timer + dt
        if self.step7Timer >= 2.5 then
            self.step = 8
        end
    end

    -- Step 7 → 8 fallback if battle ends before auto-dismiss
    if self.step == 7 and game.state == "finished" then
        self.step = 8
    end
end

-- ── handleTap ────────────────────────────────────────────────────────────────
-- Called from game's handleRelease.  Advances step when the tap lands on
-- the bubble panel.  Does NOT consume the event — game input continues normally.
function TutorialManager:handleTap(x, y)
    if self.panelW == 0 then return end
    local inPanel = x >= self.panelX and x <= self.panelX + self.panelW
                 and y >= self.panelY and y <= self.panelY + self.panelH
    if not inPanel then return end

    -- Steps 1, 4, 5 are pure "tap to continue" steps
    -- Steps 2, 3, 6 also allow tap-to-skip
    -- Step 7 is auto-only; step 8 has its own button in game.lua
    if self.step >= 1 and self.step <= 6 then
        self.step = self.step + 1
        self.tooltipSeenThisStep = false
    end
end

-- ── draw ──────────────────────────────────────────────────────────────────────
function TutorialManager:draw()
    local game = self.game

    -- Determine whether we should render a bubble right now
    local inSetup    = game.state == "setup"
    local inBattle   = game.state == "pre_battle" or game.state == "battle"
    local inFinished = game.state == "finished"

    local showBubble =
        (self.step >= 1 and self.step <= 6 and inSetup)    or
        (self.step == 7 and (inBattle or inFinished))       or
        (self.step == 8 and inFinished)

    if not showBubble then return end

    local lg = love.graphics
    local sc = Constants.SCALE
    local gw = Constants.GAME_WIDTH
    local gh = Constants.GAME_HEIGHT

    -- Bubble panel sizing
    local hPad   = 12 * sc   -- horizontal margin from screen edge
    local panelW = gw - hPad * 2
    local panelH = 88 * sc

    -- Vertical position: just above the card hand during setup; centred during battle/finished
    local panelY
    if inSetup and game.cardY then
        local margin = 6 * sc
        panelY = game.cardY - panelH - margin
    else
        panelY = gh * 0.52
    end
    local panelX = hPad

    -- Clamp so the panel never goes above the top 40% of the screen
    local minY = gh * 0.40
    if panelY < minY then panelY = minY end

    -- Cache rect for tap detection
    self.panelX = panelX
    self.panelY = panelY
    self.panelW = panelW
    self.panelH = panelH

    -- Background
    lg.setColor(0.05, 0.05, 0.12, 0.93)
    local radius = 6 * sc
    lg.rectangle('fill', panelX, panelY, panelW, panelH, radius, radius)
    -- Border
    lg.setColor(0.45, 0.65, 1, 0.85)
    lg.setLineWidth(math.max(1, 1.5 * sc))
    lg.rectangle('line', panelX, panelY, panelW, panelH, radius, radius)

    -- Step text
    local stepData = STEPS[self.step]
    if not stepData then return end

    local innerPad = 10 * sc
    lg.setFont(Fonts.small)
    lg.setColor(1, 1, 1, 1)

    -- Calculate text height to vertically centre it (rough: assume 3 lines max)
    local lineH    = Fonts.small:getHeight()
    local hintH    = Fonts.tiny:getHeight() + 4 * sc
    local textAreaH = panelH - innerPad * 2 - hintH
    local textY    = panelY + innerPad + (textAreaH - lineH * 3) / 2
    if textY < panelY + innerPad then textY = panelY + innerPad end

    lg.printf(stepData.text, panelX + innerPad, textY, panelW - innerPad * 2, 'center')

    -- "Tap to continue" hint (not shown for auto-dismiss step 7 or final step 8)
    if self.step ~= 7 and self.step ~= 8 then
        lg.setFont(Fonts.tiny)
        lg.setColor(0.55, 0.65, 0.80, 0.9)
        local hintY = panelY + panelH - hintH
        lg.printf("Tap to continue", panelX, hintY, panelW, 'center')
    end

    -- Reset graphics state
    lg.setColor(1, 1, 1, 1)
    lg.setLineWidth(1)
end

return TutorialManager
