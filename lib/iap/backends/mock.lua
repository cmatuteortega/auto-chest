-- lib/iap/backends/mock.lua
-- Fake store for desktop development, automated tests and any platform without
-- a real billing service. It exercises exactly the same code path as a device:
-- asynchronous replies, transaction ids, finish/consume round-trips.
--
-- Outcomes can be scripted so a build can be driven through the unhappy paths:
--   IAP.setMockOutcome("cancelled")   -- next purchase only
--   IAP.setMockOutcome("error", true) -- sticky, every purchase

local PATH = (...):gsub("[^%.]+%.[^%.]+$", "")
local util = require(PATH .. "util")

local Mock = {}
Mock.__index = Mock

function Mock.new(opts)
    local cfg = opts.config or {}
    return setmetatable({
        catalog      = opts.catalog,
        emit         = opts.emit,
        latency      = cfg.latency or 0.4,
        defaultOutcome = cfg.outcome or "success",
        nextOutcome  = nil,           -- one-shot override
        pendingJobs  = {},            -- { at = time, fn = function }
        ready        = false,
    }, Mock)
end

function Mock:_later(delay, fn)
    self.pendingJobs[#self.pendingJobs + 1] = { at = util.now() + delay, fn = fn }
end

function Mock:update(dt) -- luacheck: ignore dt
    if #self.pendingJobs == 0 then return end
    local now, due, keep = util.now(), {}, {}
    for _, job in ipairs(self.pendingJobs) do
        if now >= job.at then due[#due + 1] = job else keep[#keep + 1] = job end
    end
    self.pendingJobs = keep
    for _, job in ipairs(due) do job.fn() end
end

function Mock:init()
    self:_later(self.latency, function()
        local entries = {}
        for i, p in ipairs(self.catalog.list) do
            entries[i] = {
                sku               = p.sku,
                price             = p.price ~= "" and p.price or "$0.99",
                priceAmountMicros = 990000,
                currency          = "USD",
                title             = p.title,
                description       = p.description,
            }
        end
        self.ready = true
        self.emit("products", entries)
        -- A real store also reports purchases that were never finished. The
        -- mock has none, so it reports an empty set and the core moves on.
        self.emit("ready", { unfinished = {} })
    end)
end

-- Script the outcome of upcoming purchases.
-- outcome: "success" | "cancelled" | "error" | "pending"
function Mock:setOutcome(outcome, sticky)
    if sticky then
        self.defaultOutcome = outcome
        self.nextOutcome    = nil
    else
        self.nextOutcome = outcome
    end
end

function Mock:purchase(product)
    local outcome = self.nextOutcome or self.defaultOutcome
    self.nextOutcome = nil

    self:_later(self.latency, function()
        if outcome == "cancelled" then
            self.emit("purchase_failed", {
                sku = product.sku, code = "user_cancelled",
                message = "Purchase cancelled (mock)",
            })
        elseif outcome == "error" then
            self.emit("purchase_failed", {
                sku = product.sku, code = "store_error",
                message = "Simulated store failure (mock)",
            })
        elseif outcome == "pending" then
            -- Mirrors Google Play's PENDING state (cash / parental approval):
            -- nothing is granted, and the purchase lands later.
            self.emit("purchase_deferred", { sku = product.sku })
        else
            local txn = "mock-" .. util.uid(16)
            self.emit("purchase", {
                sku       = product.sku,
                txn       = txn,
                token     = "mocktoken-" .. txn,
                payload   = '{"mock":true,"productId":"' .. product.sku .. '"}',
                signature = "mock-signature",
                platform  = "mock",
            })
        end
    end)
end

function Mock:restore()
    -- The mock store has no server-side history; the core's ledger already
    -- holds local entitlements, so this just closes the loop.
    self:_later(self.latency, function()
        self.emit("restore_done", { purchases = {} })
    end)
end

function Mock:finish(record)
    self:_later(0.05, function()
        self.emit("finished", { txn = record.txn, ok = true })
    end)
end

function Mock:shutdown()
    self.pendingJobs = {}
end

return Mock
