# In-app purchases: 1000 gold for €1

The shop's **Gold** button sells `gold_1000` through Google Play, using
[love-iap](https://github.com/cmatuteortega/love-iap). Gold lives on the
server, so the server grants it, not the phone.

```
tap Gold ─► Play purchase sheet ─► paid
  client (src/iap_manager.lua): onPurchase queues the token, leaves the purchase unfinished
  ─► iap_purchase {product, token, store} ─► server (server/main.lua)
       token already in iap_purchases? ─► iap_granted (fresh=false), no gold
       else server/iap_verify.lua asks Google (purchases.products.get)
         ok        ─► insert token + add 1000 gold (one transaction) ─► currency_update + iap_granted
         not now   ─► iap_rejected retry=true (client re-sends with backoff)
         invalid   ─► iap_rejected retry=false
  client on iap_granted ─► iap.finish() consumes the purchase on Play
```

Until the client consumes it, Play re-delivers the purchase at every launch,
so a crash or lost message never loses a paid purchase, and the token ledger
means it is never granted twice. Play refunds purchases left unconsumed for
3 days, which is what happens to one the server rejects.

## 1. Play Console (once)

1. Create the app with application id **`com.cmatute.tinyturf`** (or whatever
   `ANDROID_APP_ID` is set to in the repo's Actions variables).
2. Set the `ANDROID_KEYSTORE_*` secrets if not done yet. Every build must be
   signed with the same key from now on.
3. Play wants an AAB for uploads: build one with
   `./gradlew bundleEmbedNoRecordRelease` in love-android (the CI builds the
   APK only) and upload it to **Internal testing**.
4. *Monetize → Products → In-app products → Create*: id **`gold_1000`**,
   name "1000 Gold", price **€1.00** (Play converts for other countries).
   Activate it.
5. *Settings → License testing*: add your Google account. Test purchases use
   test cards and are never charged.
6. Install from the internal testing opt-in link. A sideloaded APK from CI
   also works once a build with the same id and key has been uploaded.

## 2. Server verification (once)

1. Google Cloud console: create a service account in a project, create a JSON
   key for it, and enable the **Google Play Android Developer API** in that
   project.
2. Play Console *Users and permissions*: invite the service account's email
   with the **View financial data, orders and cancellation survey responses**
   and **Manage orders and subscriptions** permissions for the app.
3. On the VPS:
   ```bash
   sudo mkdir -p /etc/autochest
   sudo cp play-service-account.json /etc/autochest/
   sudo chmod 600 /etc/autochest/play-service-account.json
   ```
   Uncomment `IAP_GOOGLE_SERVICE_ACCOUNT` in
   `/etc/systemd/system/autochest-server.service`, then
   `sudo systemctl daemon-reload && sudo systemctl restart autochest-server`.
   The log should show `[IAP] Google Play verification on (...)`.
   The server needs `curl` and `openssl` (stock on Ubuntu).

New permissions can take up to a day to reach the API; until then the log
shows `google_auth_failed (will retry)` and purchases simply wait on the phone.

## Testing without a phone

On desktop love-iap uses a mock store (price shows as `$0.99`). The server
rejects mock purchases unless started with `IAP_ALLOW_UNVERIFIED=1`:

```bash
IAP_ALLOW_UNVERIFIED=1 love server/   # local server, point src/config.lua at 127.0.0.1
love .
```

Never set `IAP_ALLOW_UNVERIFIED` on the production server: anyone could send
a made-up token and get gold.

Tests: `luajit tests/test_iap_manager.lua` (client flow, mock store + fake socket).

## Not done yet

- **iOS**: purchases arrive as `store = "apple"`, which the server can't
  verify yet, so they wait unfinished on the device (no gold, no charge lost).
  Needs App Store Server API verification in `server/iap_verify.lua`.
- **Refunds**: a refunded purchase keeps its gold. Google's Voided Purchases
  API could claw it back later.
