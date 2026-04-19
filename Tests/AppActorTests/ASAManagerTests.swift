import XCTest
@testable import AppActor

// MARK: - Helpers

private func makeDefaultOptions(debugMode: Bool = false) -> AppActorASAOptions {
    AppActorASAOptions(autoTrackPurchases: true, debugMode: debugMode)
}

private func make400Error() -> AppActorError {
    .serverError(httpStatus: 400, code: "BAD_REQUEST", message: "bad", details: nil, requestId: nil)
}

private func make500Error() -> AppActorError {
    .serverError(httpStatus: 500, code: "INTERNAL", message: "server error", details: nil, requestId: nil)
}

private func make429Error() -> AppActorError {
    .serverError(httpStatus: 429, code: "RATE_LIMITED", message: "slow down", details: nil, requestId: nil, retryAfterSeconds: 1.0)
}

// MARK: - Attribution Tests

final class ASAAttributionTests: XCTestCase {

    private var client: MockPaymentClient!
    private var storage: InMemoryPaymentStorage!
    private var eventStore: InMemoryASAEventStore!
    private var tokenProvider: MockASATokenProvider!

    override func setUp() {
        super.setUp()
        client = MockPaymentClient()
        storage = InMemoryPaymentStorage()
        eventStore = InMemoryASAEventStore()
        tokenProvider = MockASATokenProvider()
    }

    private func makeManager(debugMode: Bool = false) -> AppActorASAManager {
        // Set app user ID (required for attribution)
        storage.set("user_123", forKey: AppActorPaymentStorageKey.appUserId)
        return AppActorASAManager(
            client: client,
            storage: storage,
            eventStore: eventStore,
            tokenProvider: tokenProvider,
            options: makeDefaultOptions(debugMode: debugMode),
            sdkVersion: "1.0.0-test"
        )
    }

    // MARK: - Happy Path

