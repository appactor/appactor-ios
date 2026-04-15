import Foundation
import StoreKit

/// Listens for `Transaction.updates` and enqueues items into `PaymentProcessor`.
///
/// This is the enqueue-only counterpart to the old `PaymentTransactionListener`.
/// All processing (POST, finish, retry) is delegated to `PaymentProcessor`.
actor AppActorTransactionWatcher {

    private let processor: AppActorPaymentProcessor
    private let storage: AppActorPaymentStorage
    private let silentSyncFetcher: any AppActorStoreKitSilentSyncFetcherProtocol
    private var listenerTask: Task<Void, Never>?
    private var asaManager: AppActorASAManager?
    private var asaTrackInSandbox = false

    // MARK: - Identity Transition Buffer

    /// When true, incoming transactions are buffered instead of enqueued.
    /// Set during logIn/logOut to prevent items from being tagged with the wrong appUserId.
    private var isIdentityTransitioning = false

    private struct BufferedTransaction {
        let transaction: Transaction
        let jws: String
        let source: AppActorPaymentQueueItem.Source
        let capturedAppUserId: String
    }

    private var pendingBuffer: [BufferedTransaction] = []

    init(
        processor: AppActorPaymentProcessor,
        storage: AppActorPaymentStorage,
        silentSyncFetcher: any AppActorStoreKitSilentSyncFetcherProtocol
    ) {
        self.processor = processor
        self.storage = storage
        self.silentSyncFetcher = silentSyncFetcher
    }

    /// Configures ASA purchase event tracking through the transaction watcher.
    ///
    /// When configured, verified transactions processed by the watcher can
    /// enqueue ASA purchase events when they represent an initial purchase in
    /// an allowed environment — eliminating the need for manual ASA tracking
    /// at each call site.
    ///
    /// - Parameters:
    ///   - manager: The ASA manager to enqueue events into.
    ///   - trackInSandbox: When `true`, sandbox transactions are also tracked.
    func configureASATracking(manager: AppActorASAManager, trackInSandbox: Bool = false) {
        self.asaManager = manager
        self.asaTrackInSandbox = trackInSandbox
    }

    /// Starts listening for `Transaction.updates`.
    ///
    /// Each verified transaction is converted to a `PaymentQueueItem` and enqueued.
    /// Unverified transactions are logged and skipped.
    func start() {
        guard listenerTask == nil, !Task.isCancelled else { return }

        listenerTask = Task(priority: .utility) { [weak self] in
            for await result in Transaction.updates {
                guard let self, !Task.isCancelled else { break }

                switch result {
                case .verified(let transaction):
                    let jws = result.jwsRepresentation
                    await self.handleVerifiedTransaction(transaction, jws: jws, source: .transactionUpdates)
                case .unverified(_, let error):
                    Log.storeKit.warn("Unverified transaction update ignored: \(error.localizedDescription)")
                }
            }
        }

        Log.storeKit.info("🍎 TransactionWatcher started")
    }

    /// Stops the listener and waits for it to finish.
    /// Awaiting ensures no overlap when a new watcher starts immediately after.
    func stop() async {
        let task = listenerTask
        task?.cancel()
        await task?.value
        listenerTask = nil
        Log.storeKit.info("🍎 TransactionWatcher stopped")
    }

    // MARK: - Identity Transition

    /// Begins an identity transition. Transactions arriving during transition are buffered
    /// with their current (pre-switch) appUserId to prevent wrong-user attribution.
    func beginIdentityTransition() {
        isIdentityTransitioning = true
    }

    /// Ends an identity transition and flushes buffered transactions.
    /// Each buffered item is enqueued with the appUserId captured at buffer time (not the new user).
    func endIdentityTransition() async {
        guard isIdentityTransitioning else {
            Log.storeKit.debug("endIdentityTransition called without matching begin — no-op")
            return
        }
        isIdentityTransitioning = false
        let buffered = pendingBuffer
        pendingBuffer.removeAll()
        for item in buffered {
            await enqueueWithUserId(
                item.transaction, jws: item.jws, source: item.source, appUserId: item.capturedAppUserId
            )
        }
    }

    // MARK: - Scan & Collect

    /// Scans `Transaction.currentEntitlements` for any verified transactions
    /// that haven't been processed yet. Used during restore fallback.
    func scanCurrentEntitlements() async {
        for entry in await collectCurrentEntitlements() {
            await handleVerifiedTransaction(entry.transaction, jws: entry.jws, source: .restore)
        }
    }

    /// Scans `Transaction.unfinished` at app launch to catch missed transactions.
    ///
    /// All verified transactions — including revoked and expired — are enqueued
    /// for server validation. This ensures the backend learns about refunds and
    /// expirations that occurred while the app was not running, matching the
    /// Adapty/RevenueCat "report everything, then finish" pattern.
    func sweepUnfinished() async {
        var count = 0
        for await result in Transaction.unfinished {
            if case .verified(let transaction) = result {
                let jws = result.jwsRepresentation
                await handleVerifiedTransaction(transaction, jws: jws, source: .sweep)
                count += 1
            }
        }
        Log.storeKit.info("sweepUnfinished completed: \(count) transaction(s) enqueued")
    }

    /// Collects all verified transactions from `Transaction.currentEntitlements`
    /// without enqueuing them into the receipt pipeline.
    ///
    /// Used by the bulk restore flow to gather transactions for the
    /// `/v1/payment/restore/apple` endpoint.
    ///
    /// - Returns: An array of `(transaction, jws)` tuples for each verified entitlement.
    func collectCurrentEntitlements() async -> [(transaction: Transaction, jws: String)] {
        var results: [(transaction: Transaction, jws: String)] = []
        for await result in Transaction.currentEntitlements {
            if case .verified(let transaction) = result {
                results.append((transaction: transaction, jws: result.jwsRepresentation))
            }
        }
        return results
    }

    // MARK: - Internal

    func handleVerifiedTransaction(
        _ transaction: Transaction,
        jws: String,
        source: AppActorPaymentQueueItem.Source
    ) async {
        // During identity transition, buffer with current user to prevent wrong-user attribution
        if isIdentityTransitioning {
            if pendingBuffer.count >= 50 {
                Log.storeKit.warn("Identity transition buffer full (\(pendingBuffer.count)) — enqueuing directly")
            } else {
                let capturedUserId = storage.ensureAppUserId()
                pendingBuffer.append(BufferedTransaction(
                    transaction: transaction, jws: jws, source: source,
                    capturedAppUserId: capturedUserId
                ))
                Log.storeKit.debug("Buffered transaction \(transaction.id) during identity transition (user: \(capturedUserId))")
                return
            }
        }

        let appUserId = storage.ensureAppUserId()
        await enqueueWithUserId(transaction, jws: jws, source: source, appUserId: appUserId)
    }

    /// Enqueues a verified transaction with an explicit appUserId.
    /// Shared by both live processing and buffer flush paths.
    private func enqueueWithUserId(
        _ transaction: Transaction,
        jws: String,
        source: AppActorPaymentQueueItem.Source,
        appUserId: String
    ) async {
        if transaction.revocationDate != nil {
            Log.storeKit.info("Enqueuing revoked transaction \(transaction.id) (product: \(transaction.productID))")
        }

        let jwsPayload = AppActorASATransactionSupport.decodeJWSPayload(jws)
        let environment = AppActorASATransactionSupport.resolveEnvironment(
            for: transaction,
            jwsPayload: jwsPayload
        )
        let appTransaction = await silentSyncFetcher.appTransaction()

        let item = AppActorPaymentProcessor.makePaymentQueueItem(
            from: transaction,
            jws: jws,
            source: source,
            appUserId: appUserId,
            jwsPayload: jwsPayload,
            environment: environment,
            signedAppTransactionInfo: appTransaction?.jwsRepresentation
        )
        await processor.enqueue(item: item, transaction: transaction)

        // Only initial purchase events should flow into ASA.
        // Restore/currentEntitlement scans are state recovery, not new conversions.
        if let asaManager {
            let reason = AppActorASATransactionSupport.resolveReason(
                for: transaction,
                jwsPayload: jwsPayload
            )

            guard AppActorASATransactionSupport.isEligibleForASAPurchaseEvent(
                source: source,
                isRevoked: transaction.revocationDate != nil,
                ownershipType: transaction.ownershipType,
                environment: environment,
                reason: reason,
                trackInSandbox: asaTrackInSandbox
            ) else {
                return
            }

            await asaManager.enqueuePurchaseEvent(
                userId: appUserId,
                productId: transaction.productID,
                transactionId: String(transaction.id),
                originalTransactionId: String(transaction.originalID),
                purchaseDate: transaction.purchaseDate,
                countryCode: transaction.storefrontCountryCode,
                storekit2Json: jwsPayload
            )
        }
    }
}
