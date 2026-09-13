package org.love2d.android;

import android.app.Activity;
import android.content.Context;
import android.os.Handler;
import android.os.HandlerThread;
import android.os.Looper;
import android.util.Log;

import androidx.annotation.NonNull;

import com.android.billingclient.api.AcknowledgePurchaseParams;
import com.android.billingclient.api.BillingClient;
import com.android.billingclient.api.BillingClientStateListener;
import com.android.billingclient.api.BillingFlowParams;
import com.android.billingclient.api.BillingResult;
import com.android.billingclient.api.ConsumeParams;
import com.android.billingclient.api.PendingPurchasesParams;
import com.android.billingclient.api.ProductDetails;
import com.android.billingclient.api.Purchase;
import com.android.billingclient.api.PurchasesUpdatedListener;
import com.android.billingclient.api.QueryProductDetailsParams;
import com.android.billingclient.api.QueryPurchasesParams;

import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.RandomAccessFile;
import java.nio.charset.Charset;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.atomic.AtomicBoolean;

/**
 * Native half of lib/iap for Android — Google Play Billing behind the file-drop
 * protocol the Lua module speaks.
 *
 * Integration (see INTEGRATION.md for the full walk-through):
 *
 *   app/build.gradle:
 *     implementation 'com.android.billingclient:billing:7.1.1'
 *
 *   GameActivity.onCreate():
 *     IAPBridge.start(this, "your_love_identity");   // t.identity from conf.lua
 *   GameActivity.onDestroy():
 *     IAPBridge.stop();
 *
 * No changes to LÖVE itself are required: the two sides only ever meet through
 * files in the game's save directory.
 */
public final class IAPBridge implements PurchasesUpdatedListener {

    private static final String TAG = "IAPBridge";
    private static final String BRIDGE_DIR = "iap_bridge";
    private static final long   POLL_MS = 250L;
    private static final Charset UTF8 = Charset.forName("UTF-8");

    private static IAPBridge instance;

    private final Activity activity;
    private final File inbox;      // to_native — written by Lua
    private final File outbox;     // to_lua    — written by us

    private final HandlerThread pollThread;
    private final Handler pollHandler;
    private final Handler mainHandler;

    private BillingClient billing;
    private final AtomicBoolean connected = new AtomicBoolean(false);
    private final AtomicBoolean stopped   = new AtomicBoolean(false);

    /** sku -> details, refreshed on every init. */
    private final Map<String, ProductDetails> details = new HashMap<>();
    /** sku -> "consumable" | "non_consumable" | "subscription", as Lua declared it. */
    private final Map<String, String> productTypes = new HashMap<>();
    /** purchaseToken -> purchase, so a finish request can find its purchase. */
    private final Map<String, Purchase> knownPurchases = new HashMap<>();

    private long replySeq = 0;

    // ── lifecycle ────────────────────────────────────────────────────────────

    public static synchronized void start(Activity activity, String loveIdentity) {
        if (instance != null) return;
        instance = new IAPBridge(activity, loveIdentity);
        instance.begin();
    }

    public static synchronized void stop() {
        if (instance == null) return;
        instance.end();
        instance = null;
    }

    private IAPBridge(Activity activity, String loveIdentity) {
        this.activity = activity;

        File base = resolveBridgeDir(activity, loveIdentity);
        this.inbox  = new File(base, "to_native");
        this.outbox = new File(base, "to_lua");
        //noinspection ResultOfMethodCallIgnored
        this.inbox.mkdirs();
        //noinspection ResultOfMethodCallIgnored
        this.outbox.mkdirs();

        Log.i(TAG, "bridge directory: " + base.getAbsolutePath());

        this.pollThread = new HandlerThread("iap-bridge-poll");
        this.pollThread.start();
        this.pollHandler = new Handler(pollThread.getLooper());
        this.mainHandler = new Handler(Looper.getMainLooper());
    }

    /**
     * LÖVE for Android stores save files under {@code getFilesDir()/save/<identity>}
     * when {@code t.externalstorage} is false (the default). If your build differs,
     * pass the identity you use, or edit this method — it is the only place the
     * path is decided.
     */
    private static File resolveBridgeDir(Context context, String loveIdentity) {
        File internal = new File(new File(context.getFilesDir(), "save"), loveIdentity);
        File candidate = new File(internal, BRIDGE_DIR);
        if (candidate.isDirectory()) return candidate;

        // t.externalstorage = true
        File external = context.getExternalFilesDir(null);
        if (external != null) {
            File ext = new File(new File(new File(external, "save"), loveIdentity), BRIDGE_DIR);
            if (ext.isDirectory()) return ext;
        }

        // Lua has not run yet; create the internal-storage location and let it
        // meet us there.
        return candidate;
    }

