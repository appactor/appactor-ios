import Foundation
import StoreKit

// MARK: - Payment Purchase Public API

extension AppActor {
    @inline(__always)
    func attachAppAccountToken(
        to options: Set<Product.PurchaseOption>,
        storage: AppActorPaymentStorage
    ) -> (options: Set<Product.PurchaseOption>, token: UUID) {
        let token = storage.ensureAppAccountToken()
        var nextOptions = options
        nextOptions.insert(.appAccountToken(token))
        return (nextOptions, token)
    }

    /// Purchases a StoreKit `Product` directly.
    ///
    /// - Parameter product: A StoreKit 2 `Product`.
    /// - Returns: The purchase result.
    /// - Throws: `AppActorError` if payment is not configured.
    public func purchase(product: Product) async throws -> AppActorPurchaseResult {
        try await executePaymentPurchase(product: product)
    }

    /// Purchases a product from a `PurchaseIntent` (promoted IAP or win-back offer).
    ///
    /// **Payment mode only.** If the intent contains a win-back offer (iOS 18+),
    /// it is automatically applied as a `.winBackOffer` purchase option.
    ///
    /// - Parameter intent: The `PurchaseIntent` received from `PurchaseIntent.intents`
    ///   or the `onPurchaseIntent` callback.
    /// - Returns: The purchase result.
    /// - Throws: `AppActorError` if payment is not configured.
    @available(iOS 16.4, macOS 14.4, tvOS 16.4, watchOS 9.4, *)
    public func purchase(intent: PurchaseIntent) async throws -> AppActorPurchaseResult {
        var options: Set<Product.PurchaseOption> = []

        if #available(iOS 18.0, macOS 15.0, tvOS 18.0, watchOS 11.0, *) {
            if let offer = intent.offer, offer.type == .winBack {
                options.insert(.winBackOffer(offer))
            }
        }

