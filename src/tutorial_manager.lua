-- TutorialManager: drives the first-time tutorial overlay and AI opponent.
-- Attached to a GameScreen instance when isTutorial == true.
-- All detection is polling-based (checked in update) to avoid modifying game logic.

local Constants    = require('src.constants')
local UnitRegistry = require('src.unit_registry')
local utf8         = require('utf8')

-- UTF-8 aware substring: returns the first n codepoints of s
local function utf8sub(s, n)
    if n <= 0 then return "" end
    local offset = utf8.offset(s, n + 1)
    if offset then return string.sub(s, 1, offset - 1) end
    return s
end

local TutorialManager = {}
TutorialManager.__index = TutorialManager

-- ── Step definitions ─────────────────────────────────────────────────────────
-- requiresAction: after the player taps this bubble away, the NEXT bubble is
--                 held until the described action is performed (+ ACTION_DELAY s).
local STEPS = {
    -- 1
    { text = "Welcome to AutoChest!\nThe bottom half is YOUR battlefield.\nThe top half belongs to your opponent." },
    -- 2
    { text = "Drag a card from your hand\nand drop it onto your side to place a unit.",
      requiresAction = true },
    -- 3
    { text = "Tap any of your units to reveal\nits stats and abilities.",
      requiresAction = true },
    -- 4
    { text = "You can upgrade units — drag another card\nof the same type onto an existing unit,\nor tap the upgrade button in the tooltip.",
      requiresAction = true },
    -- 5
    { text = "Reposition units by dragging them\nwithin your half of the battlefield.",
      requiresAction = true },
    -- 6
    { text = "Press READY when you're set!\nThen watch your units fight automatically." },
    -- 7  (auto-dismisses after 2.5 s)
    { text = "Battle has begun!\nYour units fight on their own — sit back and watch." },
    -- 8  (final — shown on finished state)
    { text = "Well done! That's the basics.\nLet's set up your account to play online!" },
}

local CHARS_PER_SEC = 35
local ACTION_DELAY  = 1.0   -- seconds to linger after the player completes an action
local BUBBLE_GAP    = 0.35  -- seconds the screen is bare between bubbles

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

    -- Pending step: fires after ACTION_DELAY seconds once an action is detected
    self.pendingStep      = nil
    self.pendingStepTimer = 0

    -- Set to true when the player taps away an action-required bubble;
    -- the current bubble hides and we wait for the action before advancing.
    self.waitingForAction = false

    -- Baselines for action detection (reset each time the relevant step begins)
    self.p1LevelBaseline = nil   -- sum of P1 unit levels at start of step 4
    self.p1PosBaseline   = nil   -- {unit → {col,row}} snapshot at start of step 5

    -- Typewriter state
    self.charIndex     = 0
    self.charTimer     = 0
    self.displayedStep = 0

    -- Gap between bubbles (bubble hidden while this counts down)
    self.stepDelay = 0

    -- Blinking cursor
    self.cursorTimer   = 0
    self.cursorVisible = true

    -- Track whether tooltip has been opened (for step 3 → 4 transition)
    self.tooltipSeenThisStep = false

    return self
end

-- ── AI helper ─────────────────────────────────────────────────────────────────
function TutorialManager:doAIPlace(unitType, col, row)
    local game        = self.game
    local unitSprites = game.sprites[unitType]
    if not unitSprites then return end
    if game.grid:getUnitAtCell(col, row) then return end
    local unit = UnitRegistry.createUnit(unitType, row, col, 2, unitSprites)
    game.grid:placeUnit(col, row, unit)
end

-- ── update ────────────────────────────────────────────────────────────────────
function TutorialManager:update(dt)
    local game = self.game

    -- ── AI placement ──────────────────────────────────────────────────────────
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

    -- ── Instant auto-advances ─────────────────────────────────────────────────

    -- Step 3 → 4: tooltip opened on a P1 unit (only after bubble was tapped away)
    if self.step == 3 and self.waitingForAction and not self.pendingStep then
        if game.tooltip.visible and game.tooltip.unit and game.tooltip.unit.owner == 1 then
            self.pendingStep      = 4
            self.pendingStepTimer = 2.0
        end
    end

    -- Step 6 → 7: battle started
    if self.step == 6 and (game.state == "pre_battle" or game.state == "battle") then
        self.step = 7
        self.step7Timer = 0
    end

    -- Step 7: auto-dismiss after 2.5 s
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

    -- ── Pending step countdown ────────────────────────────────────────────────
    if self.pendingStep then
        self.pendingStepTimer = self.pendingStepTimer - dt
        if self.pendingStepTimer <= 0 then
            self.step             = self.pendingStep
            self.pendingStep      = nil
            self.waitingForAction = false
        end
    end

    -- ── Action detection (only while waiting after a tap-dismiss) ─────────────

    -- Step 2: first P1 unit placed
    if self.step == 2 and self.waitingForAction and not self.pendingStep then
        for _, u in ipairs(game.grid:getAllUnits()) do
            if u.owner == 1 then
                self.pendingStep      = 3
                self.pendingStepTimer = ACTION_DELAY
                self.tooltipSeenThisStep = false
                break
            end
        end
    end

    -- Step 4: any P1 unit levelled up
    if self.step == 4 and self.waitingForAction and not self.pendingStep then
        if not self.p1LevelBaseline then
            local total = 0
            for _, u in ipairs(game.grid:getAllUnits()) do
                if u.owner == 1 then total = total + (u.level or 0) end
            end
            self.p1LevelBaseline = total
        end
        local total = 0
        for _, u in ipairs(game.grid:getAllUnits()) do
            if u.owner == 1 then total = total + (u.level or 0) end
        end
        if total > self.p1LevelBaseline then
            self.pendingStep      = 5
            self.pendingStepTimer = ACTION_DELAY
        end
    end

    -- Step 5: any P1 unit moved from its baseline position
    if self.step == 5 and self.waitingForAction and not self.pendingStep then
        if not self.p1PosBaseline then
            self.p1PosBaseline = {}
            for _, u in ipairs(game.grid:getAllUnits()) do
                if u.owner == 1 then
                    self.p1PosBaseline[u] = { col = u.col, row = u.row }
                end
            end
        end
        for u, pos in pairs(self.p1PosBaseline) do
            if u.col ~= pos.col or u.row ~= pos.row then
                self.pendingStep      = 6
                self.pendingStepTimer = ACTION_DELAY
                break
            end
        end
    end

    -- ── Typewriter reset on step change ───────────────────────────────────────
    if self.step ~= self.displayedStep then
        self.displayedStep   = self.step
        self.charIndex       = 0
        self.charTimer       = 0
        self.stepDelay       = BUBBLE_GAP
        self.waitingForAction = false
        self.p1LevelBaseline = nil
        self.p1PosBaseline   = nil
    end

    -- ── Inter-bubble gap countdown ────────────────────────────────────────────
    if self.stepDelay > 0 then
        self.stepDelay = self.stepDelay - dt
    end

    -- ── Typewriter advance ────────────────────────────────────────────────────
    if self.stepDelay <= 0 and not self.waitingForAction then
        local stepData = STEPS[self.step]
        if stepData then
            local fullLen = utf8.len(stepData.text)
            if self.charIndex < fullLen then
                self.charTimer = self.charTimer + dt
                local add = math.floor(self.charTimer * CHARS_PER_SEC)
                if add > 0 then
                    self.charIndex = math.min(self.charIndex + add, fullLen)
                    self.charTimer = self.charTimer - add / CHARS_PER_SEC
                end
            end
        end
    end

    -- ── Blinking cursor ───────────────────────────────────────────────────────
    self.cursorTimer = self.cursorTimer + dt
    if self.cursorTimer >= 0.5 then
        self.cursorTimer   = self.cursorTimer - 0.5
        self.cursorVisible = not self.cursorVisible
    end
