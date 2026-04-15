import Foundation
import StoreKit
import Combine

/// The main entry point for the AppActor SDK.
///
/// `AppActor` is a payment-only SDK singleton that is an `ObservableObject` and can
/// be used directly with SwiftUI's `@ObservedObject` or `@StateObject`.
///
/// ```swift
/// // Setup (call once in App init)
/// await AppActor.configure(apiKey: "pk_YOUR_PUBLIC_API_KEY")
///
/// // Check entitlements
/// if AppActor.shared.customerInfo.entitlements["premium"]?.isActive == true { ... }
/// ```
@MainActor
public final class AppActor: ObservableObject {

    // MARK: - Singleton

    /// The shared AppActor instance. Only valid after `configure()`.
    ///
    /// Marked `nonisolated(unsafe)` so callers can reference `AppActor.shared`
    /// from any isolation domain without an `await`.  This is safe because
    /// `shared` is a `let` constant (immutable reference, initialised once)
    /// and all nonisolated accessors on the instance read only from
    /// module-internal static storage — never from MainActor-isolated
    /// instance state.
    public nonisolated static let shared = AppActor()

    // MARK: - Published Properties (SwiftUI-friendly)

    /// The current customer info. Starts as `.empty`. Updated after each server sync.
    @Published public internal(set) var customerInfo: AppActorCustomerInfo = .empty {
        didSet {
            guard oldValue != customerInfo else { return }
            onCustomerInfoChanged?(customerInfo)
        }
    }

    // MARK: - Internal Components

    /// Optional callback fired whenever `customerInfo` changes.
    /// UIKit consumers can set this instead of observing the `@Published` property.
    public var onCustomerInfoChanged: ((AppActorCustomerInfo) -> Void)?

    /// Storage for the purchase intent callback (stored as Any? to avoid @available on stored property).
    var _onPurchaseIntent: Any?

    /// Called when a promoted in-app purchase or win-back offer intent arrives.
    ///
    /// **Payment mode only.** Set this callback before calling `configure()` to ensure
    /// no intents are missed. The callback receives a `PurchaseIntent` (iOS 16.4+).
    ///
    /// If not set, intents are still queued and auto-purchased via `purchase(intent:)`.
    ///
    /// ```swift
    /// AppActor.shared.onPurchaseIntent = { intent in
    ///     // Show a confirmation UI, then:
    ///     // try await AppActor.shared.purchase(intent: intent)
    /// }
    /// ```
    @available(iOS 16.4, macOS 14.4, tvOS 16.4, watchOS 9.4, *)
    public var onPurchaseIntent: (@Sendable (PurchaseIntent) -> Void)? {
        get { _onPurchaseIntent as? @Sendable (PurchaseIntent) -> Void }
        set { _onPurchaseIntent = newValue }
    }

    @_spi(AppActorPluginSupport)
    public var hasPurchaseIntentStorage: Bool {
        _onPurchaseIntent != nil
    }

    /// Called when a previously deferred (`.pending`) purchase resolves.
    ///
    /// **Payment mode only.** This fires when a transaction arrives via `Transaction.updates`
    /// for a product that was previously returned as `.pending` from `purchase()`.
    ///
    /// ```swift
    /// AppActor.shared.onDeferredPurchaseResolved = { productId, customerInfo in
    ///     // The deferred purchase was approved — update UI
    /// }
    /// ```
    public var onDeferredPurchaseResolved: ((_ productId: String, _ customerInfo: AppActorCustomerInfo) -> Void)? {
        get { paymentContext.deferredPurchaseHandler }
        set { paymentContext.deferredPurchaseHandler = newValue }
    }

    /// Centralized payment-mode state. Replaces scattered static enums.
    private(set) var paymentContext = AppActorPaymentContext()

    private nonisolated init() {}

    // MARK: - Purchase

