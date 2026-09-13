-- tests/test_iap_manager.lua
-- End-to-end test of AutoChest's IAP wiring: shop tap -> store -> server
-- verification -> coins credited -> purchase consumed.
--
-- The point of this test is the seam between client and server. The field names
-- in `verify_purchase` and `purchase_verified` have to agree with
-- server/main.lua, and nothing else checks that.
--
-- Run with:  lua tests/test_iap_manager.lua   (from the project root)

package.path = package.path .. ";./?.lua;./?/init.lua"

-- ── LÖVE stubs ────────────────────────────────────────────────────────────────

local clock = 5000.0
local files = {}

---@diagnostic disable-next-line: lowercase-global
love = {
    timer  = { getTime = function() return clock end },
    math   = { random = function(n) return math.random(n) end },
    system = { getOS = function() return "Linux" end },
    filesystem = {
        read  = function(n) return files[n] end,
        write = function(n, d) files[n] = d; return true end,
        remove = function(n) files[n] = nil; return true end,
        createDirectory = function() return true end,
        getDirectoryItems = function() return {} end,
        getInfo = function(n) return files[n] and { type = "file" } or nil end,
        getSaveDirectory = function() return "/virtual/save" end,
    },
}
math.randomseed(4242)

-- ── harness ───────────────────────────────────────────────────────────────────

local passed, failed = 0, 0
local function eq(got, want, label)
    if got == want then passed = passed + 1
    else failed = failed + 1
         print(string.format("  FAIL: %s (got %s, want %s)", label, tostring(got), tostring(want))) end
end
local function check(cond, label)
    if cond then passed = passed + 1 else failed = failed + 1; print("  FAIL: " .. label) end
end

local IAPManager

local function reload()
    for name in pairs(package.loaded) do
        if name:match("^lib%.iap") or name == "src.iap_manager" then
            package.loaded[name] = nil
        end
    end
    files = {}
    IAPManager = require("src.iap_manager")
end

local function advance(seconds)
    local step, elapsed = 1 / 60, 0
    while elapsed < seconds do
        clock = clock + step
        IAPManager.update(step)
        elapsed = elapsed + step
    end
end

