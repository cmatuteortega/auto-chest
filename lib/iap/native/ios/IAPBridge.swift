//
//  IAPBridge.swift
//  Native half of lib/iap for iOS — StoreKit 2 behind the file-drop protocol
//  the Lua module speaks.
//
//  Integration (see INTEGRATION.md for the full walk-through):
//
//    1. Add this file to the love-ios Xcode project (target: love-ios).
//    2. Add the In-App Purchase capability and the StoreKit framework.
//    3. In AppDelegate.application(_:didFinishLaunchingWithOptions:):
//           IAPBridge.shared.start(loveIdentity: "your_love_identity")
//
//  Requires iOS 15+ (StoreKit 2). Nothing in LÖVE itself needs patching: the
//  two halves only ever meet through files in the game's save directory.
//

import Foundation
import StoreKit

@available(iOS 15.0, *)
public final class IAPBridge {

    public static let shared = IAPBridge()

    private let bridgeDirName = "iap_bridge"
    private let pollInterval: TimeInterval = 0.25

    private var inbox: URL!      // to_native — written by Lua
    private var outbox: URL!     // to_lua    — written by us

    private let queue = DispatchQueue(label: "iap.bridge", qos: .utility)
    private var pollTimer: DispatchSourceTimer?
    private var updatesTask: Task<Void, Never>?

    /// productID -> Product, refreshed on every init.
    private var products: [String: Product] = [:]
    /// Lua's declared type per productID, so finish() knows consume vs. acknowledge.
    private var productTypes: [String: String] = [:]
    /// transaction id (as string) -> Transaction, so a finish request can find it.
    private var liveTransactions: [String: Transaction] = [:]

    private var replySeq: UInt64 = 0
    private var started = false

    private init() {}

    // MARK: - Lifecycle