    /// Purchases the product in the given package.
    ///
    /// Posts the transaction to the backend for validation.
    /// Entitlements are resolved server-authoritatively.
    ///
    /// - Returns: A `PurchaseResult` with the updated `CustomerInfo` on success.
    public func purchase(package: AppActorPackage, quantity: Int = 1) async throws -> AppActorPurchaseResult {
        guard package.store == .appStore else {
            throw AppActorError.validationError("Package '\(package.id)' is not purchasable via StoreKit on iOS")
        }
        guard quantity >= 1 else {
            throw AppActorError.validationError("Quantity must be at least 1")
        }
        var options: Set<Product.PurchaseOption> = []
        if quantity > 1 {
            options.insert(.quantity(quantity))
        }

        let lookupId = package.storeProductId ?? package.productId
        if let manager = offeringsManager,
           let product = try await manager.storeKitProduct(for: lookupId) {
            return try await executePaymentPurchase(product: product, options: options, offeringId: package.offeringId, packageId: package.id)
        }
        let products = try await Product.products(for: [lookupId])
        guard let product = products.first(where: { $0.id == lookupId }) else {
            throw AppActorError.validationError("StoreKit product '\(lookupId)' not found for package '\(package.id)'")
        }
        return try await executePaymentPurchase(product: product, options: options, offeringId: package.offeringId, packageId: package.id)
    }

    // MARK: - Restore & Sync Purchases

    /// Restores purchases by sending all current transactions to the server in a single bulk request.
    ///
    /// **Payment mode only.** Should only be called on explicit user action
    /// (e.g. a "Restore Purchases" button). Reads `Transaction.currentEntitlements` directly
    /// (like RevenueCat's SK2 path) — does **not** call `AppStore.sync()`, so it will
    /// **never** trigger an Apple ID sign-in prompt.
    ///
    /// Uses the bulk `/v1/payment/restore/apple` endpoint for efficiency. On failure,
    /// falls back to the single-receipt pipeline (scanCurrentEntitlements + drainAll).
    ///
    /// - Throws: ``AppActorError`` if payment mode is not configured.
    /// - Returns: The latest customer info from the server.
    /// - Parameter syncWithAppStore: When `true`, calls `AppStore.sync()` first to
    ///   refresh transactions from Apple's servers. This may prompt for Apple ID sign-in.
    ///   Defaults to `false` (reads only locally available transactions).
    @discardableResult
    public func restorePurchases(syncWithAppStore: Bool = false) async throws -> AppActorCustomerInfo {
        if syncWithAppStore {
            try await AppStore.sync()
        }

        guard paymentLifecycle == .configured else {
            throw AppActorError.notConfigured
        }
        guard let watcher = transactionWatcher,
              let processor = paymentProcessor,
              let client = paymentClient,
              let storage = paymentStorage,
              let customerManager = customerManager else {
            throw AppActorError.notConfigured
        }

        // Step 1: Collect all verified transactions without enqueuing
        let collected = await watcher.collectCurrentEntitlements()

        // Step 2: If no transactions, just refresh customer info
        if collected.isEmpty {
            let appUserId = storage.ensureAppUserId()
            let info = try await customerManager.getCustomerInfo(appUserId: appUserId, forceRefresh: true)
            setCustomerInfoIfIdentityMatches(info, expectedAppUserId: appUserId)
            Log.sdk.info("✅ Purchases restored (no transactions)")
            return info
        }

        // Step 3: Build bulk restore request (max transactions per batch)
        let appUserId = storage.ensureAppUserId()
        let maxBulkTransactions = 500
        let toSend = Array(collected.prefix(maxBulkTransactions))
        let overflow = collected.count > maxBulkTransactions ? Array(collected.suffix(from: maxBulkTransactions)) : []
        if !overflow.isEmpty {
            Log.sdk.warn("Restore: \(collected.count) transactions found, sending first 500 via bulk, remaining \(overflow.count) via single-receipt pipeline")
        }
        let items = toSend.map { entry in
            AppActorRestoreTransactionItem(
                transactionId: String(entry.transaction.id),
                jwsRepresentation: entry.jws
            )
        }
        let request = AppActorRestoreRequest(appUserId: appUserId, transactions: items)

        do {
            // Step 4: POST bulk restore
            let result = try await client.postRestore(request)

            // Step 5: Finish only the transactions we sent
            for entry in toSend {
                await entry.transaction.finish()
            }

            // Step 5b: Mark bulk-restored transactions in posted ledger + reconcile queued items.
            // Done AFTER POST (not before) to preserve the fallback path: if bulk fails,
            // scanCurrentEntitlements needs these keys to NOT be in the posted ledger.
            //
            // Trade-off: if the processor drain is concurrently POSTing the same transaction
            // via the single-receipt pipeline, a duplicate POST may occur. This is safe because
            // the server enforces idempotency via the transaction-based key — no duplicate grant
            // or data loss is possible. The duplicate POST is wasted network I/O only.
            let keysToMark = toSend.map { AppActorPaymentQueueItem.makeKey(transactionId: String($0.transaction.id)) }
            await processor.markPostedAndReconcile(keys: keysToMark)

            // Step 6: Route overflow through single-receipt pipeline
            if !overflow.isEmpty {
                for entry in overflow {
                    await watcher.handleVerifiedTransaction(entry.transaction, jws: entry.jws, source: .restore)
                }
                await processor.drainAll()
            }

            // Step 7: Seed customer cache for ETag reuse
            await customerManager.seedCache(
                info: result.customerInfo,
                eTag: result.customerETag,
                appUserId: appUserId,
                verified: result.signatureVerified
            )

            // Step 8: If overflow receipts were replayed through the single-receipt
            // pipeline, force a final authoritative snapshot before returning.
            let finalInfo = try await resolveRestoreCustomerInfo(
                from: result,
                appUserId: appUserId,
                hasOverflow: !overflow.isEmpty,
                customerManager: customerManager
            )
            setCustomerInfoIfIdentityMatches(finalInfo, expectedAppUserId: appUserId)
            Log.sdk.info("✅ Purchases restored (bulk: \(result.restoredCount) restored, transferred=\(result.transferred))")
            return finalInfo
        } catch {
            // Fallback: Bulk failed — fall back to single-receipt pipeline
            Log.sdk.warn("Bulk restore failed (\(error.localizedDescription)), falling back to single-receipt pipeline")
            await watcher.scanCurrentEntitlements()
            await processor.drainAll()
            let info = try await customerManager.getCustomerInfo(appUserId: appUserId, forceRefresh: true)
            setCustomerInfoIfIdentityMatches(info, expectedAppUserId: appUserId)
            Log.sdk.info("✅ Purchases restored (fallback)")
            return info
        }
    }

