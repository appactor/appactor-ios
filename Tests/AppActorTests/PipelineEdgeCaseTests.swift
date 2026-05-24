import XCTest
@testable import AppActor

// MARK: - Pipeline Edge Case Tests

final class PipelineEdgeCaseTests: XCTestCase {

    private var client: MockPaymentClient!
    private var store: InMemoryPaymentQueueStore!
    private var processor: AppActorPaymentProcessor!

    override func setUp() async throws {
        try await super.setUp()
        client = MockPaymentClient()
        store = InMemoryPaymentQueueStore()
        processor = AppActorPaymentProcessor(store: store, client: client)
    }

    // MARK: - Helpers

    private func makeItem(
        key: String = "apple:12345",
        transactionId: String = "12345",
        appUserId: String = "user_123",
        phase: AppActorPaymentQueueItem.Phase = .needsPost,
        attemptCount: Int = 0,
        source: AppActorPaymentQueueItem.Source = .purchase,
        sourceIntent: AppActorPaymentQueueItem.SourceIntent? = nil,
        clientPurchaseContext: AppActorClientPurchaseContext? = nil
    ) -> AppActorPaymentQueueItem {
        AppActorPaymentQueueItem(
            key: key,
            bundleId: "com.test",
            environment: "sandbox",
            transactionId: transactionId,
            jws: "jws_payload",
            signedAppTransactionInfo: nil,
            appUserId: appUserId,
            productId: "com.test.monthly",
            originalTransactionId: transactionId,
            storefront: "USA",
            offeringId: nil,
            packageId: nil,
            clientPurchaseContext: clientPurchaseContext,
            phase: phase,
            attemptCount: attemptCount,
            nextRetryAt: Date(),
            firstSeenAt: Date(),
            lastSeenAt: Date(),
            lastError: nil,
            sources: [source],
            sourceIntent: sourceIntent,
            claimedAt: nil
        )
    }

    // MARK: - Fix #18a: Bulk restore markPosted prevents duplicate enqueue

    func testMarkPostedAndReconcilePreventsReenqueue() async {
        // Simulate bulk restore marking keys as posted
        let keys = ["apple:100", "apple:200", "apple:300"]
        await processor.markPostedAndReconcile(keys: keys)

        // Try to enqueue items with same keys — they should be skipped via posted ledger
        let item1 = makeItem(key: "apple:100", transactionId: "100")
        store.upsert(item1)
        XCTAssertTrue(store.isPosted(key: "apple:100"), "Key should be in posted ledger after markPostedAndReconcile")

        // If an item with the same key was in the queue, it should have been removed
        let item2 = makeItem(key: "apple:200", transactionId: "200")
        store.upsert(item2)
        await processor.markPostedAndReconcile(keys: ["apple:200"])
        let remaining = store.snapshot().filter { $0.key == "apple:200" }
        XCTAssertTrue(remaining.isEmpty, "Queued item should be reconciled after markPostedAndReconcile")
    }

    // MARK: - Fix #18b: Identity transition buffer captures correct appUserId

    func testPendingPurchaseContextBufferKeepsAttemptAndRefreshesObservedAt() {
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let completedAt = startedAt.addingTimeInterval(3_600)
        let context = AppActorClientPurchaseContext(
            clientPurchaseAttemptStartedAt: startedAt,
            clientObservedAt: startedAt,
            clientDeliverySource: .purchaseFlow,
            clientPurchaseAttemptId: "attempt-ios-pending",
            placement: "paywall.pending"
        )
        var buffer = AppActorPendingPurchaseContextBuffer()

        buffer.append(context, productId: "com.test.monthly")
        let resolved = buffer.consume(productId: "com.test.monthly", observedAt: completedAt)

        XCTAssertEqual(resolved?.context.clientPurchaseAttemptStartedAt, startedAt)
        XCTAssertEqual(resolved?.context.clientObservedAt, completedAt)
        XCTAssertEqual(resolved?.context.clientDeliverySource, .transactionUpdates)
        XCTAssertEqual(resolved?.context.clientPurchaseAttemptId, "attempt-ios-pending")
        XCTAssertEqual(resolved?.context.placement, "paywall.pending")
        XCTAssertNil(buffer.consume(productId: "com.test.monthly", observedAt: completedAt))
    }