    private void begin() {
        billing = BillingClient.newBuilder(activity)
                .setListener(this)
                .enablePendingPurchases(
                        PendingPurchasesParams.newBuilder().enableOneTimeProducts().build())
                .build();
        connect();
        pollHandler.post(pollLoop);
    }

    private void end() {
        stopped.set(true);
        pollHandler.removeCallbacksAndMessages(null);
        pollThread.quitSafely();
        if (billing != null) {
            billing.endConnection();
            billing = null;
        }
    }

    private void connect() {
        billing.startConnection(new BillingClientStateListener() {
            @Override public void onBillingSetupFinished(@NonNull BillingResult result) {
                connected.set(result.getResponseCode() == BillingClient.BillingResponseCode.OK);
                Log.i(TAG, "billing setup: " + result.getResponseCode() + " " + result.getDebugMessage());
            }
            @Override public void onBillingServiceDisconnected() {
                connected.set(false);
                Log.w(TAG, "billing service disconnected");
                // Lua retries init on its own schedule; reconnect so the retry lands.
                mainHandler.postDelayed(() -> { if (!stopped.get()) connect(); }, 2000L);
            }
        });
    }

    // ── file-drop transport ──────────────────────────────────────────────────

    private final Runnable pollLoop = new Runnable() {
        @Override public void run() {
            if (stopped.get()) return;
            try {
                drainInbox();
            } catch (Throwable t) {
                Log.e(TAG, "poll failed", t);
            }
            pollHandler.postDelayed(this, POLL_MS);
        }
    };

    private void drainInbox() {
        String[] names = inbox.list();
        if (names == null || names.length == 0) return;

        Arrays.sort(names);   // filenames are ordered by construction
        for (String name : names) {
            if (!name.endsWith(".rdy")) continue;

            String stem = name.substring(0, name.length() - 4);
            File body   = new File(inbox, stem + ".json");
            String json = readAll(body);

            // Consume before handling: a message we cannot parse must not be
            // retried forever.
            //noinspection ResultOfMethodCallIgnored
            new File(inbox, name).delete();
            //noinspection ResultOfMethodCallIgnored
            body.delete();

            if (json == null) continue;
            try {
                final JSONObject msg = new JSONObject(json);
                mainHandler.post(() -> handle(msg));   // billing wants the main thread
            } catch (JSONException e) {
                Log.e(TAG, "undecodable request: " + json, e);
            }
        }
    }

    private static String readAll(File f) {
        if (!f.isFile()) return null;
        RandomAccessFile raf = null;
        try {
            raf = new RandomAccessFile(f, "r");
            byte[] buf = new byte[(int) raf.length()];
            raf.readFully(buf);
            return new String(buf, UTF8);
        } catch (IOException e) {
            Log.e(TAG, "read failed: " + f, e);
            return null;
        } finally {
            if (raf != null) try { raf.close(); } catch (IOException ignored) { }
        }
    }

    /** Write a reply body, then its commit marker. Lua only reads committed pairs. */
    private synchronized void reply(JSONObject msg) {
        String stem = String.format("n-%d-%06d", System.currentTimeMillis(), ++replySeq);
        File body   = new File(outbox, stem + ".json");
        File marker = new File(outbox, stem + ".rdy");
        try {
            FileOutputStream out = new FileOutputStream(body);
            out.write(msg.toString().getBytes(UTF8));
            out.flush();
            out.getFD().sync();          // durable before the marker appears
            out.close();

            FileOutputStream mk = new FileOutputStream(marker);
            mk.write('1');
            mk.flush();
            mk.getFD().sync();
            mk.close();
        } catch (IOException e) {
            Log.e(TAG, "reply failed", e);
            //noinspection ResultOfMethodCallIgnored
            body.delete();
        }
    }

    private void replyError(String id, String op, String code, String message) {
        try {
            JSONObject o = new JSONObject();
            if (id != null) o.put("id", id);
            o.put("op", op).put("ok", false).put("code", code).put("message", message);
            reply(o);
        } catch (JSONException e) {
            Log.e(TAG, "replyError failed", e);
        }
    }

