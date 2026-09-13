-- server/iap_verify.lua
-- Receipt verification for in-app purchases.
--
-- The client is not trusted. Anyone can connect to the ENet port and send a
-- `verify_purchase` message with whatever payload they like, so this module is
-- the only thing standing between a crafted message and free coins.
--
-- Android is verified offline: Google Play signs the purchase JSON with your
-- app's RSA private key and publishes the matching public key in Play Console,
-- so an `openssl dgst -sha1 -verify` is a complete check with no network call
-- and no OAuth. That is the baseline every Play integration should have.
--
-- iOS ships unconfigured on purpose — see verifyIOS() below.
--
-- Configuration (environment variables, read once at load):
--
--   AUTOCHEST_PLAY_PUBLIC_KEY     base64 RSA key from Play Console →
--                                 Monetise → Licensing. One long line.
--   AUTOCHEST_ANDROID_PACKAGE     com.cmatute.tinyturf for this app. The payload's
--                                 packageName must match.
--   AUTOCHEST_IAP_ALLOW_UNVERIFIED
--                                 "true" accepts receipts without checking the
--                                 signature. Local development only — it makes
--                                 coins free for anyone who can reach the port.

local json = require("lib.json")

local M = {}

M.config = {
    playPublicKey   = os.getenv("AUTOCHEST_PLAY_PUBLIC_KEY"),
    androidPackage  = os.getenv("AUTOCHEST_ANDROID_PACKAGE"),
    allowUnverified = os.getenv("AUTOCHEST_IAP_ALLOW_UNVERIFIED") == "true",
}

-- Result helpers. `permanent` tells the client whether to stop retrying:
-- a bad signature never becomes good, a misconfigured server might.
local function ok()                         return true                              end
local function reject(code, msg)            return false, code, msg, true            end
local function retry(code, msg)             return false, code, msg, false           end

-- ── openssl plumbing ──────────────────────────────────────────────────────────

local function writeFile(path, data)
    local f = io.open(path, "wb")
    if not f then return false end
    f:write(data)
    f:close()
    return true
end

local function removeAll(paths)
    for _, p in ipairs(paths) do os.remove(p) end
end

--- Wrap Play Console's single-line base64 key as a PEM SubjectPublicKeyInfo.
local function toPem(base64Key)
    local body = base64Key:gsub("%s", "")
    local lines = {}
    for i = 1, #body, 64 do lines[#lines + 1] = body:sub(i, i + 63) end
    return "-----BEGIN PUBLIC KEY-----\n"
        .. table.concat(lines, "\n")
        .. "\n-----END PUBLIC KEY-----\n"
end

--- Verify an RSA-SHA1 signature over `data`. Returns true only on an explicit
--  "Verified OK" from openssl — any error path is a failure, never a pass.
local function rsaVerifySha1(data, signatureB64, publicKeyB64)
    local stem    = os.tmpname()
    local fData   = stem .. ".data"
    local fSigB64 = stem .. ".sig.b64"
    local fSigBin = stem .. ".sig.bin"
    local fKey    = stem .. ".pem"
    local temps   = { stem, fData, fSigB64, fSigBin, fKey }

    if not (writeFile(fData, data)
        and writeFile(fSigB64, signatureB64)
        and writeFile(fKey, toPem(publicKeyB64))) then
        removeAll(temps)
        return false, "could not write temp files"
    end

    -- Signature arrives base64-encoded; openssl dgst wants raw bytes.
    local decode = io.popen(string.format(
        "openssl base64 -d -A -in %q -out %q 2>&1", fSigB64, fSigBin))
    local decodeOut = decode and decode:read("*a") or ""
    local decodeOk  = decode and decode:close()
    if not decodeOk then
        removeAll(temps)
        return false, "signature is not valid base64: " .. tostring(decodeOut)
    end

    local pipe = io.popen(string.format(
        "openssl dgst -sha1 -verify %q -signature %q %q 2>&1", fKey, fSigBin, fData))
    local out = pipe and pipe:read("*a") or ""
    if pipe then pipe:close() end
    removeAll(temps)

    if out:find("Verified OK", 1, true) then return true end
    return false, (out:gsub("%s+$", ""))
end

-- ── Android ───────────────────────────────────────────────────────────────────

