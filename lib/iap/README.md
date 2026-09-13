# lib/iap — in-app purchases for LÖVE

A drop-in IAP module for LÖVE games on Android and iOS. Copy the `iap/` folder
into any project, declare your products, and the same code path runs on device
and on your desktop dev machine.

```
iap/
├── init.lua                 public API + the settle loop
├── catalog.lua              product definitions, store SKUs, localised pricing
├── ledger.lua               durable record of purchases (the money-safety file)
├── util.lua                 logging, backoff, platform detection
├── json.lua                 vendored rxi/json.lua so the folder is standalone
├── transport/filedrop.lua   Lua <-> native message transport
├── backends/
│   ├── mock.lua             desktop / CI store simulator
│   └── native.lua           Google Play + StoreKit via the bridge
└── native/
    ├── android/IAPBridge.java    Play Billing 7
    └── ios/IAPBridge.swift       StoreKit 2
```

LÖVE has no billing API of its own, so real purchases need native code. The Lua
half here is complete and portable; the native half is a single file you add to
your love-android / love-ios project once.

---

## Quick start

```lua
local IAP = require("lib.iap")

IAP.init{
    products = {
        { id = "gems_small", type = "consumable", grants = { gems = 100 },
          stores = { android = "com.you.game.gems_small", ios = "gems_small" } },
        { id = "gems_large", type = "consumable", grants = { gems = 1200 },
          stores = { android = "com.you.game.gems_large", ios = "gems_large" } },
        { id = "remove_ads", type = "non_consumable", grants = { noAds = true },
          sku = "com.you.game.remove_ads" },   -- same id on both stores
    },

    -- Credit the player. Called once per purchase, on the main thread.
    onGrant = function(purchase)
        if purchase.grants.gems then
            PlayerData.gems = PlayerData.gems + purchase.grants.gems
            savePlayerData()
        end
        if purchase.grants.noAds then Settings.ads = false end
    end,
}

function love.update(dt)
    IAP.update(dt)      -- required: this is what drives everything
end
```

Buying:

```lua
IAP.purchase("gems_small", function(ok, result)
    if ok then
        showToast("Thanks! +" .. result.grants.gems .. " gems")
    elseif result.code ~= "user_cancelled" then
        showToast(result.message)
    end
end)
```

Showing the store:

```lua
for _, p in ipairs(IAP.getProducts()) do
    -- p.title and p.price are the *store's* localised strings once connected,
    -- falling back to whatever you declared until then.
    drawButton(p.title, p.price, function() IAP.purchase(p.id) end)
end
```

On desktop this runs against the mock store, so the whole flow — including the
unhappy paths — is testable without a device:

```lua
IAP.setMockOutcome("cancelled")   -- next purchase only
IAP.setMockOutcome("error", true) -- every purchase, until changed back
IAP.setMockOutcome("pending")     -- Ask to Buy / slow payment method
```

---

## Server-side validation

Without a validator, a purchase is granted on the device's word alone. That is
fine for a cosmetic unlock and **not** fine for anything a modified save could
mint. Point `validate` at your own server and it becomes the gate:

```lua
IAP.init{
    products = { ... },

    validate = function(purchase, done)
        -- purchase.payload   raw receipt: Play's originalJson, or StoreKit's JWS
        -- purchase.signature Play signature (empty on iOS — the JWS is signed)
        -- purchase.txn       store-unique transaction id
        MyServer.send("verify_purchase", {
            platform  = purchase.platform,
            productId = purchase.productId,
            payload   = purchase.payload,
            signature = purchase.signature,
            txn       = purchase.txn,
        })
        MyServer.once("verify_result", function(res)
            if res.ok then
                done(true)                                   -- grant
            elseif res.invalid then
                done(false, { permanent = true,              -- never grant, stop retrying
                              code = "invalid_receipt",
                              message = "Could not verify this purchase" })
            else
                done(false)                                  -- transient: retry with backoff
            end
        end)
    end,

    onGrant = function(purchase) ... end,
}
```

What your server does with `payload`:

- **Android** — verify the signature against your Play RSA public key, then call
  `purchases.products.get` on the Google Play Developer API to confirm the
  purchase is real and not refunded.
- **iOS** — the payload is a signed JWS. Verify its certificate chain against
  Apple's root, or look the transaction up via the App Store Server API.

Then credit the account **keyed on `txn`**. Which brings us to the one rule that
matters:

> ### Grants are at-least-once. Make your server idempotent on `txn`.
>
> A purchase is granted *before* the ledger marks it processed, so a crash in the
> middle replays it rather than losing it. That is the right trade — a duplicate
> grant is recoverable, a swallowed purchase is a refund request — but it means
> a server that blindly adds gems on every call will occasionally over-credit.
> Store the transaction id and ignore repeats.

---

## What the module guarantees

The sequence is deliberately ordered so that a kill at any point is survivable:

1. The store hands over a purchase → it is **written to disk immediately**.
2. `validate` runs (if set). Failures retry with exponential backoff, forever,
   across relaunches.
3. `onGrant` runs. If it throws or returns `false`, the purchase stays on disk
   and is retried.
4. Only now is the store told to **consume** (consumables) or **acknowledge**
   (everything else). Until that happens, Google Play and StoreKit keep
   re-delivering the purchase — which is exactly what you want.
5. The record is removed from the ledger.

Practical consequences:

- Killing the app mid-purchase does not lose it: the next launch picks it up
  from `Transaction.unfinished` / `queryPurchasesAsync` and settles it.
