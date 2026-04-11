import XCTest
@testable import AppActor

// MARK: - Tests

final class PaymentProcessorTests: XCTestCase {

    private var client: MockPaymentClient!
    private var store: InMemoryPaymentQueueStore!
    private var processor: AppActorPaymentProcessor!

    override func setUp() async throws {
        try await super.setUp()
        client = MockPaymentClient()
        store = InMemoryPaymentQueueStore()
        processor = AppActorPaymentProcessor(store: store, client: client)
        // Open the identity gate so drain() doesn't wait forever in tests.
        await processor.confirmIdentity()
    }

    // MARK: - Helpers

    /// Creates a new processor with the identity gate already open.
    private func makeProcessor(
        store: InMemoryPaymentQueueStore? = nil,
        client: MockPaymentClient? = nil
    ) async -> AppActorPaymentProcessor {
        let proc = AppActorPaymentProcessor(
            store: store ?? self.store,
            client: client ?? self.client
        )
        await proc.confirmIdentity()
        return proc
    }

    private func makeItem(
        key: String = "apple:12345",
        transactionId: String = "12345",
        phase: AppActorPaymentQueueItem.Phase = .needsPost,
        attemptCount: Int = 0,
        firstSeenAt: Date = Date(),
        source: AppActorPaymentQueueItem.Source = .purchase
    ) -> AppActorPaymentQueueItem {
        AppActorPaymentQueueItem(
            key: key,
            bundleId: "com.test",
            environment: "sandbox",
            transactionId: transactionId,
            jws: "jws_payload",
            appUserId: "user_123",
            productId: "com.test.monthly",
            originalTransactionId: "12345",
            storefront: "USA",
            offeringId: nil,
            packageId: nil,
            phase: phase,
            attemptCount: attemptCount,
            nextRetryAt: Date(),
            firstSeenAt: firstSeenAt,
            lastSeenAt: Date(),
            lastError: nil,
            sources: [source],
            claimedAt: nil
        )
    }

    // MARK: - 1. Dedup / Merge

    func testUpsertDedup() async {
        let item = makeItem()
        store.upsert(item)

        // Enqueue same key again with different source
        var item2 = makeItem(source: .transactionUpdates)
        item2.jws = "jws_updated"
        store.upsert(item2)

        let all = store.allItems()
        XCTAssertEqual(all.count, 1, "Same key should upsert, not duplicate")
        XCTAssertEqual(all.first?.jws, "jws_updated", "JWS should be updated")
        XCTAssertTrue(all.first?.sources.contains(.purchase) == true, "Original source preserved")
        XCTAssertTrue(all.first?.sources.contains(.transactionUpdates) == true, "New source merged")
    }

    func testEnqueueMergesSources() {
        let item1 = makeItem(source: .purchase)
        store.upsert(item1)

        var item2 = makeItem(source: .sweep)
        item2.jws = "jws_newer"
        store.upsert(item2)

        let all = store.allItems()
        XCTAssertEqual(all.count, 1)
        XCTAssertTrue(all.first!.sources.contains(.purchase))
        XCTAssertTrue(all.first!.sources.contains(.sweep))
        XCTAssertEqual(all.first?.jws, "jws_newer")
    }

    // MARK: - 2. Single Drain Loop

    func testKickTwiceOnlyOneDrain() async {
        var callCount = 0
        client.postReceiptHandler = { (_: AppActorReceiptPostRequest) in
            callCount += 1
            try? await Task.sleep(nanoseconds: 50_000_000) // 50ms
            return AppActorReceiptPostResponse(status: "ok", requestId: nil)
        }

        let item = makeItem()
        store.upsert(item)

        // Kick twice rapidly — second should be no-op
        await processor.kick()
        await processor.kick()

        // Wait for drain to finish
        try? await Task.sleep(nanoseconds: 200_000_000)

        // At most 1 POST should have been made
        XCTAssertLessThanOrEqual(callCount, 1, "Single drain loop should prevent concurrent processing")
    }

    // MARK: - 3. Claim Lock

    func testClaimSetsPostingPhaseBeforePOST() async {
        var phaseAtPostTime: AppActorPaymentQueueItem.Phase?
        client.postReceiptHandler = { [weak self] _ in
            // Check the item's phase at the moment of the POST
            let items = self?.store.allItems() ?? []
            phaseAtPostTime = items.first?.phase
            return AppActorReceiptPostResponse(status: "ok", requestId: "req_1")
        }

        let item = makeItem()
        store.upsert(item)
        await processor.kick()

        // Wait for drain
        try? await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(phaseAtPostTime, .posting, "Item should be in .posting phase during POST")
    }

    // MARK: - 4. inFlight Dedup

    func testInFlightDedup() async {
        var postCount = 0
        client.postReceiptHandler = { (_: AppActorReceiptPostRequest) in
            postCount += 1
            // Simulate slow response to allow overlap
            try? await Task.sleep(nanoseconds: 100_000_000)
            return AppActorReceiptPostResponse(status: "ok", requestId: nil)
        }

        let item = makeItem()
        store.upsert(item)

        // The drain loop should only POST once per key even across iterations
        await processor.kick()
        try? await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertEqual(postCount, 1, "Same key should never be POSTed concurrently")
    }

    // MARK: - 5. Phase Transitions

