import XCTest
@testable import AppActor

// MARK: - Tests

/// Tests for `AppActorAtomicJSONQueueStore` behaviors that require the real disk-backed
/// store. The in-memory mock (`InMemoryPaymentQueueStore`) has `purgeExpiredLedgerEntries`
/// as a no-op, so RCPT-07 ledger pruning tests MUST use this class with a temp directory.
final class PaymentQueueStoreTests: XCTestCase {

    private var tempDir: URL!
    private var store: AppActorAtomicJSONQueueStore!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PaymentQueueStoreTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        store = AppActorAtomicJSONQueueStore(directory: tempDir)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        store = nil
        super.tearDown()
    }

    // MARK: - RCPT-07: Ledger Pruning

    /// RCPT-07: Ledger entries older than the retention period must be removed by
    /// `purgeExpiredLedgerEntries`. This test manipulates the on-disk JSON directly
    /// to backdate a ledger entry, then verifies it is pruned.
    func test_givenOldLedgerEntries_whenPurged_thenRemovedFromLedger() throws {
        // Step 1: Mark a key as posted (writes to disk with current timestamp)
        store.markPosted(key: "old_key")
        XCTAssertTrue(store.isPosted(key: "old_key"), "Precondition: key should be in ledger")

        // Step 2: Read the queue JSON file and backdate the ledger entry to 91 days ago
        let fileURL = tempDir.appendingPathComponent("payment_queue.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path),
                      "Precondition: queue JSON file should exist after markPosted")

        let data = try Data(contentsOf: fileURL)

        // Decode as a generic JSON object to modify the timestamp
        var json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
            "JSON file should be a dictionary"
        )

        // The ledger is stored under the "postedKeys" key as [String: TimeInterval]
        var postedKeys = try XCTUnwrap(
            json["postedKeys"] as? [String: Double],
            "JSON should contain postedKeys dictionary"
        )

        // Backdate the entry to 91 days ago (beyond the 90-day retention window)
        let ninetyOneDaysAgo = Date().timeIntervalSince1970 - (91 * 24 * 60 * 60)
        postedKeys["old_key"] = ninetyOneDaysAgo
        json["postedKeys"] = postedKeys

        // Write the modified JSON back to disk atomically
        let modifiedData = try JSONSerialization.data(withJSONObject: json, options: [])
        try modifiedData.write(to: fileURL, options: .atomic)

        // Step 3: Create a fresh store instance pointing to the same directory.
        // This forces a re-read from disk since the new instance has no in-memory cache.
        let freshStore = AppActorAtomicJSONQueueStore(directory: tempDir)
        XCTAssertTrue(freshStore.isPosted(key: "old_key"),
                      "Precondition: fresh store should load backdated entry from disk")

        // Step 4: Purge entries older than 90 days
        freshStore.purgeExpiredLedgerEntries(olderThan: 90 * 24 * 60 * 60)

        // Step 5: Verify the old entry was removed
        XCTAssertFalse(freshStore.isPosted(key: "old_key"),
                       "RCPT-07: Ledger entry older than 90 days must be removed by purge")
    }

    /// RCPT-07: Ledger entries within the retention period must NOT be removed.
    func test_givenRecentLedgerEntries_whenPurged_thenNotRemoved() {
        // Mark a key as posted with the current timestamp
        store.markPosted(key: "recent_key")
        XCTAssertTrue(store.isPosted(key: "recent_key"), "Precondition: key should be in ledger")

        // Purge entries older than 90 days — the just-created entry should survive
        store.purgeExpiredLedgerEntries(olderThan: 90 * 24 * 60 * 60)

        XCTAssertTrue(store.isPosted(key: "recent_key"),
                      "RCPT-07: Ledger entry within 90-day retention must be preserved by purge")
    }

    /// RCPT-07: Entries exactly at the boundary (89 days old) should NOT be purged.
    func test_givenBoundaryAgeLedgerEntry_whenPurged_thenNotRemoved() throws {
        store.markPosted(key: "boundary_key")

        let fileURL = tempDir.appendingPathComponent("payment_queue.json")
        let data = try Data(contentsOf: fileURL)
        var json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]
        )
        var postedKeys = try XCTUnwrap(json["postedKeys"] as? [String: Double])

        // Set timestamp to exactly 89 days ago (within the 90-day window)
        let eightyNineDaysAgo = Date().timeIntervalSince1970 - (89 * 24 * 60 * 60)
        postedKeys["boundary_key"] = eightyNineDaysAgo
        json["postedKeys"] = postedKeys

        let modifiedData = try JSONSerialization.data(withJSONObject: json, options: [])
        try modifiedData.write(to: fileURL, options: .atomic)

        let freshStore = AppActorAtomicJSONQueueStore(directory: tempDir)
        freshStore.purgeExpiredLedgerEntries(olderThan: 90 * 24 * 60 * 60)

        XCTAssertTrue(freshStore.isPosted(key: "boundary_key"),
                      "RCPT-07: Ledger entry exactly 89 days old (within 90-day window) must be retained")
    }

    // MARK: - Basic ledger round-trip

    /// Verifies that markPosted + isPosted round-trips correctly through disk.
    func test_givenMarkedKey_whenCheckedInFreshStore_thenFound() {
        store.markPosted(key: "persisted_key")

        // Fresh store must load from disk
        let freshStore = AppActorAtomicJSONQueueStore(directory: tempDir)
        XCTAssertTrue(freshStore.isPosted(key: "persisted_key"),
                      "Posted key should persist to disk and be readable by a fresh store instance")
    }

    /// Verifies that an unmarked key is not found.
    func test_givenUnmarkedKey_whenChecked_thenNotFound() {
        XCTAssertFalse(store.isPosted(key: "never_posted"),
                       "Unmarked key should not be found in ledger")
    }

    func test_givenExpiredDeadLetter_whenLoaded_thenPurgedAndReportedOnce() {
        let oldDate = Date().addingTimeInterval(-(31 * 24 * 60 * 60))
        let item = AppActorPaymentQueueItem(
            key: "apple:expired",
            bundleId: "com.test",
            environment: "sandbox",
            transactionId: "expired_tx",
            jws: "jws_payload",
            signedAppTransactionInfo: nil,
            appUserId: "user_123",
            productId: "com.test.monthly",
            originalTransactionId: "expired_tx",
            storefront: "USA",
            offeringId: nil,
            packageId: nil,
            phase: .deadLettered,
            attemptCount: 3,
            nextRetryAt: oldDate,
            firstSeenAt: oldDate,
            lastSeenAt: oldDate,
            lastError: "INTERNAL",
            sources: [.purchase],
            claimedAt: nil
        )
        store.upsert(item)

        let freshStore = AppActorAtomicJSONQueueStore(directory: tempDir)
        let purged = freshStore.consumePurgedDeadLetters()

        XCTAssertEqual(
            purged,
            [
                AppActorPurgedDeadLetterSummary(
                    transactionId: "expired_tx",
                    productId: "com.test.monthly",
                    attemptCount: 3,
                    lastError: "INTERNAL"
                )
            ]
        )
        XCTAssertTrue(freshStore.snapshot().isEmpty, "Expired dead-letter should be removed from persisted queue")
        XCTAssertTrue(freshStore.consumePurgedDeadLetters().isEmpty, "Purged record should be consumed only once")
    }

    func testQueuedClientPurchaseContextPersistsAcrossDiskReload() {
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let observedAt = startedAt.addingTimeInterval(2)
        let item = AppActorPaymentQueueItem(
            key: "apple:context",
            bundleId: "com.test",
            environment: "sandbox",
            transactionId: "context_tx",
            jws: "jws_payload",
            signedAppTransactionInfo: nil,
            appUserId: "user_123",
            productId: "com.test.monthly",
            originalTransactionId: "context_tx",
            storefront: "USA",
            offeringId: nil,
            packageId: nil,
            clientPurchaseContext: AppActorClientPurchaseContext(
                clientPurchaseAttemptStartedAt: startedAt,
                clientObservedAt: observedAt,
                clientDeliverySource: .purchaseFlow,
                clientPurchaseAttemptId: "attempt-ios-disk",
                placement: "paywall.disk",
                sdkOriginated: true,
                sdkVersion: "9.9.9"
            ),
            phase: .needsPost,
            attemptCount: 0,
            nextRetryAt: startedAt,
            firstSeenAt: startedAt,
            lastSeenAt: observedAt,
            lastError: nil,
            sources: [.purchase],
            claimedAt: nil
        )
        store.upsert(item)

        let freshStore = AppActorAtomicJSONQueueStore(directory: tempDir)
        let snapshot = freshStore.snapshot()
        XCTAssertEqual(snapshot.count, 1)
        let context = snapshot.first?.clientPurchaseContext

        XCTAssertEqual(context?.clientPurchaseAttemptStartedAt, startedAt)
        XCTAssertEqual(context?.clientObservedAt, observedAt)
        XCTAssertEqual(context?.clientDeliverySource, .purchaseFlow)
        XCTAssertEqual(context?.clientPurchaseAttemptId, "attempt-ios-disk")
        XCTAssertEqual(context?.placement, "paywall.disk")
        XCTAssertEqual(context?.sdkVersion, "9.9.9")
    }

    // MARK: - I-S3-2: a claim left by an earlier process

    func test_givenClaimFromAnEarlierProcess_whenLoaded_thenDueAgainAtOnce() {
        store.upsert(.fixture(key: "apple:claimed"))
        XCTAssertEqual(store.claimReady(limit: 10, now: Date()).map(\.key), ["apple:claimed"])
        XCTAssertTrue(store.claimReady(limit: 10, now: Date()).isEmpty, "a live claim in this store is not claimed twice")

        // The process dies mid-POST and is relaunched well within the 2-minute stale window.
        let relaunched = AppActorAtomicJSONQueueStore(directory: tempDir)
        let item = relaunched.snapshot().first
        XCTAssertEqual(item?.phase, .needsPost)
        XCTAssertNil(item?.claimedAt)
        XCTAssertEqual(relaunched.claimReady(limit: 10, now: Date()).map(\.key), ["apple:claimed"])
    }

    func test_givenClaimFromAnEarlierProcess_whenTheLaunchDrainRuns_thenPosted() async {
        store.upsert(.fixture(key: "apple:claimed", appUserId: "guest"))
        _ = store.claimReady(limit: 10, now: Date())

        let client = MockPaymentClient()
        let processor = AppActorPaymentProcessor(store: AppActorAtomicJSONQueueStore(directory: tempDir), client: client)
        // The startup order: the rejected-ID migration first, then the bootstrap drain.
        await processor.reassignUnpostedItemsWithRejectedAppUserId(to: "appactor-anon-new")
        await processor.drainAll()

        XCTAssertEqual(client.postReceiptCalls.map(\.transactionId), ["apple:claimed"])
        XCTAssertEqual(client.postReceiptCalls.first?.appUserId, "appactor-anon-new")
        XCTAssertTrue(AppActorAtomicJSONQueueStore(directory: tempDir).snapshot().isEmpty)
    }

    // MARK: - I-G-1: a revocation's ledger key is not the item's key

    func test_givenRevocationLedgerKey_whenMarkedPostedAndUpdated_thenItemStaysUnderItsOwnKey() {
        store.upsert(.fixture(key: "apple:1"))
        var finished = AppActorPaymentQueueItem.fixture(key: "apple:1")
        finished.phase = .needsFinish

        store.markPostedAndUpdate(key: "apple:1:revoked", item: finished)

        XCTAssertEqual(store.snapshot().map(\.key), ["apple:1"])
        XCTAssertEqual(store.snapshot().first?.phase, .needsFinish)
        XCTAssertTrue(store.isPosted(key: "apple:1:revoked"))
        XCTAssertFalse(store.isPosted(key: "apple:1"))
        store.remove(key: "apple:1")
        XCTAssertTrue(store.snapshot().isEmpty)
        XCTAssertTrue(AppActorAtomicJSONQueueStore(directory: tempDir).snapshot().isEmpty)
    }

}
