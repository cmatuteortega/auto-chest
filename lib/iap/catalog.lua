-- lib/iap/catalog.lua
-- Normalises the product list the game declares into a platform-resolved
-- catalog: game-side product id <-> store SKU, plus store-supplied pricing
-- once the backend reports back.

local PATH = (...):gsub("[^%.]+$", "")
local util = require(PATH .. "util")

local Catalog = {}
Catalog.__index = Catalog

local VALID_TYPES = {
    consumable     = true,   -- gems, coins: can be bought repeatedly
    non_consumable = true,   -- remove ads, unlock pack: owned forever
    subscription   = true,   -- recurring
}

-- Resolve the store-side identifier for a product on a given platform.
-- Accepts, in priority order:
--   def.stores[platform]  ->  { android = "...", ios = "..." }
--   def[platform]         ->  android = "..."
--   def.sku               ->  same id on every store
--   def.id                ->  fall back to the game-side id
local function resolveSku(def, platform)
    if type(def.stores) == "table" and def.stores[platform] then
        return def.stores[platform]
    end
    if def[platform] then return def[platform] end
    return def.sku or def.id
end

-- defs: array of product definitions. platform: "android" | "ios" | "mock".
function Catalog.new(defs, platform)
    assert(type(defs) == "table", "iap: config.products must be a table")

    local self = setmetatable({
        platform = platform,
        list     = {},   -- ordered, as declared
        byId     = {},   -- game id  -> product
        bySku    = {},   -- store sku -> product
    }, Catalog)

    for i, def in ipairs(defs) do
        assert(type(def) == "table", "iap: product #" .. i .. " must be a table")
        assert(type(def.id) == "string" and def.id ~= "",
            "iap: product #" .. i .. " needs a string id")

        local ptype = def.type or "consumable"
        assert(VALID_TYPES[ptype],
            "iap: product '" .. def.id .. "' has unknown type '" .. tostring(ptype) .. "'")
        assert(not self.byId[def.id], "iap: duplicate product id '" .. def.id .. "'")

        local sku = resolveSku(def, platform)
        assert(type(sku) == "string" and sku ~= "",
            "iap: product '" .. def.id .. "' has no store sku for platform " .. tostring(platform))

        local product = {
            id          = def.id,
            sku         = sku,
            type        = ptype,
            grants      = util.copy(def.grants) or {},

            -- Fallbacks shown until the store answers with localised strings.
            title       = def.title       or def.id,
            description = def.description or "",
            price       = def.price       or "",

            -- Filled in from the store response.
            priceAmountMicros = nil,
            currency          = nil,
            available         = false,   -- true once the store confirmed it exists
        }

        self.list[#self.list + 1] = product
        self.byId[product.id]     = product
        -- Two game products may legitimately map to the same sku only by mistake;
        -- keep the first so lookups stay stable and warn loudly.
        if self.bySku[sku] then
            util.warn("sku '%s' is mapped by both '%s' and '%s'; incoming store events "
                .. "will resolve to '%s'", sku, self.bySku[sku].id, product.id, self.bySku[sku].id)
        else
            self.bySku[sku] = product
        end
    end

    return self
end

function Catalog:get(id)       return self.byId[id]  end
function Catalog:fromSku(sku)  return self.bySku[sku] end

-- Store sku list, in declared order — what the backend needs to query.
function Catalog:skus()
    local out = {}
    for i, p in ipairs(self.list) do out[i] = { sku = p.sku, type = p.type } end
    return out
end

-- Merge a store product-details response. Entries are matched by sku;
-- unknown skus are ignored (they are not ours).
-- info: { sku, price, priceAmountMicros, currency, title, description }
function Catalog:applyStoreDetails(entries)
    local matched = 0
    for _, info in ipairs(entries or {}) do
        local p = info.sku and self.bySku[info.sku]
        if p then
            matched = matched + 1
            p.available = true
            if info.price       and info.price       ~= "" then p.price       = info.price       end
            if info.title       and info.title       ~= "" then p.title       = info.title       end
            if info.description and info.description ~= "" then p.description = info.description end
            p.priceAmountMicros = tonumber(info.priceAmountMicros) or p.priceAmountMicros
            p.currency          = info.currency or p.currency
        else
            util.debug("store returned unknown sku '%s' (ignored)", tostring(info.sku))
        end
    end
    return matched
end

return Catalog
