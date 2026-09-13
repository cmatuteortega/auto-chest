-- IAPManager: AutoChest's wiring for lib/iap.
--
-- One product today: 1000 coins for ~€1, repeatable (a consumable).
--
-- Gold is server-authoritative, so the flow is deliberately *not* "add coins on
-- the device". Instead:
--
--   1. Store takes the money and hands lib/iap a receipt.
--   2. validate() forwards the receipt to our server (`verify_purchase`).
--   3. The server verifies it, credits the gold, and pushes `currency_update`
--      — the same message the rest of the economy already uses.
--   4. The server answers `purchase_verified`, lib/iap grants, and only then
--      tells Play/StoreKit to consume the purchase.
--
-- So a device that never hears back keeps retrying, and a player who is killed
-- mid-purchase gets their coins on the next launch. onGrant() only shows the
-- toast; it never touches the balance.

local IAP = require('lib.iap')

local M = {
    PRODUCT_ID  = "coins_1000",
    COIN_AMOUNT = 1000,

    _notice        = nil,   -- one-line message for the shop panel to surface
    _inited        = false,
    _pendingVerify = {},    -- txn -> done() callback awaiting the server
    _socket        = nil,   -- socket we attached our handler to
}

-- ── server round-trip ─────────────────────────────────────────────────────────

--- Attach the `purchase_verified` listener to the live socket.
--  The socket is recreated on reconnect, so re-attach whenever it changes.
--  This listener deliberately outlives the menu screen: a purchase must be able
--  to settle while the player is in a match.
local function attachSocket()
    local sock = _G.GameSocket
    if not sock then return nil end
    if sock == M._socket then return sock end

    M._socket = sock
    sock:on("purchase_verified", function(data)
        local txn  = data and data.txn
        local done = txn and M._pendingVerify[txn]
        if not done then
            -- Already timed out and retried, or not ours. lib/iap ignores stale
            -- callbacks anyway; dropping it here keeps the table clean.
            return
        end
        M._pendingVerify[txn] = nil

        if data.ok then
            done(true)
        elseif data.permanent then
            -- Receipt is bad and will never become good: do not retry.
            done(false, {
                permanent = true,
                code      = data.code or "invalid_receipt",
                message   = data.reason or "This purchase could not be verified",
            })
        else
            done(false)   -- transient (server busy, DB hiccup): lib/iap backs off
        end
    end)

    return sock
end

local function validate(purchase, done)
    local sock = attachSocket()
    if not sock or not sock:isConnected() then
        -- Not logged in / offline. Transient: lib/iap retries with backoff and
        -- the purchase stays safely on disk in the meantime.
        done(false)
        return
    end

    M._pendingVerify[purchase.txn] = done
    sock:send("verify_purchase", {
        platform   = purchase.platform,
        product_id = purchase.productId,
        sku        = purchase.sku,
        txn        = purchase.txn,
        payload    = purchase.payload,
        signature  = purchase.signature,
    })
end

-- ── notices ───────────────────────────────────────────────────────────────────

function M.pushNotice(text)
    M._notice = text
end

--- Pop the pending one-liner, if any. The shop panel polls this so a purchase
--  that lands while the player is elsewhere still gets acknowledged.
function M.takeNotice()
    local n = M._notice
    M._notice = nil
    return n
end

-- ── lifecycle ─────────────────────────────────────────────────────────────────

function M.init()
    if M._inited then return end
    M._inited = true

    IAP.init({
        logLevel = "info",
        products = {
            {
                id     = M.PRODUCT_ID,
                type   = "consumable",          -- repeatable
                grants = { coins = M.COIN_AMOUNT },
                title  = "1000 Coins",
                price  = "€1.00",               -- fallback until the store answers
                stores = { android = "coins_1000", ios = "coins_1000" },
            },
        },

        validate = validate,

        onGrant = function(purchase)
            -- The server already credited the gold and pushed currency_update.
            -- Nothing to add here but the acknowledgement.
            local amount = purchase.grants.coins or M.COIN_AMOUNT
            M.pushNotice("+" .. amount .. " coins!")
            print("[IAP] granted " .. purchase.productId .. " (" .. tostring(purchase.txn) .. ")")
        end,
    })

    IAP.on("failed", function(err)
        if err.code ~= "user_cancelled" then
            M.pushNotice(err.message or "Purchase failed")
        end
    end)

    IAP.on("deferred", function()
        M.pushNotice("Purchase pending approval")
    end)

    IAP.on("unavailable", function()
        print("[IAP] store unavailable")
    end)
end

function M.update(dt)
    if M._inited then IAP.update(dt) end
end

-- ── shop panel API ────────────────────────────────────────────────────────────

function M.isReady()  return IAP.isReady() end

--- True while a purchase is being paid for or settled — the shop button should
--  show a spinner rather than accept another tap.
function M.isBusy()   return IAP.isBusy() or IAP.getPendingCount() > 0 end

function M.getProduct() return IAP.getProduct(M.PRODUCT_ID) end

--- Store-localised price once connected, the declared fallback before that.
function M.getPrice()
    local p = IAP.getProduct(M.PRODUCT_ID)
    return (p and p.price ~= "" and p.price) or "€1.00"
end

function M.purchase(cb)
    if not M._inited then return false end
    if not _G.GameSocket or not _G.GameSocket:isConnected() then
        M.pushNotice("Connect to the server first")
        return false
    end
    return IAP.purchase(M.PRODUCT_ID, cb)
end

--- Ask the store what this account owns. For a consumable there is nothing to
--  re-own, but this also settles any purchase left unfinished by a crash — and
--  App Review requires the button to exist.
function M.restore(cb)
    if not M._inited then return false end
    M.pushNotice("Restoring...")
    return IAP.restore(function(ok, ids)
        if IAP.getPendingCount() > 0 then
            M.pushNotice("Restoring your purchase...")
        elseif ok then
            M.pushNotice("Nothing left to restore")
        else
            M.pushNotice("Could not reach the store")
        end
        if cb then cb(ok, ids) end
    end)
end

-- Debug-build helper: script the desktop mock store.
function M.setMockOutcome(outcome, sticky) IAP.setMockOutcome(outcome, sticky) end

return M