    // ── request handling ─────────────────────────────────────────────────────

    private void handle(JSONObject msg) {
        String op = msg.optString("op");
        String id = msg.has("id") ? msg.optString("id") : null;

        if ("init".equals(op))          doInit(id, msg.optJSONArray("products"));
        else if ("purchase".equals(op)) doPurchase(id, msg.optString("sku"));
        else if ("restore".equals(op))  doRestore(id);
        else if ("finish".equals(op))   doFinish(id, msg);
        else Log.w(TAG, "unknown op: " + op);
    }

    private void doInit(final String id, JSONArray products) {
        if (!connected.get()) {
            replyError(id, "init", "billing_unavailable", "Play Billing is not connected");
            connect();
            return;
        }

        productTypes.clear();
        final List<QueryProductDetailsParams.Product> inapp = new ArrayList<>();
        final List<QueryProductDetailsParams.Product> subs  = new ArrayList<>();

        for (int i = 0; products != null && i < products.length(); i++) {
            JSONObject p = products.optJSONObject(i);
            if (p == null) continue;
            String sku  = p.optString("sku");
            String type = p.optString("type", "consumable");
            if (sku.isEmpty()) continue;
            productTypes.put(sku, type);

            boolean isSub = "subscription".equals(type);
            QueryProductDetailsParams.Product entry = QueryProductDetailsParams.Product.newBuilder()
                    .setProductId(sku)
                    .setProductType(isSub ? BillingClient.ProductType.SUBS : BillingClient.ProductType.INAPP)
                    .build();
            (isSub ? subs : inapp).add(entry);
        }

        final JSONArray found = new JSONArray();
        final int[] remaining = { (inapp.isEmpty() ? 0 : 1) + (subs.isEmpty() ? 0 : 1) };
        if (remaining[0] == 0) {
            finishInit(id, found);
            return;
        }

        details.clear();
        for (final List<QueryProductDetailsParams.Product> batch : Arrays.asList(inapp, subs)) {
            if (batch.isEmpty()) continue;
            QueryProductDetailsParams params =
                    QueryProductDetailsParams.newBuilder().setProductList(batch).build();

            billing.queryProductDetailsAsync(params, (result, list) -> {
                if (result.getResponseCode() == BillingClient.BillingResponseCode.OK && list != null) {
                    for (ProductDetails pd : list) {
                        details.put(pd.getProductId(), pd);
                        JSONObject entry = describe(pd);
                        if (entry != null) found.put(entry);
                    }
                } else {
                    Log.w(TAG, "queryProductDetails: " + result.getResponseCode()
                            + " " + result.getDebugMessage());
                }
                if (--remaining[0] == 0) finishInit(id, found);
            });
        }
    }

    private static JSONObject describe(ProductDetails pd) {
        try {
            JSONObject o = new JSONObject();
            o.put("sku", pd.getProductId());
            o.put("title", pd.getTitle());
            o.put("description", pd.getDescription());

            ProductDetails.OneTimePurchaseOfferDetails one = pd.getOneTimePurchaseOfferDetails();
            if (one != null) {
                o.put("price", one.getFormattedPrice());
                o.put("priceAmountMicros", one.getPriceAmountMicros());
                o.put("currency", one.getPriceCurrencyCode());
                return o;
            }

            List<ProductDetails.SubscriptionOfferDetails> offers = pd.getSubscriptionOfferDetails();
            if (offers != null && !offers.isEmpty()) {
                List<ProductDetails.PricingPhase> phases =
                        offers.get(0).getPricingPhases().getPricingPhaseList();
                if (!phases.isEmpty()) {
                    ProductDetails.PricingPhase phase = phases.get(phases.size() - 1);
                    o.put("price", phase.getFormattedPrice());
                    o.put("priceAmountMicros", phase.getPriceAmountMicros());
                    o.put("currency", phase.getPriceCurrencyCode());
                }
            }
            return o;
        } catch (JSONException e) {
            Log.e(TAG, "describe failed", e);
            return null;
        }
    }

