# Android integration — Google Play Billing

`IAPBridge.java` is the native half of `lib/iap`. It runs inside your
love-android project and talks to the Lua side through files in the game's save
directory. LÖVE itself needs no patching.

## 1. Add the billing dependency

In `love-android/app/build.gradle`:

```gradle
dependencies {
    implementation 'com.android.billingclient:billing:7.1.1'
}
```

`minSdkVersion` must be 21 or higher (love-android already is).

## 2. Add the permission

Play Billing needs this in `AndroidManifest.xml`, inside `<manifest>`:

```xml
<uses-permission android:name="com.android.vending.BILLING" />
```

## 3. Drop in the bridge

Copy `IAPBridge.java` to:

```
love-android/app/src/main/java/org/love2d/android/IAPBridge.java
```

If your package differs, change the `package` line to match.

## 4. Start it

In `GameActivity.java` (love-android's main activity):

```java
@Override
protected void onCreate(Bundle savedInstanceState) {
    super.onCreate(savedInstanceState);
    IAPBridge.start(this, "autochest");   // <- t.identity from your conf.lua
}

@Override
protected void onDestroy() {
    IAPBridge.stop();
    super.onDestroy();
}
```

The identity string must match `t.identity` exactly — it is how the bridge finds
the same directory LÖVE writes to.

## 5. Create the products

In Play Console → Monetise → **In-app products**:

- Product ID = the `stores.android` value from your Lua catalog.
- Consumables and non-consumables are both "In-app products"; the difference is
  entirely in how `lib/iap` settles them (`type` in the Lua definition).
- Subscriptions live under **Subscriptions** and need `type = "subscription"`.
- Every product must be **Active**.

## 6. Test it

Billing only works for a build Play recognises:

1. Upload a signed build to the **Internal testing** track (it does not need to
   be released).
2. Add your Google account under **License testing** in Play Console → Settings.
3. Install from the Play test link, not via `adb install`.

License testers are charged nothing and can re-buy freely.

```bash
adb logcat -s IAPBridge
```

## How the two halves meet

```
<filesDir>/save/<identity>/iap_bridge/
    to_native/<seq>.json   request from Lua
    to_native/<seq>.rdy    commit marker — the bridge waits for this
    to_lua/<seq>.json      reply from the bridge
    to_lua/<seq>.rdy       commit marker — Lua waits for this
```

The body is always written and fsync'd before the marker, so neither side can
read a half-written message. `resolveBridgeDir()` in `IAPBridge.java` is the only
place the path is decided — if your build uses `t.externalstorage = true` or a
patched save location, adjust it there.

## Troubleshooting

| Symptom | Cause |
|---|---|
| `billing_unavailable` | Not installed from Play, or no Play Store on the device/emulator. |
| `product_unavailable` | Product ID mismatch, product not Active, or the build is not on a Play track yet. |
| `developer_error` | App not signed with the key Play expects. |
| Nothing happens at all | Identity mismatch — check the path in `adb logcat -s IAPBridge` against `love.filesystem.getSaveDirectory()`. |
| Purchase refunded after 3 days | Acknowledgement never ran; check that `onGrant` is succeeding so the module reaches the finish step. |