    func testAttributionSuccess() async {
        let manager = makeManager()
        let result = await manager.performAttributionIfNeeded()

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.attributionStatus, .attributed)
        XCTAssertEqual(result?.campaignId, 100)
        XCTAssertEqual(client.attributionCalls.count, 1)
        XCTAssertTrue(storage.asaAttributionCompleted)
    }

    // MARK: - Already Completed

    func testAttributionSkipsWhenAlreadyCompleted() async {
        storage.set("user_123", forKey: AppActorPaymentStorageKey.appUserId)
        storage.setAsaAttributionCompleted(true)

        let manager = AppActorASAManager(
            client: client, storage: storage, eventStore: eventStore,
            tokenProvider: tokenProvider, options: makeDefaultOptions(),
            sdkVersion: "1.0.0"
        )

        let result = await manager.performAttributionIfNeeded()
        XCTAssertNil(result)
        XCTAssertEqual(client.attributionCalls.count, 0, "Should not call server when already completed")
    }

    // MARK: - Organic (No Token)

    func testAttributionOrganicWhenUnavailable() async {
        tokenProvider.tokenResult = .unavailable
        let manager = makeManager()

        let result = await manager.performAttributionIfNeeded()
        XCTAssertNil(result)
        XCTAssertTrue(storage.asaAttributionCompleted, "Should mark completed for organic installs")
        XCTAssertEqual(client.attributionCalls.count, 0)
    }

    // MARK: - Permanent 4xx Error

    func testAttributionPermanent4xxMarksCompleted() async {
        client.attributionHandler = { _ in throw make400Error() }
        let manager = makeManager()

        let result = await manager.performAttributionIfNeeded()
        XCTAssertNil(result)
        XCTAssertTrue(storage.asaAttributionCompleted, "Permanent 4xx should mark completed")
        XCTAssertEqual(client.attributionCalls.count, 1, "Should not retry on permanent error")
    }

    // MARK: - Transient 5xx Retries

    func testAttributionRetries5xxThenSucceeds() async {
        var callCount = 0
        client.attributionHandler = { request in
            callCount += 1
            if callCount < 3 {
                throw make500Error()
            }
            return AppActorASAAttributionResponseDTO(
                status: "ok",
                attribution: AppActorASAAttributionResultDTO(
                    attributionStatus: "attributed", appleOrgId: nil, campaignId: nil,
                    campaignName: nil, adGroupId: nil, adGroupName: nil,
                    keywordId: nil, keywordName: nil, creativeSetId: nil,
                    conversionType: nil, claimType: nil, region: nil,
                    supplyPlacement: nil
                )
            )
        }

        let manager = makeManager()
        let result = await manager.performAttributionIfNeeded()

        XCTAssertNotNil(result, "Should succeed after transient failures")
        XCTAssertEqual(callCount, 3, "Should retry twice then succeed")
        XCTAssertTrue(storage.asaAttributionCompleted)
    }

    // MARK: - All Retries Exhausted

    func testAttributionDoesNotMarkCompletedOnExhaustion() async {
        client.attributionHandler = { _ in throw make500Error() }
        let manager = makeManager()

        let result = await manager.performAttributionIfNeeded()
        XCTAssertNil(result)
        XCTAssertFalse(storage.asaAttributionCompleted, "Should NOT mark completed when retries exhausted")
        XCTAssertEqual(client.attributionCalls.count, 3, "Should attempt maxAttributionAttempts times")
    }

    // MARK: - 429 is Transient (not permanent 4xx)

    func testAttribution429IsTransientNotPermanent() async {
        client.attributionHandler = { _ in throw make429Error() }
        let manager = makeManager()

        _ = await manager.performAttributionIfNeeded()
        XCTAssertFalse(storage.asaAttributionCompleted, "429 should NOT mark completed (it's transient)")
        XCTAssertEqual(client.attributionCalls.count, 3, "429 should be retried")
    }

    // MARK: - Token Error Defers (P1)

    func testAttributionDefersOnTokenError() async {
        tokenProvider.tokenResult = .error(NSError(domain: "AdServices", code: -1, userInfo: [NSLocalizedDescriptionKey: "Transient"]))
        let manager = makeManager()

        let result = await manager.performAttributionIfNeeded()
        XCTAssertNil(result)
        XCTAssertFalse(storage.asaAttributionCompleted, "Token error should NOT mark completed — retry on next launch")
        XCTAssertEqual(client.attributionCalls.count, 0, "Should not call server when token fetch fails")
    }

    // MARK: - Concurrent Attribution Re-Entrancy (M7)

    func testConcurrentAttributionSkipsSecondCall() async {
        // Make client slow so first attribution is still in-flight when second starts
        client.attributionHandler = { request in
            try await Task.sleep(nanoseconds: 200_000_000) // 200ms
            return AppActorASAAttributionResponseDTO(
                status: "ok",
                attribution: AppActorASAAttributionResultDTO(
                    attributionStatus: "attributed", appleOrgId: nil, campaignId: nil,
                    campaignName: nil, adGroupId: nil, adGroupName: nil,
                    keywordId: nil, keywordName: nil, creativeSetId: nil,
                    conversionType: nil, claimType: nil, region: nil,
                    supplyPlacement: nil
                )
            )
        }

        let manager = makeManager()

        // Launch two concurrent attributions
        async let attr1 = manager.performAttributionIfNeeded()
        async let attr2 = manager.performAttributionIfNeeded()
        let results = await (attr1, attr2)

        // Exactly one should succeed, the other should return nil (re-entrancy guard)
        let nonNilCount = [results.0, results.1].compactMap { $0 }.count
        XCTAssertEqual(nonNilCount, 1, "Re-entrancy guard should prevent second concurrent attribution")
        XCTAssertEqual(client.attributionCalls.count, 1, "Server should only be called once")
    }

    // MARK: - Response Status Validation (M3)

    func testAttributionNonOkResponseRetriesThenFails() async {
        // Server returns non-"ok" status every time
        client.attributionHandler = { _ in
            return AppActorASAAttributionResponseDTO(
                status: "error",
                attribution: AppActorASAAttributionResultDTO(
                    attributionStatus: "unknown", appleOrgId: nil, campaignId: nil,
                    campaignName: nil, adGroupId: nil, adGroupName: nil,
                    keywordId: nil, keywordName: nil, creativeSetId: nil,
                    conversionType: nil, claimType: nil, region: nil,
                    supplyPlacement: nil
                )
            )
        }

        let manager = makeManager()
        let result = await manager.performAttributionIfNeeded()

        XCTAssertNil(result, "Non-ok status should not succeed")
        XCTAssertEqual(client.attributionCalls.count, 3, "Should retry maxAttributionAttempts times")
        XCTAssertFalse(storage.asaAttributionCompleted, "Should NOT mark completed when all retries fail")
    }

    // MARK: - Missing Confirmed Identity

    func testAttributionDefersWhenConfirmedIdentityMissing() async {
        let manager = AppActorASAManager(
            client: client, storage: storage, eventStore: eventStore,
            tokenProvider: tokenProvider, options: makeDefaultOptions(),
            sdkVersion: "1.0.0"
        )
        // storage has no confirmed identity — attribution should defer.

        let result = await manager.performAttributionIfNeeded()
        XCTAssertNil(result, "Should defer until a confirmed server identity exists")
        XCTAssertNil(storage.currentAppUserId, "ASA should not generate a local-only identity anymore")
        XCTAssertEqual(client.attributionCalls.count, 0, "Should not POST attribution without a confirmed identity")
        XCTAssertFalse(storage.asaAttributionCompleted, "Deferred attribution must remain retryable")
    }
}

