-- lib/iap/ledger.lua
-- Durable record of everything money-related, written to the LÖVE save
-- directory. This is the file that makes purchases survive a crash, a kill, or
-- a flaky network: nothing is ever granted twice and nothing in flight is lost.
--
--   processed : transaction ids already granted        (idempotency guard)
--   owned     : non-consumable / subscription entitlements
--   pending   : purchases received from the store but not yet fully settled
--
-- Every mutation writes the file synchronously. Purchases are rare and the file
-- is tiny, so the cost is irrelevant next to the cost of losing one.

local PATH = (...):gsub("[^%.]+$", "")
local util = require(PATH .. "util")

local Ledger = {}
Ledger.__index = Ledger

local FORMAT_VERSION = 1
local MAX_PROCESSED  = 500   -- ring-buffer cap; consumables are consumed at the
                             -- store so they are never re-delivered years later

local function defaultFs()
    return {
        read = function(name)
            if not (love and love.filesystem) then return nil end
            return love.filesystem.read(name)
        end,
        write = function(name, data)
            if not (love and love.filesystem) then return false end
            return love.filesystem.write(name, data)
        end,
    }
end

-- file: name inside the save directory. json: encoder/decoder. fs: injectable
-- for tests.
function Ledger.new(file, json, fs)
    local self = setmetatable({
        file = file or "iap_ledger.json",
        json = json,
        fs   = fs or defaultFs(),
        data = {
            version        = FORMAT_VERSION,
            processed      = {},   -- txn -> wallclock
            processedOrder = {},   -- txn, oldest first (for trimming)
            owned          = {},   -- productId -> { txn, time }
            pending        = {},   -- txn -> record
        },
    }, Ledger)

    self:load()
    return self
end

function Ledger:load()
    local raw = self.fs.read(self.file)
    if not raw or raw == "" then return end

    local ok, decoded = pcall(self.json.decode, raw)
    if not ok or type(decoded) ~= "table" then
        -- A corrupt ledger must not wipe entitlements silently. Keep the bad
        -- file around for support and start clean.
        util.err("ledger is corrupt (%s); starting fresh", tostring(decoded))
        self.fs.write(self.file .. ".corrupt", raw)
        return
    end

    if decoded.version ~= FORMAT_VERSION then
        util.warn("ledger version %s != %d; migrating what we can",
            tostring(decoded.version), FORMAT_VERSION)
    end

    self.data.processed      = type(decoded.processed)      == "table" and decoded.processed      or {}
    self.data.processedOrder = type(decoded.processedOrder) == "table" and decoded.processedOrder or {}
    self.data.owned          = type(decoded.owned)          == "table" and decoded.owned          or {}
    self.data.pending        = type(decoded.pending)        == "table" and decoded.pending        or {}
    self.data.version        = FORMAT_VERSION

    -- `busy` and the two deadlines mark an operation that is in flight *in this
    -- process*. Nothing survives a restart, so anything still flagged was cut
    -- short — clear it, or the record would sit out its old deadline (or wait
    -- forever) before being retried.
    for _, rec in pairs(self.data.pending) do
        if rec.busy then
            util.info("resuming '%s' interrupted mid-%s", tostring(rec.productId),
                rec.finishDeadline and "finish" or "verify")
        end
        rec.busy           = false
        rec.finishDeadline = nil
        rec.verifyDeadline = nil
        rec.nextAttempt    = 0   -- retry immediately on the next update
    end

    util.debug("ledger loaded: %d processed, %d owned, %d pending",
        util.count(self.data.processed), util.count(self.data.owned), util.count(self.data.pending))
end

function Ledger:save()
    local ok, encoded = pcall(self.json.encode, self.data)
    if not ok then
        util.err("could not encode ledger: %s", tostring(encoded))
        return false
    end
    local written, err = self.fs.write(self.file, encoded)
    if not written then
        util.err("could not write ledger: %s", tostring(err))
        return false
    end
    return true
end

-- ── idempotency ───────────────────────────────────────────────────────────────

function Ledger:isProcessed(txn)
    return txn ~= nil and self.data.processed[txn] ~= nil
end

function Ledger:markProcessed(txn)
    if not txn or self.data.processed[txn] then return end
    self.data.processed[txn] = util.wallclock()
    local order = self.data.processedOrder
    order[#order + 1] = txn

    while #order > MAX_PROCESSED do
        local oldest = table.remove(order, 1)
        self.data.processed[oldest] = nil
    end
    self:save()
end

-- ── entitlements ──────────────────────────────────────────────────────────────

function Ledger:isOwned(productId)
    return self.data.owned[productId] ~= nil
end

function Ledger:setOwned(productId, txn)
    self.data.owned[productId] = { txn = txn, time = util.wallclock() }
    self:save()
end

function Ledger:clearOwned(productId)
    if self.data.owned[productId] == nil then return end
    self.data.owned[productId] = nil
    self:save()
end

function Ledger:ownedIds()
    local out = {}
    for id in pairs(self.data.owned) do out[#out + 1] = id end
    table.sort(out)
    return out
end

-- ── pending purchases ─────────────────────────────────────────────────────────

function Ledger:addPending(record)
    self.data.pending[record.txn] = record
    self:save()
end

function Ledger:getPending(txn)
    return self.data.pending[txn]
end

function Ledger:updatePending(txn, fields)
    local rec = self.data.pending[txn]
    if not rec then return nil end
    for k, v in pairs(fields) do rec[k] = v end
    self:save()
    return rec
end

function Ledger:removePending(txn)
    if self.data.pending[txn] == nil then return end
    self.data.pending[txn] = nil
    self:save()
end

-- Pending records in a stable order, so retries do not starve one another.
function Ledger:pendingList()
    local out = {}
    for _, rec in pairs(self.data.pending) do out[#out + 1] = rec end
    table.sort(out, function(a, b)
        if a.created == b.created then return tostring(a.txn) < tostring(b.txn) end
        return (a.created or 0) < (b.created or 0)
    end)
    return out
end

function Ledger:pendingCount()
    return util.count(self.data.pending)
end

-- Test/support hook. Wipes everything, including entitlements.
function Ledger:reset()
    self.data.processed, self.data.processedOrder = {}, {}
    self.data.owned, self.data.pending = {}, {}
    self:save()
end

return Ledger