    func resolveRestoreCustomerInfo(
        from result: AppActorRestoreResult,
        appUserId: String,
        hasOverflow: Bool,
        customerManager: AppActorCustomerManager
    ) async throws -> AppActorCustomerInfo {
        guard hasOverflow else {
            let verification = AppActorVerificationResult.from(signatureVerified: result.signatureVerified)
            return result.customerInfo.withVerification(verification)
        }
        return try await customerManager.getCustomerInfo(appUserId: appUserId, forceRefresh: true)
    }

    /// Drains the local receipt queue and refreshes customer info from the server.
    ///
    /// This preserves the previous AppActor `syncPurchases()` behavior and is
    /// intentionally separate from the new RevenueCat-style quiet store sync.
    ///
    /// - Throws: ``AppActorError`` if payment mode is not configured.
    /// - Returns: The latest customer info from the server.
    @discardableResult
    public func drainReceiptQueueAndRefreshCustomer() async throws -> AppActorCustomerInfo {
        guard paymentLifecycle == .configured else {
            throw AppActorError.notConfigured
        }
        guard let processor = paymentProcessor else {
            throw AppActorError.notConfigured
        }
        await processor.drainAll()
        return try await getCustomerInfo()
    }

    /// Quietly syncs StoreKit 2 purchases to the backend.
    ///
    /// This is the RevenueCat-style SK2 path: try one verified transaction first,
    /// then fall back to an AppTransaction post before finally fetching customer info.
    ///
    /// It does not scan `Transaction.currentEntitlements` and it does not call
    /// `AppStore.sync()`. For a user-initiated restore flow, use ``restorePurchases()``.
    ///
    /// - Throws: ``AppActorError`` if payment mode is not configured or the server
    ///   rejects the quiet sync attempt.
    /// - Returns: The latest customer info from the server.
    @discardableResult
    public func syncPurchases() async throws -> AppActorCustomerInfo {
        guard paymentLifecycle == .configured else {
            throw AppActorError.notConfigured
        }
        guard let client = paymentClient,
              let storage = paymentStorage,
              let customerManager = customerManager,
              let silentSyncFetcher = storeKitSilentSyncFetcher else {
            throw AppActorError.notConfigured
        }

        let appUserId = storage.ensureAppUserId()

        if let transaction = await silentSyncFetcher.firstVerifiedTransaction() {
            let request = makeSilentSyncRequest(from: transaction, appUserId: appUserId)
            let response = try await client.postReceipt(request)
            let info = try await resolveSilentSyncCustomerInfo(
                from: response,
                appUserId: appUserId,
                customerManager: customerManager
            )
            setCustomerInfoIfIdentityMatches(info, expectedAppUserId: appUserId)
            return info
        }

        if let appTransactionJWS = await silentSyncFetcher.appTransactionJWS() {
            let request = makeSilentSyncAppTransactionRequest(
                appTransactionJWS: appTransactionJWS,
                appUserId: appUserId
            )
            let response = try await client.postReceipt(request)
            let info = try await resolveSilentSyncCustomerInfo(
                from: response,
                appUserId: appUserId,
                customerManager: customerManager
            )
            setCustomerInfoIfIdentityMatches(info, expectedAppUserId: appUserId)
            return info
        }

        let info = try await customerManager.getCustomerInfo(appUserId: appUserId)
        setCustomerInfoIfIdentityMatches(info, expectedAppUserId: appUserId)
        return info
    }