// MARK: - Purchase Event Tests

final class ASAPurchaseEventTests: XCTestCase {

    private var client: MockPaymentClient!
    private var storage: InMemoryPaymentStorage!
    private var eventStore: InMemoryASAEventStore!

    override func setUp() {
        super.setUp()
        client = MockPaymentClient()
        storage = InMemoryPaymentStorage()
        eventStore = InMemoryASAEventStore()

        // M2: enqueuePurchaseEvent now auto-flushes after enqueue.
        // Default handler returns "ok" which would remove events immediately.
        // Make it fail by default so enqueue tests can verify store state.
        // Tests that need successful flush override this or use enqueueTestEvent() directly.
        client.purchaseEventHandler = { _ in
            throw AppActorError(
                kind: .network, httpStatus: 500, code: nil,
                message: "Test default: flush disabled", details: nil,
                requestId: nil, underlying: nil, scope: nil, retryAfterSeconds: nil
            )
        }
    }

    private func makeManager() -> AppActorASAManager {
        AppActorASAManager(
            client: client, storage: storage, eventStore: eventStore,
            tokenProvider: MockASATokenProvider(),
            options: makeDefaultOptions(),
            sdkVersion: "1.0.0"
        )
    }

    private func enqueueTestEvent(productId: String = "com.test.monthly", userId: String = "user_1") {
        let request = AppActorASAPurchaseEventRequest(
            userId: userId, productId: productId,
            transactionId: "tx_123", originalTransactionId: "tx_orig_123",
            purchaseDate: "2025-01-01T00:00:00Z", countryCode: "US",
            storekit2Json: nil, appVersion: "1.0", osVersion: "17.0", libVersion: "1.0.0"
        )
        let event = AppActorASAStoredEvent(id: UUID().uuidString, request: request, retryCount: 0, createdAt: Date())
        eventStore.enqueue(event)
    }

    // MARK: - Empty Queue

    func testFlushDoesNothingWhenEmpty() async {
        let manager = makeManager()
        await manager.flushPendingPurchaseEvents()
        XCTAssertEqual(client.purchaseEventCalls.count, 0)
    }

    // MARK: - Happy Path

    func testFlushSendsSingleEvent() async {
        enqueueTestEvent()
        client.purchaseEventHandler = nil  // Use default success response
        let manager = makeManager()

        await manager.flushPendingPurchaseEvents()

        XCTAssertEqual(client.purchaseEventCalls.count, 1)
        XCTAssertEqual(client.purchaseEventCalls.first?.productId, "com.test.monthly")
        XCTAssertEqual(eventStore.count(), 0, "Should remove event on success")
    }

    func testFlushSendsMultipleEventsInFIFOOrder() async {
        enqueueTestEvent(productId: "prod_a")
        enqueueTestEvent(productId: "prod_b")
        enqueueTestEvent(productId: "prod_c")
        client.purchaseEventHandler = nil  // Use default success response
        let manager = makeManager()

        await manager.flushPendingPurchaseEvents()

        XCTAssertEqual(client.purchaseEventCalls.count, 3)
        XCTAssertEqual(client.purchaseEventCalls[0].productId, "prod_a", "Should send oldest first")
        XCTAssertEqual(client.purchaseEventCalls[1].productId, "prod_b")
        XCTAssertEqual(client.purchaseEventCalls[2].productId, "prod_c")
        XCTAssertEqual(eventStore.count(), 0)
    }

