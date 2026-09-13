# iOS integration — StoreKit 2

`IAPBridge.swift` is the native half of `lib/iap`. It runs inside your love-ios
project and talks to the Lua side through files in the game's save directory.
LÖVE itself needs no patching.

Requires **iOS 15+** (StoreKit 2). For older deployment targets you would need a
StoreKit 1 bridge speaking the same protocol.

## 1. Add the file

Drag `IAPBridge.swift` into the love-ios Xcode project, target **love-ios**.

If the project has no Swift file yet, Xcode offers to create a bridging header —
accept it. The bridge does not need to call into Objective-C, but the project
needs the Swift toolchain enabled.

## 2. Add the capability

Target → **Signing & Capabilities** → **+ Capability** → **In-App Purchase**.

## 3. Start it

In `AppDelegate.m` (love-ios is Objective-C), import the generated Swift header
and start the bridge:

```objc
#import "love_ios-Swift.h"      // <ProductModuleName>-Swift.h

- (BOOL)application:(UIApplication *)application
        didFinishLaunchingWithOptions:(NSDictionary *)launchOptions
{
    if (@available(iOS 15.0, *)) {
        [[IAPBridge shared] startWithLoveIdentity:@"autochest"];  // t.identity
    }
    // ... existing LÖVE startup ...
}
```

The identity string must match `t.identity` in `conf.lua` exactly — it is how the
bridge finds the same directory LÖVE writes to.

## 4. Create the products

In App Store Connect → your app → **In-App Purchases**:

| Lua `type` | App Store Connect type |
|---|---|
| `consumable` | Consumable |
| `non_consumable` | Non-Consumable |
| `subscription` | Auto-Renewable Subscription |

The Product ID is the `stores.ios` value from your Lua catalog. Products must
reach at least **Ready to Submit** before they appear in sandbox.

## 5. Ship a Restore button

App Review rejects apps that sell non-consumables without a visible restore
control:

```lua
drawButton("Restore Purchases", function()
    IAP.restore(function(ok, ids)
        showToast(#ids > 0 and "Purchases restored" or "Nothing to restore")
    end)
end)
```

`IAP.restore()` calls `AppStore.sync()` and then replays
`Transaction.currentEntitlements`, so it recovers non-consumables and
subscriptions after a reinstall or on a new device.

## 6. Test it

Two options, both fine:

- **StoreKit Configuration file** (fastest): File → New → StoreKit Configuration
  File, add your products, then select it in the scheme's Run → Options. Works in
  the simulator, no App Store Connect round-trip.
- **Sandbox account**: create one in App Store Connect → Users and Access →
  Sandbox, then sign into it on a real device under Settings → Developer.

Logs:

```
[IAPBridge] bridge directory: /var/mobile/.../Documents/save/autochest/iap_bridge
```

## How the two halves meet

```
<Documents>/save/<identity>/iap_bridge/
    to_native/<seq>.json   request from Lua
    to_native/<seq>.rdy    commit marker — the bridge waits for this
    to_lua/<seq>.json      reply from the bridge
    to_lua/<seq>.rdy       commit marker — Lua waits for this
```

The body is always written atomically before the marker, so neither side can read
a half-written message. `resolveBridgeDir()` in `IAPBridge.swift` checks the
known love-ios save locations and is the only place the path is decided.

## Notes specific to StoreKit 2

- **Unverified transactions are dropped.** If `VerificationResult` is
  `.unverified`, the bridge neither reports nor finishes it. StoreKit itself
  says the signature is bad.
- **`finish()` covers both cases.** Unlike Play, StoreKit makes no
  consume/acknowledge distinction — `lib/iap` still only calls it after the
  grant lands, so an interrupted purchase is re-delivered rather than lost.
- **`payload` is the signed JWS.** Verify it on your server against Apple's root
  certificate, or look the transaction up with the App Store Server API. Never
  trust the device.
- **`Transaction.updates` is always listening**, so an Ask to Buy approval or a
  purchase made on another device arrives even with no purchase in flight.

## Troubleshooting

| Symptom | Cause |
|---|---|
| `product_unavailable` | Product ID mismatch, or the product is not Ready to Submit. |
| Empty product list | Paid Applications agreement not active in App Store Connect. |
| Nothing happens at all | Identity mismatch — compare the logged path against `love.filesystem.getSaveDirectory()`. |
| Purchases vanish on reinstall | Expected for consumables; non-consumables need `IAP.restore()`. |