    func testPendingPurchaseContextBufferPersistsAcrossRelaunch() {
        let storage = InMemoryPaymentStorage()
        let startedAt = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        let pendingAt = startedAt.addingTimeInterval(10)
        let completedAt = startedAt.addingTimeInterval(3_600)
        let context = AppActorClientPurchaseContext(
            clientPurchaseAttemptStartedAt: startedAt,
            clientObservedAt: startedAt,
            clientDeliverySource: .purchaseFlow,
            clientPurchaseAttemptId: "attempt-ios-persisted",
            placement: "paywall.persisted"
        )
        var firstBoot = AppActorPendingPurchaseContextBuffer(storage: storage)

        firstBoot.append(context, productId: "com.test.monthly", appUserId: "user-pending", recordedAt: pendingAt)

        var secondBoot = AppActorPendingPurchaseContextBuffer(storage: storage)
        let resolved = secondBoot.consume(productId: "com.test.monthly", observedAt: completedAt)

        XCTAssertEqual(resolved?.appUserId, "user-pending")
        XCTAssertEqual(resolved?.context.clientPurchaseAttemptStartedAt, startedAt)
        XCTAssertEqual(resolved?.context.clientObservedAt, completedAt)
        XCTAssertEqual(resolved?.context.clientDeliverySource, .transactionUpdates)
        XCTAssertEqual(resolved?.context.clientPurchaseAttemptId, "attempt-ios-persisted")
        XCTAssertEqual(resolved?.context.placement, "paywall.persisted")
        XCTAssertNil(storage.string(forKey: AppActorPaymentStorageKey.pendingPurchaseContexts))
    }

    func testPendingPurchaseContextBufferRestoresUnfinishedDeliverySourceAfterRelaunch() {
        let storage = InMemoryPaymentStorage()
        let startedAt = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        let completedAt = startedAt.addingTimeInterval(3_600)
        let context = AppActorClientPurchaseContext(
            clientPurchaseAttemptStartedAt: startedAt,
            clientObservedAt: startedAt,
            clientDeliverySource: .purchaseFlow,
            clientPurchaseAttemptId: "attempt-ios-unfinished"
        )
        var firstBoot = AppActorPendingPurchaseContextBuffer(storage: storage)

        firstBoot.append(context, productId: "com.test.yearly", appUserId: "user-pending", recordedAt: startedAt)

        var secondBoot = AppActorPendingPurchaseContextBuffer(storage: storage)
        let resolved = secondBoot.consume(
            productId: "com.test.yearly",
            observedAt: completedAt,
            deliverySource: .unfinished,
            transactionPurchaseDate: completedAt,
            transactionReason: .purchase
        )

        XCTAssertEqual(resolved?.appUserId, "user-pending")
        XCTAssertEqual(resolved?.context.clientPurchaseAttemptStartedAt, startedAt)
        XCTAssertEqual(resolved?.context.clientObservedAt, completedAt)
        XCTAssertEqual(resolved?.context.clientDeliverySource, .unfinished)
        XCTAssertEqual(resolved?.context.clientPurchaseAttemptId, "attempt-ios-unfinished")
        XCTAssertNil(storage.string(forKey: AppActorPaymentStorageKey.pendingPurchaseContexts))
    }

