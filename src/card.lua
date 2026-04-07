local Class = require('lib.classic')
local Constants = require('src.constants')
local BaseUnit = require('src.base_unit')
local UnitRegistry = require('src.unit_registry')

local Card = Class:extend()

local BUFF_ANIM_FPS      = 8
local BUFF_ANIM_FRAMES   = 6
local BUFF_ANIM_DURATION = BUFF_ANIM_FRAMES / BUFF_ANIM_FPS  -- 0.75s

local _goldIcon
local function getGoldIcon()
    if not _goldIcon then
        _goldIcon = love.graphics.newImage('src/assets/ui/gold.png')
        _goldIcon:setFilter('nearest', 'nearest')
    end
    return _goldIcon
end

function Card:new(x, y, cardSprite, index, unitType, trimBottom)
    self.x = x
    self.y = y
    self.startX = x  -- Original position for snap-back
    self.startY = y
    self.cardSprite = cardSprite
    self.trimBottom = trimBottom or 0  -- Transparent rows at sprite bottom (for baseline alignment)
    self.index = index
    self.unitType = unitType or "unknown"  -- Type of unit this card will spawn

    -- Card dimensions (scaled proportionally based on screen size)
    self.width = 80 * Constants.SCALE
    self.height = 100 * Constants.SCALE

    -- Drag state
    self.isDragging = false
    self.dragOffsetX = 0
    self.dragOffsetY = 0

    -- Up animation state
    self.upAnimTimer = 0
    self.upFrames    = nil

    -- Enter animation
    self.enterDelay = 0       -- seconds before card starts moving
    self.isEntering = false   -- true while sliding in
    self.enterAlpha = 1       -- opacity (0→1 during enter)
    self.velX = 0             -- exponential-smoothing velocity
    self.velY = 0

    -- Exit animation
    self.isExiting   = false  -- true while sliding out
    self.exitAlpha   = 1      -- opacity (1→0 during exit)
    self.exitVelX    = 0
    self.exitVelY    = 0
    self.exitRotation = 0     -- radians
    self.exitRotVel   = 0     -- rad/s
end

-- Set up enter-from-right animation. Card starts at offscreenX and slides to targetX/targetY.
function Card:setEnterAnim(offscreenX, targetX, targetY, delay)
    self.x          = offscreenX
    self.y          = targetY
    self.startX     = targetX   -- snapBack() still works correctly
    self.startY     = targetY
    self.velX       = 0
    self.velY       = 0
    self.enterDelay = delay or 0
    self.isEntering = true
    self.enterAlpha = 0
end

-- Begin exit animation (slide down + rotate + fade out).
-- rotDir: 1 = clockwise, -1 = counter-clockwise
function Card:startExitAnim(rotDir)
    self.isExiting    = true
    self.exitAlpha    = 1
    self.exitVelY     = 180 * Constants.SCALE
    self.exitVelX     = (rotDir or 1) * 20 * Constants.SCALE
    self.exitRotation = 0
    self.exitRotVel   = (rotDir or 1) * 2.5
    self.isDragging   = false
end

function Card:startDrag(mouseX, mouseY)
    self.isDragging = true
    self.dragOffsetX = mouseX - self.x
    self.dragOffsetY = mouseY - self.y
end

function Card:updateDrag(mouseX, mouseY)
    if self.isDragging then
        self.x = mouseX - self.dragOffsetX
        self.y = mouseY - self.dragOffsetY
    end
end

function Card:stopDrag()
    self.isDragging = false
end

function Card:update(dt)
    if self.upAnimTimer > 0 then
        self.upAnimTimer = math.max(0, self.upAnimTimer - dt)
    end

    -- Enter animation: exponential velocity smoothing toward startX/startY
    if self.isEntering then
        self.enterDelay = self.enterDelay - dt
        if self.enterDelay <= 0 then
            local dx = self.startX - self.x
            local dy = self.startY - self.y
            -- Cap dt to prevent overshoot on large first-frame spikes
            local adt = math.min(dt, 1/30)
            -- Balatro-style exponential smoother: low decay keeps tight, strength drives pull
            self.velX = self.velX * 0.004 + dx * 480 * adt
            self.velY = self.velY * 0.004 + dy * 480 * adt
            self.x = self.x + self.velX * adt
            self.y = self.y + self.velY * adt
            -- Alpha fades in once moving
            self.enterAlpha = math.min(1, self.enterAlpha + dt * 96)
            -- Snap to final position when close enough to avoid jitter
            local dist = math.sqrt(dx * dx + dy * dy)
            if dist < 1 and math.abs(self.velX) < 5 and math.abs(self.velY) < 5 then
                self.x          = self.startX
                self.y          = self.startY
                self.isEntering = false
                self.enterAlpha = 1
                self.velX, self.velY = 0, 0
            end
        else
            self.enterAlpha = 0
        end
    end

    -- Exit animation: gravity + rotation + alpha fade
    if self.isExiting then
        local GRAVITY = 600 * Constants.SCALE
        self.exitVelY     = self.exitVelY + GRAVITY * dt
        self.x            = self.x + self.exitVelX * dt
        self.y            = self.y + self.exitVelY * dt
        self.exitRotation = self.exitRotation + self.exitRotVel * dt
        self.exitAlpha    = math.max(0, self.exitAlpha - dt * 3)
        if self.exitAlpha <= 0 or self.y > Constants.GAME_HEIGHT + self.height then
            self.isExiting = false
        end
    end
