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
        }
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

    var paymentCurrentUser: AppActorCustomerInfo? {
        get { paymentContext.currentUser }
        set { paymentContext.currentUser = newValue }
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

    var asaManager: AppActorASAManager? {
        get { paymentContext.asaManager }
        set { paymentContext.asaManager = newValue }
    }
}
