# Trying the 1000-coin purchase on Android

End-to-end path: **Play Billing → the game → your VPS → gold in the DB**.

Billing does nothing in a plain sideloaded APK. Play must recognise the package
name, the signing key, and the product ID, which means a real (unreleased)
upload to a test track. Budget an hour for the first run; afterwards it is one
`./build-android.sh` away.

---

## 1. Create the product in Play Console

Play Console → your app → **Monetise → Products → In-app products → Create**.

| Field | Value |
|---|---|
| Product ID | `coins_1000` (must match `src/iap_manager.lua`) |
| Name | 1000 Coins |
| Price | €1.00 |
| Status | **Active** |

The product ID is the one thing that cannot be changed later. It must match
`stores.android` in `src/iap_manager.lua` exactly.

## 2. Grab the licensing public key

Play Console → **Monetise → Monetisation setup → Licensing**.

Copy the long base64 `RSA public key` blob. This is what the server uses to
verify receipts offline — no OAuth, no service account, no Google API call.

## 3. Add the native bridge to love-android

```bash
cp lib/iap/native/android/IAPBridge.java \
   ~/love-android/app/src/main/java/org/love2d/android/IAPBridge.java
```

`~/love-android/app/build.gradle`, in `dependencies`:

```gradle
implementation 'com.android.billingclient:billing:7.1.1'
```

`~/love-android/app/src/main/AndroidManifest.xml`, inside `<manifest>`:

```xml
<uses-permission android:name="com.android.vending.BILLING" />
```

`GameActivity.java`:

```java
@Override
protected void onCreate(Bundle savedInstanceState) {
    super.onCreate(savedInstanceState);
    IAPBridge.start(this, "autochest");   // must match t.identity in conf.lua
}

@Override
protected void onDestroy() {
    IAPBridge.stop();
    super.onDestroy();
}
```

`"autochest"` is how the bridge finds the same directory LÖVE writes to. Get it
wrong and nothing happens at all — no error, just silence.

## 4. Point the server at the key and restart

On the VPS, add to the systemd unit
(`/etc/systemd/system/autochest-server.service`, under `[Service]`):

```ini
Environment="AUTOCHEST_PLAY_PUBLIC_KEY=MIIBIjANBgkq...the whole blob..."
Environment="AUTOCHEST_ANDROID_PACKAGE=com.yourstudio.autochest"
```

Use the package name from `~/love-android/app/build.gradle`
(`applicationId`) — receipts from any other app are refused.

```bash
rsync -avz --exclude 'server/players.db' . root@75.119.142.247:/opt/autochest/
ssh root@75.119.142.247 'systemctl daemon-reload && systemctl restart autochest-server'
ssh root@75.119.142.247 'journalctl -u autochest-server -n 20'
```

The startup line tells you whether it is armed:

```
[LOG] IAP verification: android=key set, package=com.yourstudio.autochest, ios=not implemented
```

`android=NO KEY` means purchases will be refused — **transiently**, so nobody
loses coins they paid for; the client keeps the receipt and retries until the
key is set.

## 5. Upload a build Play recognises

```bash
./build-android.sh
```

Then upload the **signed release** APK/AAB to Play Console →
**Testing → Internal testing**. It does not need to be promoted or reviewed,
only uploaded and rolled out to the internal track.

Add your Google account under **Monetise → Monetisation setup → License
testing**. Licence testers are charged nothing, and their purchases can be
re-bought freely.

## 6. Install and buy

Install from the internal-testing opt-in link, **not** `adb install` — an
APK that did not come from Play gets `billing_unavailable`.

In the game: **Shop → Coins → the €1.00 button**. Play's purchase sheet opens,
shows "test card, always approves", and on confirm the button flips to
*Processing…* until the server verifies. Gold updates from the server's
`currency_update`, same as every other balance change.

## 7. Watch it happen

Device:

```bash
adb logcat -s IAPBridge:V love:V
```

Server:

```bash
ssh root@75.119.142.247 journalctl -u autochest-server -f
```

A good purchase logs:

```
[LOG] IAP OK: yourname +1000 gold (coins_1000, android) txn=GPA.3311-...
```

A replay of the same receipt (which happens naturally — the client retries
until it gets an answer) logs `IAP duplicate (already credited)` and pays out
nothing further.

---

## Testing without Play

Desktop runs the mock store, so the whole flow works with `love .`:

```lua
IAPManager.setMockOutcome("cancelled")  -- or "error", "pending"
```

The server still refuses mock receipts unless you set
`AUTOCHEST_IAP_ALLOW_UNVERIFIED=true` on a **local** server. Never set that in
production — it makes coins free for anyone who can reach port 12345.

```bash
AUTOCHEST_IAP_ALLOW_UNVERIFIED=true love server/
```

## The tests

```bash
lua tests/test_iap.lua           # module lifecycle (94 assertions)
lua tests/test_iap_verify.lua    # real RSA signature checks (27 assertions)
lua tests/test_iap_manager.lua   # client <-> server wiring (33 assertions)
```

---

## Things that go wrong

| Symptom | Cause |
|---|---|
| Button stuck on "Connecting to store..." | Bridge not started, or identity ≠ `autochest`. Check `adb logcat -s IAPBridge` for the bridge directory line. |
| `billing_unavailable` | Installed outside Play, or no Play Store (most emulators). |
| `product_unavailable` | Product ID mismatch, product not Active, or the build is not on a test track. |
| Button stuck on "Processing..." | Server refusing. Check `journalctl` for `IAP REJECTED`. |
| `IAP REJECTED (wrong_package)` | `AUTOCHEST_ANDROID_PACKAGE` ≠ the APK's `applicationId`. |
| `IAP REJECTED (bad_signature)` | Wrong licensing key, or the APK is signed with a different key than Play expects. |
| Paid but no coins | Expected to self-heal: the receipt is on disk and retries. Check the server is up; coins land within a minute, or on the next launch. |
| Charged twice | Cannot happen — `iap_transactions.txn` is a global primary key. A second claim logs `duplicate` and pays nothing. |

## Before charging real money

- [ ] `AUTOCHEST_IAP_ALLOW_UNVERIFIED` is **not** set in production.
- [ ] Startup log shows `android=key set` and the right package.
- [ ] Kill the app right after paying — the coins should appear on next launch.
- [ ] Turn off wifi right after paying — the coins should appear on reconnect.
- [ ] Buy twice in a row; both credit, and each is a separate `txn`.