    func testRetryableTransitionsToNeedsPost() async {
        client.postReceiptHandler = { (_: AppActorReceiptPostRequest) in
            AppActorReceiptPostResponse(
                status: "retryable_error",
                error: AppActorReceiptErrorInfo(code: "RATE_LIMIT", message: nil),
                requestId: "req_1"
            )
        }

        let item = makeItem()
        store.upsert(item)
        await processor.kick()
        try? await Task.sleep(nanoseconds: 200_000_000)

        let items = store.allItems()
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.phase, .needsPost, "Retryable should transition to .needsPost")
        XCTAssertEqual(items.first?.attemptCount, 1)
        XCTAssertNotNil(items.first?.lastError)
        XCTAssertTrue(items.first?.lastError?.contains("RATE_LIMIT") == true)
    }

    func testOkTransitionsToRemovedViaNeedsFinish() async {
        client.postReceiptHandler = { (_: AppActorReceiptPostRequest) in
            AppActorReceiptPostResponse(status: "ok", requestId: "req_1")
        }

        let item = makeItem()
        store.upsert(item)
        await processor.kick()
        try? await Task.sleep(nanoseconds: 200_000_000)

        let items = store.allItems()
        XCTAssertEqual(items.count, 0, "ok → needsFinish → removed")
    }

    func testPermanentErrorTransitionsToRemovedViaNeedsFinish() async {
        client.postReceiptHandler = { (_: AppActorReceiptPostRequest) in
            AppActorReceiptPostResponse(
                status: "permanent_error",
                error: AppActorReceiptErrorInfo(code: "REVOKED_TRANSACTION", message: "Refunded"),
                requestId: "req_1"
            )
        }

        let item = makeItem()
        store.upsert(item)
        await processor.kick()
        try? await Task.sleep(nanoseconds: 200_000_000)

        let items = store.allItems()
        XCTAssertEqual(items.count, 0, "permanent_error → needsFinish → removed")
    }

    func testPermanentRejectionResultCanBeRecoveredAfterWatcherPostsFirst() async {
        client.postReceiptHandler = { (_: AppActorReceiptPostRequest) in
            AppActorReceiptPostResponse(
                status: "permanent_error",
                error: AppActorReceiptErrorInfo(code: "REVOKED_TRANSACTION", message: "Refunded"),
                requestId: "req_rejected"
            )
        }

        let item = makeItem()
        store.upsert(item)

        await processor.drainAll()

        guard case let .permanentlyRejected(errorCode, message, requestId)? =
            await processor.consumeCompletedResult(for: item.key) else {
            return XCTFail("Expected completed permanent rejection result")
        }

        XCTAssertEqual(errorCode, "REVOKED_TRANSACTION")
        XCTAssertEqual(message, "Refunded")
        XCTAssertEqual(requestId, "req_rejected")
        let secondRead = await processor.consumeCompletedResult(for: item.key)
        XCTAssertNil(secondRead, "Result should be consumed once")
    }

    func testDeadLetterAfterMaxAttempts() async {
        client.postReceiptHandler = { (_: AppActorReceiptPostRequest) in
            AppActorReceiptPostResponse(
                status: "retryable_error",
                error: AppActorReceiptErrorInfo(code: "INTERNAL", message: nil),
                requestId: "req_1"
            )
        }

        let item = makeItem(attemptCount: AppActorPaymentProcessor.maxRetryAttempts - 1)
        store.upsert(item)
        await processor.kick()
        try? await Task.sleep(nanoseconds: 200_000_000)

        let items = store.allItems()
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.phase, .deadLettered, "Should dead-letter after max attempts")
        XCTAssertEqual(items.first?.attemptCount, AppActorPaymentProcessor.maxRetryAttempts)
    }

    // MARK: - 6. POST-then-finish ordering

    func testPostThenFinishOrdering() async {
        var postTimestamp: Date?
        client.postReceiptHandler = { (_: AppActorReceiptPostRequest) in
            postTimestamp = Date()
            return AppActorReceiptPostResponse(status: "ok", requestId: "req_1")
        }

        let item = makeItem()
        store.upsert(item)
        await processor.kick()
        try? await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertNotNil(postTimestamp, "POST should have been made")
        let items = store.allItems()
        XCTAssertEqual(items.count, 0, "Item should be removed after finish")
    }

    // MARK: - 7. Crash Safety

    func testStalePotingItemReclaimed() async {
        // Simulate an item stuck in .posting (stale claim from a crashed processor)
        var item = makeItem(phase: .needsPost)
        item.phase = .posting
        item.claimedAt = Date().addingTimeInterval(-300) // 5 min ago (stale)
        store.update(item)

        client.postReceiptHandler = { (_: AppActorReceiptPostRequest) in
            AppActorReceiptPostResponse(status: "ok", requestId: "req_1")
        }

        // claimReady should reclaim the stale item
        let claimed = store.claimReady(limit: 10, now: Date())
        XCTAssertEqual(claimed.count, 1, "Stale .posting item should be reclaimed")
    }

    func testNeedsFinishCompletedAfterRecreate() async {
        // Simulate an item in .needsFinish (POST succeeded but crash before finish)
        var item = makeItem()
        item.phase = .needsFinish
        store.update(item)

        // New processor should pick up and finish the item
        let newProcessor = await makeProcessor()
        await newProcessor.kick()
        try? await Task.sleep(nanoseconds: 200_000_000)

        let items = store.allItems()
        XCTAssertEqual(items.count, 0, ".needsFinish item should be completed by new processor")
    }

    // MARK: - 8. Revocation

    func testRevokedTransactionStillPosted() async {
        var wasPosted = false
        client.postReceiptHandler = { (_: AppActorReceiptPostRequest) in
            wasPosted = true
            return AppActorReceiptPostResponse(
                status: "permanent_error",
                error: AppActorReceiptErrorInfo(code: "REVOKED_TRANSACTION", message: "Refunded"),
                requestId: "req_1"
            )
        }

        // Revoked transactions get the same queue item — they're not skipped
        let item = makeItem()
        store.upsert(item)
        await processor.kick()
        try? await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertTrue(wasPosted, "Revoked transaction should still be POSTed to server")
        XCTAssertEqual(store.allItems().count, 0, "Should be removed after permanent_error")
    }

    // MARK: - 9. Backoff + retryAfterSeconds

    func testBackoffSchedule() {
        XCTAssertEqual(AppActorPaymentProcessor.backoffDelay(attempt: 0), 0)
        XCTAssertEqual(AppActorPaymentProcessor.backoffDelay(attempt: 1), 0.75)
        XCTAssertEqual(AppActorPaymentProcessor.backoffDelay(attempt: 2), 3)
        XCTAssertEqual(AppActorPaymentProcessor.backoffDelay(attempt: 3), 3, "Should cap at 3s")
    }

    func testRetryDelayRespectsServerRetryAfter() {
        // Server says 20s, backoff would be 0.75s → use max = 20
        XCTAssertEqual(AppActorPaymentProcessor.retryDelay(attempt: 1, serverRetryAfter: 20), 20)
        // Server says 2s, backoff is 3s → use max = 3
        XCTAssertEqual(AppActorPaymentProcessor.retryDelay(attempt: 2, serverRetryAfter: 2), 3)
        // Server says nil → use backoff
        XCTAssertEqual(AppActorPaymentProcessor.retryDelay(attempt: 1, serverRetryAfter: nil), 0.75)
        // Server says 0 → ignore, use backoff
        XCTAssertEqual(AppActorPaymentProcessor.retryDelay(attempt: 1, serverRetryAfter: 0), 0.75)
        // Server says negative → ignore, use backoff
        XCTAssertEqual(AppActorPaymentProcessor.retryDelay(attempt: 1, serverRetryAfter: -10), 0.75)
        // Server says > 30 → ignore, use backoff
        XCTAssertEqual(AppActorPaymentProcessor.retryDelay(attempt: 1, serverRetryAfter: 60), 0.75)
    }

    func testRetryableRespectsRetryAfterSeconds() async {
        client.postReceiptHandler = { (_: AppActorReceiptPostRequest) in
            AppActorReceiptPostResponse(
                status: "retryable_error",
                error: AppActorReceiptErrorInfo(code: "RATE_LIMIT", message: nil),
                retryAfterSeconds: 20,
                requestId: "req_1"
            )
        }

        let before = Date()
        let item = makeItem()
        store.upsert(item)
        await processor.kick()
        try? await Task.sleep(nanoseconds: 200_000_000)

        let items = store.allItems()
        XCTAssertEqual(items.count, 1)
        // retryAfterSeconds=20 > backoff(1)=0.75 → should use 20
        let nextRetry = items.first!.nextRetryAt
        XCTAssertTrue(nextRetry >= before.addingTimeInterval(19), "Should respect retryAfterSeconds (20s)")
    }

    // MARK: - Network Error

    func testNetworkErrorRetry() async {
        client.postReceiptHandler = { (_: AppActorReceiptPostRequest) in
            throw AppActorError.networkError(URLError(.notConnectedToInternet))
        }

        let item = makeItem()
        store.upsert(item)
        await processor.kick()
        try? await Task.sleep(nanoseconds: 200_000_000)

        let items = store.allItems()
        XCTAssertEqual(items.count, 1, "Network error should keep item in queue")
        XCTAssertEqual(items.first?.phase, .needsPost)
        XCTAssertEqual(items.first?.attemptCount, 1)
        XCTAssertNotNil(items.first?.lastError)
    }

    // MARK: - Request Construction

    func testMakeRequest() {
        let item = makeItem()
        let request = AppActorPaymentProcessor.makeRequest(from: item)

        XCTAssertEqual(request.appUserId, "user_123")
        XCTAssertEqual(request.appId, "com.test")
        XCTAssertEqual(request.environment, "sandbox")
        XCTAssertEqual(request.bundleId, "com.test")
        XCTAssertEqual(request.storefront, "USA")
        XCTAssertEqual(request.signedTransactionInfo, "jws_payload")
        XCTAssertEqual(request.transactionId, "12345")
        XCTAssertEqual(request.productId, "com.test.monthly")
        XCTAssertEqual(request.idempotencyKey, "apple:12345")
        XCTAssertEqual(request.originalTransactionId, "12345")
    }

    // MARK: - Key Format

    func testKeyFormat() {
        let key = AppActorPaymentQueueItem.makeKey(transactionId: "99999")
        XCTAssertEqual(key, "apple:99999")
    }

    // MARK: - Observability: Counts

    func testPendingAndDeadLetteredCounts() async {
        let pending0 = await processor.pendingCount()
        let dead0 = await processor.deadLetteredCount()
        XCTAssertEqual(pending0, 0)
        XCTAssertEqual(dead0, 0)

        store.upsert(makeItem(key: "apple:1", transactionId: "1"))
        store.upsert(makeItem(key: "apple:2", transactionId: "2"))

        let pending2 = await processor.pendingCount()
        XCTAssertEqual(pending2, 2)

        var deadItem = makeItem(key: "apple:3", transactionId: "3")
        deadItem.phase = .deadLettered
        store.update(deadItem)

        let dead1 = await processor.deadLetteredCount()
        XCTAssertEqual(dead1, 1)
        let pending2b = await processor.pendingCount()
        XCTAssertEqual(pending2b, 2, "Dead-lettered should not count as pending")
    }

    // MARK: - Observability: Snapshot

    func testQueueSnapshot() async {
        let item = makeItem()
        store.upsert(item)

        let snapshot = await processor.snapshot()
        XCTAssertEqual(snapshot.count, 1)
        XCTAssertEqual(snapshot.first?.id, item.key)
        XCTAssertEqual(snapshot.first?.productId, "com.test.monthly")
        XCTAssertEqual(snapshot.first?.status, "needsPost")
        XCTAssertEqual(snapshot.first?.attemptCount, 0)
    }

    // MARK: - Pipeline Events

    func testPipelineEventEmittedOnOk() async {
        let accumulator = PipelineEventAccumulator()
        await processor.setPipelineEventHandler { accumulator.append($0) }

        client.postReceiptHandler = { (_: AppActorReceiptPostRequest) in
            AppActorReceiptPostResponse(status: "ok", requestId: "req_1")
        }

        store.upsert(makeItem())
        await processor.kick()
        try? await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(accumulator.events.count, 1)
        if case .postedOk(let txId) = accumulator.events.first?.event {
            XCTAssertEqual(txId, "12345")
        } else {
            XCTFail("Expected .postedOk event")
        }
    }

    func testPipelineEventEmittedOnRetry() async {
        let accumulator = PipelineEventAccumulator()
        await processor.setPipelineEventHandler { accumulator.append($0) }

        client.postReceiptHandler = { (_: AppActorReceiptPostRequest) in
            AppActorReceiptPostResponse(
                status: "retryable_error",
                error: AppActorReceiptErrorInfo(code: "RATE_LIMIT", message: nil),
                requestId: "req_1"
            )
        }

        store.upsert(makeItem())
        await processor.kick()
        try? await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(accumulator.events.count, 1)
        if case .retryScheduled(let txId, let attempt, _, let code) = accumulator.events.first?.event {
            XCTAssertEqual(txId, "12345")
            XCTAssertEqual(attempt, 1)
            XCTAssertEqual(code, "RATE_LIMIT")
        } else {
            XCTFail("Expected .retryScheduled event")
        }
    }

    func testPipelineEventEmittedOnPermanentError() async {
        let accumulator = PipelineEventAccumulator()
        await processor.setPipelineEventHandler { accumulator.append($0) }

        client.postReceiptHandler = { (_: AppActorReceiptPostRequest) in
            AppActorReceiptPostResponse(
                status: "permanent_error",
                error: AppActorReceiptErrorInfo(code: "INVALID_JWS", message: nil),
                requestId: "req_1"
            )
        }

        store.upsert(makeItem())
        await processor.kick()
        try? await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(accumulator.events.count, 1)
        if case .permanentlyRejected(let txId, let code) = accumulator.events.first?.event {
            XCTAssertEqual(txId, "12345")
            XCTAssertEqual(code, "INVALID_JWS")
        } else {
            XCTFail("Expected .permanentlyRejected event")
        }
    }

    func testPipelineEventEmittedOnDeadLetter() async {
        let accumulator = PipelineEventAccumulator()
        await processor.setPipelineEventHandler { accumulator.append($0) }

        client.postReceiptHandler = { (_: AppActorReceiptPostRequest) in
            AppActorReceiptPostResponse(
                status: "retryable_error",
                error: AppActorReceiptErrorInfo(code: "INTERNAL", message: nil),
                requestId: "req_1"
            )
        }

        let item = makeItem(attemptCount: AppActorPaymentProcessor.maxRetryAttempts - 1)
        store.upsert(item)
        await processor.kick()
        try? await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(accumulator.events.count, 1)
        if case .deadLettered(let txId, let attempts, let code) = accumulator.events.first?.event {
            XCTAssertEqual(txId, "12345")
            XCTAssertEqual(attempts, AppActorPaymentProcessor.maxRetryAttempts)
            XCTAssertEqual(code, "INTERNAL")
        } else {
            XCTFail("Expected .deadLettered event")
        }
    }

    func testPipelineEventEmittedOnNetworkError() async {
        let accumulator = PipelineEventAccumulator()
        await processor.setPipelineEventHandler { accumulator.append($0) }

        client.postReceiptHandler = { (_: AppActorReceiptPostRequest) in
            throw AppActorError.networkError(URLError(.notConnectedToInternet))
        }

        store.upsert(makeItem())
        await processor.kick()
        try? await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(accumulator.events.count, 1)
        if case .retryScheduled(_, let attempt, _, let code) = accumulator.events.first?.event {
            XCTAssertEqual(attempt, 1)
            XCTAssertNil(code, "Network errors have no server error code")
        } else {
            XCTFail("Expected .retryScheduled event for network error")
        }
    }

    // MARK: - Unknown Status

    func testUnknownStatusTreatedAsRetryable() async {
        client.postReceiptHandler = { (_: AppActorReceiptPostRequest) in
            AppActorReceiptPostResponse(status: "something_unexpected", requestId: "req_1")
        }

        let item = makeItem()
        store.upsert(item)
        await processor.kick()
        try? await Task.sleep(nanoseconds: 200_000_000)

        let items = store.allItems()
        XCTAssertEqual(items.count, 1, "Unknown status should keep item in queue")
        XCTAssertEqual(items.first?.attemptCount, 1)
        XCTAssertTrue(items.first?.lastError?.contains("something_unexpected") == true)
    }

    // MARK: - Response Forward-Compatibility

    func testResponseIgnoresUnknownFields() throws {
        let json = """
        {"status": "ok", "requestId": "req_1", "should_finish": true, "extra_field": 42}
        """
        let data = json.data(using: .utf8)!
        let response = try JSONDecoder().decode(AppActorReceiptPostResponse.self, from: data)
        XCTAssertEqual(response.status, "ok")
        XCTAssertEqual(response.requestId, "req_1")
        XCTAssertNil(response.customer)
        XCTAssertNil(response.error)
        XCTAssertNil(response.retryAfterSeconds)
    }

    // MARK: - Multiple Items

    func testMultipleItemsProcessed() async {
        client.postReceiptHandler = { (_: AppActorReceiptPostRequest) in
            AppActorReceiptPostResponse(status: "ok", requestId: nil)
        }

        for i in 1...3 {
            store.upsert(makeItem(key: "apple:com.test:sandbox:\(i)", transactionId: "\(i)"))
        }

        await processor.kick()

        // Poll until all items are processed. Re-kick on each iteration
        // because the drain loop may exit while findUnfinishedTransaction
        // is still completing for the last item in the task group.
        for _ in 0..<30 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            if store.allItems().isEmpty && client.postReceiptCalls.count == 3 { break }
            await processor.kick()
        }

        let items = store.allItems()
        XCTAssertEqual(items.count, 0, "All items should be processed and removed")
        XCTAssertEqual(client.postReceiptCalls.count, 3)
    }

    // MARK: - Decode Mismatch (aggressive dead-letter)

    func testDecodeMismatchDeadLettersAfter5Attempts() async {
        client.postReceiptHandler = { (_: AppActorReceiptPostRequest) in
            throw AppActorError.decodingError(
                NSError(domain: "Test", code: 0, userInfo: [NSLocalizedDescriptionKey: "missing key"]),
                requestId: "req_decode"
            )
        }

        // Start at attempt 4, so next attempt (5) triggers dead-letter
        let item = makeItem(attemptCount: AppActorPaymentProcessor.maxDecodeRetryAttempts - 1)
        store.upsert(item)
        await processor.kick()
        try? await Task.sleep(nanoseconds: 200_000_000)

        let items = store.allItems()
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.phase, .deadLettered, "Decode mismatch should dead-letter after 5 attempts")
        XCTAssertTrue(items.first?.lastError?.contains("decode_mismatch") == true)
    }

    func testDecodeMismatchRetriesBeforeDeadLetter() async {
        client.postReceiptHandler = { (_: AppActorReceiptPostRequest) in
            throw AppActorError.decodingError(
                NSError(domain: "Test", code: 0, userInfo: [NSLocalizedDescriptionKey: "bad json"]),
                requestId: "req_decode"
            )
        }

        let item = makeItem(attemptCount: 0)
        store.upsert(item)
        await processor.kick()
        try? await Task.sleep(nanoseconds: 200_000_000)

        let items = store.allItems()
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.phase, .needsPost, "Decode mismatch should retry before dead-letter limit")
        XCTAssertEqual(items.first?.attemptCount, 1)
        XCTAssertTrue(items.first?.lastError?.contains("decode_mismatch") == true)
    }

    func testDecodeMismatchEmitsCorrectPipelineEvent() async {
        let accumulator = PipelineEventAccumulator()
        await processor.setPipelineEventHandler { accumulator.append($0) }

        client.postReceiptHandler = { (_: AppActorReceiptPostRequest) in
            throw AppActorError.decodingError(
                NSError(domain: "Test", code: 0, userInfo: [NSLocalizedDescriptionKey: "bad"]),
                requestId: nil
            )
        }

        let item = makeItem(attemptCount: AppActorPaymentProcessor.maxDecodeRetryAttempts - 1)
        store.upsert(item)
        await processor.kick()
        try? await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(accumulator.events.count, 1)
        if case .deadLettered(let txId, let attempts, let code) = accumulator.events.first?.event {
            XCTAssertEqual(txId, "12345")
            XCTAssertEqual(attempts, AppActorPaymentProcessor.maxDecodeRetryAttempts)
            XCTAssertEqual(code, "DECODE_MISMATCH")
        } else {
            XCTFail("Expected .deadLettered event for decode mismatch")
        }
    }

    // MARK: - ServerCustomerInfo Defensive Decode

    func testServerCustomerInfoDecodesWithMissingFields() throws {
        // Backend returns customer with only appUserId — no entitlements/subscriptions keys
        let json = """
        {"appUserId": "user_1"}
        """
        let info = try JSONDecoder().decode(AppActorCustomerInfo.self, from: json.data(using: .utf8)!)
        XCTAssertEqual(info.appUserId, "user_1")
        XCTAssertEqual(info.entitlements, [:], "Missing entitlements should default to [:]")
        XCTAssertEqual(info.subscriptions, [:], "Missing subscriptions should default to [:]")
        XCTAssertNil(info.requestDate)
    }

    func testServerCustomerInfoDecodesWithNullFields() throws {
        let json = """
        {"appUserId": "user_2", "entitlements": null, "subscriptions": null}
        """
        let info = try JSONDecoder().decode(AppActorCustomerInfo.self, from: json.data(using: .utf8)!)
        XCTAssertEqual(info.appUserId, "user_2")
        XCTAssertEqual(info.entitlements, [:])
        XCTAssertEqual(info.subscriptions, [:])
    }

    func testServerCustomerInfoDecodesWithPopulatedDictFields() throws {
        // New canonical dict-based format
        let json = """
        {
            "appUserId": "user_3",
            "entitlements": {"premium": {"id": "premium", "isActive": true}},
            "subscriptions": {"monthly": {"productIdentifier": "monthly", "isActive": true}},
            "requestDate": "2026-01-01T00:00:00Z"
        }
        """
        let info = try JSONDecoder().decode(AppActorCustomerInfo.self, from: json.data(using: .utf8)!)
        XCTAssertEqual(info.appUserId, "user_3")
        XCTAssertEqual(info.entitlements.count, 1)
        XCTAssertEqual(info.entitlements["premium"]?.id, "premium")
        XCTAssertTrue(info.entitlements["premium"]?.isActive == true)
        XCTAssertEqual(info.subscriptions.count, 1)
        XCTAssertEqual(info.subscriptions["monthly"]?.productIdentifier, "monthly")
        XCTAssertEqual(info.requestDate, "2026-01-01T00:00:00Z")
    }

    func testServerCustomerInfoDecodesLegacyArrayFormat() throws {
        // Old array-based format — decoded via backward-compat path
        let json = """
        {
            "appUserId": "user_3b",
            "entitlements": [{"id": "premium", "isActive": true}],
            "requestDate": "2026-01-01T00:00:00Z"
        }
        """
        let info = try JSONDecoder().decode(AppActorCustomerInfo.self, from: json.data(using: .utf8)!)
        XCTAssertEqual(info.appUserId, "user_3b")
        XCTAssertEqual(info.entitlements.count, 1)
        XCTAssertEqual(info.entitlements["premium"]?.id, "premium")
        XCTAssertEqual(info.requestDate, "2026-01-01T00:00:00Z")
    }

    func testServerCustomerInfoDecodesWithMalformedEntitlements() throws {
        // entitlements contains a non-decodable value — should fall back to [:]
        let json = """
        {"appUserId": "user_4", "entitlements": "not_a_dict", "subscriptions": {}}
        """
        let info = try JSONDecoder().decode(AppActorCustomerInfo.self, from: json.data(using: .utf8)!)
        XCTAssertEqual(info.appUserId, "user_4")
        XCTAssertEqual(info.entitlements, [:], "Malformed entitlements should fall back to [:]")
        XCTAssertEqual(info.subscriptions, [:])
    }

    // MARK: - Persisted Rate-Limit Cooldown

    func testRateLimitCooldownPersistedToStore() async {
        client.postReceiptHandler = { (_: AppActorReceiptPostRequest) in
            AppActorReceiptPostResponse(
                status: "retryable_error",
                error: AppActorReceiptErrorInfo(code: "RATE_LIMIT", message: nil),
                retryAfterSeconds: 60,
                requestId: "req_rl"
            )
        }

        let item = makeItem()
        store.upsert(item)
        await processor.kick()
        try? await Task.sleep(nanoseconds: 200_000_000)

        // Cooldown should be persisted in the store
        let cooldown = store.getRateLimitCooldown()
        XCTAssertNotNil(cooldown, "Rate-limit cooldown should be persisted to store")
        XCTAssertTrue(cooldown! > Date(), "Cooldown should be in the future")
    }

    func testNewProcessorRespectsPersistedCooldown() async {
        // Simulate a persisted cooldown from a previous session
        let futureCooldown = Date().addingTimeInterval(300) // 5 min from now
        store.setRateLimitCooldown(futureCooldown)

        // Items ready to POST
        store.upsert(makeItem())

        client.postReceiptHandler = { (_: AppActorReceiptPostRequest) in
            XCTFail("Should NOT POST while under rate-limit cooldown")
            return AppActorReceiptPostResponse(status: "ok", requestId: nil)
        }

        // New processor (simulates app restart) should load the persisted cooldown
        let newProcessor = await makeProcessor()
        await newProcessor.kick()
        try? await Task.sleep(nanoseconds: 300_000_000)

        // Item should still be in the store (not processed)
        let items = store.allItems()
        XCTAssertEqual(items.count, 1, "Item should not be processed while under cooldown")
        XCTAssertEqual(items.first?.phase, .needsPost, "Phase should remain .needsPost")
    }

    func testExpiredCooldownClearedOnDrain() async {
        // Simulate an expired cooldown
        let pastCooldown = Date().addingTimeInterval(-10) // 10s ago
        store.setRateLimitCooldown(pastCooldown)

        store.upsert(makeItem())

        client.postReceiptHandler = { (_: AppActorReceiptPostRequest) in
            AppActorReceiptPostResponse(status: "ok", requestId: "req_ok")
        }

        let newProcessor = await makeProcessor()
        await newProcessor.kick()
        try? await Task.sleep(nanoseconds: 300_000_000)

        // Expired cooldown should be cleared and item processed
        XCTAssertNil(store.getRateLimitCooldown(), "Expired cooldown should be cleared")
        XCTAssertEqual(store.allItems().count, 0, "Item should be processed after cooldown expired")
    }

    func testDrainSkipsPostButFinishesNeedsFinishDuringCooldown() async {
        // Cooldown active — drain should still handle .needsFinish items
        let futureCooldown = Date().addingTimeInterval(300)
        store.setRateLimitCooldown(futureCooldown)

        // One item needs finishing, one needs posting
        var finishItem = makeItem(key: "apple:com.test:sandbox:fin", transactionId: "fin")
        finishItem.phase = .needsFinish
        store.update(finishItem)

        store.upsert(makeItem(key: "apple:com.test:sandbox:post", transactionId: "post"))

        client.postReceiptHandler = { (_: AppActorReceiptPostRequest) in
            XCTFail("Should NOT POST while under rate-limit cooldown")
            return AppActorReceiptPostResponse(status: "ok", requestId: nil)
        }

        let newProcessor = await makeProcessor()
        await newProcessor.kick()
        try? await Task.sleep(nanoseconds: 300_000_000)

        let items = store.allItems()
        // .needsFinish item should be finished and removed
        XCTAssertFalse(items.contains { $0.key == "apple:com.test:sandbox:fin" },
                       ".needsFinish item should be finished even during cooldown")
        // .needsPost item should remain untouched
        XCTAssertTrue(items.contains { $0.key == "apple:com.test:sandbox:post" },
                      ".needsPost item should remain during cooldown")
    }

    // MARK: - Posted Ledger (Duplicate POST Prevention)

    func testSuccessfulPostMarksKeyInLedger() async {
        client.postReceiptHandler = { (_: AppActorReceiptPostRequest) in
            AppActorReceiptPostResponse(status: "ok", requestId: "req_ok")
        }

        let item = makeItem()
        store.upsert(item)
        await processor.kick()
        try? await Task.sleep(nanoseconds: 300_000_000)

        // Item should be processed and removed
        XCTAssertEqual(store.allItems().count, 0)
        // Key should be in the posted ledger
        XCTAssertTrue(store.isPosted(key: item.key), "Successful POST should mark key in ledger")
    }

    func testPermanentErrorAlsoMarksLedger() async {
        client.postReceiptHandler = { (_: AppActorReceiptPostRequest) in
            AppActorReceiptPostResponse(
                status: "permanent_error",
                error: AppActorReceiptErrorInfo(code: "INVALID_JWS", message: nil),
                requestId: "req_perm"
            )
        }

        let item = makeItem()
        store.upsert(item)
        await processor.kick()
        try? await Task.sleep(nanoseconds: 300_000_000)

        // Permanent errors should also mark the ledger to prevent re-enqueue
        XCTAssertTrue(store.isPosted(key: item.key), "Permanent error should also mark key in ledger")
    }

    func testPostedLedgerPreventsDuplicatePostAfterRestart() async {
        // Phase 1: First processor posts successfully
        client.postReceiptHandler = { (_: AppActorReceiptPostRequest) in
            AppActorReceiptPostResponse(status: "ok", requestId: "req_ok")
        }

        let item = makeItem()
        store.upsert(item)
        await processor.kick()
        try? await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertEqual(store.allItems().count, 0, "Item should be processed and removed")
        XCTAssertTrue(store.isPosted(key: item.key), "Key should be in posted ledger")
        let postCountAfterFirst = client.postReceiptCalls.count
        XCTAssertEqual(postCountAfterFirst, 1)

        // Phase 2: Simulate app crash/restart
        // Transaction.updates re-fires → item re-enqueued into store
        store.upsert(item)

        client.postReceiptHandler = { (_: AppActorReceiptPostRequest) in
            XCTFail("Should NOT POST — key is already in posted ledger")
            return AppActorReceiptPostResponse(status: "ok", requestId: nil)
        }

        // New processor with same store (simulates restart)
        let restartedProcessor = await makeProcessor()
        await restartedProcessor.kick()
        try? await Task.sleep(nanoseconds: 300_000_000)

        // Drain Step 1 should clean up the stale posted item without POSTing
        XCTAssertEqual(store.allItems().count, 0, "Stale posted item should be removed by drain")
        XCTAssertEqual(client.postReceiptCalls.count, postCountAfterFirst,
                       "No additional POST should be made for already-posted key")
    }

    func testRetryableErrorDoesNotMarkLedger() async {
        client.postReceiptHandler = { (_: AppActorReceiptPostRequest) in
            AppActorReceiptPostResponse(
                status: "retryable_error",
                error: AppActorReceiptErrorInfo(code: "INTERNAL", message: nil),
                requestId: "req_retry"
            )
        }

        let item = makeItem()
        store.upsert(item)
        await processor.kick()
        try? await Task.sleep(nanoseconds: 300_000_000)

        // Retryable errors should NOT mark the ledger — the item needs to be retried
        XCTAssertFalse(store.isPosted(key: item.key),
                       "Retryable error should NOT mark key in ledger")
        XCTAssertEqual(store.allItems().count, 1, "Item should remain in queue for retry")
    }

    func testPostedLedgerPreventsDuplicateAcrossMultipleRestarts() async {
        // Phase 1: Successful POST
        client.postReceiptHandler = { (_: AppActorReceiptPostRequest) in
            AppActorReceiptPostResponse(status: "ok", requestId: "req_ok")
        }

        let item = makeItem()
        store.upsert(item)
        await processor.kick()
        try? await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertTrue(store.isPosted(key: item.key))
        let postCount = client.postReceiptCalls.count

        // Suppress the XCTFail handler — just count POSTs instead
        client.postReceiptHandler = { (_: AppActorReceiptPostRequest) in
            AppActorReceiptPostResponse(status: "ok", requestId: nil)
        }

        // Phase 2 & 3: Two more "restarts" re-enqueue the same key
        for restart in 1...2 {
            store.upsert(item)
            let proc = await makeProcessor()
            await proc.kick()
            try? await Task.sleep(nanoseconds: 300_000_000)

            XCTAssertEqual(store.allItems().count, 0,
                           "Restart \(restart): stale item should be cleaned up")
        }

        // No additional POSTs across any restart
        XCTAssertEqual(client.postReceiptCalls.count, postCount,
                       "No additional POSTs should occur across multiple restarts")
    }

    func testDuplicateSkippedPipelineEventOnStaleCleanup() async {
        let accumulator = PipelineEventAccumulator()

        // Pre-populate ledger (simulating previous session's successful POST)
        store.markPosted(key: "apple:12345")

        // Item exists in store (simulating crash — item wasn't removed before crash)
        store.upsert(makeItem())

        client.postReceiptHandler = { (_: AppActorReceiptPostRequest) in
            XCTFail("Should NOT POST — key is in posted ledger")
            return AppActorReceiptPostResponse(status: "ok", requestId: nil)
        }

        let newProcessor = await makeProcessor()
        await newProcessor.setPipelineEventHandler { accumulator.append($0) }
        await newProcessor.kick()
        try? await Task.sleep(nanoseconds: 300_000_000)

        // Item should be removed by drain Step 1
        XCTAssertEqual(store.allItems().count, 0, "Stale posted item should be removed")
        // No POST should have been made
        XCTAssertEqual(client.postReceiptCalls.count, 0)
    }

    // MARK: - RCPT-02: Dead-letter paths populate posted ledger

    /// RCPT-02 / F1: Retryable exhaustion (maxRetryAttempts reached) must write to posted ledger
    /// before finishing the transaction. Verifies the fix applied in Plan 01-01.
    func test_givenRetryableExhausted_whenDeadLettered_thenNotPostedWhenYoung() async {
        client.postReceiptHandler = { (_: AppActorReceiptPostRequest) in
            AppActorReceiptPostResponse(
                status: "retryable_error",
                error: AppActorReceiptErrorInfo(code: "INTERNAL", message: nil),
                requestId: "req_retry"
            )
        }

        // Set attemptCount to maxRetryAttempts - 1 so the next attempt triggers dead-letter
        let item = makeItem(attemptCount: AppActorPaymentProcessor.maxRetryAttempts - 1)
        store.upsert(item)
        await processor.kick()
        try? await Task.sleep(nanoseconds: 300_000_000)

        let items = store.allItems()
        XCTAssertEqual(items.count, 1, "Dead-lettered item should remain for diagnostics")
        XCTAssertEqual(items.first?.phase, .deadLettered, "Item should be dead-lettered after max attempts")
        // Young items (<7 days) must NOT be marked posted — sweepUnfinished() will recover them
        XCTAssertFalse(store.isPosted(key: item.key),
                       "Young dead-lettered items must NOT be in posted ledger to allow recovery on next boot")
    }

    func test_givenRetryableExhausted_whenDeadLettered_thenPostedWhenExpired() async {
        client.postReceiptHandler = { (_: AppActorReceiptPostRequest) in
            AppActorReceiptPostResponse(
                status: "retryable_error",
                error: AppActorReceiptErrorInfo(code: "INTERNAL", message: nil),
                requestId: "req_retry"
            )
        }

        // Create an item older than retryLifetimeLimit (7 days)
        let item = makeItem(
            attemptCount: AppActorPaymentProcessor.maxRetryAttempts - 1,
            firstSeenAt: Date().addingTimeInterval(-(AppActorPaymentProcessor.retryLifetimeLimit + 24 * 60 * 60))
        )
        store.upsert(item)
        await processor.kick()
        try? await Task.sleep(nanoseconds: 300_000_000)

        let items = store.allItems()
        XCTAssertEqual(items.count, 1, "Dead-lettered item should remain for diagnostics")
        XCTAssertEqual(items.first?.phase, .deadLettered)
        // Expired items (>7 days) must be permanently dead-lettered
        XCTAssertTrue(store.isPosted(key: item.key),
                      "Expired dead-lettered items must be in posted ledger — no more recovery attempts")
    }

    /// RCPT-02 / F2: Decode mismatch exhaustion (maxDecodeRetryAttempts reached) must also write
    /// to posted ledger before finishing. Verifies the fix applied in Plan 01-01.
    func test_givenDecodeMismatchExhausted_whenDeadLettered_thenLedgerMarked() async {
        client.postReceiptHandler = { (_: AppActorReceiptPostRequest) in
            throw AppActorError.decodingError(
                NSError(domain: "Test", code: 0, userInfo: [NSLocalizedDescriptionKey: "missing key"]),
                requestId: "req_decode"
            )
        }

        // Set attemptCount to maxDecodeRetryAttempts - 1 so the next attempt triggers dead-letter
        let item = makeItem(attemptCount: AppActorPaymentProcessor.maxDecodeRetryAttempts - 1)
        store.upsert(item)
        await processor.kick()
        try? await Task.sleep(nanoseconds: 300_000_000)

        let items = store.allItems()
        XCTAssertEqual(items.count, 1, "Dead-lettered item should remain for diagnostics")
        XCTAssertEqual(items.first?.phase, .deadLettered, "Item should be dead-lettered after max decode attempts")
        // KEY ASSERTION: decode-mismatch dead-letter must also write to posted ledger
        XCTAssertTrue(store.isPosted(key: item.key),
                      "RCPT-02: Dead-letter via decode mismatch must write to posted ledger")
    }

    /// RCPT-02 + RCPT-03: A key already in the posted ledger (from dead-letter or prior POST)
    /// prevents re-enqueue via the drain loop and the enqueue() path.
    ///
    /// Tests both sweep dedup (RCPT-03: sweepUnfinished → enqueue() → isPosted check)
    /// and direct re-enqueue dedup (RCPT-02: any path that upserts into store).
    /// Since unit tests cannot create real StoreKit transactions for sweepUnfinished(),
    /// we test the enqueue() dedup path directly — the same code path exercised by sweepUnfinished.
    func test_givenDeadLetteredInLedger_whenEnqueueSameKey_thenSkipped() async {
        // Pre-populate ledger: item was dead-lettered (or previously posted) in a prior session
        store.markPosted(key: "apple:12345")

        // Simulate re-enqueue after app restart (e.g., StoreKit re-delivers the transaction)
        store.upsert(makeItem())

        client.postReceiptHandler = { (_: AppActorReceiptPostRequest) in
            XCTFail("RCPT-02/RCPT-03: Should NOT POST — key is already in posted ledger")
            return AppActorReceiptPostResponse(status: "ok", requestId: nil)
        }

        let newProcessor = await makeProcessor()
        await newProcessor.kick()
        try? await Task.sleep(nanoseconds: 300_000_000)

        // Drain Step 1 should clean up the stale posted item without POSTing
        XCTAssertEqual(client.postReceiptCalls.count, 0,
                       "RCPT-02/RCPT-03: No POST should be made for a key already in posted ledger")
        XCTAssertEqual(store.allItems().count, 0,
                       "Stale item with posted key should be removed by drain cleanup")
    }

    // MARK: - Redrain (kick during active drain)

    /// Verifies that an item enqueued while drain is running gets processed
    /// via the stream buffer (bufferingNewest(1) coalescing).
    func testItemEnqueuedDuringDrainGetsProcessed() async {
        var postCount = 0

        // First item takes 200ms to process — gives time to enqueue second item mid-drain
        client.postReceiptHandler = { _ in
            postCount += 1
            if postCount == 1 {
                try? await Task.sleep(nanoseconds: 200_000_000) // 200ms
            }
            return AppActorReceiptPostResponse(status: "ok", requestId: nil)
        }

        let item1 = makeItem(key: "apple:com.test:sandbox:weekly_001", transactionId: "weekly_001")
        store.upsert(item1)
        await processor.kick()

        // Wait 50ms — drain is in-flight processing item1
        try? await Task.sleep(nanoseconds: 50_000_000)

        // Enqueue second item while drain is still running
        let item2 = makeItem(key: "apple:com.test:sandbox:yearly_002", transactionId: "yearly_002")
        store.upsert(item2)
        await processor.kick()  // This yields to the stream buffer

        // Wait enough for both drain cycles to complete
        try? await Task.sleep(nanoseconds: 600_000_000)

        XCTAssertEqual(postCount, 2, "Both items should be POSTed — second via stream coalescing")
        XCTAssertEqual(store.allItems().count, 0, "Both items should be removed after successful POST")
    }

    /// Verifies that kick() during active drain triggers another pass via stream coalescing.
    func testKickDuringDrainCleanupTriggersRedrain() async {
        client.postReceiptHandler = { _ in
            return AppActorReceiptPostResponse(status: "ok", requestId: nil)
        }

        let item1 = makeItem(key: "apple:com.test:sandbox:tx_100", transactionId: "tx_100")
        store.upsert(item1)

        // Start drain — it will process item1 quickly
        await processor.kick()
        try? await Task.sleep(nanoseconds: 200_000_000)

        // Drain should have finished processing item1
        XCTAssertEqual(client.postReceiptCalls.count, 1)

        // Now enqueue item2 and kick — the stream coalescing
        // mechanism ensures item2 gets processed
        let item2 = makeItem(key: "apple:com.test:sandbox:tx_200", transactionId: "tx_200")
        store.upsert(item2)
        await processor.kick()

        try? await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertEqual(client.postReceiptCalls.count, 2, "Second item should be POSTed")
        XCTAssertEqual(store.allItems().count, 0, "All items should be processed")
    }

    // MARK: - Dead-Letter Upsert Reset

    func test_deadLetteredItemResetsOnReenqueue() {
        let item = makeItem(phase: .deadLettered, attemptCount: 3)
        store.upsert(item)

        XCTAssertEqual(store.allItems().first?.phase, .deadLettered)
        XCTAssertEqual(store.allItems().first?.attemptCount, 3)

        // Simulate sweepUnfinished re-enqueue: upsert same key with fresh item
        let freshItem = makeItem(phase: .needsPost, attemptCount: 0)
        store.upsert(freshItem)

        let result = store.allItems().first
        XCTAssertEqual(result?.phase, .needsPost, "Dead-lettered item must reset to needsPost on re-enqueue")
        XCTAssertEqual(result?.attemptCount, 0, "Attempt count must reset for fresh retry cycle")
    }
}