    public func start(loveIdentity: String) {
        guard !started else { return }
        started = true

        let base = IAPBridge.resolveBridgeDir(loveIdentity: loveIdentity,
                                              dirName: bridgeDirName)
        inbox  = base.appendingPathComponent("to_native")
        outbox = base.appendingPathComponent("to_lua")
        try? FileManager.default.createDirectory(at: inbox,  withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: outbox, withIntermediateDirectories: true)
        NSLog("[IAPBridge] bridge directory: %@", base.path)

        // Transactions can arrive with no purchase in flight: Ask to Buy being
        // approved, a purchase made on another device, a subscription renewing.
        updatesTask = Task.detached(priority: .background) { [weak self] in
            for await result in Transaction.updates {
                await self?.deliver(result, restored: false)
            }
        }

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: pollInterval)
        timer.setEventHandler { [weak self] in self?.drainInbox() }
        timer.resume()
        pollTimer = timer
    }

    public func stop() {
        pollTimer?.cancel(); pollTimer = nil
        updatesTask?.cancel(); updatesTask = nil
        started = false
    }

    /// LÖVE for iOS keeps save files under `Documents/save/<identity>`. Older
    /// builds used `Library/Application Support/LOVE/<identity>`. Both are
    /// checked; if neither exists yet the Documents location is created and Lua
    /// meets us there. This is the only place the path is decided.
    private static func resolveBridgeDir(loveIdentity: String, dirName: String) -> URL {
        let fm = FileManager.default
        var candidates: [URL] = []

        if let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first {
            candidates.append(docs.appendingPathComponent("save/\(loveIdentity)/\(dirName)"))
            candidates.append(docs.appendingPathComponent("\(loveIdentity)/\(dirName)"))
        }
        if let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            candidates.append(support.appendingPathComponent("LOVE/\(loveIdentity)/\(dirName)"))
        }

        for url in candidates where fm.fileExists(atPath: url.path) { return url }
        return candidates.first!
    }

    // MARK: - File-drop transport

    private func drainInbox() {
        guard let inbox = inbox else { return }
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: inbox.path) else { return }

        // Filenames are ordered by construction, so sorting preserves send order.
        for name in names.sorted() where name.hasSuffix(".rdy") {
            let stem   = String(name.dropLast(4))
            let body   = inbox.appendingPathComponent("\(stem).json")
            let data   = try? Data(contentsOf: body)

            // Consume before handling: a message we cannot parse must not be
            // retried forever.
            try? fm.removeItem(at: inbox.appendingPathComponent(name))
            try? fm.removeItem(at: body)

            guard let data = data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                NSLog("[IAPBridge] undecodable request: %@", stem)
                continue
            }
            Task { await handle(obj) }
        }
    }

    /// Write a reply body, then its commit marker. Lua only reads committed pairs.
    private func reply(_ msg: [String: Any]) {
        queue.async {
            self.replySeq += 1
            let stem = String(format: "n-%.0f-%06llu",
                              Date().timeIntervalSince1970 * 1000, self.replySeq)
            let body   = self.outbox.appendingPathComponent("\(stem).json")
            let marker = self.outbox.appendingPathComponent("\(stem).rdy")
            do {
                let data = try JSONSerialization.data(withJSONObject: msg)
                try data.write(to: body, options: .atomic)
                try Data("1".utf8).write(to: marker, options: .atomic)
            } catch {
                NSLog("[IAPBridge] reply failed: %@", String(describing: error))
                try? FileManager.default.removeItem(at: body)
            }
        }
    }

    private func replyError(id: String?, op: String, code: String, message: String) {
        var msg: [String: Any] = ["op": op, "ok": false, "code": code, "message": message]
        if let id = id { msg["id"] = id }
        reply(msg)
    }

    // MARK: - Request handling

    private func handle(_ msg: [String: Any]) async {
        let op = msg["op"] as? String ?? ""
        let id = msg["id"] as? String

        switch op {
        case "init":     await doInit(id: id, products: msg["products"] as? [[String: Any]] ?? [])
        case "purchase": await doPurchase(id: id, sku: msg["sku"] as? String ?? "")
        case "restore":  await doRestore(id: id)
        case "finish":   await doFinish(id: id, msg: msg)
        default:         NSLog("[IAPBridge] unknown op: %@", op)
        }
    }

    private func doInit(id: String?, products declared: [[String: Any]]) async {
        productTypes.removeAll()
        var ids: [String] = []
        for entry in declared {
            guard let sku = entry["sku"] as? String, !sku.isEmpty else { continue }
            ids.append(sku)
            productTypes[sku] = entry["type"] as? String ?? "consumable"
        }

        var details: [[String: Any]] = []
        do {
            let fetched = try await Product.products(for: ids)
            self.products = Dictionary(uniqueKeysWithValues: fetched.map { ($0.id, $0) })
            details = fetched.map { product in
                [
                    "sku": product.id,
                    "price": product.displayPrice,
                    "priceAmountMicros": NSDecimalNumber(decimal: product.price * 1_000_000).int64Value,
                    "currency": product.priceFormatStyle.currencyCode,
                    "title": product.displayName,
                    "description": product.description,
                ]
            }
        } catch {
            replyError(id: id, op: "init", code: "service_unavailable",
                       message: String(describing: error))
            return
        }

        // Anything StoreKit still considers unfinished is money we may owe the
        // player: hand it to Lua, which grants it and then asks us to finish.
        var unfinished: [[String: Any]] = []
        for await result in Transaction.unfinished {
            if let entry = record(result, restored: false) { unfinished.append(entry) }
        }

        var msg: [String: Any] = ["op": "init", "ok": true,
                                  "products": details, "unfinished": unfinished]
        if let id = id { msg["id"] = id }
        reply(msg)
    }

    private func doPurchase(id: String?, sku: String) async {
        guard let product = products[sku] else {
            replyError(id: id, op: "purchase", code: "product_unavailable",
                       message: "No product details for \(sku)")
            return
        }

        do {
            switch try await product.purchase() {
            case .success(let verification):
                guard let entry = record(verification, restored: false) else {
                    // StoreKit could not verify its own signature — do not
                    // finish it, and never grant it.
                    replyError(id: id, op: "purchase", code: "invalid_receipt",
                               message: "Transaction failed StoreKit verification")
                    return
                }
                reply(["op": "purchase", "ok": true, "purchase": entry])

            case .userCancelled:
                replyError(id: id, op: "purchase", code: "user_cancelled",
                           message: "Cancelled by the player")

            case .pending:
                // Ask to Buy / SCA: nothing yet, it arrives via Transaction.updates.
                reply(["op": "purchase_deferred", "sku": sku])

            @unknown default:
                replyError(id: id, op: "purchase", code: "store_error",
                           message: "Unknown StoreKit result")
            }
        } catch {
            replyError(id: id, op: "purchase", code: "store_error",
                       message: String(describing: error))
        }
    }

    private func doRestore(id: String?) async {
        // Pull anything the account is entitled to. syncing first makes the
        // "Restore Purchases" button behave the way reviewers expect.
        try? await AppStore.sync()

        var list: [[String: Any]] = []
        for await result in Transaction.currentEntitlements {
            if let entry = record(result, restored: true) { list.append(entry) }
        }

        var msg: [String: Any] = ["op": "restore", "ok": true, "purchases": list]
        if let id = id { msg["id"] = id }
        reply(msg)
    }

    /// Lua has granted the purchase; tell StoreKit we are done with it.
    /// StoreKit 2 makes no consume/acknowledge distinction — finish() covers both.
    private func doFinish(id: String?, msg: [String: Any]) async {
        let token = msg["token"] as? String ?? ""
        let txn   = msg["txn"] as? String

        var finished = false
        if let transaction = liveTransactions[token] {
            await transaction.finish()
            liveTransactions.removeValue(forKey: token)
            finished = true
        } else {
            // Not in memory (a relaunch, say): find it among the unfinished set.
            for await result in Transaction.unfinished {
                if case .verified(let transaction) = result,
                   String(transaction.id) == token {
                    await transaction.finish()
                    finished = true
                    break
                }
            }
            // Nothing left to finish is success as far as Lua is concerned.
            if !finished { finished = true }
        }

        var out: [String: Any] = ["op": "finish", "ok": finished]
        if let id = id   { out["id"] = id }
        if let txn = txn { out["txn"] = txn }
        reply(out)
    }

    // MARK: - Transactions

    private func deliver(_ result: VerificationResult<Transaction>, restored: Bool) async {
        guard let entry = record(result, restored: restored) else {
            NSLog("[IAPBridge] dropped an unverified transaction")
            return
        }
        reply(["op": "purchase", "ok": true, "purchase": entry])
    }

    /// Turn a verified StoreKit transaction into the Lua-side purchase shape.
    /// Unverified results return nil: they are never granted and never finished.
    private func record(_ result: VerificationResult<Transaction>,
                        restored: Bool) -> [String: Any]? {
        guard case .verified(let transaction) = result else { return nil }

        let token = String(transaction.id)
        liveTransactions[token] = transaction

        return [
            "sku": transaction.productID,
            "txn": token,
            "token": token,
            // The signed JWS. Send this to your own server and verify it there
            // with the App Store Server API — never trust the device.
            "payload": result.jwsRepresentation,
            "signature": "",
            "platform": "ios",
            "restored": restored,
        ]
    }
}