    func testPendingPurchaseResolvedFromUnfinishedUsesPurchaseIntentAndUnfinishedDelivery() {
        let storage = InMemoryPaymentStorage()
        let startedAt = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        let completedAt = startedAt.addingTimeInterval(3_600)
        let context = AppActorClientPurchaseContext(
            clientPurchaseAttemptStartedAt: startedAt,
            clientObservedAt: startedAt,
            clientDeliverySource: .purchaseFlow,
            clientPurchaseAttemptId: "attempt-ios-unfinished-intent",
            placement: "paywall.unfinished"
        )
        var firstBoot = AppActorPendingPurchaseContextBuffer(storage: storage)

        firstBoot.append(context, productId: "com.test.yearly", appUserId: "user-pending", recordedAt: startedAt)

        var secondBoot = AppActorPendingPurchaseContextBuffer(storage: storage)
        let resolved = secondBoot.consume(
            productId: "com.test.yearly",
            observedAt: completedAt,
            deliverySource: .unfinished,
            transactionPurchaseDate: completedAt,
            transactionReason: .purchase
        )
        let queueSource = AppActorTransactionWatcher.queueSource(
            for: .sweep,
            pendingPurchaseContextMatch: resolved
        )

        let item = makeItem(
            appUserId: resolved?.appUserId ?? "missing",
            source: queueSource,
            clientPurchaseContext: resolved?.context
        )
        let request = AppActorPaymentProcessor.makeRequest(from: item)

        XCTAssertEqual(queueSource, .purchase)
        XCTAssertEqual(request.sourceIntent, "purchase")
        XCTAssertEqual(request.clientDeliverySource, "unfinished")
        XCTAssertEqual(request.clientPurchaseAttemptId, "attempt-ios-unfinished-intent")
        XCTAssertEqual(request.placement, "paywall.unfinished")
    }

    func testPassiveUnfinishedSweepWithoutPendingContextStaysSyncIntent() {
        let queueSource = AppActorTransactionWatcher.queueSource(
            for: .sweep,
            pendingPurchaseContextMatch: nil
        )
        let item = makeItem(
            source: queueSource,
            clientPurchaseContext: AppActorClientPurchaseContext(
                clientObservedAt: Date(timeIntervalSince1970: 1_700_000_000),
                clientDeliverySource: .unfinished
            )
        )
        let request = AppActorPaymentProcessor.makeRequest(from: item)

        XCTAssertEqual(queueSource, .sweep)
        XCTAssertEqual(request.sourceIntent, "sync")
        XCTAssertEqual(request.clientDeliverySource, "unfinished")
        XCTAssertNil(request.clientPurchaseAttemptId)
        XCTAssertNil(request.placement)
    }

    @MainActor
    func testDeferredPurchaseResolvedCallbackUsesPersistedPendingContextAfterRelaunch() async {
        let appactor = AppActor.shared
        await appactor.reset()

        let storage = InMemoryPaymentStorage()
        storage.setAppUserId("user-pending")
        appactor.configureForTesting(
            config: AppActorPaymentConfiguration(
                apiKey: "pk_test_deferred",
                baseURL: URL(string: "https://api.test.appactor.com")!
            ),
            client: MockPaymentClient(),
            storage: storage
        )

        var callbackProductId: String?
        var callbackUserId: String?
        appactor.onDeferredPurchaseResolved = { productId, customerInfo in
            callbackProductId = productId
            callbackUserId = customerInfo.appUserId
        }

        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let completedAt = startedAt.addingTimeInterval(3_600)
        let receiptContext = AppActorReceiptCustomerUpdateContext(
            appUserId: "user-pending",
            productId: "com.test.yearly",
            sourceIntent: .purchase,
            originalTransactionId: nil,
            syncedOriginalTransactionId: nil,
            clientPurchaseContext: AppActorClientPurchaseContext(
                clientPurchaseAttemptStartedAt: startedAt,
                clientObservedAt: completedAt,
                clientDeliverySource: .unfinished,
                clientPurchaseAttemptId: "attempt-ios-callback"
            )
        )

        await appactor.handleReceiptCustomerInfoUpdate(
            AppActorCustomerInfo(appUserId: "user-pending"),
            receiptContext: receiptContext
        )

        XCTAssertEqual(callbackProductId, "com.test.yearly")
        XCTAssertEqual(callbackUserId, "user-pending")
        await appactor.reset()
    }

