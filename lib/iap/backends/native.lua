-- lib/iap/backends/native.lua
-- Talks to the platform billing service through the file-drop transport and
-- the reference native bridges in lib/iap/native/.
--
-- Wire protocol (JSON objects, one per message)
--
--   Lua -> native
--     { id, op = "init",     products = { { sku, type }, ... } }
--     { id, op = "purchase", sku }
--     { id, op = "restore" }
--     { id, op = "finish",   sku, type, token, txn }
--
--   native -> Lua
--     { id, op = "init",     ok, products = { { sku, price, priceAmountMicros,
--                                               currency, title, description }, ... },
--                            unfinished = { <purchase>, ... }, code, message }
--     {     op = "purchase", ok = true,  purchase = <purchase> }
--     {     op = "purchase", ok = false, sku, code, message }
--     {     op = "purchase_deferred", sku }
--     { id, op = "restore",  ok, purchases = { <purchase>, ... } }
--     { id, op = "finish",   ok, txn, code, message }
--     {     op = "log",      level, message }
--
--   <purchase> = { sku, txn, token, payload, signature, platform, restored }
--
-- `payload` is the raw receipt/purchase JSON and `signature` its store
-- signature: both are forwarded verbatim to the game's own server, which is the
-- only place a purchase may actually be verified.

local PATH  = (...):gsub("[^%.]+%.[^%.]+$", "")
local util  = require(PATH .. "util")
local FileDrop = require(PATH .. "transport.filedrop")

local Native = {}
Native.__index = Native

-- A purchase dialog can legitimately sit open for a long time, so its deadline
-- is generous; everything else should answer quickly.
local TIMEOUTS = { init = 60, purchase = 900, restore = 60, finish = 60 }

function Native.new(opts)
    local cfg = opts.config or {}
    local self = setmetatable({
        catalog   = opts.catalog,
        emit      = opts.emit,
        platform  = opts.platform,
        transport = cfg.transport or FileDrop.new({
            dir  = cfg.dir  or "iap_bridge",
            poll = cfg.poll or 0.25,
            json = opts.json,
        }),
        outstanding = {},   -- id -> { op, deadline, sku }
        nextId      = 0,
        initTries   = 0,
    }, Native)

    -- Requests from a previous run are meaningless now: we will re-issue
    -- whatever we still need. Replies are left alone — they may be purchases.
    if self.transport.sweepStaleRequests then
        self.transport:sweepStaleRequests()
    end

    return self
end

function Native:describe()
    return self.transport.describe and self.transport:describe() or "native bridge"
end

function Native:_send(op, fields)
    self.nextId = self.nextId + 1
    local id = tostring(self.nextId)

    local msg = { id = id, op = op }
    for k, v in pairs(fields or {}) do msg[k] = v end

    local ok, err = self.transport:send(msg)
    if not ok then
        util.err("could not send '%s' to native bridge: %s", op, tostring(err))
        return nil, err
    end

    self.outstanding[id] = {
        op       = op,
        sku      = fields and fields.sku,
        deadline = util.now() + (TIMEOUTS[op] or 60),
    }
    return id
end

-- ── outgoing ──────────────────────────────────────────────────────────────────

function Native:init()
    self.initTries = self.initTries + 1
    self:_send("init", { products = self.catalog:skus() })
end

function Native:purchase(product)
    local id = self:_send("purchase", { sku = product.sku, type = product.type })
    if not id then
        self.emit("purchase_failed", {
            sku = product.sku, code = "bridge_unavailable",
            message = "Could not reach the store bridge",
        })
    end
end

function Native:restore()
    local id = self:_send("restore")
    if not id then
        self.emit("restore_done", { purchases = {}, error = "bridge_unavailable" })
    end
end

function Native:finish(record)
    local id = self:_send("finish", {
        sku   = record.sku,
        type  = record.type,
        token = record.token,
        txn   = record.txn,
    })
    if not id then
        -- Core will retry on its own backoff schedule.
        self.emit("finished", { txn = record.txn, ok = false, code = "bridge_unavailable" })
    end
end

function Native:shutdown()
    self.outstanding = {}
end

-- ── incoming ──────────────────────────────────────────────────────────────────

local function normalisePurchase(p, platform)
    if type(p) ~= "table" or not p.sku then return nil end
    return {
        sku       = p.sku,
        -- Store-unique transaction id. Falling back to the token keeps the
        -- idempotency guard working even if a store omits an order id.
        txn       = p.txn or p.orderId or p.transactionId or p.token,
        token     = p.token,
        payload   = p.payload,
        signature = p.signature,
        platform  = p.platform or platform,
        restored  = p.restored and true or false,
    }
end

function Native:_handle(msg)
    local op = msg.op
    local req = msg.id and self.outstanding[msg.id] or nil
    if msg.id then self.outstanding[msg.id] = nil end

    if op == "log" then
        util.log(msg.level or "info", "native: %s", tostring(msg.message))

    elseif op == "init" then
        if msg.ok then
            self.emit("products", msg.products or {})
            local unfinished = {}
            for _, p in ipairs(msg.unfinished or {}) do
                local np = normalisePurchase(p, self.platform)
                if np then unfinished[#unfinished + 1] = np end
            end
            self.emit("ready", { unfinished = unfinished })
        else
            self.emit("init_failed", {
                code    = msg.code or "init_failed",
                message = msg.message or "Store unavailable",
            })
        end

    elseif op == "purchase" then
        if msg.ok then
            local p = normalisePurchase(msg.purchase, self.platform)
            if p then
                self.emit("purchase", p)
            else
                util.err("native sent a purchase without a sku; ignoring")
            end
        else
            self.emit("purchase_failed", {
                sku     = msg.sku or (req and req.sku),
                code    = msg.code or "store_error",
                message = msg.message or "Purchase failed",
            })
        end

    elseif op == "purchase_deferred" then
        self.emit("purchase_deferred", { sku = msg.sku or (req and req.sku) })

    elseif op == "restore" then
        local list = {}
        for _, p in ipairs(msg.purchases or {}) do
            local np = normalisePurchase(p, self.platform)
            if np then
                np.restored = true
                list[#list + 1] = np
            end
        end
        self.emit("restore_done", { purchases = list, error = (not msg.ok) and (msg.code or "restore_failed") or nil })

    elseif op == "finish" then
        self.emit("finished", { txn = msg.txn, ok = msg.ok and true or false, code = msg.code })

    else
        util.warn("unknown op '%s' from native bridge", tostring(op))
    end
end

function Native:_expire()
    local now = util.now()
    for id, req in pairs(self.outstanding) do
        if now >= req.deadline then
            self.outstanding[id] = nil
            util.warn("native '%s' request timed out", req.op)

            if req.op == "purchase" then
                self.emit("purchase_failed", {
                    sku = req.sku, code = "timeout",
                    message = "The store did not respond",
                })
            elseif req.op == "init" then
                self.emit("init_failed", { code = "timeout", message = "The store did not respond" })
            elseif req.op == "restore" then
                self.emit("restore_done", { purchases = {}, error = "timeout" })
            elseif req.op == "finish" then
                self.emit("finished", { txn = nil, ok = false, code = "timeout" })
            end
        end
    end
end

function Native:update(dt)
    for _, msg in ipairs(self.transport:receive(dt)) do
        local ok, err = pcall(self._handle, self, msg)
        if not ok then
            util.err("error handling native message: %s", tostring(err))
        end
    end
    self:_expire()
end

return Native
