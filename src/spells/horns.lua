local HornsSpell = {}
HornsSpell.__index = HornsSpell

local BUFF_DURATION       = 5.0
local HASTE_MULT          = 1.25
local NOTE_SPAWN_INTERVAL = 0.22  -- seconds between paired spawns
local NOTE_LIFETIME       = 1.6   -- seconds per note
local NOTE_WAVE_FREQ      = 4     -- rad/s vertical wobble
local BOUNCE_FREQ         = 5     -- rad/s idle trumpet bounce

local function lcgNext(s)
    return (s * 1664525 + 1013904223) % (2 ^ 32)
end

function HornsSpell.new(col, row, owner, grid, sprites, placementId)
    local self = setmetatable({}, HornsSpell)
    self.col         = col
    self.row         = row
    self.owner       = owner
    self.sprites     = sprites
    self.complete    = false
    self.timer       = 0
    self.rng         = (placementId or 1) * 7331 + 17

    self.initialized    = false
    self.leftX          = 0
    self.rightX         = 0
    self.rowY           = 0
    self.leftTipX       = 0
    self.rightTipX      = 0
    self.midX           = 0
    self.sc             = 1
    self.bounceAmp      = 3
    self.waveAmp        = 4

    self.tootTimer      = 999   -- large = no active toot
    self.notes          = {}
    self.noteSpawnTimer = 0

    return self
end

function HornsSpell:_init(grid)
    local cs       = grid.cellSize
    self.sc        = math.floor(cs / 16)
    self.bounceAmp = cs / 16
    self.waveAmp   = cs / 8

    -- Trumpet centers: 1.5 cells outside each grid edge for clear separation
    local lx, ry = grid:getCellCenter(0, self.row)
    local rx, _  = grid:getCellCenter(6, self.row)
    self.leftX  = lx - cs / 2
    self.rightX = rx + cs / 2
    self.rowY   = ry

    -- Bell-tip positions: the "inner" end of each trumpet pointing into the grid.
    -- Left trumpet is drawn with -sc x-scale (flipped), so its pixel-0 edge maps to
    -- leftX + sc*iw/2 in screen space (the rightmost point = the bell facing inward).
    -- Right trumpet uses +sc, pixel-0 edge is at rightX - sc*iw/2 (leftmost = inward).
    local sc = self.sc
    local trumpet = self.sprites and self.sprites.trumpet
    if trumpet then
        local iw, _ = trumpet:getDimensions()
        self.leftTipX  = self.leftX  + sc * iw / 2
        self.rightTipX = self.rightX - sc * iw / 2
    else
        self.leftTipX  = self.leftX
        self.rightTipX = self.rightX
    end

    -- Notes travel to the center column (col 3)
    local mx, _ = grid:getCellCenter(3, self.row)
    self.midX = mx

    for _, u in ipairs(grid:getAllUnits()) do
        if u.owner == self.owner and u.row == self.row and not u.isDead then
            u:applyHaste(BUFF_DURATION, HASTE_MULT)
            u.buffAnimTimer = 0.5
        end
    end

    self.initialized = true
end

function HornsSpell:update(dt, grid)
    if not self.initialized then self:_init(grid) end

    self.timer     = self.timer + dt
    self.tootTimer = self.tootTimer + dt

    if self.timer >= BUFF_DURATION then
        self.complete = true
        return
    end

    self.noteSpawnTimer = self.noteSpawnTimer + dt
    if self.noteSpawnTimer >= NOTE_SPAWN_INTERVAL then
        self.noteSpawnTimer = self.noteSpawnTimer - NOTE_SPAWN_INTERVAL
        self:_spawnNotePair()
    end

    for i = #self.notes, 1, -1 do
        local n = self.notes[i]
        n.life = n.life + dt
        n.x    = n.x + n.vx * dt
        n.y    = n.baseY + math.sin(n.life * NOTE_WAVE_FREQ + n.phase) * self.waveAmp
        if n.life >= NOTE_LIFETIME then
            table.remove(self.notes, i)
        end
    end