    // MARK: - Permanent 4xx Removes Event

    func testFlushRemovesEventOnPermanent4xx() async {
        enqueueTestEvent()
        client.purchaseEventHandler = { _ in throw make400Error() }
        let manager = makeManager()

        await manager.flushPendingPurchaseEvents()

        XCTAssertEqual(eventStore.count(), 0, "Permanent 4xx should remove event")
    }

    // MARK: - Transient Error Increments Retry

    func testFlushIncrementsRetryOnTransientError() async {
        enqueueTestEvent()
        client.purchaseEventHandler = { _ in throw make500Error() }
        let manager = makeManager()

        await manager.flushPendingPurchaseEvents()

        XCTAssertEqual(eventStore.count(), 1, "Event should remain after transient error")
        let updated = eventStore.pending().first
        XCTAssertEqual(updated?.retryCount, 1, "Retry count should be incremented")
    }

    // MARK: - Dead Letter After Max Retries

    func testFlushRemovesEventAfterMaxRetries() async {
        // Enqueue event with retryCount already at 4 (max is 5)
        let request = AppActorASAPurchaseEventRequest(
            userId: "u", productId: "prod_dead", transactionId: nil,
            originalTransactionId: nil, purchaseDate: "2025-01-01T00:00:00Z",
            countryCode: nil, storekit2Json: nil, appVersion: "1.0",
            osVersion: "17.0", libVersion: "1.0.0"
        )
        let event = AppActorASAStoredEvent(id: "dead-letter-test", request: request, retryCount: 4, createdAt: Date())
        eventStore.enqueue(event)

        client.purchaseEventHandler = { _ in throw make500Error() }

        let manager = makeManager()

        await manager.flushPendingPurchaseEvents()

        XCTAssertEqual(eventStore.count(), 0, "Should remove event after max retries")
    }

    // MARK: - Transient Error Stops Processing

    func testFlushStopsOnTransientError() async {
        enqueueTestEvent(productId: "prod_1")
        enqueueTestEvent(productId: "prod_2")
        enqueueTestEvent(productId: "prod_3")

        var callCount = 0
        client.purchaseEventHandler = { req in
            callCount += 1
            if callCount == 2 {
                throw make500Error()
            }
            return AppActorASAPurchaseEventResponseDTO(status: "ok", eventId: "evt_ok")
        }

        let manager = makeManager()
        await manager.flushPendingPurchaseEvents()

        // First succeeds (removed), second fails (stays), third not attempted (stays)
        XCTAssertEqual(callCount, 2, "Should stop after first transient error")
        XCTAssertEqual(eventStore.count(), 2, "Two events should remain")
    }

    // MARK: - 429 is Transient

    func testFlush429IsTransient() async {
        enqueueTestEvent()
        client.purchaseEventHandler = { _ in throw make429Error() }
        let manager = makeManager()

        await manager.flushPendingPurchaseEvents()

        XCTAssertEqual(eventStore.count(), 1, "429 should not remove event")
        XCTAssertEqual(eventStore.pending().first?.retryCount, 1)
    }

    // MARK: - Re-entrancy Guard

    func testConcurrentFlushSkipsSecondCall() async {
        // Enqueue events so flush has work to do
        enqueueTestEvent(productId: "prod_slow")
        enqueueTestEvent(productId: "prod_fast")

        // Make client slow so first flush is still in-flight when second starts
        client.purchaseEventHandler = { req in
            try await Task.sleep(nanoseconds: 200_000_000) // 200ms
            return AppActorASAPurchaseEventResponseDTO(status: "ok", eventId: "evt_ok")
        }

        let manager = makeManager()

        // Launch two concurrent flushes
        async let flush1: () = manager.flushPendingPurchaseEvents()
        async let flush2: () = manager.flushPendingPurchaseEvents()
        _ = await (flush1, flush2)

        // Only one flush should have actually processed events.
        // If re-entrancy guard works, second call is a no-op.
        // Both events are sent by the first flush = 2 calls total (not 4).
        XCTAssertEqual(client.purchaseEventCalls.count, 2, "Second concurrent flush should be skipped by re-entrancy guard")
    }