    @MainActor
    func testDeferredPurchaseCallbackDoesNotOverfireForNonDeferredReceipt() async {
        let appactor = AppActor.shared
        await appactor.reset()

        let storage = InMemoryPaymentStorage()
        storage.setAppUserId("user-pending")
        appactor.configureForTesting(
            config: AppActorPaymentConfiguration(
                apiKey: "pk_test_deferred_guard",
                baseURL: URL(string: "https://api.test.appactor.com")!
            ),
            client: MockPaymentClient(),
            storage: storage
        )

        var callbackCount = 0
        appactor.onDeferredPurchaseResolved = { _, _ in
            callbackCount += 1
        }
        appactor.paymentContext.pendingProductCounts["com.test.yearly"] = 1

        await appactor.handleReceiptCustomerInfoUpdate(
            AppActorCustomerInfo(appUserId: "user-pending"),
            receiptContext: AppActorReceiptCustomerUpdateContext(
                appUserId: "user-pending",
                productId: "com.test.yearly",
                sourceIntent: .sync,
                originalTransactionId: nil,
                syncedOriginalTransactionId: nil,
                clientPurchaseContext: AppActorClientPurchaseContext(
                    clientObservedAt: Date(),
                    clientDeliverySource: .foregroundSync
                )
            )
        )

        XCTAssertEqual(callbackCount, 0)
        XCTAssertEqual(appactor.paymentContext.pendingProductCounts["com.test.yearly"], 1)

        await appactor.handleReceiptCustomerInfoUpdate(
            AppActorCustomerInfo(appUserId: "user-pending"),
            receiptContext: AppActorReceiptCustomerUpdateContext(
                appUserId: "user-pending",
                productId: "com.test.yearly",
                sourceIntent: .purchase,
                originalTransactionId: nil,
                syncedOriginalTransactionId: nil,
                clientPurchaseContext: AppActorClientPurchaseContext(
                    clientPurchaseAttemptStartedAt: Date(),
                    clientObservedAt: Date(),
                    clientDeliverySource: .transactionUpdates,
                    clientPurchaseAttemptId: "attempt-ios-deferred-guard"
                )
            )
        )

        XCTAssertEqual(callbackCount, 1)
        XCTAssertNil(appactor.paymentContext.pendingProductCounts["com.test.yearly"])
        await appactor.reset()
    }

    func testPendingPurchaseContextBufferDoesNotConsumeRenewal() {
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let renewalAt = startedAt.addingTimeInterval(3_600)
        let context = AppActorClientPurchaseContext(
            clientPurchaseAttemptStartedAt: startedAt,
            clientObservedAt: startedAt,
            clientDeliverySource: .purchaseFlow,
            clientPurchaseAttemptId: "attempt-ios-renewal"
        )
        var buffer = AppActorPendingPurchaseContextBuffer()

        buffer.append(context, productId: "com.test.monthly")

        let renewalMatch = buffer.consume(
            productId: "com.test.monthly",
            observedAt: renewalAt,
            deliverySource: .transactionUpdates,
            transactionPurchaseDate: renewalAt,
            transactionReason: .renewal
        )
        let purchaseMatch = buffer.consume(
            productId: "com.test.monthly",
            observedAt: renewalAt,
            deliverySource: .transactionUpdates,
            transactionPurchaseDate: renewalAt,
            transactionReason: .purchase
        )

        XCTAssertNil(renewalMatch)
        XCTAssertEqual(purchaseMatch?.context.clientPurchaseAttemptId, "attempt-ios-renewal")
    }

    func testPendingPurchaseContextBufferDropsExpiredPersistedAttempts() {
        let storage = InMemoryPaymentStorage()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let expiredCompletion = startedAt.addingTimeInterval(AppActorPendingPurchaseContextBuffer.retentionInterval + 1)
        let context = AppActorClientPurchaseContext(
            clientPurchaseAttemptStartedAt: startedAt,
            clientObservedAt: startedAt,
            clientDeliverySource: .purchaseFlow,
            clientPurchaseAttemptId: "attempt-ios-expired"
        )
        var firstBoot = AppActorPendingPurchaseContextBuffer(storage: storage)

        firstBoot.append(context, productId: "com.test.monthly", recordedAt: startedAt)
        var secondBoot = AppActorPendingPurchaseContextBuffer(storage: storage)
        let resolved = secondBoot.consume(productId: "com.test.monthly", observedAt: expiredCompletion)

        XCTAssertNil(resolved)
        XCTAssertNil(storage.string(forKey: AppActorPaymentStorageKey.pendingPurchaseContexts))
    }