    /** Report product details plus everything Play still considers unfinished. */
    private void finishInit(final String id, final JSONArray products) {
        queryOwned((purchases, ok) -> {
            try {
                JSONArray unfinished = new JSONArray();
                for (Purchase p : purchases) {
                    // PENDING purchases carry no entitlement yet; Play delivers
                    // them again once they clear.
                    if (p.getPurchaseState() != Purchase.PurchaseState.PURCHASED) continue;
                    knownPurchases.put(p.getPurchaseToken(), p);
                    for (JSONObject entry : toJson(p, false)) unfinished.put(entry);
                }
                JSONObject o = new JSONObject();
                if (id != null) o.put("id", id);
                o.put("op", "init").put("ok", true)
                 .put("products", products).put("unfinished", unfinished);
                reply(o);
            } catch (JSONException e) {
                replyError(id, "init", "internal", e.getMessage());
            }
        });
    }

    private void doPurchase(final String id, final String sku) {
        ProductDetails pd = details.get(sku);
        if (pd == null) {
            replyError(id, "purchase", "product_unavailable", "No details for " + sku);
            return;
        }

        BillingFlowParams.ProductDetailsParams.Builder pdp =
                BillingFlowParams.ProductDetailsParams.newBuilder().setProductDetails(pd);

        List<ProductDetails.SubscriptionOfferDetails> offers = pd.getSubscriptionOfferDetails();
        if (offers != null && !offers.isEmpty()) {
            pdp.setOfferToken(offers.get(0).getOfferToken());
        }

        BillingFlowParams flow = BillingFlowParams.newBuilder()
                .setProductDetailsParamsList(java.util.Collections.singletonList(pdp.build()))
                .build();

        BillingResult result = billing.launchBillingFlow(activity, flow);
        if (result.getResponseCode() != BillingClient.BillingResponseCode.OK) {
            replyError(id, "purchase", codeFor(result.getResponseCode()), result.getDebugMessage());
        }
        // Success is delivered asynchronously through onPurchasesUpdated.
    }

    private void doRestore(final String id) {
        queryOwned((purchases, ok) -> {
            try {
                JSONArray list = new JSONArray();
                for (Purchase p : purchases) {
                    if (p.getPurchaseState() != Purchase.PurchaseState.PURCHASED) continue;
                    knownPurchases.put(p.getPurchaseToken(), p);
                    for (JSONObject entry : toJson(p, true)) list.put(entry);
                }
                JSONObject o = new JSONObject();
                if (id != null) o.put("id", id);
                o.put("op", "restore").put("ok", ok).put("purchases", list);
                reply(o);
            } catch (JSONException e) {
                replyError(id, "restore", "internal", e.getMessage());
            }
        });
    }

    /**
     * Settle a purchase Lua has already granted: consumables are consumed so
     * they can be bought again, everything else is acknowledged (Play refunds
     * anything left unacknowledged for three days).
     */
    private void doFinish(final String id, JSONObject msg) {
        final String token = msg.optString("token");
        final String txn   = msg.optString("txn");
        final String type  = msg.optString("type", "consumable");

        if (token.isEmpty()) {
            replyError(id, "finish", "no_token", "finish request carried no purchase token");
            return;
        }

        if ("consumable".equals(type)) {
            ConsumeParams params = ConsumeParams.newBuilder().setPurchaseToken(token).build();
            billing.consumeAsync(params, (result, outToken) ->
                    replyFinish(id, txn, result.getResponseCode() == BillingClient.BillingResponseCode.OK
                                    || result.getResponseCode() == BillingClient.BillingResponseCode.ITEM_NOT_OWNED,
                            result));
            return;
        }

        Purchase known = knownPurchases.get(token);
        if (known != null && known.isAcknowledged()) {
            replyFinish(id, txn, true, null);
            return;
        }

        AcknowledgePurchaseParams params = AcknowledgePurchaseParams.newBuilder()
                .setPurchaseToken(token).build();
        billing.acknowledgePurchase(params, result ->
                replyFinish(id, txn, result.getResponseCode() == BillingClient.BillingResponseCode.OK,
                        result));
    }

    private void replyFinish(String id, String txn, boolean ok, BillingResult result) {
        try {
            JSONObject o = new JSONObject();
            if (id != null)  o.put("id", id);
            if (txn != null && !txn.isEmpty()) o.put("txn", txn);
            o.put("op", "finish").put("ok", ok);
            if (!ok && result != null) {
                o.put("code", codeFor(result.getResponseCode()));
                o.put("message", result.getDebugMessage());
            }
            reply(o);
        } catch (JSONException e) {
            Log.e(TAG, "replyFinish failed", e);
        }
    }

    // ── Play callbacks ───────────────────────────────────────────────────────