    // MARK: - Response Status Validation (M3)

    func testFlushNonOkResponseTreatedAsTransient() async {
        enqueueTestEvent(productId: "prod_status")
        client.purchaseEventHandler = { _ in
            return AppActorASAPurchaseEventResponseDTO(status: "error", eventId: "")
        }
        let manager = makeManager()

        await manager.flushPendingPurchaseEvents()

        XCTAssertEqual(eventStore.count(), 1, "Non-ok response should keep event (transient)")
        XCTAssertEqual(eventStore.pending().first?.retryCount, 1, "Retry count should be incremented")
    }

    // MARK: - Enqueue Purchase Event

    // MARK: - Original Transaction ID Dedup

    func testEnqueueDeduplicatesByOriginalTransactionId() async {
        let manager = makeManager()

        // Enqueue first event
        await manager.enqueuePurchaseEvent(
            userId: "user_1",
            productId: "com.test.monthly",
            transactionId: "tx_100",
            originalTransactionId: "tx_orig_100",
            purchaseDate: Date(),
            countryCode: "US",
            storekit2Json: nil
        )

        XCTAssertEqual(eventStore.count(), 1, "First enqueue should succeed")

        // Enqueue renewal with SAME originalTransactionId but different transactionId
        await manager.enqueuePurchaseEvent(
            userId: "user_1",
            productId: "com.test.monthly",
            transactionId: "tx_101",
            originalTransactionId: "tx_orig_100",
            purchaseDate: Date(),
            countryCode: "US",
            storekit2Json: nil
        )

        XCTAssertEqual(eventStore.count(), 1, "Same originalTransactionId (renewal) should be skipped")
    }

    func testEnqueueAllowsDifferentOriginalTransactionIds() async {
        let manager = makeManager()

        await manager.enqueuePurchaseEvent(
            userId: "user_1",
            productId: "com.test.monthly",
            transactionId: "tx_100",
            originalTransactionId: "tx_orig_100",
            purchaseDate: Date(),
            countryCode: "US",
            storekit2Json: nil
        )

        // Different subscription (different originalTransactionId)
        await manager.enqueuePurchaseEvent(
            userId: "user_1",
            productId: "com.test.annual",
            transactionId: "tx_200",
            originalTransactionId: "tx_orig_200",
            purchaseDate: Date(),
            countryCode: "US",
            storekit2Json: nil
        )

        XCTAssertEqual(eventStore.count(), 2, "Different originalTransactionIds should both be enqueued")
    }

    func testEnqueueAllowsNilOriginalTransactionId() async {
        let manager = makeManager()

        // Nil originalTransactionId should bypass dedup
        await manager.enqueuePurchaseEvent(
            userId: "user_1",
            productId: "com.test.monthly",
            transactionId: "tx_100",
            originalTransactionId: nil,
            purchaseDate: Date(),
            countryCode: "US",
            storekit2Json: nil
        )

        await manager.enqueuePurchaseEvent(
            userId: "user_1",
            productId: "com.test.monthly",
            transactionId: "tx_101",
            originalTransactionId: nil,
            purchaseDate: Date(),
            countryCode: "US",
            storekit2Json: nil
        )

        XCTAssertEqual(eventStore.count(), 2, "Nil originalTransactionIds should not be deduplicated")
    }

    func testEnqueueAllowsEmptyStringOriginalTransactionId() async {
        let manager = makeManager()

        // Empty-string originalTransactionId should bypass dedup (same as nil)
        await manager.enqueuePurchaseEvent(
            userId: "user_1",
            productId: "com.test.monthly",
            transactionId: "tx_100",
            originalTransactionId: "",
            purchaseDate: Date(),
            countryCode: "US",
            storekit2Json: nil
        )

        await manager.enqueuePurchaseEvent(
            userId: "user_1",
            productId: "com.test.monthly",
            transactionId: "tx_101",
            originalTransactionId: "",
            purchaseDate: Date(),
            countryCode: "US",
            storekit2Json: nil
        )

        XCTAssertEqual(eventStore.count(), 2, "Empty-string originalTransactionIds should not be deduplicated")
    }

