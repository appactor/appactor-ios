import Foundation

/// A receipt queued for server-side validation via `PaymentProcessor`.
///
/// Each item tracks its processing phase, retry metadata, and origin sources.
/// The `key` serves as a globally unique idempotency key in the format
/// `"apple:<transactionId>"`.
struct AppActorPaymentQueueItem: Codable, Sendable {

    // MARK: - Identity

    /// Idempotency key: `"apple:<transactionId>"`.
    let key: String

    /// The app's bundle identifier.
    let bundleId: String

    /// `"sandbox"`, `"production"`, or `"unknown"` when no reliable signal is available.
    let environment: String

    /// The StoreKit transaction ID (UInt64 encoded as String).
    let transactionId: String

    // MARK: - Payload

    /// The JWS-signed transaction info. Updated on re-enqueue if a newer JWS is available.
    var jws: String

    /// The app user ID at the time of the transaction.
    let appUserId: String

    /// The product identifier.
    let productId: String

    /// The original transaction ID for subscription renewals.
    let originalTransactionId: String?

    /// ISO 3166-1 alpha-3 storefront code, if available.
    let storefront: String?

    // MARK: - Purchase Context (Analytics Attribution)

    /// The offering that contained the purchased package. `nil` for non-package purchases
    /// (direct `Product` purchase, restore, sweep) or items persisted before this field was added.
    /// Mutable so `mergeFrom` can adopt non-nil context from a richer incoming item.
    var offeringId: String?

    /// The package identifier within the offering. `nil` for non-package purchases
    /// or items persisted before this field was added.
    var packageId: String?

    // MARK: - Phase State Machine

    /// Current processing phase.
    var phase: Phase

    /// Number of POST attempts made.
    var attemptCount: Int

    /// When the next retry should be attempted.
    var nextRetryAt: Date

    /// When this item was first created.
    let firstSeenAt: Date

    /// When this item was last updated (enqueue, retry, etc.).
    var lastSeenAt: Date

    /// The last error message, if any.
    var lastError: String?

    /// Which code paths enqueued this item.
    var sources: Set<Source>

    /// When this item was claimed for processing. Used for stale claim detection.
    var claimedAt: Date?

    // MARK: - Phase Enum

    /// Processing phases for the payment queue state machine.
    ///
    /// ```
    /// needsPost ──► posting ──► needsFinish ──► (removed)
    ///     ▲             │
    ///     └─ retryable ─┘
    ///
    /// needsPost ──► posting ──► deadLettered (after maxRetryAttempts)
    /// ```
    enum Phase: String, Codable, Sendable {
        /// Ready for POST (or waiting for backoff to expire).
        case needsPost
        /// Claimed and currently being POSTed.
        case posting
        /// POST succeeded or permanently rejected; transaction needs `.finish()`.
        case needsFinish
        /// Exhausted all retry attempts.
        case deadLettered
    }

    // MARK: - Source Enum

    /// Origin of the queue item — tracks which code path enqueued it.
    enum Source: String, Codable, Sendable {
        /// Enqueued from an explicit `purchase()` call.
        case purchase
        /// Enqueued from `Transaction.updates` listener.
        case transactionUpdates
        /// Enqueued from `restorePurchases()` / `scanCurrentEntitlements()`.
        case restore
        /// Enqueued from `sweepUnfinished()` at app launch.
        case sweep
    }

    // MARK: - Key Construction

    /// Idempotency key: `"apple:<transactionId>"`.
    static func makeKey(transactionId: String) -> String {
        "apple:\(transactionId)"
    }

    // MARK: - Merge

    /// Merges an incoming item (e.g. from sweepUnfinished re-enqueue) into this existing item.
    /// Updates JWS and sources; resets dead-lettered items for a fresh retry cycle.
    mutating func mergeFrom(_ incoming: AppActorPaymentQueueItem) {
        jws = incoming.jws
        sources = sources.union(incoming.sources)
        lastSeenAt = incoming.lastSeenAt
        // Prefer non-nil purchase context from the richer source (e.g. purchase flow
        // re-enqueuing an item that arrived earlier via sweep with nil context).
        if offeringId == nil { offeringId = incoming.offeringId }
        if packageId == nil { packageId = incoming.packageId }
        if phase == .deadLettered {
            phase = .needsPost
            attemptCount = 0
            nextRetryAt = incoming.nextRetryAt
            claimedAt = nil
        }
    }
}
