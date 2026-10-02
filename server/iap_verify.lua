-- In-app purchase verification for the server.
--
-- The client sends a store purchase token; before any gold is granted the
-- token is checked with the store. Google Play checks run on a worker thread
-- (curl + openssl, both stock on Ubuntu) so a slow Google answer never stalls
-- the ENet loop.
--
-- Environment (set in the systemd unit, see deploy/autochest-server.service):
--   IAP_GOOGLE_SERVICE_ACCOUNT  path to the Play Console service account JSON key
--   IAP_ANDROID_PACKAGE         application id (default com.cmatute.tinyturf)
--   IAP_ALLOW_UNVERIFIED=1      accept tokens without asking the store. Testing only:
--                               anyone could mint gold with a made-up token.
--
-- Refunds: every VOIDED_INTERVAL the worker asks Google's Voided Purchases
-- API for purchases refunded, cancelled or charged back in the last 30 days
-- and hands their tokens to IapVerify.onVoided (server/main.lua takes the gold
-- back). The 30-day window overlaps every time; the ledger's refunded_at
-- makes repeats no-ops.
--
-- Results are { ok, reason, retry, order }. retry = true means "not now"
-- (store unreachable, verification not configured yet): the client keeps the
-- purchase unfinished and sends it again, so a paid purchase is never lost.

local IapVerify = {}

local GOOGLE_PACKAGE   = os.getenv("IAP_ANDROID_PACKAGE") or "com.cmatute.tinyturf"
local GOOGLE_KEY_PATH  = os.getenv("IAP_GOOGLE_SERVICE_ACCOUNT")
local ALLOW_UNVERIFIED = os.getenv("IAP_ALLOW_UNVERIFIED") == "1"

local VOIDED_INTERVAL   = 3600   -- seconds between refund checks
local VOIDED_FIRST      = 60     -- first check this long after start

local requests, results, thread
local jobs   = {}   -- id -> caller's job table
local nextId = 0
local log    = print
local voidedTimer, voidedInFlight = VOIDED_FIRST, false

-- Set by the server: called with a list of refunded purchase tokens
IapVerify.onVoided = nil