-- payload is Play's `originalJson`, signature its base64 RSA signature.
local function verifyAndroid(payload, signature, expectedSku)
    if type(payload) ~= "string" or payload == "" then
        return reject("no_payload", "Purchase carried no receipt")
    end

    if not M.config.playPublicKey or M.config.playPublicKey == "" then
        if M.config.allowUnverified then
            print("[IAP] *** UNVERIFIED *** accepting Android receipt with no public key configured")
        else
            -- Transient on purpose: a server misconfiguration must not destroy
            -- a purchase the player already paid for. They keep their receipt,
            -- the client keeps retrying, and it lands once the key is set.
            print("[IAP] AUTOCHEST_PLAY_PUBLIC_KEY is not set — refusing to credit")
            return retry("not_configured", "Store verification is unavailable, please try again later")
        end
    else
        if type(signature) ~= "string" or signature == "" then
            return reject("no_signature", "Purchase carried no signature")
        end
        local verified, why = rsaVerifySha1(payload, signature, M.config.playPublicKey)
        if not verified then
            print("[IAP] signature check FAILED: " .. tostring(why))
            return reject("bad_signature", "This purchase could not be verified")
        end
    end

    local decoded
    local decodeOk, err = pcall(function() decoded = json.decode(payload) end)
    if not decodeOk or type(decoded) ~= "table" then
        return reject("bad_payload", "Malformed receipt: " .. tostring(err))
    end

    -- A signature only proves Play signed *something* for this app. These
    -- checks prove it is the thing we are about to pay out for.
    if M.config.androidPackage and M.config.androidPackage ~= ""
       and decoded.packageName ~= M.config.androidPackage then
        return reject("wrong_package", "Receipt is for a different app")
    end

    if expectedSku and decoded.productId ~= expectedSku then
        return reject("wrong_product", "Receipt is for a different product")
    end

    -- 0 = purchased, 1 = cancelled, 2 = pending.
    if decoded.purchaseState ~= nil and decoded.purchaseState ~= 0 then
        return reject("not_purchased", "This purchase has not completed")
    end

    return ok()
end

-- ── iOS ───────────────────────────────────────────────────────────────────────

--- StoreKit 2 hands us a signed JWS. Verifying it properly means checking the
--  ES256 signature against the x5c chain in its header and anchoring that chain
--  to Apple's root CA — or, more simply, calling the App Store Server API and
--  letting Apple answer.
--
--  Neither is implemented here, so iOS receipts are refused unless
--  AUTOCHEST_IAP_ALLOW_UNVERIFIED is set. Refusing is the safe default:
--  accepting an unverified JWS would make coins free on iOS.
--
--  The refusal is transient, so a player who paid keeps their receipt and gets
--  their coins as soon as this is implemented.
local function verifyIOS(payload, _signature, expectedSku)
    if type(payload) ~= "string" or payload == "" then
        return reject("no_payload", "Purchase carried no receipt")
    end

    -- Decode the middle JWS segment for logging and product matching. This is
    -- informational only — an attacker can write anything here.
    local claims = nil
    local segment = payload:match("^[^%.]+%.([^%.]+)%.")
    if segment then
        local b64 = segment:gsub("-", "+"):gsub("_", "/")
        b64 = b64 .. string.rep("=", (4 - #b64 % 4) % 4)
        local pipe = io.popen(string.format("printf %%s %q | openssl base64 -d -A 2>/dev/null", b64))
        local raw  = pipe and pipe:read("*a") or ""
        if pipe then pipe:close() end
        if raw ~= "" then
            pcall(function() claims = json.decode(raw) end)
        end
    end

    if M.config.allowUnverified then
        print("[IAP] *** UNVERIFIED *** accepting iOS receipt (dev mode)")
        if expectedSku and type(claims) == "table"
           and claims.productId and claims.productId ~= expectedSku then
            return reject("wrong_product", "Receipt is for a different product")
        end
        return ok()
    end

    print("[IAP] iOS verification is not implemented — refusing to credit "
        .. tostring(claims and claims.productId or "?"))
    return retry("not_configured", "Store verification is unavailable, please try again later")
end

-- ── entry point ───────────────────────────────────────────────────────────────

--- Verify a receipt.
--  Returns: ok(boolean), code(string|nil), message(string|nil), permanent(boolean)
--  `permanent` true means the receipt will never verify — the client should
--  stop retrying. False means try again later.
function M.verify(platform, payload, signature, expectedSku)
    if platform == "android" then
        return verifyAndroid(payload, signature, expectedSku)
    elseif platform == "ios" then
        return verifyIOS(payload, signature, expectedSku)
    elseif platform == "mock" then
        -- Desktop builds running lib/iap's mock store.
        if M.config.allowUnverified then
            print("[IAP] *** UNVERIFIED *** accepting mock receipt (dev mode)")
            return ok()
        end
        return reject("mock_rejected", "Test purchases are not accepted by this server")
    end
    return reject("unknown_platform", "Unknown store platform: " .. tostring(platform))
end

function M.describe()
    local parts = {}
    parts[#parts + 1] = "android=" ..
        ((M.config.playPublicKey and M.config.playPublicKey ~= "") and "key set" or "NO KEY")
    parts[#parts + 1] = "package=" .. tostring(M.config.androidPackage or "unset")
    parts[#parts + 1] = "ios=not implemented"
    if M.config.allowUnverified then parts[#parts + 1] = "ALLOW_UNVERIFIED" end
    return table.concat(parts, ", ")
end

return M