    func testEnqueueSameTransactionIdDifferentOriginalIdAllowed() async {
        let manager = makeManager()

        // Edge case: same transactionId but different originalTransactionId
        // (shouldn't happen in practice, but tests dedup is purely on originalTransactionId)
        await manager.enqueuePurchaseEvent(
            userId: "user_1",
            productId: "com.test.monthly",
            transactionId: "tx_100",
            originalTransactionId: "tx_orig_A",
            purchaseDate: Date(),
            countryCode: "US",
            storekit2Json: nil
        )

        await manager.enqueuePurchaseEvent(
            userId: "user_1",
            productId: "com.test.annual",
            transactionId: "tx_100",
            originalTransactionId: "tx_orig_B",
            purchaseDate: Date(),
            countryCode: "US",
            storekit2Json: nil
        )

        XCTAssertEqual(eventStore.count(), 2, "Different originalTransactionIds should be enqueued even with same transactionId")
    }

    // MARK: - Lifetime Dedup (Sent Storage)

    func testEnqueueSkipsAlreadySentOriginalTransactionId() async {
        // Pre-mark an originalTransactionId as already sent
        storage.markAsaSentOriginalTransactionId("tx_orig_already_sent")

        let manager = makeManager()

        await manager.enqueuePurchaseEvent(
            userId: "user_1",
            productId: "com.test.monthly",
            transactionId: "tx_200",
            originalTransactionId: "tx_orig_already_sent",
            purchaseDate: Date(),
            countryCode: "US",
            storekit2Json: nil
        )

        XCTAssertEqual(eventStore.count(), 0, "Already-sent originalTransactionId should be skipped (lifetime dedup)")
    }

    func testFlushMarksSentOriginalTransactionId() async {
        let manager = makeManager()

        // Enqueue a purchase event (auto-flush fails due to setUp default handler)
        await manager.enqueuePurchaseEvent(
            userId: "user_1",
            productId: "com.test.monthly",
            transactionId: "tx_300",
            originalTransactionId: "tx_orig_300",
            purchaseDate: Date(),
            countryCode: "US",
            storekit2Json: nil
        )

        XCTAssertFalse(storage.isAsaOriginalTransactionIdSent("tx_orig_300"), "Should not be marked as sent before flush")

        // Now enable successful flush
        client.purchaseEventHandler = nil

        await manager.flushPendingPurchaseEvents()

        XCTAssertTrue(storage.isAsaOriginalTransactionIdSent("tx_orig_300"), "Should be marked as sent after successful flush")
        XCTAssertEqual(eventStore.count(), 0, "Event should be removed after successful flush")

        // Now try to enqueue another event with the same originalTransactionId
        await manager.enqueuePurchaseEvent(
            userId: "user_1",
            productId: "com.test.monthly",
            transactionId: "tx_301",
            originalTransactionId: "tx_orig_300",
            purchaseDate: Date(),
            countryCode: "US",
            storekit2Json: nil
        )

        XCTAssertEqual(eventStore.count(), 0, "Re-enqueue after sent should be blocked by lifetime dedup")
    }

    func testFlushDoesNotMarkSentOnFailure() async {
        let manager = makeManager()

        // Enqueue an event
        await manager.enqueuePurchaseEvent(
            userId: "user_1",
            productId: "com.test.monthly",
            transactionId: "tx_400",
            originalTransactionId: "tx_orig_400",
            purchaseDate: Date(),
            countryCode: "US",
            storekit2Json: nil
        )

        // Make flush fail with transient error
        client.purchaseEventHandler = { _ in
            throw make500Error()
        }

        await manager.flushPendingPurchaseEvents()

        XCTAssertFalse(storage.isAsaOriginalTransactionIdSent("tx_orig_400"), "Should NOT be marked as sent on failure")
        XCTAssertEqual(eventStore.count(), 1, "Event should remain in queue after failure")
    }

    // MARK: - Enqueue Basic

    func testEnqueueCreatesStoredEvent() async {
        let manager = makeManager()

        await manager.enqueuePurchaseEvent(
            userId: "user_1",
            productId: "com.test.annual",
            transactionId: "tx_999",
            originalTransactionId: "tx_orig_999",
            purchaseDate: Date(),
            countryCode: "TR",
            storekit2Json: nil
        )

        XCTAssertEqual(eventStore.count(), 1)
        let stored = eventStore.pending().first
        XCTAssertEqual(stored?.request.productId, "com.test.annual")
        XCTAssertEqual(stored?.request.userId, "user_1")
        XCTAssertEqual(stored?.request.countryCode, "TR")
        // retryCount is 1 because auto-flush (M2) runs after enqueue and fails
        // with the default test handler, incrementing retryCount.
        XCTAssertEqual(stored?.retryCount, 1)
    }
}

