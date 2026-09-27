import Foundation
import StoreKit

struct AppActorForegroundPurchaseScope {
    private let watcher: AppActorTransactionWatcher?
    private let token: UUID?

    static func begin(
        watcher: AppActorTransactionWatcher?,
        productId: String,
        appUserId: String,
        appAccountToken: UUID,
        clientPurchaseContext: AppActorClientPurchaseContext
    ) async -> AppActorForegroundPurchaseScope {
        let token = await watcher?.beginForegroundPurchase(
            productId: productId,
            appUserId: appUserId,
            appAccountToken: appAccountToken,
            clientPurchaseContext: clientPurchaseContext
        )
        return AppActorForegroundPurchaseScope(watcher: watcher, token: token)
    }

    func end(handledTransactionId: String?, preserveContextForPending: Bool = false) async {
        await watcher?.endForegroundPurchase(
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
    private(set) var isIdentityTransitioning = false
    private var identityTransitionAppUserId: String?

    private struct BufferedTransaction {
        let transaction: Transaction
        let jws: String
        let source: AppActorPaymentQueueItem.Source
        let capturedAppUserId: String
        let clientPurchaseContext: AppActorClientPurchaseContext?
    }

    /// A purchase() in flight, keyed by its scope token.
    private struct ForegroundPurchase {
        let productId: String
        let context: AppActorClientPurchaseContext
        let appUserId: String
        let appAccountToken: UUID
        var buffered: [BufferedTransaction] = []
    }

    private var pendingBuffer: [BufferedTransaction] = []
    private var foregroundPurchaseProductTokens: [String: UUID] = [:]
    private var foregroundPurchases: [UUID: ForegroundPurchase] = [:]
    private var pendingPurchaseContexts: AppActorPendingPurchaseContextBuffer

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
                    // Deliberately not finished here: a live verification failure can be transient
                    // (device identifiers mid-restore, for example). If it is still unverified at the
                    // next launch, `sweepUnfinished` finishes it.
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
    func beginIdentityTransition(appUserId: String? = nil) {
        // Verbatim, as configure() and logIn() store it: the receipt is posted under it.
        identityTransitionAppUserId = appUserId.flatMap { AppActorPaymentValidation.isBlank($0) ? nil : $0 }
            ?? storage.ensureAppUserId()
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
        identityTransitionAppUserId = nil
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
        appAccountToken: UUID,
        clientPurchaseContext: AppActorClientPurchaseContext
    ) -> UUID {
        let token = UUID()
        foregroundPurchaseProductTokens[productId] = token
        foregroundPurchases[token] = ForegroundPurchase(
            productId: productId,
            context: clientPurchaseContext,
            appUserId: appUserId,
            appAccountToken: appAccountToken
        )
        return token
    }

    func endForegroundPurchase(
        token: UUID?,
        handledTransactionId: String?,
        preserveContextForPending: Bool = false
    ) async {
        guard let token, let purchase = foregroundPurchases.removeValue(forKey: token) else { return }
        if foregroundPurchaseProductTokens[purchase.productId] == token {
            foregroundPurchaseProductTokens.removeValue(forKey: purchase.productId)
        }
        if preserveContextForPending, handledTransactionId == nil, purchase.buffered.isEmpty {
            pendingPurchaseContexts.append(
                purchase.context,
                productId: purchase.productId,
                appUserId: purchase.appUserId,
                appAccountToken: purchase.appAccountToken
            )
        }
        for item in purchase.buffered {
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
    /// Every verified transaction — including revoked and expired — is enqueued for
    /// server validation and finished only after the server accepts it (Adapty /
    /// RevenueCat "report everything, then finish"). Nothing is held back: the server
    /// is idempotent per transaction, so an older renewal it already knows costs one
    /// no-op round-trip, whereas a transaction that is never posted is never finished
    /// and is re-delivered here on every launch. Unverified transactions can never be
    /// posted, so they are finished right away instead of accumulating.
    func sweepUnfinished() async {
        var verifiedCount = 0
        var finishedUnverifiedCount = 0
        for await result in Transaction.unfinished {
            switch result {
            case .verified(let transaction):
                await handleVerifiedTransaction(transaction, jws: result.jwsRepresentation, source: .sweep)
                verifiedCount += 1
            case .unverified(let transaction, let error):
                Log.storeKit.warn(
                    "Finishing unverified unfinished transaction \(transaction.id) (product: \(transaction.productID)): \(error.localizedDescription)"
                )
                await transaction.finish()
                finishedUnverifiedCount += 1
            }
        }

        Log.storeKit.info(
            "sweepUnfinished completed: \(verifiedCount) verified transaction(s) handed to the receipt queue, \(finishedUnverifiedCount) unverified finished"
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
           let purchase = foregroundPurchases[token],
           Self.shouldBufferForegroundTransaction(
               source: source,
               transactionProductId: transaction.productID,
               transactionId: String(transaction.id),
               originalTransactionId: String(transaction.originalID),
               purchaseDate: transaction.purchaseDate,
               transactionReason: transactionReason,
               transactionAppAccountToken: transaction.appAccountToken,
               foregroundProductId: purchase.productId,
               foregroundAppAccountToken: purchase.appAccountToken,
               foregroundContext: purchase.context
           ) {
            let buffered = BufferedTransaction(
                transaction: transaction,
                jws: jws,
                source: source,
                capturedAppUserId: purchase.appUserId,
                clientPurchaseContext: purchase.context.replacingDeliverySource(.transactionUpdates, observedAt: Date())
            )
            foregroundPurchases[token]?.buffered.append(buffered)
            Log.storeKit.debug("Buffered transaction \(transaction.id) during foreground purchase (product: \(transaction.productID))")
            return
        }

        let pendingMatch = pendingPurchaseContextMatch(
            for: transaction,
            source: source,
            transactionReason: transactionReason
        )
        let effectiveContext = pendingMatch?.context ?? observedContext
        let capturedAppUserId = pendingMatch?.appUserId
        let enqueueSource = Self.queueSource(
            for: source,
            pendingPurchaseContextMatch: pendingMatch
        )

        // During identity transition, buffer with the ownership user captured before the transition.
        if isIdentityTransitioning {
            let capturedUserId = capturedAppUserId?.isEmpty == false
                ? capturedAppUserId!
                : identityTransitionAppUserId ?? storage.ensureAppUserId()
            if pendingBuffer.count >= 50 {
                Log.storeKit.warn("Identity transition buffer full (\(pendingBuffer.count)) — enqueuing directly")
                await enqueueWithUserId(
                    transaction,
                    jws: jws,
                    source: enqueueSource,
                    appUserId: capturedUserId,
                    clientPurchaseContext: effectiveContext
                )
                return
            } else {
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
            appAccountToken: transaction.appAccountToken,
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
        transactionAppAccountToken: UUID?,
        foregroundProductId: String,
        foregroundAppAccountToken: UUID,
        foregroundContext: AppActorClientPurchaseContext
    ) -> Bool {
        // Same appAccountToken rule as the pending buffer's `consume`: another identity's
        // approved Ask to Buy or an offer code is never this purchase's result.
        guard source == .transactionUpdates,
              transactionProductId == foregroundProductId,
              transactionAppAccountToken == foregroundAppAccountToken else {
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
        guard let attemptStartedAt = foregroundContext.clientPurchaseAttemptStartedAt else {
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