--- Stand-in for the ENet client socket, recording what the game sends.
local function fakeSocket(opts)
    opts = opts or {}
    local sock = { sent = {}, handlers = {}, connected = opts.connected ~= false }
    function sock:on(event, fn) self.handlers[event] = fn; return fn end
    function sock:send(event, data) self.sent[#self.sent + 1] = { event = event, data = data } end
    function sock:isConnected() return self.connected end
    function sock:deliver(event, data)
        local fn = self.handlers[event]
        if fn then fn(data) end
    end
    function sock:lastSent(event)
        for i = #self.sent, 1, -1 do
            if self.sent[i].event == event then return self.sent[i].data end
        end
    end
    return sock
end

print("\n=== AutoChest IAP wiring tests ===\n")

-- ══════════════════════════════════════════════════════════════════════════════

print("• the shop sees one repeatable coin pack")
do
    reload()
    IAPManager.init()
    advance(1.0)

    eq(IAPManager.PRODUCT_ID, "coins_1000", "product id")
    eq(IAPManager.COIN_AMOUNT, 1000, "coin amount")
    check(IAPManager.isReady(), "store ready on desktop (mock backend)")

    local p = IAPManager.getProduct()
    eq(p.type, "consumable", "consumable, so it can be bought again")
    eq(p.grants.coins, 1000, "grants 1000 coins")
    check(IAPManager.getPrice() ~= "", "a price string is available for the button")
end

print("• a purchase is verified by the server before coins are credited")
do
    reload()
    local sock = fakeSocket()
    _G.GameSocket = sock
    IAPManager.init()
    advance(1.0)

    IAPManager.purchase()
    advance(1.5)

    local req = sock:lastSent("verify_purchase")
    check(req ~= nil, "verify_purchase sent to the server")
    eq(req.product_id, "coins_1000", "product_id field (server reads msgData.product_id)")
    eq(req.sku, "coins_1000", "sku field")
    check(req.txn ~= nil and req.txn ~= "", "txn field (server's idempotency key)")
    check(req.payload ~= nil, "payload field (the receipt the server verifies)")
    eq(req.platform, "mock", "platform field")

    -- Nothing granted while the server has not answered.
    eq(IAPManager.takeNotice(), nil, "no coins announced before verification")
    check(IAPManager.isBusy(), "shop button shows as busy while settling")

    -- Server verifies and credits.
    sock:deliver("purchase_verified", { txn = req.txn, ok = true, gold = 1000 })
    advance(1.0)

    eq(IAPManager.takeNotice(), "+1000 coins!", "purchase acknowledged after the server said yes")
    check(not IAPManager.isBusy(), "settled")
end

print("• the client never credits coins itself")
do
    reload()
    local sock = fakeSocket()
    _G.GameSocket = sock
    _G.PlayerData = { gold = 250 }
    IAPManager.init()
    advance(1.0)

    IAPManager.purchase()
    advance(1.5)
    local req = sock:lastSent("verify_purchase")
    sock:deliver("purchase_verified", { txn = req.txn, ok = true, gold = 1250 })
    advance(1.0)

    -- Gold only ever moves via the server's currency_update, handled in menu.lua.
    eq(_G.PlayerData.gold, 250, "PlayerData.gold untouched by the IAP path")
    _G.PlayerData = nil
end

print("• a rejected receipt never pays out, and stops retrying")
do
    reload()
    local sock = fakeSocket()
    _G.GameSocket = sock
    IAPManager.init()
    advance(1.0)

    IAPManager.purchase()
    advance(1.5)
    local req = sock:lastSent("verify_purchase")

    sock:deliver("purchase_verified", {
        txn = req.txn, ok = false, permanent = true,
        code = "bad_signature", reason = "This purchase could not be verified",
    })
    advance(2.0)

    eq(IAPManager.takeNotice(), "This purchase could not be verified", "player told why")
    check(not IAPManager.isBusy(), "no longer retrying a permanently bad receipt")
end

print("• a server hiccup retries instead of losing the purchase")
do
    reload()
    local sock = fakeSocket()
    _G.GameSocket = sock
    IAPManager.init()
    advance(1.0)

    IAPManager.purchase()
    advance(1.5)
    local first = sock:lastSent("verify_purchase")

    -- Transient failure: no `permanent` flag.
    sock:deliver("purchase_verified", { txn = first.txn, ok = false, code = "db_busy" })
    advance(8.0)

    local attempts = 0
    for _, m in ipairs(sock.sent) do
        if m.event == "verify_purchase" then attempts = attempts + 1 end
    end
    check(attempts >= 2, "server was asked again (" .. attempts .. " attempts)")
    eq(sock:lastSent("verify_purchase").txn, first.txn, "same transaction id every time")

    sock:deliver("purchase_verified", { txn = first.txn, ok = true })
    advance(1.0)
    eq(IAPManager.takeNotice(), "+1000 coins!", "paid out once the server recovered")
end

print("• buying while logged out keeps the purchase until the socket returns")
do
    reload()
    local sock = fakeSocket({ connected = false })
    _G.GameSocket = sock
    IAPManager.init()
    advance(1.0)

    -- Refused up front: no point opening a store dialog we cannot verify.
    eq(IAPManager.purchase(), false, "purchase refused while disconnected")
    eq(IAPManager.takeNotice(), "Connect to the server first", "player told why")

    -- But a purchase that already happened survives the outage.
    sock.connected = true
    IAPManager.purchase()
    advance(1.0)
    sock.connected = false
    advance(3.0)
    check(IAPManager.isBusy(), "purchase still pending, not lost, while offline")

    sock.connected = true
    advance(6.0)
    local req = sock:lastSent("verify_purchase")
    sock:deliver("purchase_verified", { txn = req.txn, ok = true })
    advance(1.0)
    eq(IAPManager.takeNotice(), "+1000 coins!", "settled once the connection came back")
end

print("• an interrupted purchase is recovered on the next launch")
do
    reload()
    local sock = fakeSocket()
    _G.GameSocket = sock
    IAPManager.init()
    advance(1.0)
    IAPManager.purchase()
    advance(1.5)

    local req = sock:lastSent("verify_purchase")
    check(req ~= nil, "purchase reached the verification stage")
    local ledgerBefore = files["iap_ledger.json"]
    check(ledgerBefore ~= nil and ledgerBefore:find(req.txn, 1, true) ~= nil,
        "purchase was written to disk before being granted")

    -- Simulate a kill: drop the module but keep the save directory.
    local saved = files["iap_ledger.json"]
    for name in pairs(package.loaded) do
        if name:match("^lib%.iap") or name == "src.iap_manager" then package.loaded[name] = nil end
    end
    files = { ["iap_ledger.json"] = saved }
    IAPManager = require("src.iap_manager")

    local sock2 = fakeSocket()
    _G.GameSocket = sock2
    IAPManager.init()
    advance(2.0)

    local retried = sock2:lastSent("verify_purchase")
    check(retried ~= nil, "the purchase was retried after the restart")
    eq(retried.txn, req.txn, "same transaction id, so the server pays out once")

    sock2:deliver("purchase_verified", { txn = retried.txn, ok = true })
    advance(1.0)
    eq(IAPManager.takeNotice(), "+1000 coins!", "player finally got their coins")
end

print("• restore settles anything left unfinished")
do
    reload()
    local sock = fakeSocket()
    _G.GameSocket = sock
    IAPManager.init()
    advance(1.0)

    local done = nil
    IAPManager.restore(function(ok) done = ok end)
    advance(1.5)

    eq(done, true, "restore completed")
    check(IAPManager.takeNotice() ~= nil, "restore reports back to the player")
end

_G.GameSocket = nil
print(string.format("\n=== %d passed, %d failed ===\n", passed, failed))
os.exit(failed == 0 and 0 or 1)