// MARK: - Diagnostics Tests

final class ASADiagnosticsTests: XCTestCase {

    func testDiagnosticsSnapshot() async {
        let storage = InMemoryPaymentStorage()
        storage.set("user_1", forKey: AppActorPaymentStorageKey.appUserId)
        storage.setAsaAttributionCompleted(true)
        let eventStore = InMemoryASAEventStore()
        // Add 3 events
        for i in 0..<3 {
            let req = AppActorASAPurchaseEventRequest(
                userId: "u", productId: "prod_\(i)", transactionId: nil,
                originalTransactionId: nil, purchaseDate: "2025-01-01T00:00:00Z",
                countryCode: nil, storekit2Json: nil, appVersion: "1.0",
                osVersion: "17.0", libVersion: "1.0.0"
            )
            eventStore.enqueue(AppActorASAStoredEvent(id: "e\(i)", request: req, retryCount: 0, createdAt: Date()))
        }

        let manager = AppActorASAManager(
            client: MockPaymentClient(), storage: storage, eventStore: eventStore,
            tokenProvider: MockASATokenProvider(),
            options: AppActorASAOptions(autoTrackPurchases: true, debugMode: true),
            sdkVersion: "1.0.0"
        )

        let diag = await manager.diagnostics()

        XCTAssertTrue(diag.attributionCompleted)
        XCTAssertEqual(diag.pendingPurchaseEventCount, 3)
        XCTAssertTrue(diag.debugMode)
        XCTAssertTrue(diag.autoTrackPurchases)
    }

    func testDiagnosticsEmptyState() async {
        let manager = AppActorASAManager(
            client: MockPaymentClient(), storage: InMemoryPaymentStorage(),
            eventStore: InMemoryASAEventStore(),
            tokenProvider: MockASATokenProvider(),
            options: AppActorASAOptions(autoTrackPurchases: false, debugMode: false),
            sdkVersion: "1.0.0"
        )

        let diag = await manager.diagnostics()

        XCTAssertFalse(diag.attributionCompleted)
        XCTAssertEqual(diag.pendingPurchaseEventCount, 0)
        XCTAssertFalse(diag.debugMode)
        XCTAssertFalse(diag.autoTrackPurchases)
    }

    func testPendingPurchaseEventCount() async {
        let eventStore = InMemoryASAEventStore()
        let req = AppActorASAPurchaseEventRequest(
            userId: "u", productId: "p", transactionId: nil,
            originalTransactionId: nil, purchaseDate: "2025-01-01T00:00:00Z",
            countryCode: nil, storekit2Json: nil, appVersion: "1.0",
            osVersion: "17.0", libVersion: "1.0.0"
        )
        eventStore.enqueue(AppActorASAStoredEvent(id: "e1", request: req, retryCount: 0, createdAt: Date()))
        eventStore.enqueue(AppActorASAStoredEvent(id: "e2", request: req, retryCount: 0, createdAt: Date()))

        let manager = AppActorASAManager(
            client: MockPaymentClient(), storage: InMemoryPaymentStorage(),
            eventStore: eventStore, tokenProvider: MockASATokenProvider(),
            options: makeDefaultOptions(), sdkVersion: "1.0.0"
        )

        let count = await manager.pendingPurchaseEventCount()
        XCTAssertEqual(count, 2)
    }
}

// MARK: - L1: Token-Only Attempt Counter Tests

final class ASATokenOnlyAttemptTests: XCTestCase {

    private var client: MockPaymentClient!
    private var storage: InMemoryPaymentStorage!
    private var tokenProvider: MockASATokenProvider!

    override func setUp() {
        super.setUp()
        client = MockPaymentClient()
        storage = InMemoryPaymentStorage()
        storage.set("user_123", forKey: AppActorPaymentStorageKey.appUserId)
        tokenProvider = MockASATokenProvider()
        // Make Apple API fail so we get token-only path
        tokenProvider.appleAttributionResult = .error(NSError(domain: "test", code: 500, userInfo: nil))
    }