        return try await executePaymentPurchase(product: intent.product, options: options)
    }

    /// Callback invoked when the receipt pipeline processes an event.
    ///
    /// Each event includes the `productId` and `appUserId` for diagnostics.
    ///
    /// ```swift
    /// AppActor.shared.onReceiptPipelineEvent = { detail in
    ///     switch detail.event {
    ///     case .postedOk(let txId):
    ///         logger.info("Receipt posted: \(txId) (product: \(detail.productId))")
    ///     case .deadLettered(let txId, let attempts, _):
    ///         logger.error("Dead-lettered: \(txId) after \(attempts) attempts")
    ///     default: break
    ///     }
    /// }
    /// ```
    public var onReceiptPipelineEvent: (@Sendable (AppActorReceiptPipelineEventDetail) -> Void)? {
        get { paymentContext.pipelineEventHandler }
        set {
            paymentContext.pipelineEventHandler = newValue
            if let processor = paymentProcessor {
                Task { await processor.setPipelineEventHandler(newValue) }
            }
        }
    }

    // MARK: - Internal Purchase Flow

    /// Core purchase execution: SK2 purchase → verify → enqueue receipt → post to server.
    ///
    /// Only one purchase may be in-flight at a time. Concurrent calls throw
    /// `AppActorError.purchaseAlreadyInProgress`.
    func executePaymentPurchase(
        product: Product,
        options: Set<Product.PurchaseOption> = [],
        offeringId: String? = nil,
        packageId: String? = nil
    ) async throws -> AppActorPurchaseResult {
        guard paymentLifecycle == .configured else {
            throw AppActorError.notConfigured
        }
        guard let processor = paymentProcessor,
              let storage = paymentStorage else {
            throw AppActorError.notConfigured
        }

        // Single-flight guard: only one purchase at a time
        guard !isPurchaseInProgress else {
            throw AppActorError.purchaseAlreadyInProgress
        }
        isPurchaseInProgress = true
        defer { isPurchaseInProgress = false }

        // Attach appAccountToken so Apple embeds it in the transaction JWS.
        // This binds the transaction to the current user for server-side reconciliation.
        let purchaseIdentity = attachAppAccountToken(to: options, storage: storage)
        let options = purchaseIdentity.options
        let purchaseAppUserId = storage.ensureAppUserId()
        Log.receipts.debug("Purchase with appAccountToken: \(String(purchaseIdentity.token.uuidString.lowercased().prefix(8)))…")

        // Execute the StoreKit purchase
        let result: Product.PurchaseResult
        do {
            result = try await product.purchase(options: options)
        } catch {
            if let skError = error as? StoreKitError, case .userCancelled = skError {
                return .cancelled
            }
            throw AppActorError.fromPurchaseError(error)
        }

        switch result {
        case .success(let verificationResult):
            switch verificationResult {
            case .verified(let transaction):
                // ASA purchase event tracking is handled centrally by
                // TransactionWatcher via Transaction.updates — no manual
                // enqueue needed here. Watcher start is kicked off in
                // configureInternal() before bootstrap, so it will
                // be listening well before any user-initiated purchase
                // can complete (StoreKit dialog requires human interaction).

                let jws = verificationResult.jwsRepresentation
                let item = AppActorPaymentProcessor.makePaymentQueueItem(
                    from: transaction,
                    jws: jws,
                    source: .purchase,
                    appUserId: purchaseAppUserId,
                    offeringId: offeringId,
                    packageId: packageId
                )

                let postResult = await processor.enqueueAndAwait(
                    item: item,
                    transaction: transaction
                )

                switch postResult {
                case .success(let customerInfo):
                    guard let customerInfo else {
                        throw AppActorError.clientError(
                            kind: .receiptPostFailed,
                            code: "NO_CUSTOMER_INFO",
                            message: "Server returned ok but no customer info"
                        )
                    }
                    // Update @Published customerInfo immediately so UI reflects
                    // premium state as soon as purchase() returns.
                    self.customerInfo = customerInfo
                    return .success(
                        customerInfo: customerInfo,
                        purchaseInfo: purchaseInfo(for: transaction)
                    )
                case .alreadyPosted:
                    // Another code path already finished the POST and we no longer
                    // have an in-memory terminal result for this key. Re-fetch the
                    // latest customer snapshot before surfacing a result.
                    // Fall back to cached customerInfo if the network call fails.
                    let info = (try? await getCustomerInfo()) ?? self.customerInfo
                    self.customerInfo = info
                    return .success(
                        customerInfo: info,
                        purchaseInfo: purchaseInfo(for: transaction)
                    )
                case .permanentlyRejected(let errorCode, let message, let requestId):
                    throw AppActorError.clientError(
                        kind: .receiptPostFailed,
                        code: errorCode,
                        message: message ?? "Server permanently rejected the receipt",
                        requestId: requestId
                    )
                case .queued:
                    // Server didn't confirm in time — compute offline entitlements
                    // from StoreKit transactions. Receipt stays queued for background retry.
                    if let offlineInfo = await queuedPurchaseOfflineCustomerInfo(appUserId: purchaseAppUserId) {
                        self.customerInfo = offlineInfo
                        return .success(
                            customerInfo: offlineInfo,
                            purchaseInfo: purchaseInfo(for: transaction)
                        )
                    }
                    // No offline entitlements available — fall through to error
                    throw AppActorError.clientError(
                        kind: .receiptQueuedForRetry,
                        code: "RECEIPT_QUEUED",
                        message: "Purchase succeeded but server did not confirm in time. Receipt is queued for automatic retry."
                    )
                }

            case .unverified(_, let error):
                Log.receipts.error("Purchase verification failed: \(error.localizedDescription)")
                throw AppActorError.clientError(
                    kind: .receiptPostFailed,
                    code: "VERIFICATION_FAILED",
                    message: "Transaction verification failed: \(error.localizedDescription)",
                    underlying: error
                )
            }

        case .userCancelled:
            return .cancelled

        case .pending:
            paymentContext.pendingProductCounts[product.id, default: 0] += 1
            Log.receipts.debug("Purchase deferred (pending): \(product.id)")
            return .pending

        @unknown default:
            Log.receipts.warn("Unknown PurchaseResult case for product \(product.id) — treating as pending")
            return .pending
        }
    }

    private func purchaseInfo(for transaction: Transaction) -> AppActorPurchaseInfo {
        AppActorPurchaseInfo(
            store: .appStore,
            productId: transaction.productID,
            transactionId: String(transaction.id),
            originalTransactionId: String(transaction.originalID),
            purchaseDate: transaction.purchaseDate,
            isSandbox: isSandbox(transaction)
        )
    }

    private func isSandbox(_ transaction: Transaction) -> Bool {
        AppActorASATransactionSupport.resolveEnvironment(
            for: transaction,
            jwsPayload: nil
        ) == .sandbox
    }

    func queuedPurchaseOfflineCustomerInfo(appUserId: String) async -> AppActorCustomerInfo? {
        guard let manager = customerManager else { return nil }
        let offlineKeys = await manager.activeEntitlementKeysOffline(appUserId: appUserId)
        guard let offlineInfo = offlineCustomerInfoIfIdentityMatches(
            expectedAppUserId: appUserId,
            offlineKeys: offlineKeys
        ) else {
            return nil
        }
        Log.receipts.info("Purchase queued — offline entitlements: \(offlineKeys)")
        return offlineInfo
    }
}