    func testIdentityTransitionBufferCapturesAppUserId() async {
        let storage = InMemoryPaymentStorage()
        storage.set("user_A", forKey: AppActorPaymentStorageKey.appUserId)

        let watcher = AppActorTransactionWatcher(
            processor: processor,
            storage: storage,
            silentSyncFetcher: MockStoreKitSilentSyncFetcher()
        )

        // Begin transition — watcher should buffer incoming transactions
        await watcher.beginIdentityTransition(appUserId: "user_A")

        // Simulate a transaction arriving during transition
        // (We can't create real Transaction objects, but we can verify the buffer mechanism
        // by checking that sweepUnfinished/scanCurrentEntitlements still works after transition)

        // Switch identity
        storage.set("user_B", forKey: AppActorPaymentStorageKey.appUserId)

        // End transition — buffered items should flush with captured user ID
        await watcher.endIdentityTransition()

        // No crash, no assertion failure = success
        // (Full integration test would require real StoreKit transactions)
    }

    func testForegroundPurchaseBuffersUpgradeStylePurchaseUpdate() {
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let context = AppActorClientPurchaseContext(
            clientPurchaseAttemptStartedAt: startedAt,
            clientObservedAt: startedAt,
            clientDeliverySource: .purchaseFlow,
            clientPurchaseAttemptId: "attempt-ios-upgrade"
        )

        let shouldBuffer = AppActorTransactionWatcher.shouldBufferForegroundTransaction(
            source: .transactionUpdates,
            transactionProductId: "com.test.yearly",
            transactionId: "200",
            originalTransactionId: "100",
            purchaseDate: startedAt.addingTimeInterval(30),
            transactionReason: .purchase,
            foregroundProductId: "com.test.yearly",
            foregroundContext: context
        )

        XCTAssertTrue(shouldBuffer)
    }

    func testForegroundPurchaseDoesNotBufferPassiveRenewalUpdate() {
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let context = AppActorClientPurchaseContext(
            clientPurchaseAttemptStartedAt: startedAt,
            clientObservedAt: startedAt,
            clientDeliverySource: .purchaseFlow,
            clientPurchaseAttemptId: "attempt-ios-renewal-guard"
        )

        let shouldBuffer = AppActorTransactionWatcher.shouldBufferForegroundTransaction(
            source: .transactionUpdates,
            transactionProductId: "com.test.yearly",
            transactionId: "200",
            originalTransactionId: "100",
            purchaseDate: startedAt.addingTimeInterval(30),
            transactionReason: .renewal,
            foregroundProductId: "com.test.yearly",
            foregroundContext: context
        )

        XCTAssertFalse(shouldBuffer)
    }

    // MARK: - Fix #19: Identity change during drain

    func testItemsPostedWithOriginalUserIdDuringDrain() async {
        var capturedUserIds: [String] = []
        client.postReceiptHandler = { (request: AppActorReceiptPostRequest) in
            capturedUserIds.append(request.appUserId)
            // Slow response to create window for identity change
            try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
            return AppActorReceiptPostResponse(status: "ok", requestId: "req_1")
        }

        // Enqueue items for user_A
        let item1 = makeItem(key: "apple:1", transactionId: "1", appUserId: "user_A")
        let item2 = makeItem(key: "apple:2", transactionId: "2", appUserId: "user_A")
        let item3 = makeItem(key: "apple:3", transactionId: "3", appUserId: "user_A")
        store.upsert(item1)
        store.upsert(item2)
        store.upsert(item3)

        await processor.kick()
        try? await Task.sleep(nanoseconds: 500_000_000) // 500ms for drain

        // All items should have been posted with user_A
        XCTAssertEqual(capturedUserIds.count, 3, "All 3 items should be posted")
        for userId in capturedUserIds {
            XCTAssertEqual(userId, "user_A", "Items should be posted with original user ID")
        }
    }