    private func makeManager() -> AppActorASAManager {
        AppActorASAManager(
            client: client, storage: storage,
            eventStore: InMemoryASAEventStore(),
            tokenProvider: tokenProvider,
            options: makeDefaultOptions(),
            sdkVersion: "1.0.0"
        )
    }

    /// Token-only success should increment attempt counter.
    func testTokenOnlySuccessIncrementsCounter() async {
        let manager = makeManager()

        _ = await manager.performAttributionIfNeeded()

        XCTAssertEqual(storage.asaTokenOnlyAttempts, 1)
        XCTAssertFalse(storage.asaAttributionCompleted, "Should not be completed after 1 attempt")
    }

    /// After maxTokenOnlyAttempts (3), attribution should be marked completed.
    func testTokenOnlyMaxAttemptsMarksCompleted() async {
        // Pre-set counter to 2 (one below max)
        storage.set("2", forKey: AppActorPaymentStorageKey.asaTokenOnlyAttempts)

        let manager = makeManager()

        _ = await manager.performAttributionIfNeeded()

        XCTAssertTrue(storage.asaAttributionCompleted, "Should be completed after max attempts")
        XCTAssertEqual(storage.asaTokenOnlyAttempts, 0, "Counter should be cleared after completion")
    }

    /// Full Apple response success should clear token-only counter.
    func testFullResponseClearsTokenOnlyCounter() async {
        storage.set("2", forKey: AppActorPaymentStorageKey.asaTokenOnlyAttempts)
        // Restore successful Apple API
        tokenProvider.appleAttributionResult = .success(
            AppActorASAAppleAttributionResponse(json: ["attribution": true])
        )

        let manager = makeManager()

        _ = await manager.performAttributionIfNeeded()

        XCTAssertTrue(storage.asaAttributionCompleted)
        XCTAssertEqual(storage.asaTokenOnlyAttempts, 0, "Full response should clear counter")
    }
}

// MARK: - M2: Immediate Flush After Enqueue Tests

final class ASAImmediateFlushTests: XCTestCase {

    private var client: MockPaymentClient!
    private var storage: InMemoryPaymentStorage!
    private var eventStore: InMemoryASAEventStore!

    override func setUp() {
        super.setUp()
        client = MockPaymentClient()
        storage = InMemoryPaymentStorage()
        eventStore = InMemoryASAEventStore()
    }

    private func makeManager() -> AppActorASAManager {
        AppActorASAManager(
            client: client, storage: storage, eventStore: eventStore,
            tokenProvider: MockASATokenProvider(),
            options: makeDefaultOptions(),
            sdkVersion: "1.0.0"
        )
    }

    /// enqueuePurchaseEvent should trigger flush automatically — event is sent immediately.
    func testEnqueueTriggersImmediateFlush() async {
        let manager = makeManager()

        await manager.enqueuePurchaseEvent(
            userId: "user_1",
            productId: "com.test.annual",
            transactionId: "tx_imm",
            originalTransactionId: "tx_orig_imm",
            purchaseDate: Date(),
            countryCode: "US",
            storekit2Json: nil
        )

        // Default mock client returns "ok" — event should be flushed immediately
        XCTAssertEqual(client.purchaseEventCalls.count, 1, "Should have called API immediately")
        XCTAssertEqual(eventStore.count(), 0, "Event should be removed after successful flush")
        XCTAssertTrue(storage.isAsaOriginalTransactionIdSent("tx_orig_imm"), "Should be marked as sent")
    }

    /// If immediate flush fails, event should remain in store for retry.
    func testEnqueueKeepsEventOnFlushFailure() async {
        client.purchaseEventHandler = { _ in throw make500Error() }
        let manager = makeManager()

        await manager.enqueuePurchaseEvent(
            userId: "user_1",
            productId: "com.test.annual",
            transactionId: "tx_fail",
            originalTransactionId: "tx_orig_fail",
            purchaseDate: Date(),
            countryCode: "US",
            storekit2Json: nil
        )

        XCTAssertEqual(eventStore.count(), 1, "Event should remain after flush failure")
        XCTAssertFalse(storage.isAsaOriginalTransactionIdSent("tx_orig_fail"), "Should not be marked as sent")
    }
}