end

-- ── handleTap ────────────────────────────────────────────────────────────────
-- Called on any release (tap or end of drag) from game's handleRelease.
function TutorialManager:handleTap(x, y)
    local stepData = STEPS[self.step]
    if not stepData then return end
    if self.stepDelay > 0 or self.waitingForAction then return end

    local fullLen = utf8.len(stepData.text)

    if self.charIndex < fullLen then
        -- Reveal full message instantly
        self.charIndex = fullLen
        return
    end

    -- Message fully shown: tap dismisses the bubble
    if self.step >= 1 and self.step <= 6 then
        if stepData.requiresAction then
            -- Hide bubble and wait for the action before showing the next one
            self.waitingForAction = true
            self.p1LevelBaseline  = nil
            self.p1PosBaseline    = nil
        else
            self.step = self.step + 1
            self.tooltipSeenThisStep = false
        end
    end
end

-- ── draw ──────────────────────────────────────────────────────────────────────
function TutorialManager:draw()
    local game = self.game

    local inSetup    = game.state == "setup"
    local inBattle   = game.state == "pre_battle" or game.state == "battle"
    local inFinished = game.state == "finished"

    local showBubble =
        (self.step >= 1 and self.step <= 6 and inSetup)    or
        (self.step == 7 and (inBattle or inFinished))       or
        (self.step == 8 and inFinished)

    if not showBubble or self.stepDelay > 0 or self.waitingForAction then return end

    local lg = love.graphics
    local sc = Constants.SCALE
    local gw = Constants.GAME_WIDTH
    local gh = Constants.GAME_HEIGHT

    local hPad   = 12 * sc
    local panelW = gw - hPad * 2
    local panelH = 120 * sc
    local panelX = hPad
    local panelY = gh / 2 - panelH / 2

    -- Background
    lg.setColor(0.05, 0.05, 0.12, 0.93)
    local radius = 6 * sc
    lg.rectangle('fill', panelX, panelY, panelW, panelH, radius, radius)
    -- Border
    lg.setColor(0.45, 0.65, 1, 0.85)
    lg.setLineWidth(math.max(1, 1.5 * sc))
    lg.rectangle('line', panelX, panelY, panelW, panelH, radius, radius)

    local stepData = STEPS[self.step]
    if not stepData then return end

    local fullText    = stepData.text
    local displayText = utf8sub(fullText, self.charIndex)
    local isComplete  = (self.charIndex >= utf8.len(fullText))

    local innerPad  = 10 * sc
    lg.setFont(Fonts.small)
    lg.setColor(1, 1, 1, 1)

    local lineH     = Fonts.small:getHeight()
    local hintH     = Fonts.tiny:getHeight() + 4 * sc
    local textAreaH = panelH - innerPad * 2 - hintH
    local textY     = panelY + innerPad + (textAreaH - lineH * 3) / 2
    if textY < panelY + innerPad then textY = panelY + innerPad end

    lg.printf(displayText, panelX + innerPad, textY, panelW - innerPad * 2, 'center')

    -- Bottom hint
    lg.setFont(Fonts.tiny)
    local hintY = panelY + panelH - hintH
    if self.step ~= 7 and self.step ~= 8 then
        if not isComplete then
            lg.setColor(0.35, 0.40, 0.55, 0.7)
            lg.printf("Tap to skip", panelX, hintY, panelW, 'center')
        elseif self.cursorVisible then
            lg.setColor(0.55, 0.65, 0.80, 0.9)
            lg.printf("Tap to continue", panelX, hintY, panelW, 'center')
        end
    end

    lg.setColor(1, 1, 1, 1)
    lg.setLineWidth(1)
end

return TutorialManager
