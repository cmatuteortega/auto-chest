-- IapManager: in-app purchases (lib/iap.lua, from cmatuteortega/love-iap)
-- with the grant done by the server.
--
-- Gold lives in the server's database, so a purchase can't be granted inside
-- iap's onPurchase. Instead:
--   1. onPurchase queues the purchase and returns false (left unfinished).
--   2. Once logged in, the token is sent as `iap_purchase`; the server checks
--      it with the store, records it and adds the gold.
--   3. `iap_granted` → iap.finish() consumes it on the store.
-- Until step 3 the store hands the purchase back at every launch, and the
-- server's token ledger answers a repeat with iap_granted (fresh = false), so
-- a crash or lost message anywhere loses nothing and never grants twice.
--
-- On desktop the store is mocked; the server only accepts mock purchases
-- when started with IAP_ALLOW_UNVERIFIED=1.

local iap           = require('lib.iap')
local SocketManager = require('src.socket_manager')

local IapManager = {}

IapManager.GOLD_PACK        = "gold_1000"
IapManager.GOLD_PACK_AMOUNT = 1000   -- shown on the button; the server decides the grant

-- Shown to the player, keyed by the reasons iap and the server report
local FAIL_TEXT = {
    network                 = "No connection to the store",
    unavailable             = "Store unavailable on this device",
    not_ready               = "Store is still loading, try again",
    unknown_product         = "This pack isn't available yet",
    invalid_token           = "Purchase couldn't be verified",
    purchase_cancelled      = "Purchase was cancelled",
    already_used            = "Purchase already used",
    test_purchases_disabled = "Test purchases are off on this server",
}

local pending = {}      -- token -> { id, order, sentAt, wait }
local boundSocket       -- socket our handlers are registered on

-- Screens set this to show short messages (menu shop notice)
IapManager.onNotice = nil

local function notice(text)
    if text and IapManager.onNotice then IapManager.onNotice(text) end
end

local function storeName()
    if iap.status() == "mock" then return "mock" end
    local os = love.system.getOS()
    if os == "Android" then return "google" end
    return "apple"
end

local function bind(sock)
    boundSocket = sock
    -- Anything sent on the old socket may be lost: send it again now
    for _, p in pairs(pending) do p.sentAt = nil end

    sock:on("iap_granted", function(data)
        if type(data) ~= "table" or not data.token then return end
        local p = pending[data.token]
        pending[data.token] = nil
        iap.finish(data.product or (p and p.id), data.token)
        if data.gold and _G.PlayerData then _G.PlayerData.gold = data.gold end
        if data.fresh then
            notice("+" .. IapManager.GOLD_PACK_AMOUNT .. " gold! Thanks for your support")
        end
    end)

    sock:on("iap_rejected", function(data)
        if type(data) ~= "table" or not data.token then return end
        local p = pending[data.token]
        if not p then return end
        if data.retry then
            -- Server can't check it right now: back off and send again
            p.sentAt = love.timer.getTime()
            p.wait   = math.min(p.wait * 2, 300)
        else
            -- Left unfinished on the store; Play refunds it after 3 days
            pending[data.token] = nil
            notice(FAIL_TEXT[data.reason] or "Purchase couldn't be completed")
        end
    end)
end

function IapManager.init()
    iap.init {
        products = {
            { id = IapManager.GOLD_PACK, consumable = true },
        },
        mock = love.system.getOS() ~= "Android" and love.system.getOS() ~= "iOS",
        onPurchase = function(id, purchase)
            if not pending[purchase.token] then
                pending[purchase.token] = { id = id, order = purchase.order, wait = 15 }
            end
            return false   -- finished in iap_granted, after the server has granted it
        end,
        onPending = function()
            notice("Payment pending: gold arrives once it clears")
        end,
        onFail = function(_, reason)
            -- "cancelled": the player closed the sheet, nothing to say
            if reason ~= "cancelled" then notice(FAIL_TEXT[reason] or "Purchase failed") end
        end,
    }
end

-- Call every frame (main.lua). Sends queued purchases once logged in.
function IapManager.update()
    iap.update()

    if not next(pending) or not _G.PlayerData or not SocketManager.isHealthy() then return end
    local sock = _G.GameSocket
    if sock ~= boundSocket then bind(sock) end

    local now = love.timer.getTime()
    for token, p in pairs(pending) do
        if not p.sentAt or now - p.sentAt >= p.wait then
            p.sentAt = now
            sock:send("iap_purchase", {
                product = p.id, token = token, order = p.order, store = storeName(),
            })
        end
    end
end

function IapManager.buyGoldPack()
    if not SocketManager.isHealthy() then
        notice("Connect to the server to buy gold")
        return
    end
    if not iap.available() then
        local state = iap.status()
        notice(state == "starting" and FAIL_TEXT.not_ready or FAIL_TEXT.unavailable)
        return
    end
    iap.buy(IapManager.GOLD_PACK)
end

-- Localised price from the store ("1,00 €"), or nil until the store answers
function IapManager.goldPackPrice()
    return iap.price(IapManager.GOLD_PACK)
end

-- True while a paid purchase is waiting on the server
function IapManager.hasPending()
    return next(pending) ~= nil
end

return IapManager