- Google Play auto-refunds any non-consumable left unacknowledged for three
  days. Step 4 is what prevents that, and it can only run after step 3.
- A receipt your server rejects outright is consumed rather than left to
  re-deliver forever — but it is never granted.
- `IAP.getPendingCount() > 0` means money is in flight. A good place for a
  "restoring your purchase…" spinner.

---

## API

| Call | Notes |
|---|---|
| `IAP.init(config)` | Once, at startup. |
| `IAP.update(dt)` | Every frame. Nothing happens without it. |
| `IAP.purchase(id, cb)` | `cb(ok, purchase \| err)`. Returns false if refused outright. |
| `IAP.restore(cb)` | `cb(ok, productIds)`. Required on iOS — ship a visible button. |
| `IAP.getProducts()` | Declared order, with store pricing merged in. |
| `IAP.getProduct(id)` / `IAP.getPrice(id)` | |
| `IAP.isOwned(id)` | Non-consumables and subscriptions. |
| `IAP.getOwned()` | Array of owned product ids. |
| `IAP.isReady()` / `IAP.getState()` | `idle` → `connecting` → `ready` \| `unavailable`. |
| `IAP.isBusy()` | A purchase dialog is open. |
| `IAP.getPendingCount()` | Unsettled purchases. |
| `IAP.flush()` | Force a settle pass (e.g. on `love.focus(true)`). |
| `IAP.on(event, fn)` / `IAP.off(handle)` | |
| `IAP.shutdown()` | |
| `IAP.setMockOutcome(outcome, sticky)` | Mock backend only. |
| `IAP.resetLocalState()` | Wipes the ledger. Debug only. |

### Events

| Event | Payload |
|---|---|
| `ready` | `{ products }` — the store connected |
| `unavailable` | `{ code, message }` — gave up connecting |
| `products` | product list, after pricing arrives |
| `purchase` | the granted purchase |
| `failed` | `{ productId, code, message }` |
| `cancelled` | the player backed out |
| `deferred` | `{ productId }` — Ask to Buy / pending payment |
| `restored` | `{ productIds }` |

`IAP.on("*", fn)` receives everything, with the event name as the second argument.

### Error codes

`user_cancelled`, `already_owned`, `product_unavailable`, `not_ready`, `busy`,
`unknown_product`, `invalid_receipt`, `network_error`, `service_unavailable`,
`billing_unavailable`, `developer_error`, `timeout`, `store_error`.

### Config

| Key | Default | |
|---|---|---|
| `products` | — | Required. |
| `onGrant` | — | Credit the player. Return `false` to retry. |
| `validate` | — | Server check. Omit to trust the device. |
| `backend` | `"auto"` | `auto` picks `native` on device, `mock` elsewhere. |
| `platform` | auto | Force `android` / `ios` / `mock`. |
| `storageFile` | `iap_ledger.json` | In the LÖVE save directory. |
| `logLevel` | `"info"` | `off` / `error` / `warn` / `info` / `debug`. |
| `logger` | `print` | |
| `json` | vendored | Any lib with `encode` / `decode`. |
| `retryBase`, `retryCap` | `2`, `120` | Backoff seconds. |
| `bridge` | `{ dir = "iap_bridge", poll = 0.25 }` | Native transport. |
| `mock` | `{ latency = 0.4, outcome = "success" }` | |

### Product definition

```lua
{ id      = "gems_small",        -- your key, used everywhere in game code
  type    = "consumable",        -- consumable | non_consumable | subscription
  grants  = { gems = 100 },      -- free-form; handed to onGrant
  title   = "Handful of Gems",   -- fallback until the store answers
  price   = "$0.99",             -- fallback only — never charge from this
  stores  = { android = "com.you.game.gems_small", ios = "gems_small" } }
```

Use `sku = "..."` instead of `stores` when the identifier is the same on both.

---

## Native setup

Per-platform walk-throughs:

- `native/android/INTEGRATION.md` — Play Billing 7, one Gradle line and two
  method calls.
- `native/ios/INTEGRATION.md` — StoreKit 2, one Swift file and one call.

Both halves talk over files in the save directory (`iap_bridge/to_native/` and
`iap_bridge/to_lua/`), each message committed by a separate `.rdy` marker so a
half-written message is never read. No sockets, no extra permissions, and a
reply that arrives while the game is backgrounded is simply still on disk when
it comes back.

---

## Tests

```bash
lua tests/test_iap.lua
```

86 assertions, no LÖVE required: grant-exactly-once, crash recovery of an
in-flight purchase, consume-only-after-grant, transient and permanent
validation failures, the file-drop transport, and a scripted native bridge
driving a full Play-style purchase.

---

## Shipping checklist

- [ ] Product ids created in Play Console / App Store Connect, **active**, and
      matching the `stores` values exactly.
- [ ] Android: app uploaded to a test track, tester account added. Billing does
      nothing for a sideloaded debug build with no matching Play listing.
- [ ] iOS: sandbox tester account; a visible **Restore Purchases** button
      calling `IAP.restore()` (App Review rejects builds without one).
- [ ] `validate` wired to your server for anything worth cheating for.
- [ ] Server credits are idempotent on `txn`.
- [ ] Tested: kill the app between paying and the reward landing — the reward
      should appear on the next launch.
- [ ] Tested: buy with no network; buy, cancel, buy again.

---

MIT, same as the rest of the project. `json.lua` is rxi/json.lua, also MIT.
