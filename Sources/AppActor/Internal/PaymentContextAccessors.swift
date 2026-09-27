import Foundation

// MARK: - Payment Lifecycle State

/// Explicit lifecycle state machine for payment mode.
///
/// Transitions:
/// - `.idle` → `.configured` (via `configure()`)
/// - `.configured` → `.resetting` (via `reset()`)
/// - `.resetting` → `.idle` (when `reset()` completes)
///
/// Invalid transitions (guarded):
/// - `.configured` → `.configured` (must reset first)
/// - `.resetting` → `.configured` (must wait for reset to finish)
enum AppActorPaymentLifecycle: Sendable {
    case idle
    case configured
    case resetting
}

// MARK: - Payment State Accessors (delegating to PaymentContext)

extension AppActor {
    var paymentLifecycle: AppActorPaymentLifecycle {
        get { paymentContext.lifecycle }
        set {
            paymentContext.lifecycle = newValue
            AppActorPaymentContext._lifecycle = newValue
            if newValue == .configured {
                paymentContext.sessionGeneration &+= 1
            }
        }
    }

    /// Identifies the configured session; it advances each time the lifecycle becomes
    /// `.configured`. Work that awaits captures it and checks ``isSessionCurrent(_:)`` before it
    /// writes, so a result that lands after `reset()` (or a cancelled startup) never reaches
    /// storage or the session configured after it.
    var sessionGeneration: UInt64 { paymentContext.sessionGeneration }

    func isSessionCurrent(_ generation: UInt64) -> Bool {
        paymentLifecycle == .configured && paymentContext.sessionGeneration == generation
    }

    /// Runs `read` for the current user and returns what it read, once the session and the user
    /// are still the ones it ran for; `publish` runs then too, with no suspension in between.
    ///
    /// A logIn, logOut or reset() can land while the read is in flight. Its result is then the
    /// previous user's, entitlement-targeted values included: it is neither published nor
    /// returned, and the read runs again for whoever is current (or throws after a reset). It
    /// also runs again when a cache clear cancelled it (identity switches and entitlement changes
    /// do that), unless the caller itself was cancelled. Android's `executeGuardedRead`.
    func guardedRead<Value>(
        _ read: (_ appUserId: String?) async throws -> (Value, requestId: String?),
        publish: (Value) -> Void = { _ in }
    ) async throws -> Value {
        // One logIn can cancel a read up to four times (its clears, the switch, the entitlement
        // change); the bound only stops a pathological loop.
        for _ in 0..<5 {
            guard paymentLifecycle == .configured else { throw AppActorError.notConfigured }
            let session = sessionGeneration
            let appUserId = paymentStorage?.currentAppUserId
            let value: Value
            let requestId: String?
            do {
                (value, requestId) = try await read(appUserId)
            } catch is CancellationError where !Task.isCancelled {
                continue
            }
            guard isSessionCurrent(session), paymentStorage?.currentAppUserId == appUserId else { continue }

            publish(value)
            if let requestId {
                paymentStorage?.setLastRequestId(requestId)
            }
            return value
        }
        throw AppActorError.stateChangedDuringOperation
    }

    var paymentConfig: AppActorPaymentConfiguration? {
        get { paymentContext.config }
        set { paymentContext.config = newValue }
    }

    var paymentStorage: (any AppActorPaymentStorage)? {
        get { paymentContext.storage }
        set {
            paymentContext.storage = newValue
            AppActorPaymentContext._storage = newValue
        }
    }

    var paymentClient: (any AppActorPaymentClientProtocol)? {
        get { paymentContext.client }
        set { paymentContext.client = newValue }
    }

    var paymentETagManager: AppActorETagManager? {
        get { paymentContext.etagManager }
        set { paymentContext.etagManager = newValue }
    }

    var lifecycleObservers: [NSObjectProtocol] {
        get { paymentContext.lifecycleObservers }
        set { paymentContext.lifecycleObservers = newValue }
    }

    var asaTask: Task<Void, Never>? {
        get { paymentContext.asaTask }
        set { paymentContext.asaTask = newValue }
    }

    var foregroundTask: Task<Void, Never>? {
        get { paymentContext.foregroundTask }
        set { paymentContext.foregroundTask = newValue }
    }

    var stalenessTimerTask: Task<Void, Never>? {
        get { paymentContext.stalenessTimerTask }
        set { paymentContext.stalenessTimerTask = newValue }
    }

    var offeringsPrefetchTask: Task<Void, Never>? {
        get { paymentContext.offeringsPrefetchTask }
        set { paymentContext.offeringsPrefetchTask = newValue }
    }

    var profileContextSyncTask: Task<Void, Never>? {
        get { paymentContext.profileContextSyncTask }
        set { paymentContext.profileContextSyncTask = newValue }
    }

    var asaManager: AppActorASAManager? {
        get { paymentContext.asaManager }
        set { paymentContext.asaManager = newValue }
    }

    var storeKitSilentSyncFetcher: (any AppActorStoreKitSilentSyncFetcherProtocol)? {
        get { paymentContext.storeKitSilentSyncFetcher }
        set { paymentContext.storeKitSilentSyncFetcher = newValue }
    }

    var customerAttributesManager: AppActorCustomerAttributesManager {
        paymentContext.customerAttributesManager
    }
}
