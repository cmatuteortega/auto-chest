-- tests/test_iap.lua
-- Headless lifecycle tests for lib/iap. Run with:  lua tests/test_iap.lua
--
-- Covers the paths that cost real money when they break: grant-exactly-once,
-- crash recovery of an in-flight purchase, consume-only-after-grant, server
-- validation (transient retry and permanent rejection), and the file-drop
-- transport the native bridges speak.

package.path = package.path .. ";./?.lua;./?/init.lua"

-- ── LÖVE stubs ────────────────────────────────────────────────────────────────

local clock = 1000.0
local files = {}   -- virtual save directory: path -> string
local dirs  = { [""] = true }

local function parentDirs(path)
    local acc = {}
    for part in path:gmatch("[^/]+") do
        acc[#acc + 1] = part
    end
    return acc
end

---@diagnostic disable-next-line: lowercase-global
love = {
    timer  = { getTime = function() return clock end },
    math   = { random = function(n) return math.random(n) end },
    system = { getOS = function() return "Linux" end },
    filesystem = {
        read  = function(name) return files[name] end,
        write = function(name, data) files[name] = data; return true end,
        remove = function(name) files[name] = nil; dirs[name] = nil; return true end,
        createDirectory = function(name)
            local parts, path = parentDirs(name), nil
            for _, part in ipairs(parts) do
                path = path and (path .. "/" .. part) or part
                dirs[path] = true
            end
            return true
        end,
        getInfo = function(name)
            if files[name] then return { type = "file", size = #files[name] } end
            if dirs[name]  then return { type = "directory" } end
            return nil
        end,
        getDirectoryItems = function(dir)
            local out, seen = {}, {}
            local prefix = dir .. "/"
            for path in pairs(files) do
                local rest = path:sub(1, #prefix) == prefix and path:sub(#prefix + 1) or nil
                if rest and not rest:find("/") and not seen[rest] then
                    seen[rest] = true
                    out[#out + 1] = rest
                end
            end
            table.sort(out)
            return out
        end,
        getSaveDirectory = function() return "/virtual/save" end,
    },
}

math.randomseed(12345)

-- ── harness ───────────────────────────────────────────────────────────────────

local passed, failed = 0, 0
local currentTest = "?"

local function check(cond, label)
    if cond then
        passed = passed + 1
    else
        failed = failed + 1
        print(string.format("  FAIL [%s] %s", currentTest, label))
    end
end

local function eq(got, want, label)
    if got ~= want then
        failed = failed + 1
        print(string.format("  FAIL [%s] %s: got %s, want %s",
            currentTest, label, tostring(got), tostring(want)))
    else
        passed = passed + 1
    end
end

local IAP

local function freshModule()
    -- Force a clean require so module-level state never leaks between tests.
    for name in pairs(package.loaded) do
        if name:match("^lib%.iap") then package.loaded[name] = nil end
    end
    IAP = require("lib.iap")
end

local function wipeFs()
    files, dirs = {}, { [""] = true }
end

-- Advance simulated time, pumping the module the way love.update would.
local function advance(seconds, step)
    step = step or 1 / 60
    local elapsed = 0
    while elapsed < seconds do
        clock = clock + step
        IAP.update(step)
        elapsed = elapsed + step
    end
end

local function test(name, fn)
    currentTest = name
    print("• " .. name)
    local ok, err = pcall(fn)
    if not ok then
        failed = failed + 1
        print("  FAIL [" .. name .. "] error: " .. tostring(err))
    end
    if IAP then IAP.shutdown() end
end

-- ── fixtures ──────────────────────────────────────────────────────────────────

local PRODUCTS = {
    { id = "gems_small", type = "consumable", grants = { gems = 100 },
      title = "Handful of Gems", price = "$0.99",
      stores = { android = "com.test.gems_small", ios = "gems_small" } },
    { id = "gems_large", type = "consumable", grants = { gems = 1200 },
      stores = { android = "com.test.gems_large", ios = "gems_large" } },
    { id = "remove_ads", type = "non_consumable", grants = { noAds = true },
      sku = "com.test.remove_ads" },
}

local function bootMock(overrides)
    wipeFs()
    freshModule()
    local cfg = {
        products = PRODUCTS,
        backend  = "mock",
        platform = "mock",
        logLevel = "off",
        mock     = { latency = 0.1 },
    }
    for k, v in pairs(overrides or {}) do cfg[k] = v end
    IAP.init(cfg)
    advance(0.5)
    return cfg
end

-- ══════════════════════════════════════════════════════════════════════════════

print("\n=== lib/iap lifecycle tests ===\n")

test("init reaches ready and fills in store pricing", function()
    local readyFired = 0
    bootMock()
    IAP.on("ready", function() readyFired = readyFired + 1 end)

    check(IAP.isReady(), "module reports ready")
    eq(#IAP.getProducts(), 3, "product count")
    eq(IAP.getPrice("gems_small"), "$0.99", "declared fallback price kept")
    eq(IAP.getProduct("gems_small").sku, "gems_small", "mock platform resolves to bare id")
    eq(IAP.getProduct("remove_ads").sku, "com.test.remove_ads", "shared sku used on all stores")
    check(IAP.getProduct("gems_large").available, "store confirmed availability")
end)

test("successful consumable purchase grants once and settles", function()
    local grants, events = {}, {}
    bootMock({ onGrant = function(p) grants[#grants + 1] = p end })
    IAP.on("purchase", function(p) events[#events + 1] = p.productId end)

    local cbOk, cbPurchase
    IAP.purchase("gems_small", function(ok, p) cbOk, cbPurchase = ok, p end)
    check(IAP.isBusy(), "busy while the dialog is open")

    advance(1.0)

    eq(#grants, 1, "onGrant called once")
    eq(grants[1].productId, "gems_small", "granted the right product")
    eq(grants[1].grants.gems, 100, "grant payload carries the gem count")
    eq(#events, 1, "purchase event fired once")
    eq(cbOk, true, "purchase callback reported success")
    check(cbPurchase and cbPurchase.txn, "callback carries a transaction id")
    eq(IAP.getPendingCount(), 0, "ledger drained after the store finished it")
    check(not IAP.isBusy(), "no longer busy")
    check(not IAP.isOwned("gems_small"), "consumables are not marked owned")
end)

test("cancelled purchase grants nothing", function()
    local grants, cancels = 0, 0
    bootMock({ onGrant = function() grants = grants + 1 end })
    IAP.on("cancelled", function() cancels = cancels + 1 end)

    IAP.setMockOutcome("cancelled")
    local cbOk, cbErr
    IAP.purchase("gems_small", function(ok, err) cbOk, cbErr = ok, err end)
    advance(1.0)

    eq(grants, 0, "nothing granted")
    eq(cancels, 1, "cancelled event fired")
    eq(cbOk, false, "callback reported failure")
    eq(cbErr and cbErr.code, "user_cancelled", "cancellation code propagated")
    eq(IAP.getPendingCount(), 0, "nothing left pending")
end)

test("deferred purchase grants nothing yet", function()
    local grants, deferred = 0, 0
    bootMock({ onGrant = function() grants = grants + 1 end })
    IAP.on("deferred", function() deferred = deferred + 1 end)

    IAP.setMockOutcome("pending")
    IAP.purchase("gems_small")
    advance(1.0)

    eq(grants, 0, "nothing granted for a deferred purchase")
    eq(deferred, 1, "deferred event fired")
    check(not IAP.isBusy(), "in-flight state cleared")
end)

test("non-consumable is owned afterwards and cannot be re-bought", function()
    bootMock()
    IAP.purchase("remove_ads")
    advance(1.0)

    check(IAP.isOwned("remove_ads"), "entitlement recorded")
    eq(#IAP.getOwned(), 1, "exactly one entitlement")

    local cbOk, cbErr
    IAP.purchase("remove_ads", function(ok, err) cbOk, cbErr = ok, err end)
    eq(cbOk, false, "second purchase refused")
    eq(cbErr and cbErr.code, "already_owned", "refusal reason")
end)

test("entitlements survive a restart", function()
    bootMock()
    IAP.purchase("remove_ads")
    advance(1.0)
    check(IAP.isOwned("remove_ads"), "owned before restart")

    IAP.shutdown()
    freshModule()  -- same virtual filesystem, fresh module state
    IAP.init({ products = PRODUCTS, backend = "mock", platform = "mock",
               logLevel = "off", mock = { latency = 0.1 } })
    advance(0.5)

    check(IAP.isOwned("remove_ads"), "entitlement reloaded from the ledger")
end)

test("purchase interrupted before granting is recovered on next launch", function()
    -- Simulate a kill between "store handed us the purchase" and "player got
    -- the gems": the ledger holds an unverified record and nothing else.
    wipeFs()
    freshModule()

    local json = require("lib.iap.json")
    files["iap_ledger.json"] = json.encode({
        version = 1,
        processed = {}, processedOrder = {}, owned = {},
        pending = {
            ["txn-interrupted"] = {
                txn = "txn-interrupted", productId = "gems_large", sku = "gems_large",
                type = "consumable", platform = "mock", token = "tok-interrupted",
                status = "unverified", attempts = 0, nextAttempt = 0, created = 1,
            },
        },
    })

    local grants = {}
    IAP.init({ products = PRODUCTS, backend = "mock", platform = "mock", logLevel = "off",
               mock = { latency = 0.1 },
               onGrant = function(p) grants[#grants + 1] = p end })
    advance(1.0)

    eq(#grants, 1, "interrupted purchase was granted on relaunch")
    eq(grants[1].productId, "gems_large", "recovered the right product")
    eq(grants[1].grants.gems, 1200, "recovered grant payload")
    eq(IAP.getPendingCount(), 0, "record settled and removed")
end)

test("a purchase already granted is finished but never granted twice", function()
    wipeFs()
    freshModule()

    local json = require("lib.iap.json")
    files["iap_ledger.json"] = json.encode({
        version = 1,
        processed = { ["txn-done"] = 123 },
        processedOrder = { "txn-done" },
        owned = {},
        pending = {
            ["txn-done"] = {
                txn = "txn-done", productId = "gems_small", sku = "gems_small",
                type = "consumable", platform = "mock", token = "tok-done",
                status = "granted", attempts = 0, nextAttempt = 0, created = 1,
            },
        },
    })

    local grants = 0
    IAP.init({ products = PRODUCTS, backend = "mock", platform = "mock", logLevel = "off",
               mock = { latency = 0.1 },
               onGrant = function() grants = grants + 1 end })
    advance(1.0)

    eq(grants, 0, "no second grant for an already-processed transaction")
    eq(IAP.getPendingCount(), 0, "but the store was still told to consume it")
end)

test("server validation gates the grant", function()
    local seen = {}
    bootMock({
        onGrant  = function(p) seen[#seen + 1] = p.productId end,
        validate = function(purchase, done)
            check(purchase.payload ~= nil, "validator receives the raw receipt")
            check(purchase.txn ~= nil, "validator receives the transaction id")
            done(true)
        end,
    })

    IAP.purchase("gems_small")
    advance(1.0)

    eq(#seen, 1, "granted after the validator approved")
    eq(IAP.getPendingCount(), 0, "settled")
end)

test("transient validation failure retries, then grants", function()
    local attempts, grants = 0, 0
    bootMock({
        onGrant  = function() grants = grants + 1 end,
        retryBase = 0.2, retryCap = 0.5,
        validate = function(_, done)
            attempts = attempts + 1
            done(attempts >= 3)   -- fail twice, then succeed
        end,
    })

    IAP.purchase("gems_small")
    advance(6.0)

    check(attempts >= 3, "validator retried until it succeeded (" .. attempts .. " attempts)")
    eq(grants, 1, "granted exactly once")
    eq(IAP.getPendingCount(), 0, "settled")
end)

test("permanently rejected receipt is never granted but is still consumed", function()
    local grants, failures = 0, {}
    bootMock({
        onGrant  = function() grants = grants + 1 end,
        validate = function(_, done)
            done(false, { permanent = true, code = "invalid_receipt",
                          message = "Signature did not verify" })
        end,
    })
    IAP.on("failed", function(e) failures[#failures + 1] = e.code end)

    local cbOk
    IAP.purchase("gems_small", function(ok) cbOk = ok end)
    advance(2.0)

    eq(grants, 0, "nothing granted for a bad receipt")
    eq(failures[1], "invalid_receipt", "failure surfaced to the game")
    eq(cbOk, false, "callback reported failure")
    eq(IAP.getPendingCount(), 0, "consumed so the store stops re-delivering it")
end)

test("onGrant errors are retried rather than swallowed", function()
    local calls = 0
    bootMock({
        retryBase = 0.2, retryCap = 0.5,
        onGrant = function()
            calls = calls + 1
            if calls < 3 then error("database is down") end
        end,
    })

    IAP.purchase("gems_small")
    advance(6.0)

    check(calls >= 3, "onGrant retried after throwing (" .. calls .. " calls)")
    eq(IAP.getPendingCount(), 0, "settled once onGrant stopped failing")
end)

test("guards: unknown product, not ready, and concurrent purchases", function()
    wipeFs()
    freshModule()
    IAP.init({ products = PRODUCTS, backend = "mock", platform = "mock",
               logLevel = "off", mock = { latency = 0.1 } })

    local _, notReady
    IAP.purchase("gems_small", function(ok, err) _, notReady = ok, err end)
    eq(notReady and notReady.code, "not_ready", "purchase before ready is refused")

    advance(0.5)

    local unknown
    IAP.purchase("no_such_thing", function(_, err) unknown = err end)
    eq(unknown and unknown.code, "unknown_product", "unknown product refused")

    IAP.purchase("gems_small")
    local busy
    IAP.purchase("gems_large", function(_, err) busy = err end)
    eq(busy and busy.code, "busy", "second concurrent purchase refused")
end)

test("unknown skus from the store are consumed, never granted", function()
    wipeFs()
    freshModule()
    local json = require("lib.iap.json")

    local inbox, outbox = {}, {}
    local fakeTransport = {
        send = function(_, msg) outbox[#outbox + 1] = msg; return true end,
        receive = function() local o = inbox; inbox = {}; return o end,
        sweepStaleRequests = function() end,
    }

    local grants = 0
    IAP.init({ products = PRODUCTS, backend = "native", platform = "android",
               logLevel = "off", json = json, bridge = { transport = fakeTransport },
               onGrant = function() grants = grants + 1 end })

    inbox[1] = { id = outbox[1].id, op = "init", ok = true, unfinished = {},
                 products = { { sku = "com.test.gems_small", price = "$0.99" } } }
    advance(0.5)

    -- A sku from an older build, or another game sharing the account.
    inbox[1] = { op = "purchase", ok = true, purchase = {
        sku = "com.test.retired_bundle", orderId = "GPA.ghost", token = "ghost-token" } }
    advance(0.5)

    eq(grants, 0, "nothing granted for an unknown sku")
    eq(IAP.getPendingCount(), 0, "nothing written to the ledger")
    local last = outbox[#outbox]
    eq(last.op, "finish", "store told to consume it so it stops re-delivering")
    eq(last.token, "ghost-token", "finish targets the ghost purchase")
end)

-- ── transport ─────────────────────────────────────────────────────────────────

test("file-drop transport round-trips through the native side", function()
    wipeFs()
    freshModule()
    local json     = require("lib.iap.json")
    local FileDrop = require("lib.iap.transport.filedrop")

    local t = FileDrop.new({ dir = "iap_bridge", poll = 0, json = json })
    check(t:send({ id = "1", op = "init" }), "request written")

    -- The native half: read committed requests, reply into to_lua.
    local items = love.filesystem.getDirectoryItems("iap_bridge/to_native")
    local sawBody, sawMarker = false, false
    for _, name in ipairs(items) do
        if name:match("%.json$") then sawBody = true end
        if name:match("%.rdy$")  then sawMarker = true end
    end
    check(sawBody, "body file present")
    check(sawMarker, "commit marker present")

    love.filesystem.write("iap_bridge/to_lua/r1.json",
        json.encode({ id = "1", op = "init", ok = true, products = {} }))
    love.filesystem.write("iap_bridge/to_lua/r1.rdy", "1")

    local msgs = t:receive(1.0)
    eq(#msgs, 1, "one reply received")
    eq(msgs[1].op, "init", "reply op")
    eq(msgs[1].ok, true, "reply payload")

    eq(#t:receive(1.0), 0, "reply consumed exactly once")

    -- A body with no marker is a half-written message and must be ignored.
    love.filesystem.write("iap_bridge/to_lua/r2.json", "{\"op\":\"purchase\"}")
    eq(#t:receive(1.0), 0, "uncommitted message ignored")
end)

test("native backend drives a full purchase over the bridge", function()
    wipeFs()
    freshModule()
    local json = require("lib.iap.json")

    -- Stand-in for IAPBridge.java / IAPBridge.swift.
    local nativeSide = {}
    local outbox = {}
    local fakeTransport = {
        send = function(_, msg) outbox[#outbox + 1] = msg; return true end,
        receive = function()
            local out = nativeSide
            nativeSide = {}
            return out
        end,
        describe = function() return "fake" end,
        sweepStaleRequests = function() end,
    }
    local function reply(msg) nativeSide[#nativeSide + 1] = msg end

    local grants = {}
    IAP.init({
        products = PRODUCTS, backend = "native", platform = "android", logLevel = "off",
        json = json,
        bridge = { transport = fakeTransport },
        onGrant = function(p) grants[#grants + 1] = p end,
    })

    eq(outbox[1] and outbox[1].op, "init", "init request sent to native")
    eq(outbox[1].products[1].sku, "com.test.gems_small", "android sku used")

    reply({ id = outbox[1].id, op = "init", ok = true, unfinished = {},
            products = { { sku = "com.test.gems_small", price = "€1,09",
                           currency = "EUR", priceAmountMicros = 1090000,
                           title = "Handful of Gems" },
                         { sku = "com.test.gems_large", price = "€10,99" },
                         { sku = "com.test.remove_ads", price = "€2,99" } } })
    advance(0.5)

    check(IAP.isReady(), "ready after the native init reply")
    eq(IAP.getPrice("gems_small"), "€1,09", "localised price adopted")

    IAP.purchase("gems_small")
    advance(0.1)
    local purchaseReq = outbox[#outbox]
    eq(purchaseReq.op, "purchase", "purchase request sent")
    eq(purchaseReq.sku, "com.test.gems_small", "purchase used the store sku")

    reply({ op = "purchase", ok = true, purchase = {
        sku = "com.test.gems_small", orderId = "GPA.1234-5678",
        token = "play-token-xyz", payload = '{"orderId":"GPA.1234-5678"}',
        signature = "sig", platform = "android" } })
    advance(0.5)

    eq(#grants, 1, "granted once")
    eq(grants[1].txn, "GPA.1234-5678", "orderId used as the transaction id")
    eq(grants[1].token, "play-token-xyz", "purchase token passed through")

    local finishReq = outbox[#outbox]
    eq(finishReq.op, "finish", "finish request sent after the grant")
    eq(finishReq.token, "play-token-xyz", "finish carries the token")
    eq(IAP.getPendingCount(), 1, "still pending until native confirms the consume")

    reply({ id = finishReq.id, op = "finish", ok = true, txn = "GPA.1234-5678" })
    advance(0.5)
    eq(IAP.getPendingCount(), 0, "settled after the consume was confirmed")

    -- Re-delivery of the same transaction (Play does this until consumed).
    reply({ op = "purchase", ok = true, purchase = {
        sku = "com.test.gems_small", orderId = "GPA.1234-5678",
        token = "play-token-xyz", platform = "android" } })
    advance(0.5)
    eq(#grants, 1, "duplicate delivery did not grant again")
end)

test("native restore re-establishes entitlements", function()
    wipeFs()
    freshModule()
    local json = require("lib.iap.json")

    local inbox, outbox = {}, {}
    local fakeTransport = {
        send = function(_, msg) outbox[#outbox + 1] = msg; return true end,
        receive = function() local o = inbox; inbox = {}; return o end,
        describe = function() return "fake" end,
        sweepStaleRequests = function() end,
    }
    local function reply(msg) inbox[#inbox + 1] = msg end

    IAP.init({ products = PRODUCTS, backend = "native", platform = "ios",
               logLevel = "off", json = json, bridge = { transport = fakeTransport } })

    reply({ id = outbox[1].id, op = "init", ok = true, unfinished = {},
            products = { { sku = "remove_ads", price = "$2.99" } } })
    advance(0.5)
    eq(outbox[1].products[3].sku, "com.test.remove_ads", "ios falls back to the shared sku")

    local restoredIds
    IAP.restore(function(_, ids) restoredIds = ids end)
    advance(0.1)
    eq(outbox[#outbox].op, "restore", "restore request sent")

    reply({ id = outbox[#outbox].id, op = "restore", ok = true, purchases = {
        { sku = "com.test.remove_ads", transactionId = "ios-txn-1", token = "ios-token" } } })
    advance(0.5)

    check(IAP.isOwned("remove_ads"), "entitlement restored")
    eq(restoredIds and restoredIds[1], "remove_ads", "restore callback lists the product")
end)

test("native init failure eventually reports the store as unavailable", function()
    wipeFs()
    freshModule()
    local json = require("lib.iap.json")

    local inbox, outbox = {}, {}
    local fakeTransport = {
        send = function(_, msg) outbox[#outbox + 1] = msg; return true end,
        receive = function() local o = inbox; inbox = {}; return o end,
        sweepStaleRequests = function() end,
    }

    local unavailable = nil
    IAP.init({ products = PRODUCTS, backend = "native", platform = "android",
               logLevel = "off", json = json, retryBase = 0.05, retryCap = 0.2,
               bridge = { transport = fakeTransport } })
    IAP.on("unavailable", function(e) unavailable = e end)

    for _ = 1, 8 do
        local last = outbox[#outbox]
        inbox[#inbox + 1] = { id = last.id, op = "init", ok = false,
                              code = "billing_unavailable", message = "no Play Store" }
        advance(1.0)
    end

    check(unavailable ~= nil, "unavailable event fired after exhausting retries")
    eq(IAP.getState(), "unavailable", "state reflects it")
    check(not IAP.isReady(), "not ready")

    local err
    IAP.purchase("gems_small", function(_, e) err = e end)
    eq(err and err.code, "not_ready", "purchases refused while unavailable")
end)

-- ── summary ───────────────────────────────────────────────────────────────────

print(string.format("\n=== %d passed, %d failed ===\n", passed, failed))
os.exit(failed == 0 and 0 or 1)
