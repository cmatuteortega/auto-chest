# Trying the 1000-coin purchase on Android

End-to-end path: **Play Billing → the game → your VPS → gold in the DB**.

Billing does nothing in a plain sideloaded APK. Play must recognise the package
name, the signing key, and the product ID, which means a real (unreleased)
upload to a test track. Budget an hour for the first run; afterwards it is one
`./build-android.sh` away.

## This app's identifiers

| | |
|---|---|
| Play Store name | Tiny Turf: Auto Tactics PVP |
| Package name (`applicationId`) | `com.cmatute.tinyturf` |
| LÖVE identity (`t.identity`) | `autochest` |
| Product ID | `coins_1000` |

Two of these are permanent and two are easy to break:

- **`com.cmatute.tinyturf` can never be changed** once the app exists in Play
  Console, and must be identical in three places: Play Console, love-android's
  `applicationId`, and `AUTOCHEST_ANDROID_PACKAGE` on the VPS. A mismatch shows
  up as `IAP REJECTED (wrong_package)`.
- **`autochest` must not be renamed.** The Play name and the identity are
  unrelated on purpose: the identity is the save-directory name and the place
  the native bridge and Lua meet. Changing it wipes every player's local data
  and silently breaks the bridge.
- Do **not** confuse `applicationId` with the `package org.love2d.android;`
  line at the top of `IAPBridge.java`. That is the *Java* package — where the
  class lives in the project — and it stays as it is. Only `applicationId` goes
  to Play.

---

## 0. Two gates before anything else

Both of these block product creation, and both are easy to miss:

**A payments profile.** Play Console → **Setup → Payments profile**. Without a
Google payments merchant profile linked to the account you cannot sell anything,
and the in-app products page stays closed.

**A build with the BILLING permission, already uploaded.** Play will not let you
create in-app products until it has seen an APK/AAB that declares
`com.android.vending.BILLING`. This is why the build comes *before* the product
here — the opposite order does not work.

If the in-app products page is already open for you, skip ahead to step 3, come
back for the build, and nothing is lost: the product and the build only have to
meet before you can actually buy anything.

## 1. Prepare love-android

```bash
cp lib/iap/native/android/IAPBridge.java \
   ~/love-android/app/src/main/java/org/love2d/android/IAPBridge.java
```

`~/love-android/app/build.gradle`, in `defaultConfig` — love-android ships with
`org.love2d.android`, which is the LÖVE app's own package and is already taken
on Play, so this **must** be changed:

```gradle
defaultConfig {
    applicationId "com.cmatute.tinyturf"
    // ...
}
```

Same file, in `dependencies`:

```gradle
implementation 'com.android.billingclient:billing:7.1.1'
```

`~/love-android/app/src/main/AndroidManifest.xml`, inside `<manifest>` — this is
the line Play looks for before it unlocks in-app products:

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

## 2. Build and upload to Internal testing

```bash
./build-android.sh
```

`build-android.sh` produces a **debug** APK. Debug builds are fine for running
the game locally but Play rejects them: the upload must be signed with a real
key, so you need an upload keystore first.

```bash
keytool -genkey -v -keystore ~/tinyturf-upload.jks \
        -keyalg RSA -keysize 2048 -validity 10000 -alias upload
```

Back it up somewhere safe — lose it and you cannot ship updates without Google's
key-reset process. Wire it into `~/love-android/app/build.gradle`
(`signingConfigs` + `buildTypes.release.signingConfig`), then:

```bash
cd ~/love-android && ./gradlew bundleEmbedNoRecordRelease
```

The task name follows love-android's `embed`/`noRecord` product flavours — the
same ones `build-android.sh` uses for its debug build. Run `./gradlew tasks
--all | grep -i bundle` if your checkout names them differently. The output
lands in `app/build/outputs/bundle/`.

Play Console → **Testing → Internal testing → Create new release**. It does not
need review or promotion — uploading and rolling out to the internal track is
enough. Accept Play App Signing when offered; the key above then becomes your
*upload* key and Google holds the release key.

Play will also ask you to complete **App content** (privacy policy, ads, content
rating, target audience, data safety) before it lets you roll out. Internal
testing needs far less than production, but it is not zero.

> New personal developer accounts also need 12 testers opted in for 14 days
> before *production* access. That does not affect internal testing, so it does
> not block anything here — but it is worth knowing before you plan a launch.

## 3. Create the product

Now the page is open: Play Console → **Monetise → Products → In-app products →
Create product**.

| Field | Value |
|---|---|
| Product ID | `coins_1000` — **permanent**, must match `stores.android` in `src/iap_manager.lua` |
| Name | `1000 Coins` (max 55 chars) |
| Description | e.g. `A pile of 1000 coins to spend in the shop.` (max 200) |
| Default price | `€1.00` — let Play auto-convert the other currencies |
| Status | **Active** — a new product is inactive and will not be sold until you activate it |

Two things bite here: the product ID cannot be changed or reused after
creation, and a product left inactive returns `product_unavailable` at runtime
with no other clue.

## 4. Grab the licensing public key

Play Console → **Monetise → Monetisation setup → Licensing**.

Copy the long base64 `RSA public key` blob. This is what the server uses to
verify receipts offline — no OAuth, no service account, no Google API call.

## 5. Point the server at the key and restart

On the VPS, add to the systemd unit
(`/etc/systemd/system/autochest-server.service`, under `[Service]`):

```ini
Environment="AUTOCHEST_PLAY_PUBLIC_KEY=MIIBIjANBgkq...the whole blob..."
Environment="AUTOCHEST_ANDROID_PACKAGE=com.cmatute.tinyturf"
```

This is the `applicationId` set in step 1 — receipts from any other app are
refused.

```bash
rsync -avz --exclude 'server/players.db' . root@75.119.142.247:/opt/autochest/
ssh root@75.119.142.247 'systemctl daemon-reload && systemctl restart autochest-server'
ssh root@75.119.142.247 'journalctl -u autochest-server -n 20'
```

The startup line tells you whether it is armed:

```
[LOG] IAP verification: android=key set, package=com.cmatute.tinyturf, ios=not implemented
```

`android=NO KEY` means purchases will be refused — **transiently**, so nobody
loses coins they paid for; the client keeps the receipt and retries until the
key is set.

## 6. Install and buy

Add your Google account under **Monetise → Monetisation setup → License
testing**. Licence testers are charged nothing and can re-buy freely.

Install from the internal-testing opt-in link, **not** `adb install` — an APK
that did not come from Play gets `billing_unavailable`.

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
| `product_unavailable` | Product ID mismatch, product left **inactive**, or the build is not on a test track. |
| In-app products page won't open | No payments profile, or no uploaded build declaring `com.android.vending.BILLING`. |
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