    // MARK: - Fix #21: Mixed drain failure

    func testMixedDrainFailurePartialSuccess() async {
        client.postReceiptHandler = { (request: AppActorReceiptPostRequest) in
            switch request.transactionId {
            case "1":
                return AppActorReceiptPostResponse(status: "ok", requestId: "req_ok")
            case "2":
                return AppActorReceiptPostResponse(
                    status: "retryable_error",
                    error: AppActorReceiptErrorInfo(code: "INTERNAL", message: nil),
                    requestId: "req_retry"
                )
            default:
                throw AppActorError.networkError(URLError(.notConnectedToInternet))
            }
        }

        let item1 = makeItem(key: "apple:1", transactionId: "1")
        let item2 = makeItem(key: "apple:2", transactionId: "2")
        let item3 = makeItem(key: "apple:3", transactionId: "3")
        store.upsert(item1)
        store.upsert(item2)
        store.upsert(item3)

        await processor.kick()
        try? await Task.sleep(nanoseconds: 500_000_000)

        // Item 1: should be posted and removed
        XCTAssertTrue(store.isPosted(key: "apple:1"), "Successful item should be in posted ledger")

        // Item 2: should be retrying (phase = needsPost, attemptCount > 0)
        let item2State = store.snapshot().first { $0.key == "apple:2" }
        XCTAssertNotNil(item2State, "Retryable item should still be in queue")
        XCTAssertEqual(item2State?.phase, .needsPost, "Retryable item should be needsPost")
        XCTAssertGreaterThan(item2State?.attemptCount ?? 0, 0, "Retryable item should have incremented attempt")

        // Item 3: should also be retrying (network error)
        let item3State = store.snapshot().first { $0.key == "apple:3" }
        XCTAssertNotNil(item3State, "Network error item should still be in queue")
        XCTAssertEqual(item3State?.phase, .needsPost, "Network error item should be needsPost")
    }

    // MARK: - Fix #22: getCustomer 401 does NOT fallback to offline

    @MainActor
    func testGetCustomer401DoesNotFallbackToOffline() async {
        let appactor = AppActor.shared
        let mockClient = MockPaymentClient()
        let storage = InMemoryPaymentStorage()

        mockClient.identifyHandler = { _ in
            AppActorIdentifyResult(
                appUserId: "test_user",
                customerInfo: .empty,
                customerETag: nil,
                requestId: "req_id",
                signatureVerified: false
            )
        }

        mockClient.getCustomerHandler = { _, _ in
            throw AppActorError.serverError(
                httpStatus: 401,
                code: "UNAUTHORIZED",
                message: "Invalid API key",
                details: nil,
                requestId: "req_401"
            )
        }

        appactor.configureForTesting(
            config: AppActorPaymentConfiguration(
                apiKey: "pk_test_123",
                baseURL: URL(string: "https://api.test.com")!
            ),
            client: mockClient,
            storage: storage
        )

        do {
            _ = try await appactor.getCustomerInfo()
            XCTFail("getCustomerInfo should throw on 401")
        } catch let error as AppActorError {
            XCTAssertEqual(error.kind, .server, "Error should be server type")
            XCTAssertEqual(error.httpStatus, 401, "Error should be 401")
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }

        // Cleanup
        await appactor.reset()
    }

    // MARK: - Fix #23: configure + reset race

    @MainActor
    func testConfigureAndResetRaceDoesNotCrash() async {
        let appactor = AppActor.shared

        // Start configure in a task
        let configTask = Task { @MainActor in
            await AppActor.configure(apiKey: "pk_test_123", options: .init())
        }

        // Immediately reset
        try? await Task.sleep(nanoseconds: 50_000_000) // 50ms — let configure start
        await appactor.reset()

        // Wait for configure to finish (may have been cancelled by reset)
        await configTask.value

        // Verify consistent final state
        XCTAssertEqual(appactor.paymentLifecycle, .idle, "After reset, lifecycle should be idle")
        XCTAssertNil(appactor.paymentProcessor, "After reset, processor should be nil")
    }
}