    private func makeSilentSyncRequest(
        from transaction: AppActorSilentSyncTransaction,
        appUserId: String
    ) -> AppActorReceiptPostRequest {
        AppActorReceiptPostRequest(
            appUserId: appUserId,
            appId: transaction.bundleId,
            environment: transaction.environment,
            bundleId: transaction.bundleId,
            storefront: transaction.storefront,
            signedTransactionInfo: transaction.jwsRepresentation,
            signedAppTransactionInfo: nil,
            transactionId: transaction.transactionId,
            productId: transaction.productId,
            idempotencyKey: AppActorPaymentQueueItem.makeKey(transactionId: transaction.transactionId),
            originalTransactionId: transaction.originalTransactionId,
            offeringId: nil,
            packageId: nil
        )
    }

    private func makeSilentSyncAppTransactionRequest(
        appTransactionJWS: String,
        appUserId: String
    ) -> AppActorReceiptPostRequest {
        let bundleId = Bundle.main.bundleIdentifier ?? "unknown"
        return AppActorReceiptPostRequest(
            appUserId: appUserId,
            appId: bundleId,
            environment: "production",
            bundleId: bundleId,
            storefront: nil,
            signedTransactionInfo: nil,
            signedAppTransactionInfo: appTransactionJWS,
            transactionId: nil,
            productId: nil,
            idempotencyKey: nil,
            originalTransactionId: nil,
            offeringId: nil,
            packageId: nil
        )
    }

    private func resolveSilentSyncCustomerInfo(
        from response: AppActorReceiptPostResponse,
        appUserId: String,
        customerManager: AppActorCustomerManager
    ) async throws -> AppActorCustomerInfo {
        switch response.status {
        case "ok":
            if let customer = response.customer {
                let info = AppActorCustomerInfo(dto: customer, appUserId: appUserId, requestDate: nil)
                await customerManager.seedCache(info: info, eTag: nil, appUserId: appUserId)
                return info
            }

            let info = try await customerManager.getCustomerInfo(appUserId: appUserId, forceRefresh: true)
            return info

        case "retryable_error":
            throw AppActorError.serverError(
                httpStatus: 503,
                code: response.error?.code ?? "QUIET_SYNC_RETRYABLE",
                message: response.error?.message ?? "Store sync temporarily failed. Retry again shortly.",
                details: nil,
                requestId: response.requestId,
                retryAfterSeconds: response.retryAfterSeconds
            )

        case "permanent_error":
            throw AppActorError.clientError(
                kind: .receiptPostFailed,
                code: response.error?.code,
                message: response.error?.message ?? "Server permanently rejected the quiet sync receipt",
                requestId: response.requestId
            )

        default:
            throw AppActorError.receiptPostFailed("Unexpected quiet sync response status: \(response.status)")
        }
    }

}


