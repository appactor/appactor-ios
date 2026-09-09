import Foundation

/// Predefined log categories for the AppActor SDK.
///
/// Use these to route log messages to semantically meaningful categories:
/// ```swift
/// Log.network.info("→ POST /v1/payment/identify")
/// Log.storeKit.debug("Transaction \(txnID) finished")
/// ```
enum Log {
    /// Default / lifecycle (configure, reset, bootstrap).
    static let sdk         = AppActorLogCategory(name: "sdk")
    /// HTTP requests / responses.
    static let network     = AppActorLogCategory(name: "Network")
    /// Identify / login / logout.
    static let identity    = AppActorLogCategory(name: "Identity")
    /// Offerings fetch / cache.
    static let offerings   = AppActorLogCategory(name: "Offerings")
    /// Customer info.
    static let customer    = AppActorLogCategory(name: "Customer")
    /// StoreKit operations.
    static let storeKit    = AppActorLogCategory(name: "StoreKit")
    /// Receipt pipeline.
    static let receipts    = AppActorLogCategory(name: "Receipts")
    /// ETag / disk cache.
    static let cache       = AppActorLogCategory(name: "Cache")
    /// Response signature verification.
    static let signing     = AppActorLogCategory(name: "Signing")
    /// Apple Search Ads attribution.
    static let attribution = AppActorLogCategory(name: "ASA")
    /// Persistence / queue store.
    static let storage     = AppActorLogCategory(name: "Storage")

    /// Random 6-char stamp for request correlation.
    static var stamp: String { AppActorLogger.stamp }

    /// Hierarchical stamp: `"parent/child"` for nested operations.
    static func stamp(parent: String) -> String { AppActorLogger.stamp(parent: parent) }

    /// Check whether a given level is enabled.
    nonisolated static func isLevel(_ level: AppActorLogLevel) -> Bool {
        AppActorLogger.isLevel(level)
    }
}

// MARK: - Hashable Stamp

extension Hashable {
    /// Converts the receiver's hash value into a deterministic 10-char base-62 stamp.
    /// Useful for stable correlation IDs derived from object identity.
    ///
    /// Note: `hashValue` is randomized per process in Swift, so the stamp is only
    /// stable within a single app launch — not across launches.
    var logStamp: String {
        let chars = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")
        // UInt(bitPattern:) avoids abs(Int.min) overflow trap
        var value = UInt(bitPattern: hashValue)
        var result = ""
        result.reserveCapacity(11)
        for i in 0..<10 {
            if i == 5 { result.append("_") }
            result.append(chars[Int(value % 62)])
            value /= 62
        }
        return result
    }
}
