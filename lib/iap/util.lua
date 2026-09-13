-- lib/iap/util.lua
-- Small helpers shared by the IAP module. No LÖVE dependency beyond optional
-- love.timer / love.math, so the module can be unit-tested headless.

local util = {}

-- ── time ──────────────────────────────────────────────────────────────────────

function util.now()
    if love and love.timer and love.timer.getTime then
        return love.timer.getTime()
    end
    return os.clock()
end

-- Wall-clock seconds (used for ledger timestamps that must survive restarts).
function util.wallclock()
    return os.time()
end

-- ── logging ───────────────────────────────────────────────────────────────────

local LEVELS = { off = 0, error = 1, warn = 2, info = 3, debug = 4 }

util.logLevel = "info"
local sink = print

-- Redirect log output (e.g. into an in-game console).
function util.setLogger(fn)
    sink = fn or print
end

function util.log(level, fmt, ...)
    if (LEVELS[level] or 4) > (LEVELS[util.logLevel] or 3) then return end
    local msg = fmt
    if select('#', ...) > 0 then
        local ok, formatted = pcall(string.format, fmt, ...)
        if ok then msg = formatted end
    end
    sink(string.format("[iap:%s] %s", level, msg))
end

function util.debug(...) util.log("debug", ...) end
function util.info(...)  util.log("info",  ...) end
function util.warn(...)  util.log("warn",  ...) end
function util.err(...)   util.log("error", ...) end

-- ── misc ──────────────────────────────────────────────────────────────────────

local seeded = false
local function rand(n)
    if love and love.math and love.math.random then return love.math.random(n) end
    if not seeded then
        math.randomseed(os.time() % 2147483647)
        seeded = true
    end
    return math.random(n)
end

util.random = rand

local HEX = "0123456789abcdef"

-- Short opaque id. Used for request correlation and mock transaction ids only —
-- never as a security token.
function util.uid(len)
    local out = {}
    for i = 1, (len or 12) do
        local n = rand(16)
        out[i] = HEX:sub(n, n)
    end
    return table.concat(out)
end

function util.copy(t)
    if type(t) ~= "table" then return t end
    local out = {}
    for k, v in pairs(t) do out[k] = util.copy(v) end
    return out
end

function util.count(t)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end

-- Exponential backoff with jitter, capped. attempt is 0-based.
function util.backoff(attempt, base, cap)
    base = base or 2
    cap  = cap  or 120
    local delay = math.min(cap, base * (2 ^ math.min(attempt, 10)))
    return delay * (0.75 + rand(50) / 100)  -- ±25% jitter
end

-- Detect the store platform. "mock" means "no real store here".
function util.detectPlatform()
    if not (love and love.system and love.system.getOS) then return "mock" end
    local os_ = love.system.getOS()
    if os_ == "Android" then return "android" end
    if os_ == "iOS"     then return "ios"     end
    return "mock"
end

return util