end

function Card:snapBack()
    self.x = self.startX
    self.y = self.startY
end

function Card:contains(mouseX, mouseY)
    if self.isExiting then return false end
    if self.isEntering and self.enterDelay > 0 then return false end
    return mouseX >= self.x and mouseX <= self.x + self.width and
           mouseY >= self.y and mouseY <= self.y + self.height
end

function Card:draw()
    local lg = love.graphics

    -- Determine current alpha
    local alpha = 1
    if self.isExiting then
        alpha = self.exitAlpha
    elseif self.isEntering then
        alpha = self.enterAlpha
    end

    if alpha <= 0 then return end

    -- Apply rotation around card center (only during exit)
    local rotation = self.isExiting and self.exitRotation or 0
    local cx = self.x + self.width  / 2
    local cy = self.y + self.height / 2

    lg.push()
    lg.translate(cx, cy)
    lg.rotate(rotation)
    lg.translate(-cx, -cy)

    -- Scaled values
    local cornerRadius = 4 * Constants.SCALE
    local borderWidth = 2 * Constants.SCALE
    local namePadding = 4 * Constants.SCALE

    -- Card background
    if self.isDragging then
        lg.setColor(0.3, 0.3, 0.4, 0.9 * alpha)
    else
        lg.setColor(0.2, 0.2, 0.3, alpha)
    end
    lg.rectangle('fill', self.x, self.y, self.width, self.height, cornerRadius, cornerRadius)

    -- Card border
    lg.setColor(0.4, 0.4, 0.5, alpha)
    lg.setLineWidth(borderWidth)
    lg.rectangle('line', self.x, self.y, self.width, self.height, cornerRadius, cornerRadius)

    -- Card name (capitalize first letter) - at the top
    lg.setFont(Fonts.tiny)
    lg.setColor(0.8, 0.8, 0.8, alpha)
    local displayName = self.unitType:sub(1, 1):upper() .. self.unitType:sub(2)
    lg.printf(displayName, self.x, self.y + namePadding, self.width, 'center')

    -- Draw sprite in center of card (scaled proportionally with integer scale for crisp pixels)
    lg.setColor(1, 1, 1, alpha)
    local spriteScale = math.max(1, math.floor(3 * Constants.SCALE))
    local spriteWidth = self.cardSprite:getWidth()
    local spriteHeight = self.cardSprite:getHeight()
    local spriteX = math.floor(self.x + (self.width - spriteWidth * spriteScale) / 2)
    -- Anchor visual bottom (ignoring transparent padding) 3 sprite-pixels above card bottom,
    -- matching the same baseline used in BaseUnit:draw() for grid cells.
    local BOTTOM_MARGIN = 3
    local spriteY = math.floor(self.y + self.height - (spriteHeight - self.trimBottom + BOTTOM_MARGIN) * spriteScale)
    lg.setShader(BaseUnit.getPaletteShader())
    lg.draw(self.cardSprite, spriteX, spriteY, 0, spriteScale, spriteScale)
    lg.setShader()

    -- Cost display below card (only when not dragging and not exiting)
    if not self.isDragging and not self.isExiting then
        lg.setFont(Fonts.small)
        lg.setColor(1, 1, 1, alpha)
        local cost = UnitRegistry.unitCosts[self.unitType] or 3
        local costPadding = 8 * Constants.SCALE
        local costY = self.y + self.height + costPadding
        local icon = getGoldIcon()
        local iconH = math.floor(Fonts.small:getHeight() * 0.55)
        local iconSc = iconH / icon:getHeight()
        local iconW = icon:getWidth() * iconSc
        local costStr = tostring(cost)
        local textW = Fonts.small:getWidth(costStr)
        local gap = 2
        local totalW = iconW + gap + textW
        local startX = math.floor(self.x + (self.width - totalW) / 2)
        local visH  = Fonts.small:getAscent() - Fonts.small:getDescent()
        local iconY = math.floor(costY + (visH - iconH) / 2)
        lg.draw(icon, startX, iconY, 0, iconSc, iconSc)
        lg.print(costStr, startX + iconW + gap, costY)
    end

    -- Draw "up" animation at top-right corner when this card can upgrade a field unit
    if self.upAnimTimer > 0 and self.upFrames and #self.upFrames > 0 then
        local elapsed  = BUFF_ANIM_DURATION - self.upAnimTimer
        local frameIdx = math.min(#self.upFrames, math.floor(elapsed * BUFF_ANIM_FPS) + 1)
        local img      = self.upFrames[frameIdx]
        local sw, sh   = img:getWidth(), img:getHeight()
        local scale    = math.max(1, math.floor(3 * Constants.SCALE))
        local px = math.floor(self.x + self.width  - sw * scale / 2)
        local py = math.floor(self.y               + sh * scale / 2)
        lg.setColor(1, 1, 1, alpha)
        lg.setShader(BaseUnit.getPaletteShader())
        lg.draw(img, px, py, 0, scale, scale, sw / 2, sh / 2)
        lg.setShader()
    end

    lg.pop()
end

return Card
