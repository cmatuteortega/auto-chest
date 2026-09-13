-- lib/iap/init.lua
-- Drop-in in-app purchases for LÖVE games.
--
--   local IAP = require("lib.iap")
--
--   IAP.init{
--       products = {
--           { id = "gems_small", type = "consumable",     grants = { gems = 100 },
--             stores = { android = "com.you.game.gems_small", ios = "gems_small" } },
--           { id = "remove_ads", type = "non_consumable", grants = { noAds = true } },
--       },
--       validate = function(purchase, done) ... end,   -- server-side check
--       onGrant  = function(purchase) ... end,         -- credit the player
--   }
--
--   function love.update(dt) IAP.update(dt) end
--   IAP.purchase("gems_small")
--
-- Design rules this module enforces, because they are the ones that cost real
-- money when broken:
--
--   1. A purchase is written to disk the moment the store hands it over, and is
--      only removed once it has been granted *and* finished at the store. Kill
--      the app at any point and the next launch picks the purchase back up.
--   2. Nothing is granted until `validate` says so, when a validator is set.
--   3. The store is only told to consume/acknowledge *after* the grant landed,
--      so a failure anywhere earlier means the store simply re-delivers.
--   4. Grants are at-least-once. Duplicate delivery after a crash is possible
--      by design, so `validate` / the game server must be idempotent on
--      `purchase.txn`.
--
-- Licence: MIT, same as the rest of the module.

local PATH = (...):gsub("%.init$", "") .. "."

local util    = require(PATH .. "util")
local Catalog = require(PATH .. "catalog")
local Ledger  = require(PATH .. "ledger")

local IAP = {
    _VERSION = "1.0.0",
}

-- ── module state ──────────────────────────────────────────────────────────────

local S = nil  -- nil until init()

local STATE_IDLE       = "idle"
local STATE_CONNECTING = "connecting"
local STATE_READY      = "ready"
local STATE_UNAVAILABLE = "unavailable"

local MAX_INIT_ATTEMPTS = 5

-- ── events ────────────────────────────────────────────────────────────────────

local function emit(event, payload)
    if not S then return end
    for _, entry in ipairs(S.listeners) do
        if entry.event == event or entry.event == "*" then
            local ok, err = pcall(entry.fn, payload, event)
            if not ok then
                util.err("listener for '%s' errored: %s", event, tostring(err))
            end
        end
    end
end

