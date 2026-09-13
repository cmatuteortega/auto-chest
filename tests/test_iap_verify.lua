-- tests/test_iap_verify.lua
-- Exercises server/iap_verify.lua against a real RSA keypair, signing payloads
-- the way Google Play does (RSA-SHA1 over the purchase JSON, base64 signature).
--
-- Run with:  lua tests/test_iap_verify.lua   (from the project root; needs openssl)

package.path = package.path .. ";./?.lua;./?/init.lua"

local json = require("lib.json")

local passed, failed = 0, 0
local function check(cond, label)
    if cond then passed = passed + 1
    else failed = failed + 1; print("  FAIL: " .. label) end
end
local function eq(got, want, label)
    if got == want then passed = passed + 1
    else failed = failed + 1
         print(string.format("  FAIL: %s (got %s, want %s)", label, tostring(got), tostring(want))) end
end

-- ── build a throwaway Play-style keypair ─────────────────────────────────────

local TMP = os.getenv("TMPDIR") or "/tmp"
local KEY = TMP .. "/iap_test_key.pem"
local PUB = TMP .. "/iap_test_pub.pem"

os.execute(string.format("openssl genrsa -out %q 2048 2>/dev/null", KEY))
os.execute(string.format("openssl rsa -in %q -pubout -out %q 2>/dev/null", KEY, PUB))

-- Play Console shows the key as one base64 line (the PEM body, no headers).
local function readPublicKeyBase64()
    local f = assert(io.open(PUB, "r"))
    local pem = f:read("*a"); f:close()
    return (pem:gsub("%-%-%-%-%-[^\n]*%-%-%-%-%-", ""):gsub("%s", ""))
end

local PUBLIC_KEY_B64 = readPublicKeyBase64()

--- Sign a payload exactly as Play does: RSA-SHA1, base64-encoded.
local function sign(payload)
    local dataFile = TMP .. "/iap_test_payload.json"
    local sigFile  = TMP .. "/iap_test_sig.bin"
    local f = assert(io.open(dataFile, "wb")); f:write(payload); f:close()
    os.execute(string.format("openssl dgst -sha1 -sign %q -out %q %q", KEY, sigFile, dataFile))
    local p = io.popen(string.format("openssl base64 -A -in %q", sigFile))
    local sig = p:read("*a"); p:close()
    os.remove(dataFile); os.remove(sigFile)
    return (sig:gsub("%s", ""))
end

local PACKAGE = "com.yourstudio.autochest"

local function makePayload(overrides)
    local t = {
        orderId       = "GPA.3311-0000-1111-22222",
        packageName   = PACKAGE,
        productId     = "coins_1000",
        purchaseTime  = 1700000000000,
        purchaseState = 0,
        purchaseToken = "abcdefghijklmnop",
    }
    for k, v in pairs(overrides or {}) do t[k] = v end
    return json.encode(t)
end

-- ── tests ────────────────────────────────────────────────────────────────────

print("\n=== server/iap_verify tests ===\n")

local V = require("server.iap_verify")
V.config.playPublicKey  = PUBLIC_KEY_B64
V.config.androidPackage = PACKAGE
V.config.allowUnverified = false

print("• a genuine Play receipt verifies")
do
    local payload = makePayload()
    local ok, code = V.verify("android", payload, sign(payload), "coins_1000")
    eq(ok, true, "genuine receipt accepted (" .. tostring(code) .. ")")
end

print("• a tampered payload is rejected permanently")
do
    local payload = makePayload()
    local signature = sign(payload)
    -- Same signature, payload edited to claim a bigger product.
    local tampered = payload:gsub("coins_1000", "coins_9999")
    local ok, code, _, permanent = V.verify("android", tampered, signature, "coins_9999")
    eq(ok, false, "tampered payload refused")
    eq(code, "bad_signature", "reported as a signature failure")
    eq(permanent, true, "permanent — the client must stop retrying")
end

print("• a receipt signed by the wrong key is rejected")
do
    local payload = makePayload()
    local signature = sign(payload)
    local other = TMP .. "/iap_other.pem"
    os.execute(string.format("openssl genrsa -out %q 2048 2>/dev/null", other))
    os.execute(string.format("openssl rsa -in %q -pubout -out %q 2>/dev/null", other, PUB))
    local wrongKey = readPublicKeyBase64()
    local saved = V.config.playPublicKey
    V.config.playPublicKey = wrongKey
    local ok, code = V.verify("android", payload, signature, "coins_1000")
    eq(ok, false, "foreign signature refused")
    eq(code, "bad_signature", "reported as a signature failure")
    V.config.playPublicKey = saved
    os.remove(other)
end

print("• a valid receipt for another product is rejected")
do
    local payload = makePayload({ productId = "coins_500" })
    local ok, code, _, permanent = V.verify("android", payload, sign(payload), "coins_1000")
    eq(ok, false, "product mismatch refused")
    eq(code, "wrong_product", "reported as a product mismatch")
    eq(permanent, true, "permanent")
end

print("• a valid receipt from another app is rejected")
do
    local payload = makePayload({ packageName = "com.someoneelse.game" })
    local ok, code = V.verify("android", payload, sign(payload), "coins_1000")
    eq(ok, false, "package mismatch refused")
    eq(code, "wrong_package", "reported as a package mismatch")
end

print("• a cancelled or pending purchase is not credited")
do
    for _, state in ipairs({ 1, 2 }) do
        local payload = makePayload({ purchaseState = state })
        local ok, code = V.verify("android", payload, sign(payload), "coins_1000")
        eq(ok, false, "purchaseState=" .. state .. " refused")
        eq(code, "not_purchased", "reported as not purchased")
    end
end

print("• a missing signature is rejected")
do
    local payload = makePayload()
    local ok, code = V.verify("android", payload, nil, "coins_1000")
    eq(ok, false, "unsigned receipt refused")
    eq(code, "no_signature", "reported as missing signature")
end

print("• an unconfigured server refuses, but only transiently")
do
    local saved = V.config.playPublicKey
    V.config.playPublicKey = nil
    local payload = makePayload()
    local ok, code, _, permanent = V.verify("android", payload, sign(payload), "coins_1000")
    eq(ok, false, "no key configured -> refused")
    eq(code, "not_configured", "reported as misconfiguration")
    eq(permanent, false, "transient, so a paid-for purchase is not destroyed")
    V.config.playPublicKey = saved
end

print("• unverified receipts are refused unless dev mode is on")
do
    local ok = V.verify("mock", "{}", "", "coins_1000")
    eq(ok, false, "mock receipt refused by default")

    V.config.allowUnverified = true
    local ok2 = V.verify("mock", "{}", "", "coins_1000")
    eq(ok2, true, "mock receipt accepted in dev mode")
    V.config.allowUnverified = false
end

print("• iOS refuses transiently until verification is implemented")
do
    local ok, code, _, permanent = V.verify("ios", "aaa.bbb.ccc", "", "coins_1000")
    eq(ok, false, "iOS receipt refused")
    eq(code, "not_configured", "reported as not configured")
    eq(permanent, false, "transient, so the purchase survives")
end

print("• an unknown platform is refused")
do
    local ok, code = V.verify("windows_store", "{}", "", "coins_1000")
    eq(ok, false, "unknown platform refused")
    eq(code, "unknown_platform", "reported as unknown platform")
end

os.remove(KEY); os.remove(PUB)

print(string.format("\n=== %d passed, %d failed ===\n", passed, failed))
os.exit(failed == 0 and 0 or 1)