// MARK: - Payment State Accessors (delegating to PaymentContext)

extension AppActor {
    var paymentProcessor: AppActorPaymentProcessor? {
        get { paymentContext.paymentProcessor }
        set {
            paymentContext.paymentProcessor = newValue
            // Wire up pipeline event handler if already set
            if let handler = paymentContext.pipelineEventHandler, let processor = newValue {
                Task { await processor.setPipelineEventHandler(handler) }
            }
        }
    }

    var paymentQueueStore: AppActorPaymentQueueStoreProtocol? {
        get { paymentContext.paymentQueueStore }
        set { paymentContext.paymentQueueStore = newValue }
    }

    var transactionWatcher: AppActorTransactionWatcher? {
        get { paymentContext.transactionWatcher }
        set { paymentContext.transactionWatcher = newValue }
    }

    var isPurchaseInProgress: Bool {
        get { paymentContext.isPurchaseInProgress }
        set { paymentContext.isPurchaseInProgress = newValue }
    }

    var isBootstrapComplete: Bool {
        get { paymentContext.isBootstrapComplete }
        set { paymentContext.isBootstrapComplete = newValue }
    }

    var purchaseIntentWatcher: Any? {
        get { paymentContext.purchaseIntentWatcher }
        set { paymentContext.purchaseIntentWatcher = newValue }
    }

    var pendingPurchaseIntents: [Any] {
        get { paymentContext.pendingPurchaseIntents }
        set { paymentContext.pendingPurchaseIntents = newValue }
    }
}

// MARK: - StoreKit Error Mapping

extension AppActorError {

    /// Maps any purchase-time error (StoreKit or generic) to a specific `AppActorError`.
    @available(iOS 15.0, macOS 12.0, tvOS 15.0, watchOS 8.0, *)
    static func fromPurchaseError(_ error: Error) -> AppActorError {
        // iOS 16.4+ purchase-specific errors
        if #available(iOS 16.4, macOS 14.4, tvOS 16.4, watchOS 9.4, *) {
            if let purchaseError = error as? Product.PurchaseError {
                switch purchaseError {
                case .invalidOfferIdentifier:
                    return .clientError(
                        kind: .invalidOffer,
                        code: "INVALID_OFFER_IDENTIFIER",
                        message: "The offer identifier is invalid",
                        underlying: purchaseError
                    )
                case .invalidOfferPrice:
                    return .clientError(
                        kind: .invalidOffer,
                        code: "INVALID_OFFER_PRICE",
                        message: "The offer price is invalid",
                        underlying: purchaseError
                    )
                case .invalidOfferSignature:
                    return .clientError(
                        kind: .invalidOffer,
                        code: "INVALID_OFFER_SIGNATURE",
                        message: "The offer signature is invalid",
                        underlying: purchaseError
                    )
                case .missingOfferParameters:
                    return .clientError(
                        kind: .invalidOffer,
                        code: "MISSING_OFFER_PARAMETERS",
                        message: "Required offer parameters are missing",
                        underlying: purchaseError
                    )
                case .ineligibleForOffer:
                    return .clientError(
                        kind: .purchaseIneligible,
                        code: "INELIGIBLE_FOR_OFFER",
                        message: "The user is not eligible for this offer",
                        underlying: purchaseError
                    )
                default:
                    break
                }
            }
        }

        if let skError = error as? StoreKitError {
            switch skError {
            case .networkError(let urlError):
                return .networkError(urlError)
            case .notAvailableInStorefront:
                return .clientError(
                    kind: .productNotAvailableInStorefront,
                    code: "NOT_AVAILABLE_IN_STOREFRONT",
                    message: "Product is not available in the current storefront",
                    underlying: skError
                )
            case .systemError(let systemError):
                return .clientError(
                    kind: .purchaseFailed,
                    code: "STOREKIT_SYSTEM_ERROR",
                    message: "StoreKit system error: \(systemError.localizedDescription)",
                    underlying: systemError
                )
            default:
                break
            }
        }
        return .clientError(
            kind: .purchaseFailed,
            code: "PURCHASE_FAILED",
            message: "Purchase failed: \(error.localizedDescription)",
            underlying: error
        )
    }
}