end

function HornsSpell:_spawnNotePair()
    local frames = self.sprites and self.sprites.noteFrames
    if not frames or #frames == 0 then return end

    self.tootTimer = 0  -- kick off toot animation

    local function pickNote()
        self.rng = lcgNext(self.rng)
        local idx = (self.rng % #frames) + 1
        self.rng = lcgNext(self.rng)
        local yOff = (self.rng % 13) - 6
        self.rng = lcgNext(self.rng)
        local phase = (self.rng % 629) / 100
        return frames[idx], yOff, phase
    end

    local sprL, yOffL, phL = pickNote()
    local sprR, yOffR, phR = pickNote()
    local sc = self.sc

    -- Velocity: tip → midX over NOTE_LIFETIME, so the note arrives at mid exactly as it fades
    local vxL = (self.midX - self.leftTipX)  / NOTE_LIFETIME
    local vxR = (self.midX - self.rightTipX) / NOTE_LIFETIME

    table.insert(self.notes, {
        x = self.leftTipX,  baseY = self.rowY + yOffL * sc,
        y = self.rowY + yOffL * sc, vx = vxL, life = 0, sprite = sprL, phase = phL,
    })
    table.insert(self.notes, {
        x = self.rightTipX, baseY = self.rowY + yOffR * sc,
        y = self.rowY + yOffR * sc, vx = vxR, life = 0, sprite = sprR, phase = phR,
    })
end

function HornsSpell:draw()
    if not self.initialized then return end

    local sc = self.sc
    local globalAlpha = 1.0
    if self.timer > BUFF_DURATION - 0.5 then
        globalAlpha = (BUFF_DURATION - self.timer) / 0.5
    end

    -- Toot animation: damped oscillation on squash/stretch/tilt/bounce
    local d       = math.exp(-self.tootTimer * 8)
    local squeeze = d * math.cos(self.tootTimer * 22) * 0.25  -- ±25% along length axis
    local tilt    = d * math.sin(self.tootTimer * 18) * 0.22  -- ±~13° tilt
    local tootY   = -self.bounceAmp * 2 * d                   -- upward kick at toot

    -- Idle slow bounce layered on top
    local idleY = math.sin(self.timer * BOUNCE_FREQ) * self.bounceAmp
    local totalY = idleY + tootY

    -- Squash along trumpet's horizontal axis, stretch perpendicular
    local trSX = sc * (1 + squeeze)
    local trSY = sc * (1 - squeeze * 0.5)

    local trumpet = self.sprites and self.sprites.trumpet
    if trumpet then
        local iw, ih = trumpet:getDimensions()
        love.graphics.setColor(1, 1, 1, globalAlpha)
        -- Left: flipped (-trSX), tilts counterclockwise when tooting
        love.graphics.draw(trumpet, self.leftX,  self.rowY + totalY,
            -tilt, -trSX, trSY, iw / 2, ih / 2)
        -- Right: normal (+trSX), tilts clockwise when tooting
        love.graphics.draw(trumpet, self.rightX, self.rowY + totalY,
             tilt,  trSX, trSY, iw / 2, ih / 2)
    end

    -- Notes: drawn above units, fade out in last 25% of life
    for _, n in ipairs(self.notes) do
        if n.sprite then
            local life_t = n.life / NOTE_LIFETIME
            local alpha  = life_t > 0.75 and ((1 - life_t) / 0.25) or 1.0
            local iw, ih = n.sprite:getDimensions()
            love.graphics.setColor(1, 1, 1, alpha * globalAlpha)
            love.graphics.draw(n.sprite, n.x, n.y, 0, sc, sc, iw / 2, ih / 2)
        end
    end

    love.graphics.setColor(1, 1, 1, 1)
end

return HornsSpell