private final class AppActorLockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func get() -> Value {
        lock.withLock { value }
    }

    func set(_ newValue: Value) {
        lock.withLock { value = newValue }
    }
}



// MARK: - Payment Context

/// Centralized holder for all payment-mode state.
///
/// Replaces the 7+ scattered `private enum` + `nonisolated(unsafe) static` patterns.
/// Lives as a stored property on `AppActor` (MainActor), making state ownership
/// explicit and test isolation straightforward.
@MainActor
final class AppActorPaymentContext {
    var lifecycle: AppActorPaymentLifecycle = .idle
    var config: AppActorPaymentConfiguration?
    var storage: (any AppActorPaymentStorage)?
    var client: (any AppActorPaymentClientProtocol)?
    var currentUser: AppActorCustomerInfo?
    var etagManager: AppActorETagManager?
    var lifecycleObservers: [NSObjectProtocol] = []
    var asaTask: Task<Void, Never>?
    var foregroundTask: Task<Void, Never>?
    var stalenessTimerTask: Task<Void, Never>?
    var offeringsPrefetchTask: Task<Void, Never>?
    var paymentProcessor: AppActorPaymentProcessor?
    var paymentQueueStore: (any AppActorPaymentQueueStoreProtocol)?
    var transactionWatcher: AppActorTransactionWatcher?
    /// The purchase intent watcher. iOS 16.4+ only; stored as Any? to avoid @available on stored property.
    var purchaseIntentWatcher: Any?
    /// Intents received before bootstrap completes. Drained sequentially after bootstrap.
    var pendingPurchaseIntents: [Any] = []
    var isPurchaseInProgress: Bool = false
    /// Set to `true` when `runBootstrap()` completes. Guards PurchaseIntent
    /// processing and foreground observer from firing before bootstrap finishes.
    var isBootstrapComplete: Bool = false
    var pipelineEventHandler: (@Sendable (AppActorReceiptPipelineEventDetail) -> Void)?
    /// Product IDs for purchases that returned `.pending` (Ask to Buy / SCA).
    /// Keyed by product ID, value is the count of pending purchases for that SKU.
    var pendingProductCounts: [String: Int] = [:]
    /// Called when a previously deferred (`.pending`) purchase resolves via Transaction.updates.
    var deferredPurchaseHandler: ((_ productId: String, _ customerInfo: AppActorCustomerInfo) -> Void)?
    /// Bundled fallback offerings DTO for first-launch offline scenarios.
    var fallbackOfferingsDTO: AppActorOfferingsResponseDTO?

    var customerManager: AppActorCustomerManager?
    var offeringsManager: AppActorOfferingsManager?
    var experimentManager: AppActorExperimentManager?
    var remoteConfigManager: AppActorRemoteConfigManager?
    var asaManager: AppActorASAManager?
    var storeKitSilentSyncFetcher: (any AppActorStoreKitSilentSyncFetcherProtocol)?

    var offerings: AppActorOfferings?
    var remoteConfigs: AppActorRemoteConfigs?

    // nonisolated bridges — used by nonisolated accessors (appUserId, isAnonymous, getRemoteConfig, etc.)
    // These stay synchronous for API ergonomics, but route through lock-backed storage.
    nonisolated private static let _lifecycleBox = AppActorLockedBox<AppActorPaymentLifecycle>(.idle)
    nonisolated private static let _storageBox = AppActorLockedBox<(any AppActorPaymentStorage)?>(nil)

    nonisolated static var _lifecycle: AppActorPaymentLifecycle {
        get { _lifecycleBox.get() }
        set { _lifecycleBox.set(newValue) }
    }

    nonisolated static var _storage: (any AppActorPaymentStorage)? {
        get { _storageBox.get() }
        set { _storageBox.set(newValue) }
    }

    // _remoteConfigs is mutated on every fetch + cleared on login/logout/reset → needs lock.
    nonisolated private static let _remoteConfigsLock = NSLock()
    private nonisolated(unsafe) static var _remoteConfigsBacking: AppActorRemoteConfigs?

    nonisolated static var _remoteConfigs: AppActorRemoteConfigs? {
        get { _remoteConfigsLock.withLock { _remoteConfigsBacking } }
        set { _remoteConfigsLock.withLock { _remoteConfigsBacking = newValue } }
    }
}
