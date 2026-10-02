-- Headless test for the server side of in-app purchases: the purchase ledger,
-- refunds into negative gold, and the verifier worker's Voided Purchases call
-- (Google is faked by stubbing io.popen).
-- Needs lsqlite3complete (luarocks install lsqlite3complete).
-- Run from project root: luajit tests/test_iap_server.lua

package.path = "./?.lua;" .. package.path
love = { system = { getOS = function() return "Linux" end } }
package.preload.bcrypt = function()
    return { digest = function(p) return "h" .. p end, verify = function() return true end }
end

local passed, failed = 0, 0
local function check(name, cond)
    if cond then passed = passed + 1 else failed = failed + 1 print("FAIL " .. name) end
end

-- ── Database: ledger, refunds, negative gold ────────────────────────────────
local Database = require("server.database")
local dbPath = os.tmpname()
local db = Database.new(dbPath)
local p = db:registerPlayer("alice", "pw")
local id = type(p) == "table" and p.id or p

check("first grant", db:grantIapPurchase("tokA", id, "gold_1000", "google", "GPA.1", 1000) == 1000)
check("replay grants nothing", db:grantIapPurchase("tokA", id, "gold_1000", "google", "GPA.1", 1000) == nil)
check("spend 800", db:updateGold(id, -800) == 200)

local pid, gold = db:refundIapPurchase("tokA", 1000)
check("refund goes negative", pid == id and gold == -800)
check("row marked refunded", db:getIapPurchase("tokA").refunded)
check("second refund is a no-op", db:refundIapPurchase("tokA", 1000) == nil)
check("unknown token refund is a no-op", db:refundIapPurchase("nope", 1000) == nil)
check("reading gold keeps the debt", db:updateGold(id, 0) == -800)
check("spending doesn't deepen debt", db:updateGold(id, -100) == -800)
check("earnings pay it off", db:updateGold(id, 10) == -790)
check("can climb back above 0", db:updateGold(id, 1000) == 210)
check("spending stops at 0 again", db:updateGold(id, -500) == 0)

os.remove(dbPath)

-- ── Worker: purchases.voidedpurchases.list parsing and paging ───────────────
local src = io.open("server/iap_verify.lua"):read("*a")
local worker = src:match("local WORKER = %[%[\n(.-)\n%]%]")

local commands = {}
local pages = {
    '{"tokenPagination":{"nextPageToken":"PAGE2"},"voidedPurchases":[' ..
        '{"purchaseToken":"tok.one-1","orderId":"GPA.1"},{"purchaseToken":"tok_two","orderId":"GPA.2"}]}\n200',
    '{"voidedPurchases":[{"purchaseToken":"tok3","orderId":"GPA.3"}]}\n200',
}
local realPopen = io.popen
io.popen = function(cmd)
    commands[#commands + 1] = cmd
    local out
    if cmd:find("openssl dgst") then out = "c2lnbmF0dXJl\n"
    elseif cmd:find("oauth2.googleapis.com/token") then out = '{"access_token":"ya29.test","expires_in":3599}'
    elseif cmd:find("voidedpurchases") then out = table.remove(pages, 1) or "{}\n500"
    else out = "" end
    return { read = function() return out end, close = function() end }
end

local pushed = {}
local jobs = { { kind = "voided", id = 0 } }
local requests = { demand = function() return table.remove(jobs, 1) or error("done") end }
local results  = { push = function(_, r) pushed[#pushed + 1] = r end }
package.preload["love.thread"] = function() return {} end
local pem = os.tmpname()
pcall(load(worker), requests, results, "sa@x.iam.gserviceaccount.com", pem, "com.cmatute.tinyturf")
io.popen = realPopen
os.remove(pem)

local r = pushed[1]
check("voided job answered", r and r.kind == "voided" and r.ok)
check("tokens from both pages", r and r.tokens == "tok.one-1\ntok_two\ntok3")
local voidedCalls = 0
for _, c in ipairs(commands) do
    if c:find("voidedpurchases") then
        voidedCalls = voidedCalls + 1
        check("bearer token sent", c:find("Bearer ya29.test", 1, true) ~= nil)
    end
end
check("followed the page token", voidedCalls == 2 and commands[#commands]:find("&token=PAGE2", 1, true) ~= nil)

print(("%d passed, %d failed"):format(passed, failed))
os.exit(failed == 0 and 0 or 1)