-- Runs on the worker thread. Only the standard Lua libraries are used there.
local WORKER = [[
require("love.thread")
local requests, results, email, pemPath, package = ...

local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
local function b64url(s)
    local out = {}
    for i = 1, #s, 3 do
        local a, b, c = s:byte(i, i + 2)
        local n = a * 65536 + (b or 0) * 256 + (c or 0)
        local chars = 2 + (b and 1 or 0) + (c and 1 or 0)
        for k = 1, chars do
            local idx = math.floor(n / 2 ^ (6 * (4 - k))) % 64
            out[#out + 1] = B64:sub(idx + 1, idx + 1)
        end
    end
    return table.concat(out)
end

local function run(cmd)
    local f = io.popen(cmd .. " 2>/dev/null", "r")
    if not f then return "" end
    local out = f:read("*a") or ""
    f:close()
    return out
end

local accessToken, accessExpires = nil, 0

local function getAccessToken()
    if accessToken and os.time() < accessExpires - 60 then return accessToken end
    local now = os.time()
    local header = b64url('{"alg":"RS256","typ":"JWT"}')
    local claims = b64url(string.format(
        '{"iss":"%s","scope":"https://www.googleapis.com/auth/androidpublisher",' ..
        '"aud":"https://oauth2.googleapis.com/token","iat":%d,"exp":%d}',
        email, now, now + 3600))
    local unsigned = header .. "." .. claims
    local tmp = os.tmpname()
    local f = io.open(tmp, "wb")
    if not f then return nil end
    f:write(unsigned)
    f:close()
    local sig = run("openssl dgst -sha256 -sign '" .. pemPath .. "' '" .. tmp .. "' | openssl base64 -A")
    os.remove(tmp)
    sig = sig:gsub("%s", ""):gsub("%+", "-"):gsub("/", "_"):gsub("=", "")
    if sig == "" then return nil end
    local body = run("curl -sS --max-time 15 -X POST" ..
        " -H 'Content-Type: application/x-www-form-urlencoded'" ..
        " --data 'grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Ajwt-bearer&assertion=" ..
        unsigned .. "." .. sig .. "' https://oauth2.googleapis.com/token")
    local token = body:match('"access_token"%s*:%s*"([%w%._%-]+)"')
    if not token then return nil end
    accessToken = token
    accessExpires = now + (tonumber(body:match('"expires_in"%s*:%s*(%d+)')) or 3600)
    return accessToken
end

-- purchases.products.get: https://developers.google.com/android-publisher/api-ref/rest/v3/purchases.products/get
local function verifyGoogle(job)
    local access = getAccessToken()
    if not access then return false, "google_auth_failed", true end
    local out = run("curl -sS --max-time 15 -w '\\n%{http_code}'" ..
        " -H 'Authorization: Bearer " .. access .. "'" ..
        " 'https://androidpublisher.googleapis.com/androidpublisher/v3/applications/" ..
        package .. "/purchases/products/" .. job.product .. "/tokens/" .. job.token .. "'")
    local body, code = out:match("^(.*)\n(%d+)%s*$")
    code = tonumber(code)
    if code == 200 then
        local state = body:match('"purchaseState"%s*:%s*(%d+)')
        local order = body:match('"orderId"%s*:%s*"([^"]*)"')
        if state == nil or state == "0" then return true, nil, false, order end
        if state == "2" then return false, "payment_pending", true end
        return false, "purchase_cancelled", false
    elseif code == 401 or code == 403 then
        accessToken = nil
        return false, "google_auth_failed", true
    elseif code == 400 or code == 404 or code == 410 then
        return false, "invalid_token", false
    end
    return false, "store_unreachable", true
end

-- purchases.voidedpurchases.list (default window: the last 30 days).
-- Returns the tokens joined by newlines (channels carry flat tables only).
local function listVoided()
    local access = getAccessToken()
    if not access then return nil, "google_auth_failed" end
    local tokens, page = {}, nil
    for _ = 1, 20 do
        local out = run("curl -sS --max-time 20 -w '\\n%{http_code}'" ..
            " -H 'Authorization: Bearer " .. access .. "'" ..
            " 'https://androidpublisher.googleapis.com/androidpublisher/v3/applications/" ..
            package .. "/purchases/voidedpurchases?type=0&maxResults=1000" ..
            (page and ("&token=" .. page) or "") .. "'")
        local body, code = out:match("^(.*)\n(%d+)%s*$")
        if tonumber(code) ~= 200 then
            if tonumber(code) == 401 or tonumber(code) == 403 then accessToken = nil end
            return nil, "http_" .. tostring(code)
        end
        for t in body:gmatch('"purchaseToken"%s*:%s*"([%w%._%-]+)"') do tokens[#tokens + 1] = t end
        page = body:match('"nextPageToken"%s*:%s*"([%w%-_=]+)"')
        if not page then break end
    end
    return table.concat(tokens, "\n")
end

while true do
    local job = requests:demand()
    if job.kind == "voided" then
        local tokens, err = listVoided()
        results:push({ id = job.id, kind = "voided", ok = tokens ~= nil, tokens = tokens or "", reason = err or "" })
    else
        local ok, reason, retry, order = verifyGoogle(job)
        results:push({ id = job.id, ok = ok, reason = reason or "", retry = retry and true or false, order = order or "" })
    end
end
]]

-- Pull client_email and private_key out of the service account JSON, and
-- write the key to a private PEM file openssl can read.
local function loadServiceAccount(path)
    local f = io.open(path, "r")
    if not f then return nil, "cannot read " .. path end
    local raw = f:read("*a")
    f:close()
    local email = raw:match('"client_email"%s*:%s*"([^"]+)"')
    local key   = raw:match('"private_key"%s*:%s*"(.-[^\\])"')
    if not email or not key then return nil, "no client_email/private_key in " .. path end
    key = key:gsub("\\n", "\n")
    local pemPath = path .. ".pem"
    os.execute("umask 077 && : > '" .. pemPath .. "'")
    local out = io.open(pemPath, "w")
    if not out then return nil, "cannot write " .. pemPath end
    out:write(key)
    out:close()
    return email, pemPath
end

function IapVerify.init(logFn)
    log = logFn or print
    if GOOGLE_KEY_PATH then
        local email, pemOrErr = loadServiceAccount(GOOGLE_KEY_PATH)
        if email then
            requests = love.thread.newChannel()
            results  = love.thread.newChannel()
            thread   = love.thread.newThread(WORKER)
            thread:start(requests, results, email, pemOrErr, GOOGLE_PACKAGE)
            log("[IAP] Google Play verification on (" .. GOOGLE_PACKAGE .. ", " .. email .. ")")
        else
            log("[IAP] Google Play verification OFF: " .. pemOrErr)
        end
    else
        log("[IAP] Google Play verification OFF: IAP_GOOGLE_SERVICE_ACCOUNT not set")
    end
    if ALLOW_UNVERIFIED then
        log("[IAP] WARNING: IAP_ALLOW_UNVERIFIED=1, purchases are granted without store checks")
    end
end

-- Queue a check. job = { store, product, token, ... } (extra fields are kept
-- and handed back). onResult(job, ok, reason, retry, order) runs from poll().
function IapVerify.request(job, onResult)
    job.onResult = onResult
    if job.store == "google" and thread then
        nextId = nextId + 1
        job.id = nextId
        jobs[nextId] = job
        requests:push({ id = nextId, product = job.product, token = job.token })
        return
    end
    -- No store check available for this purchase.
    if ALLOW_UNVERIFIED then
        onResult(job, true, nil, false, job.order)
    elseif job.store == "mock" then
        onResult(job, false, "test_purchases_disabled", false)
    else
        -- A real purchase we can't check yet: leave it unfinished on the
        -- device so it's granted once verification is configured.
        onResult(job, false, "verification_unavailable", true)
    end
end

-- Call every server tick: delivers finished Google checks and schedules the
-- refund check.
function IapVerify.poll(dt)
    if not results then return end
    if thread and not voidedInFlight then
        voidedTimer = voidedTimer - (dt or 0)
        if voidedTimer <= 0 then
            voidedTimer, voidedInFlight = VOIDED_INTERVAL, true
            requests:push({ kind = "voided", id = 0 })
        end
    end
    if thread then
        local err = thread:getError()
        if err then
            log("[IAP] verifier thread died: " .. err)
            thread = nil
        end
    end
    while true do
        local r = results:pop()
        if not r then break end
        if r.kind == "voided" then
            voidedInFlight = false
            if not r.ok then
                log("[IAP] refund check failed: " .. r.reason)
            elseif r.tokens ~= "" and IapVerify.onVoided then
                local list = {}
                for t in r.tokens:gmatch("[^\n]+") do list[#list + 1] = t end
                IapVerify.onVoided(list)
            end
        end
        local job = jobs[r.id]
        jobs[r.id] = nil
        if job then
            job.onResult(job, r.ok, r.reason ~= "" and r.reason or nil, r.retry,
                         r.order ~= "" and r.order or job.order)
        end
    end
end

return IapVerify
