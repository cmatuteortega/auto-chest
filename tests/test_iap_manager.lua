-- Headless test for src/iap_manager.lua: store purchase → server grant → finish.
-- Uses lib/iap.lua's mock store (desktop) and a fake socket standing in for the server.
-- Run from project root: luajit tests/test_iap_manager.lua   (or lua)

package.path = package.path .. ";./?.lua;./?/init.lua"

local now = 0
local files = {}
love = {
    system = { getOS = function() return "Linux" end },
    timer  = { getTime = function() return now end },
    filesystem = {
        getInfo = function(name) return files[name] and { type = "file" } or nil end,
        lines   = function(name) return files[name]:gmatch("([^\n]*)\n") end,
        write   = function(name, data) files[name] = data return true end,
    },
}

-- Fake socket: records sends, lets the test fire server messages
local function newSocket()
    local sock = { sent = {}, handlers = {} }
    function sock:isConnected() return true end
    function sock:on(event, fn) self.handlers[event] = fn return fn end
    function sock:send(event, data) self.sent[#self.sent + 1] = { event = event, data = data } end
    function sock:fire(event, data) self.handlers[event](data) end
    return sock
end

-- SocketManager pulls in ENet; only isHealthy() is used here
package.loaded['src.socket_manager'] = {
    isHealthy = function() return _G.GameSocket ~= nil and _G.GameSocket:isConnected() end,
}

local IapManager = require('src.iap_manager')

local passed, failed = 0, 0
local function check(name, cond)
    if cond then passed = passed + 1 else failed = failed + 1 print("FAIL " .. name) end
end

local notices = {}
IapManager.onNotice = function(t) notices[#notices + 1] = t end

IapManager.init()
IapManager.update()
check("mock store has a price", IapManager.goldPackPrice() ~= nil)

-- Not connected: buying is refused with a notice
IapManager.buyGoldPack()
check("offline buy refused", notices[#notices] == "Connect to the server to buy gold")

-- Connected and logged in
local sock = newSocket()
_G.GameSocket = sock
_G.PlayerData = { gold = 50 }

IapManager.buyGoldPack()
IapManager.update()   -- mock store delivers the purchase
IapManager.update()   -- queued purchase is sent
check("purchase pending", IapManager.hasPending())
check("one iap_purchase sent", #sock.sent == 1 and sock.sent[1].event == "iap_purchase")
local msg = sock.sent[1].data
check("message fields", msg.product == "gold_1000" and msg.store == "mock" and msg.token:match("^mock%-"))

-- No reply yet: not resent before the wait
now = 10 IapManager.update()
check("no early resend", #sock.sent == 1)
now = 16 IapManager.update()
check("resent after 15s", #sock.sent == 2 and sock.sent[2].data.token == msg.token)

-- Server can't verify yet: backs off (30s) and keeps it
sock:fire("iap_rejected", { token = msg.token, reason = "verification_unavailable", retry = true })
check("retry keeps it pending", IapManager.hasPending())
now = 40 IapManager.update()
check("backoff doubles", #sock.sent == 2)
now = 47 IapManager.update()
check("sent again after backoff", #sock.sent == 3)

-- Granted: gold set, purchase finished, notice shown
sock:fire("iap_granted", { token = msg.token, product = "gold_1000", gold = 1050, fresh = true })
check("granted clears pending", not IapManager.hasPending())
check("gold updated", _G.PlayerData.gold == 1050)
check("thank-you notice", notices[#notices]:find("1000 gold"))
now = 100 IapManager.update()
check("nothing more sent", #sock.sent == 3)

-- A permanent rejection drops it with a message
IapManager.buyGoldPack()
IapManager.update() IapManager.update()
local tok2 = sock.sent[#sock.sent].data.token
check("second purchase has its own token", tok2 ~= msg.token)
sock:fire("iap_rejected", { token = tok2, reason = "test_purchases_disabled", retry = false })
check("rejected dropped", not IapManager.hasPending())
check("rejection notice", notices[#notices] == "Test purchases are off on this server")

-- A new socket (reconnect) gets its own handlers
IapManager.buyGoldPack()
IapManager.update()
local sock2 = newSocket()
_G.GameSocket = sock2
IapManager.update()
check("sent on the new socket", #sock2.sent == 1 and sock2.handlers.iap_granted ~= nil)
sock2:fire("iap_granted", { token = sock2.sent[1].data.token, product = "gold_1000", gold = 2050, fresh = true })
check("granted via new socket", not IapManager.hasPending() and _G.PlayerData.gold == 2050)

print(("%d passed, %d failed"):format(passed, failed))
os.exit(failed == 0 and 0 or 1)