--- Subscribe to an IAP event.
--  Events: "ready", "unavailable", "products", "purchase", "failed",
--          "deferred", "restored".
--  Returns a handle for IAP.off().
function IAP.on(event, fn)
    assert(S, "iap: call IAP.init() first")
    assert(type(fn) == "function", "iap: listener must be a function")
    local entry = { event = event, fn = fn }
    S.listeners[#S.listeners + 1] = entry
    return entry
end

function IAP.off(handle)
    if not S or not handle then return end
    for i, entry in ipairs(S.listeners) do
        if entry == handle then
            table.remove(S.listeners, i)
            return true
        end
    end
    return false
end

-- ── purchase records ──────────────────────────────────────────────────────────

-- Public shape handed to validate / onGrant / the "purchase" event.
local function publicPurchase(record)
    local product = S.catalog:get(record.productId)
    return {
        txn        = record.txn,
        productId  = record.productId,
        sku        = record.sku,
        type       = record.type,
        platform   = record.platform,
        token      = record.token,
        payload    = record.payload,     -- raw receipt, for the game's server
        signature  = record.signature,
        restored   = record.restored or false,
        grants     = product and util.copy(product.grants) or {},
        product    = product,
    }
end

-- Bring a purchase reported by the store under the ledger's care. Returns the
-- stored record, or nil if it is one we have already fully settled.
local function ingest(purchase, opts)
    opts = opts or {}
    local product = S.catalog:fromSku(purchase.sku)

    if not product then
        -- Not one of ours (or the catalog changed between releases). Finish it
        -- so the store stops re-delivering, but never grant anything.
        util.warn("store delivered unknown sku '%s'; finishing without granting",
            tostring(purchase.sku))
        if S.backend.finish then
            S.backend:finish({ sku = purchase.sku, type = "consumable",
                               token = purchase.token, txn = purchase.txn })
        end
        return nil
    end

    if not purchase.txn then
        util.err("store delivered '%s' without a transaction id; ignoring", purchase.sku)
        return nil
    end

    local existing = S.ledger:getPending(purchase.txn)
    if existing then
        -- Re-delivery of something already in flight: refresh the token (it can
        -- change across a restore) and let the normal loop carry on.
        existing.token     = purchase.token or existing.token
        existing.payload   = purchase.payload or existing.payload
        existing.signature = purchase.signature or existing.signature
        S.ledger:save()
        return existing
    end

    local record = {
        txn        = purchase.txn,
        productId  = product.id,
        sku        = product.sku,
        type       = product.type,
        platform   = purchase.platform or S.platform,
        token      = purchase.token,
        payload    = purchase.payload,
        signature  = purchase.signature,
        restored   = purchase.restored or opts.restored or false,
        -- Already granted in a previous run? Then all that is left is to tell
        -- the store we are done with it.
        status     = S.ledger:isProcessed(purchase.txn) and "granted" or "unverified",
        attempts   = 0,
        nextAttempt = 0,
        created    = util.wallclock(),
    }

    S.ledger:addPending(record)
    util.info("ingested %s (%s, %s)", record.productId, record.txn, record.status)
    return record
end

-- ── the settle loop ───────────────────────────────────────────────────────────

local function scheduleRetry(record, reason)
    record.attempts = (record.attempts or 0) + 1
    local delay = util.backoff(record.attempts, S.config.retryBase, S.config.retryCap)
    S.ledger:updatePending(record.txn, {
        attempts    = record.attempts,
        nextAttempt = util.now() + delay,
        busy        = false,
    })
    util.warn("%s for %s failed (%s); retrying in %.1fs",
        record.status, record.productId, tostring(reason), delay)
end

local function doGrant(record)
    local purchase = publicPurchase(record)

    -- The game credits the player here. It runs *before* the ledger marks the
    -- transaction processed, so a crash mid-grant replays rather than loses it.
    if S.config.onGrant then
        local ok, result = pcall(S.config.onGrant, purchase)
        if not ok then
            scheduleRetry(record, "onGrant errored: " .. tostring(result))
            return false
        end
        if result == false then
            scheduleRetry(record, "onGrant declined")
            return false
        end
    end

    S.ledger:markProcessed(record.txn)
    if record.type ~= "consumable" then
        S.ledger:setOwned(record.productId, record.txn)
    end

    S.ledger:updatePending(record.txn, { status = "granted", attempts = 0, nextAttempt = 0, busy = false })

    util.info("granted %s (%s)", record.productId, record.txn)
    emit("purchase", purchase)

    -- Resolve the caller waiting on IAP.purchase().
    if S.inFlight and S.inFlight.productId == record.productId then
        local cb = S.inFlight.cb
        S.inFlight = nil
        if cb then pcall(cb, true, purchase) end
    end

    return true
end

local function verify(record)
    if not S.config.validate then
        -- No server to ask: local trust only. Fine for cosmetic unlocks,
        -- not for anything a cheated save could mint.
        return doGrant(record)
    end

    S.ledger:updatePending(record.txn, { busy = true })

    local settled = false
    local function done(ok, err)
        if settled then
            util.warn("validate() called back twice for %s; ignoring", record.txn)
            return
        end
        settled = true

        local live = S.ledger:getPending(record.txn)
        if not live then return end  -- cancelled/reset while we waited

        if ok then
            live.busy = false
            doGrant(live)
        elseif type(err) == "table" and err.permanent then
            -- The server rejected the receipt outright (invalid, refunded,
            -- already consumed elsewhere). Finishing it stops the store from
            -- re-delivering it forever.
            util.err("validation permanently rejected %s: %s",
                live.productId, tostring(err.message or err.code))
            S.ledger:updatePending(live.txn, { status = "rejected", busy = false, nextAttempt = 0 })
            emit("failed", {
                productId = live.productId,
                code      = err.code or "invalid_receipt",
                message   = err.message or "This purchase could not be verified",
            })
            if S.inFlight and S.inFlight.productId == live.productId then
                local cb = S.inFlight.cb
                S.inFlight = nil
                if cb then pcall(cb, false, { code = err.code or "invalid_receipt" }) end
            end
        else
            live.busy = false
            scheduleRetry(live, err and (err.message or err.code or err) or "validation failed")
        end
    end

    local ok, err = pcall(S.config.validate, publicPurchase(record), done)
    if not ok then
        settled = true
        scheduleRetry(record, "validate errored: " .. tostring(err))
    end
end

local function finishAtStore(record)
    S.ledger:updatePending(record.txn, { busy = true, finishDeadline = util.now() + 60 })
    S.backend:finish(record)
end

local function pumpPending()
    local now = util.now()

    for _, record in ipairs(S.ledger:pendingList()) do
        if record.busy then
            -- Guard against a native bridge that never answers a finish.
            if record.finishDeadline and now > record.finishDeadline then
                S.ledger:updatePending(record.txn, { busy = false, finishDeadline = nil })
                scheduleRetry(record, "finish timed out")
            end
        elseif now >= (record.nextAttempt or 0) then
            if record.status == "unverified" then
                verify(record)
            elseif record.status == "granted" or record.status == "rejected" then
                finishAtStore(record)
            end
        end
    end
end

-- ── backend events ────────────────────────────────────────────────────────────

local handlers = {}

function handlers.products(entries)
    local matched = S.catalog:applyStoreDetails(entries)
    util.info("store returned details for %d/%d product(s)", matched, #S.catalog.list)
    emit("products", S.catalog.list)
end

function handlers.ready(data)
    S.state      = STATE_READY
    S.initTries  = 0

    -- Purchases the store still considers unfinished: either granted in a
    -- previous run and never consumed, or bought while the game was closed.
    for _, purchase in ipairs((data and data.unfinished) or {}) do
        ingest(purchase)
    end

    util.info("store ready (%d pending purchase(s) to settle)", S.ledger:pendingCount())
    emit("ready", { products = S.catalog.list })
end

function handlers.init_failed(err)
    if S.initTries < MAX_INIT_ATTEMPTS then
        local delay = util.backoff(S.initTries, S.config.retryBase, 60)
        S.initTries    = S.initTries + 1
        S.retryInitAt  = util.now() + delay
        util.warn("store init failed (%s); retry %d/%d in %.1fs",
            tostring(err and err.message), S.initTries, MAX_INIT_ATTEMPTS, delay)
    else
        S.state = STATE_UNAVAILABLE
        util.err("store unavailable after %d attempts", MAX_INIT_ATTEMPTS)
        emit("unavailable", {
            code    = (err and err.code) or "init_failed",
            message = (err and err.message) or "Store unavailable",
        })
    end
end

function handlers.purchase(purchase)
    local record = ingest(purchase)
    if record then pumpPending() end
end

function handlers.purchase_failed(err)
    local product = err.sku and S.catalog:fromSku(err.sku)
    local payload = {
        productId = product and product.id or nil,
        sku       = err.sku,
        code      = err.code or "store_error",
        message   = err.message or "Purchase failed",
    }

    util.info("purchase failed: %s (%s)", payload.code, tostring(payload.message))

    if S.inFlight then
        local cb = S.inFlight.cb
        S.inFlight = nil
        if cb then pcall(cb, false, payload) end
    end

    emit(payload.code == "user_cancelled" and "cancelled" or "failed", payload)
end

function handlers.purchase_deferred(data)
    local product = data.sku and S.catalog:fromSku(data.sku)
    -- Google Play PENDING / StoreKit deferred: nothing to grant yet, the store
    -- delivers it later (possibly on a future launch).
    if S.inFlight then
        local cb = S.inFlight.cb
        S.inFlight = nil
        if cb then pcall(cb, false, { code = "deferred" }) end
    end
    emit("deferred", { productId = product and product.id, sku = data.sku })
end

function handlers.restore_done(data)
    local ids = {}
    for _, purchase in ipairs((data and data.purchases) or {}) do
        purchase.restored = true
        local record = ingest(purchase, { restored = true })
        if record then ids[#ids + 1] = record.productId end
    end
    pumpPending()

    if S.restoreCb then
        local cb = S.restoreCb
        S.restoreCb = nil
        pcall(cb, not (data and data.error), ids)
    end

    util.info("restore finished: %d purchase(s)", #ids)
    emit("restored", { productIds = ids, error = data and data.error })
end

function handlers.finished(data)
    if data.ok and data.txn then
        util.info("store finished %s", data.txn)
        S.ledger:removePending(data.txn)
        return
    end

    -- Failed or unattributed finish: clear the busy flag so the loop retries.
    if data.txn then
        local record = S.ledger:getPending(data.txn)
        if record then
            S.ledger:updatePending(data.txn, { busy = false, finishDeadline = nil })
            scheduleRetry(record, data.code or "finish failed")
        end
    else
        for _, record in ipairs(S.ledger:pendingList()) do
            if record.busy then
                S.ledger:updatePending(record.txn, { busy = false, finishDeadline = nil })
            end
        end
    end
end

-- ── lifecycle ─────────────────────────────────────────────────────────────────

--- Initialise the module.
--  config:
--    products    (required) array of product definitions, see Catalog.
--    backend     "auto" | "mock" | "native" | backend factory table. Default "auto".
--    platform    override the detected platform ("android"|"ios"|"mock").
--    validate    function(purchase, done) — call done(true) to grant,
--                done(false) to retry, done(false, {permanent=true}) to reject.
--    onGrant     function(purchase) — credit the player. Return false to retry.
--    storageFile ledger filename in the save directory.
--    json        JSON library (defaults to the copy vendored beside this file).
--    logLevel    "off"|"error"|"warn"|"info"|"debug". Default "info".
--    bridge      { dir, poll, transport } for the native backend.
--    mock        { latency, outcome } for the mock backend.
function IAP.init(config)
    config = config or {}
    assert(config.products, "iap: config.products is required")

    if S then
        util.warn("IAP.init() called twice; shutting the previous instance down")
        IAP.shutdown()
    end

    util.logLevel = config.logLevel or "info"
    if config.logger then util.setLogger(config.logger) end

    local json     = config.json or require(PATH .. "json")
    local platform = config.platform or util.detectPlatform()

    local backendName = config.backend or "auto"
    if backendName == "auto" then
        backendName = (platform == "mock") and "mock" or "native"
    end

    S = {
        config    = config,
        platform  = platform,
        json      = json,
        catalog   = Catalog.new(config.products, platform),
        ledger    = Ledger.new(config.storageFile or "iap_ledger.json", json, config.fs),
        listeners = {},
        state     = STATE_CONNECTING,
        initTries = 0,
        inFlight  = nil,
        restoreCb = nil,
    }

    local function dispatch(kind, data)
        local handler = handlers[kind]
        if not handler then
            util.warn("unhandled backend event '%s'", tostring(kind))
            return
        end
        local ok, err = pcall(handler, data)
        if not ok then util.err("error in '%s' handler: %s", kind, tostring(err)) end
    end

    local backendOpts = {
        catalog  = S.catalog,
        platform = platform,
        json     = json,
        emit     = dispatch,
        config   = (backendName == "mock") and (config.mock or {}) or (config.bridge or {}),
    }

    if type(backendName) == "table" then
        S.backend = backendName.new(backendOpts)
        S.backendName = "custom"
    else
        S.backend = require(PATH .. "backends." .. backendName).new(backendOpts)
        S.backendName = backendName
    end

    util.info("initialising (platform=%s backend=%s products=%d)",
        platform, S.backendName, #S.catalog.list)

    S.backend:init()
    return true
end

--- Pump the module. Call once per frame from love.update.
function IAP.update(dt)
    if not S then return end

    S.backend:update(dt or 0)

    if S.retryInitAt and util.now() >= S.retryInitAt then
        S.retryInitAt = nil
        S.state = STATE_CONNECTING
        S.backend:init()
    end

    pumpPending()
end

function IAP.shutdown()
    if not S then return end
    if S.backend and S.backend.shutdown then S.backend:shutdown() end
    S = nil
end

-- ── queries ───────────────────────────────────────────────────────────────────

function IAP.isReady()   return S ~= nil and S.state == STATE_READY end
function IAP.getState()  return S and S.state or STATE_IDLE end
function IAP.isAvailable() return S ~= nil and S.state ~= STATE_UNAVAILABLE end

--- All products, in declaration order, with store pricing filled in.
function IAP.getProducts()
    if not S then return {} end
    return S.catalog.list
end

function IAP.getProduct(id)
    return S and S.catalog:get(id) or nil
end

--- Localised price string, or the configured fallback before the store answers.
function IAP.getPrice(id)
    local p = IAP.getProduct(id)
    return p and p.price or ""
end

--- True for a non-consumable / subscription the player owns.
function IAP.isOwned(id)
    return S ~= nil and S.ledger:isOwned(id)
end

function IAP.getOwned()
    return S and S.ledger:ownedIds() or {}
end

--- Purchases received but not yet settled. Non-zero means money is in flight.
function IAP.getPendingCount()
    return S and S.ledger:pendingCount() or 0
end

--- True while a purchase dialog is open.
function IAP.isBusy()
    return S ~= nil and S.inFlight ~= nil
end

function IAP.getBridgeInfo()
    if not S or not S.backend.describe then return nil end
    return S.backend:describe()
end

-- ── actions ───────────────────────────────────────────────────────────────────

local function failNow(cb, code, message, productId)
    local payload = { code = code, message = message, productId = productId }
    if cb then pcall(cb, false, payload) end
    emit(code == "user_cancelled" and "cancelled" or "failed", payload)
    return false
end

--- Start a purchase. cb(ok, purchaseOrError) fires once the flow settles.
function IAP.purchase(productId, cb)
    if not S then
        util.err("IAP.purchase() before IAP.init()")
        return false
    end

    local product = S.catalog:get(productId)
    if not product then
        return failNow(cb, "unknown_product", "No such product: " .. tostring(productId), productId)
    end
    if S.state ~= STATE_READY then
        return failNow(cb, "not_ready", "The store is not ready yet", productId)
    end
    if S.inFlight then
        return failNow(cb, "busy", "Another purchase is already in progress", productId)
    end
    if product.type ~= "consumable" and S.ledger:isOwned(productId) then
        return failNow(cb, "already_owned", "You already own this", productId)
    end
    if not product.available then
        return failNow(cb, "product_unavailable",
            "This item is not available in your store", productId)
    end

    util.info("purchasing %s (%s)", productId, product.sku)
    S.inFlight = { productId = productId, cb = cb, startedAt = util.now() }
    S.backend:purchase(product)
    return true
end

--- Ask the store for everything this account already owns. Required on iOS,
--  and the right way to recover non-consumables after a reinstall.
function IAP.restore(cb)
    if not S then return false end
    if S.state ~= STATE_READY then
        if cb then pcall(cb, false, {}) end
        return false
    end
    S.restoreCb = cb
    S.backend:restore()
    return true
end

--- Force the settle loop to run now (e.g. after the app regains focus).
function IAP.flush()
    if S then pumpPending() end
end

-- ── testing helpers ───────────────────────────────────────────────────────────

--- Script the mock store's next (or every) outcome:
--  "success" | "cancelled" | "error" | "pending".
function IAP.setMockOutcome(outcome, sticky)
    if S and S.backend.setOutcome then S.backend:setOutcome(outcome, sticky) end
end

--- Wipe all local IAP state. Entitlements are lost until IAP.restore() runs.
function IAP.resetLocalState()
    if S then S.ledger:reset() end
end

return IAP
