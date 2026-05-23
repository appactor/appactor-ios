import Foundation
import StoreKit

struct AppActorForegroundPurchaseScope {
    private let watcher: AppActorTransactionWatcher?
    private let productId: String
    private let appUserId: String
    private let token: UUID?

    static func begin(
        watcher: AppActorTransactionWatcher?,
        productId: String,
        appUserId: String,
        clientPurchaseContext: AppActorClientPurchaseContext
    ) async -> AppActorForegroundPurchaseScope {
        let token = await watcher?.beginForegroundPurchase(
            productId: productId,
            appUserId: appUserId,
            clientPurchaseContext: clientPurchaseContext
        )
        return AppActorForegroundPurchaseScope(
            watcher: watcher,
            productId: productId,
            appUserId: appUserId,
            token: token
        )
    }

    func end(handledTransactionId: String?, preserveContextForPending: Bool = false) async {
        await watcher?.endForegroundPurchase(
            productId: productId,
            appUserId: appUserId,
            token: token,
            handledTransactionId: handledTransactionId,
            preserveContextForPending: preserveContextForPending
        )
    }
}

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
        let clientPurchaseContext: AppActorClientPurchaseContext?
    }

    private var pendingBuffer: [BufferedTransaction] = []
    private var foregroundPurchaseProductTokens: [String: UUID] = [:]
    private var foregroundPurchaseContexts: [UUID: AppActorClientPurchaseContext] = [:]
    private var foregroundPurchaseAppUserIds: [UUID: String] = [:]
    private var foregroundPurchaseBuffer: [UUID: [BufferedTransaction]] = [:]
    private var coalescedUnfinishedByOriginalId: [String: [CoalescedUnfinishedEntry]] = [:]
    private var pendingPurchaseContexts: AppActorPendingPurchaseContextBuffer

    private struct CoalescedUnfinishedEntry {
        let transactionId: String
        let finish: () async -> Void
    }

    init(
        processor: AppActorPaymentProcessor,
        storage: AppActorPaymentStorage,
        silentSyncFetcher: any AppActorStoreKitSilentSyncFetcherProtocol
    ) {
        self.processor = processor
        self.storage = storage
        self.silentSyncFetcher = silentSyncFetcher
        self.pendingPurchaseContexts = AppActorPendingPurchaseContextBuffer(storage: storage)
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
                item.transaction,
                jws: item.jws,
                source: item.source,
                appUserId: item.capturedAppUserId,
                clientPurchaseContext: item.clientPurchaseContext
            )
        }
    }

    // MARK: - Foreground Purchase Coordination

    func beginForegroundPurchase(
        productId: String,
        appUserId: String,
        clientPurchaseContext: AppActorClientPurchaseContext
    ) -> UUID {
        let token = UUID()
        foregroundPurchaseProductTokens[productId] = token
        foregroundPurchaseContexts[token] = clientPurchaseContext
        foregroundPurchaseAppUserIds[token] = appUserId
        return token
    }

    func endForegroundPurchase(
        productId: String,
        appUserId: String,
        token: UUID?,
        handledTransactionId: String?,
        preserveContextForPending: Bool = false
    ) async {
        guard let token else { return }
        let context = foregroundPurchaseContexts[token]
        if foregroundPurchaseProductTokens[productId] == token {
            foregroundPurchaseProductTokens.removeValue(forKey: productId)
        }
        foregroundPurchaseContexts.removeValue(forKey: token)
        let capturedAppUserId = foregroundPurchaseAppUserIds.removeValue(forKey: token) ?? appUserId
        let buffered = foregroundPurchaseBuffer.removeValue(forKey: token) ?? []
        if preserveContextForPending, handledTransactionId == nil, buffered.isEmpty, let context {
            pendingPurchaseContexts.append(context, productId: productId, appUserId: capturedAppUserId)
        }
        for item in buffered {
            let source: AppActorPaymentQueueItem.Source =
                handledTransactionId == String(item.transaction.id) ? .purchase : item.source
            await enqueueWithUserId(
                item.transaction,
                jws: item.jws,
                source: source,
                appUserId: item.capturedAppUserId,
                clientPurchaseContext: item.clientPurchaseContext
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
        var entries: [(transaction: Transaction, jws: String, reason: AppActorTransactionReason)] = []
        for await result in Transaction.unfinished {
            if case .verified(let transaction) = result {
                let jws = result.jwsRepresentation
                let reason = AppActorASATransactionSupport.resolveReason(
                    for: transaction,
                    jwsPayload: AppActorASATransactionSupport.decodeJWSPayload(jws)
                )
                entries.append((transaction: transaction, jws: jws, reason: reason))
            }
        }

        let selectedTransactionIds = AppActorUnfinishedTransactionCoalescer.selectRepresentativeIds(
            from: entries.map { entry in
                AppActorUnfinishedTransactionCandidate(
                    transactionId: String(entry.transaction.id),
                    originalTransactionId: String(entry.transaction.originalID),
                    productId: entry.transaction.productID,
                    purchaseDate: entry.transaction.purchaseDate,
                    revocationDate: entry.transaction.revocationDate,
                    reason: entry.reason
                )
            }
        )

        var enqueuedCount = 0
        for entry in entries {
            let transactionId = String(entry.transaction.id)
            if selectedTransactionIds.contains(transactionId) {
                await handleVerifiedTransaction(entry.transaction, jws: entry.jws, source: .sweep)
                enqueuedCount += 1
            } else {
                let originalTransactionId = String(entry.transaction.originalID)
                recordCoalescedUnfinished(
                    originalTransactionId: originalTransactionId,
                    transactionId: transactionId,
                    finish: { await entry.transaction.finish() }
                )
            }
        }

        let coalescedCount = entries.count - enqueuedCount
        Log.storeKit.info(
            "sweepUnfinished completed: \(enqueuedCount) transaction(s) enqueued, \(coalescedCount) coalesced"
        )
    }

    func recordCoalescedUnfinished(
        originalTransactionId: String,
        transactionId: String,
        finish: @escaping () async -> Void
    ) {
        guard !originalTransactionId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        var existing = coalescedUnfinishedByOriginalId[originalTransactionId] ?? []
        guard !existing.contains(where: { $0.transactionId == transactionId }) else {
            return
        }
        existing.append(CoalescedUnfinishedEntry(transactionId: transactionId, finish: finish))
        coalescedUnfinishedByOriginalId[originalTransactionId] = existing
    }

    func finishCoalescedUnfinished(originalTransactionId: String) async {
        guard !originalTransactionId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let entries = coalescedUnfinishedByOriginalId.removeValue(forKey: originalTransactionId),
              !entries.isEmpty else {
            return
        }

        let keys = entries.map { AppActorPaymentQueueItem.makeKey(transactionId: $0.transactionId) }
        await processor.markPostedAndReconcile(keys: keys)
        for entry in entries {
            await entry.finish()
        }
        Log.storeKit.info(
            "Finished \(entries.count) coalesced unfinished transaction(s) after successful chain sync"
        )
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
        source: AppActorPaymentQueueItem.Source,
        clientPurchaseContext: AppActorClientPurchaseContext? = nil
    ) async {
        let observedContext = clientPurchaseContext ?? AppActorClientPurchaseContext.forQueueSource(source)
        let jwsPayload = AppActorASATransactionSupport.decodeJWSPayload(jws)
        let transactionReason = AppActorASATransactionSupport.resolveReason(
            for: transaction,
            jwsPayload: jwsPayload
        )
        if let token = foregroundPurchaseProductTokens[transaction.productID],
           Self.shouldBufferForegroundTransaction(
               source: source,
               transactionProductId: transaction.productID,
               transactionId: String(transaction.id),
               originalTransactionId: String(transaction.originalID),
               purchaseDate: transaction.purchaseDate,
               transactionReason: transactionReason,
               foregroundProductId: transaction.productID,
               foregroundContext: foregroundPurchaseContexts[token]
           ) {
            let capturedUserId = foregroundPurchaseAppUserIds[token] ?? storage.ensureAppUserId()
            let foregroundContext = (foregroundPurchaseContexts[token] ?? observedContext)
                .replacingDeliverySource(.transactionUpdates, observedAt: Date())
            let buffered = BufferedTransaction(
                transaction: transaction,
                jws: jws,
                source: source,
                capturedAppUserId: capturedUserId,
                clientPurchaseContext: foregroundContext
            )
            foregroundPurchaseBuffer[token, default: []].append(buffered)
            Log.storeKit.debug("Buffered transaction \(transaction.id) during foreground purchase (product: \(transaction.productID))")
            return
        }

        let pendingMatch = pendingPurchaseContextMatch(
            for: transaction,
            source: source,
            transactionReason: transactionReason
        )
        let effectiveContext = pendingMatch?.context ?? observedContext
        let capturedAppUserId = pendingMatch?.appUserId?.trimmingCharacters(in: .whitespacesAndNewlines)
        let enqueueSource = Self.queueSource(
            for: source,
            pendingPurchaseContextMatch: pendingMatch
        )

        // During identity transition, buffer with the ownership user captured before the transition.
        if isIdentityTransitioning {
            if pendingBuffer.count >= 50 {
                Log.storeKit.warn("Identity transition buffer full (\(pendingBuffer.count)) — enqueuing directly")
            } else {
                let capturedUserId = capturedAppUserId?.isEmpty == false ? capturedAppUserId! : storage.ensureAppUserId()
                pendingBuffer.append(BufferedTransaction(
                    transaction: transaction, jws: jws, source: enqueueSource,
                    capturedAppUserId: capturedUserId,
                    clientPurchaseContext: effectiveContext
                ))
                Log.storeKit.debug("Buffered transaction \(transaction.id) during identity transition (user: \(capturedUserId))")
                return
            }
        }

        let appUserId = capturedAppUserId?.isEmpty == false ? capturedAppUserId! : storage.ensureAppUserId()
        await enqueueWithUserId(
            transaction,
            jws: jws,
            source: enqueueSource,
            appUserId: appUserId,
            clientPurchaseContext: effectiveContext
        )
    }

    private func pendingPurchaseContextMatch(
        for transaction: Transaction,
        source: AppActorPaymentQueueItem.Source,
        transactionReason: AppActorTransactionReason
    ) -> AppActorPendingPurchaseContextMatch? {
        guard source == .transactionUpdates || source == .sweep else {
            return nil
        }
        return pendingPurchaseContexts.consume(
            productId: transaction.productID,
            observedAt: Date(),
            deliverySource: source.defaultClientDeliverySource,
            transactionPurchaseDate: transaction.purchaseDate,
            transactionReason: transactionReason
        )
    }

    static func queueSource(
        for source: AppActorPaymentQueueItem.Source,
        pendingPurchaseContextMatch: AppActorPendingPurchaseContextMatch?
    ) -> AppActorPaymentQueueItem.Source {
        guard pendingPurchaseContextMatch != nil else { return source }
        switch source {
        case .transactionUpdates, .sweep:
            return .purchase
        case .purchase, .restore:
            return source
        }
    }

    static func shouldBufferForegroundTransaction(
        source: AppActorPaymentQueueItem.Source,
        transactionProductId: String,
        transactionId: String,
        originalTransactionId: String,
        purchaseDate: Date,
        transactionReason: AppActorTransactionReason,
        foregroundProductId: String,
        foregroundContext: AppActorClientPurchaseContext?
    ) -> Bool {
        guard source == .transactionUpdates,
              transactionProductId == foregroundProductId else {
            return false
        }
        if originalTransactionId == transactionId {
            return true
        }
        if transactionReason == .renewal {
            return false
        }
        if transactionReason == .purchase {
            return true
        }
        guard let attemptStartedAt = foregroundContext?.clientPurchaseAttemptStartedAt else {
            return false
        }
        return purchaseDate >= attemptStartedAt.addingTimeInterval(-60)
    }

    /// Enqueues a verified transaction with an explicit appUserId.
    /// Shared by both live processing and buffer flush paths.
    private func enqueueWithUserId(
        _ transaction: Transaction,
        jws: String,
        source: AppActorPaymentQueueItem.Source,
        appUserId: String,
        clientPurchaseContext: AppActorClientPurchaseContext? = nil
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
            signedAppTransactionInfo: appTransaction?.jwsRepresentation,
            clientPurchaseContext: clientPurchaseContext
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