    @Override
    public void onPurchasesUpdated(@NonNull BillingResult result, List<Purchase> purchases) {
        int code = result.getResponseCode();

        if (code == BillingClient.BillingResponseCode.USER_CANCELED) {
            replyError(null, "purchase", "user_cancelled", "Cancelled by the player");
            return;
        }
        if (code != BillingClient.BillingResponseCode.OK || purchases == null) {
            replyError(null, "purchase", codeFor(code), result.getDebugMessage());
            return;
        }

        for (Purchase p : purchases) {
            if (p.getPurchaseState() == Purchase.PurchaseState.PENDING) {
                try {
                    JSONObject o = new JSONObject();
                    o.put("op", "purchase_deferred");
                    if (!p.getProducts().isEmpty()) o.put("sku", p.getProducts().get(0));
                    reply(o);
                } catch (JSONException ignored) { }
                continue;
            }
            if (p.getPurchaseState() != Purchase.PurchaseState.PURCHASED) continue;

            knownPurchases.put(p.getPurchaseToken(), p);
            for (JSONObject entry : toJson(p, false)) {
                try {
                    reply(new JSONObject().put("op", "purchase").put("ok", true).put("purchase", entry));
                } catch (JSONException e) {
                    Log.e(TAG, "purchase reply failed", e);
                }
            }
        }
    }

    private interface OwnedCallback { void onOwned(List<Purchase> purchases, boolean ok); }

    /** Play keeps INAPP and SUBS in separate ledgers; ask both and merge. */
    private void queryOwned(final OwnedCallback cb) {
        if (!connected.get()) {
            cb.onOwned(new ArrayList<>(), false);
            return;
        }

        final List<Purchase> all = new ArrayList<>();
        final boolean[] ok = { true };
        final int[] remaining = { 2 };

        for (final String type : new String[] { BillingClient.ProductType.INAPP,
                                                BillingClient.ProductType.SUBS }) {
            billing.queryPurchasesAsync(
                    QueryPurchasesParams.newBuilder().setProductType(type).build(),
                    (result, list) -> {
                        if (result.getResponseCode() == BillingClient.BillingResponseCode.OK) {
                            if (list != null) all.addAll(list);
                        } else {
                            ok[0] = false;
                            Log.w(TAG, "queryPurchases(" + type + "): " + result.getDebugMessage());
                        }
                        if (--remaining[0] == 0) cb.onOwned(all, ok[0]);
                    });
        }
    }

    /**
     * A Play purchase can cover several products (multi-line checkout), so this
     * yields one Lua-side purchase per product. The transaction id stays unique
     * per line by suffixing the sku when there is more than one.
     */
    private List<JSONObject> toJson(Purchase p, boolean restored) {
        List<JSONObject> out = new ArrayList<>();
        List<String> skus = p.getProducts();
        String orderId = p.getOrderId();
        if (orderId == null || orderId.isEmpty()) orderId = p.getPurchaseToken();

        for (String sku : skus) {
            try {
                JSONObject o = new JSONObject();
                o.put("sku", sku);
                o.put("txn", skus.size() > 1 ? orderId + ":" + sku : orderId);
                o.put("token", p.getPurchaseToken());
                o.put("payload", p.getOriginalJson());     // verify this server-side
                o.put("signature", p.getSignature());
                o.put("platform", "android");
                o.put("restored", restored);
                out.add(o);
            } catch (JSONException e) {
                Log.e(TAG, "toJson failed", e);
            }
        }
        return out;
    }

    private static String codeFor(int responseCode) {
        switch (responseCode) {
            case BillingClient.BillingResponseCode.USER_CANCELED:        return "user_cancelled";
            case BillingClient.BillingResponseCode.ITEM_ALREADY_OWNED:   return "already_owned";
            case BillingClient.BillingResponseCode.ITEM_UNAVAILABLE:     return "product_unavailable";
            case BillingClient.BillingResponseCode.SERVICE_DISCONNECTED:
            case BillingClient.BillingResponseCode.SERVICE_UNAVAILABLE:  return "service_unavailable";
            case BillingClient.BillingResponseCode.BILLING_UNAVAILABLE:  return "billing_unavailable";
            case BillingClient.BillingResponseCode.NETWORK_ERROR:        return "network_error";
            case BillingClient.BillingResponseCode.DEVELOPER_ERROR:      return "developer_error";
            default:                                                     return "store_error";
        }
    }
}
