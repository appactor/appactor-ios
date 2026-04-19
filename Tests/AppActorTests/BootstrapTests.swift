import XCTest
@testable import AppActor

@MainActor
final class BootstrapTests: XCTestCase {

    private var appactor: AppActor!
    private var mockClient: MockPaymentClient!
    private var storage: InMemoryPaymentStorage!

    private func makeQueueItem(
        appUserId: String,
        transactionId: String,
        phase: AppActorPaymentQueueItem.Phase = .needsPost
    ) -> AppActorPaymentQueueItem {
        AppActorPaymentQueueItem(
            key: AppActorPaymentQueueItem.makeKey(transactionId: transactionId),
            bundleId: "com.test",
            environment: "sandbox",
            transactionId: transactionId,
            jws: "jws_\(transactionId)",
            signedAppTransactionInfo: nil,
            appUserId: appUserId,
            productId: "com.test.monthly",
            originalTransactionId: transactionId,
            storefront: "USA",
            offeringId: nil,
            packageId: nil,
            phase: phase,
            attemptCount: 0,
            nextRetryAt: Date(),
            firstSeenAt: Date(),
            lastSeenAt: Date(),
            lastError: nil,
            sources: [.purchase],
            claimedAt: nil
        )
    }

    override func setUp() {
        super.setUp()
        appactor = AppActor.shared
        mockClient = MockPaymentClient()
        storage = InMemoryPaymentStorage()
    }

    override func tearDown() {
        appactor.asaTask?.cancel()
        appactor.asaTask = nil
        appactor.foregroundTask?.cancel()
        appactor.foregroundTask = nil
        appactor.offeringsPrefetchTask?.cancel()
        appactor.offeringsPrefetchTask = nil
        appactor.paymentConfig = nil
        appactor.paymentStorage = nil
        appactor.paymentClient = nil
        appactor.paymentCurrentUser = nil
        appactor.paymentETagManager = nil
        appactor.offeringsManager = nil
        appactor.customerManager = nil
        appactor.remoteConfigManager = nil
        appactor.experimentManager = nil
        appactor.paymentProcessor = nil
        appactor.transactionWatcher = nil
        appactor.paymentQueueStore = nil
        appactor.paymentLifecycle = .idle
        super.tearDown()
    }

    // MARK: - Configure awaits bootstrap

    func testConfigureAwaitsBootstrapCompletion() async {
        // configure is now async — when it returns, bootstrap is done
        let config = AppActorPaymentConfiguration(
            apiKey: "pk_test_await",
            baseURL: URL(string: "https://api.test.appactor.com")!
        )
        appactor.configureForTesting(config: config, client: mockClient, storage: storage)
        await appactor.runStartupSequence()

        // After await, the local identity and offerings API warm-up should already be ready
        XCTAssertEqual(mockClient.identifyCalls.count, 0,
                       "RC-style configure should not perform an identify handshake")
        XCTAssertEqual(mockClient.getOfferingsCallCount, 1,
                       "Offerings API should be warmed during configure")
        XCTAssertNotNil(appactor.appUserId,
                        "Local appUserId should be ready after configure completes")
    }

    func testConfigureTreatsWhitespaceAppUserIdAsOmittedAndReusesCachedIdentity() async {
        storage.setAppUserId("cached_user")

        let config = AppActorPaymentConfiguration(
            apiKey: "pk_test_whitespace_config",
            baseURL: URL(string: "https://api.test.appactor.com")!,
            appUserId: "   "
        )
        appactor.configureForTesting(config: config, client: mockClient, storage: storage)
        await appactor.runStartupSequence()

        XCTAssertEqual(appactor.appUserId, "cached_user")
        XCTAssertEqual(storage.currentAppUserId, "cached_user")
        XCTAssertEqual(mockClient.identifyCalls.count, 0)
    }

    // MARK: - Bootstrap order

    func testBootstrapUsesLocalIdentityBeforeOfferingsApiWarmup() async {
        nonisolated(unsafe) var localIdentityReadyBeforeOfferingsStart = false
        let capturedStorage = storage!

        mockClient.getOfferingsHandler = { _ in
            localIdentityReadyBeforeOfferingsStart = capturedStorage.currentAppUserId != nil
            return .fresh(
                AppActorOfferingsResponseDTO(currentOffering: nil, offerings: []),
                eTag: "offerings_hash",
                requestId: "req_offerings",
                signatureVerified: false
            )
        }

        let config = AppActorPaymentConfiguration(
            apiKey: "pk_test_order",
            baseURL: URL(string: "https://api.test.appactor.com")!
        )
        appactor.configureForTesting(config: config, client: mockClient, storage: storage)
        await appactor.runStartupSequence()

        XCTAssertEqual(mockClient.identifyCalls.count, 0, "Bootstrap should not call identify")
        XCTAssertEqual(mockClient.getOfferingsCallCount, 1, "Offerings API should be called once")
        XCTAssertTrue(localIdentityReadyBeforeOfferingsStart,
                      "Local appUserId must exist before offerings API warm-up starts")
    }

    // MARK: - Customer refresh failure

    func testBootstrapContinuesAfterCustomerRefreshFailureAndStillWarmsOfferingsApi() async {
        mockClient.getCustomerHandler = { _, _ in
            throw AppActorError.networkError(URLError(.notConnectedToInternet))
        }

        var offeringsCalled = false
        mockClient.getOfferingsHandler = { _ in
            offeringsCalled = true
            return .fresh(
                AppActorOfferingsResponseDTO(currentOffering: nil, offerings: []),
                eTag: nil,
                requestId: nil,
                signatureVerified: false
            )
        }

        let config = AppActorPaymentConfiguration(
            apiKey: "pk_test_identify_fail",
            baseURL: URL(string: "https://api.test.appactor.com")!
        )
        appactor.configureForTesting(config: config, client: mockClient, storage: storage)
        await appactor.runStartupSequence()

        XCTAssertEqual(mockClient.identifyCalls.count, 0, "Bootstrap should not attempt identify")
        XCTAssertTrue(offeringsCalled,
                      "Offerings API warm-up should still run even when customer refresh fails")
        XCTAssertNil(appactor.paymentCurrentUser,
                     "No server customer snapshot should be set when refresh failed")
    }

    func testSuccessfulCustomerFetchDrainsQueuedReceiptsInSameSession() async throws {
        storage.setAppUserId("current_user")
        let queueStore = InMemoryPaymentQueueStore()
        let processor = AppActorPaymentProcessor(store: queueStore, client: mockClient)
        let watcher = AppActorTransactionWatcher(
            processor: processor,
            storage: storage,
            silentSyncFetcher: AppActorStoreKitSilentSyncFetcher()
        )

        queueStore.upsert(makeQueueItem(appUserId: "current_user", transactionId: "tx_waiting"))

        mockClient.getCustomerHandler = { appUserId, _ in
            .fresh(
                AppActorCustomerInfo(
                    entitlements: ["premium": AppActorEntitlementInfo(id: "premium", isActive: true)],
                    appUserId: appUserId
                ),
                eTag: "cust_hash",
                requestId: "req_customer_success",
                signatureVerified: false
            )
        }
        mockClient.postReceiptHandler = { request in
            XCTAssertEqual(request.appUserId, "current_user")
            return AppActorReceiptPostResponse(status: "ok", requestId: "req_receipt_release")
        }

        let config = AppActorPaymentConfiguration(
            apiKey: "pk_test_identify_fail_release",
            baseURL: URL(string: "https://api.test.appactor.com")!
        )
        appactor.configureForTesting(config: config, client: mockClient, storage: storage)
        appactor.paymentQueueStore = queueStore
        appactor.paymentProcessor = processor
        appactor.transactionWatcher = watcher

        await appactor.runStartupSequence()
        try await Task.sleep(nanoseconds: 400_000_000)

        XCTAssertEqual(mockClient.postReceiptCalls.count, 1,
                       "Bootstrap should drain queued receipts in the same session")
        XCTAssertTrue(queueStore.allItems().isEmpty)
    }

    func testReceiptForOldIdentityRefreshesCurrentCustomerState() async throws {
        storage.setAppUserId("current_user")
        let queueStore = InMemoryPaymentQueueStore()
        var customerFetchCount = 0

        mockClient.getCustomerHandler = { appUserId, _ in
            customerFetchCount += 1
            let entitlementId = customerFetchCount == 1 ? "stale" : "fresh"
            return .fresh(
                AppActorCustomerInfo(
                    entitlements: [entitlementId: AppActorEntitlementInfo(id: entitlementId, isActive: true)],
                    appUserId: appUserId
                ),
                eTag: "customer_hash_\(customerFetchCount)",
                requestId: "req_customer_\(customerFetchCount)",
                signatureVerified: false
            )
        }
        mockClient.postReceiptHandler = { request in
            XCTAssertEqual(request.appUserId, "old_user")
            return AppActorReceiptPostResponse(
                status: "ok",
                customer: AppActorCustomerDTO(
                    entitlements: [
                        "legacy": AppActorEntitlementDTO(
                            isActive: true,
                            productId: "com.test.monthly"
                        )
                    ]
                ),
                requestId: "req_old_receipt"
            )
        }

        let config = AppActorPaymentConfiguration(
            apiKey: "pk_test_old_receipt_refresh",
            baseURL: URL(string: "https://api.test.appactor.com")!
        )
        appactor.configureForTesting(
            config: config,
            client: mockClient,
            storage: storage,
            paymentQueueStore: queueStore
        )
        await appactor.runStartupSequence()
        let baselineCustomerFetches = mockClient.getCustomerCalls.count

        queueStore.upsert(makeQueueItem(appUserId: "old_user", transactionId: "tx_old"))
        await appactor.paymentProcessor?.kick()
        try await Task.sleep(nanoseconds: 500_000_000)

        XCTAssertEqual(mockClient.getCustomerCalls.count, baselineCustomerFetches + 1,
                       "An old-identity receipt should trigger a refresh for the current user")
        XCTAssertEqual(appactor.customerInfo.appUserId, "current_user")
        XCTAssertNotNil(appactor.customerInfo.entitlements["fresh"])
        XCTAssertTrue(queueStore.allItems().isEmpty)
    }

    // MARK: - Lazy offerings fetch

    func testOfferingsFetchesOnDemandAfterBootstrap() async {
        let config = AppActorPaymentConfiguration(
            apiKey: "pk_test_dedup",
            baseURL: URL(string: "https://api.test.appactor.com")!
        )
        appactor.configureForTesting(config: config, client: mockClient, storage: storage)
        await appactor.runStartupSequence()

        XCTAssertEqual(mockClient.identifyCalls.count, 0,
                       "Bootstrap should not call identify")
        XCTAssertEqual(mockClient.getOfferingsCallCount, 1,
                       "Bootstrap should warm the offerings API exactly once")

        let offerings = try? await appactor.offerings()
        XCTAssertNotNil(offerings)
        XCTAssertEqual(mockClient.getOfferingsCallCount, 1,
                       "First explicit offerings() call should reuse the warmed in-flight/cached result")
    }

    // MARK: - Exactly once per configure

    func testBootstrapRunsExactlyOncePerConfigure() async {
        let config = AppActorPaymentConfiguration(
            apiKey: "pk_test_once",
            baseURL: URL(string: "https://api.test.appactor.com")!
        )
        appactor.configureForTesting(config: config, client: mockClient, storage: storage)
        await appactor.runStartupSequence()

        XCTAssertEqual(mockClient.identifyCalls.count, 0)
        XCTAssertEqual(mockClient.getOfferingsCallCount, 1)

        // Re-configure — should start a new bootstrap, not duplicate
        await appactor.reset()
        let freshClient = MockPaymentClient()

        let config2 = AppActorPaymentConfiguration(
            apiKey: "pk_test_once",
            baseURL: URL(string: "https://api.test.appactor.com")!
        )
        appactor.configureForTesting(config: config2, client: freshClient, storage: storage)
        await appactor.runStartupSequence()

        XCTAssertEqual(freshClient.identifyCalls.count, 0,
                       "Second configure should not perform identify")
        XCTAssertEqual(freshClient.getOfferingsCallCount, 1,
                       "Second configure should run exactly one offerings API warm-up")
    }

    // MARK: - BOOT-01: appUserId set before TransactionWatcher starts

    /// BOOT-01: Proves `resolveAppUserId(explicit:)` runs synchronously in `configureInternal()`
    /// BEFORE `runStartupSequence()`. The first async bootstrap step now warms offerings,
    /// so when the offerings request starts the local appUserId is already set.
    func testAppUserIdSeededBeforeWatcherStart() async {
        nonisolated(unsafe) var userIdAtOfferingsTime: String? = nil

        let capturedStorage = storage!
        mockClient.getOfferingsHandler = { _ in
            userIdAtOfferingsTime = capturedStorage.currentAppUserId
            return .fresh(
                AppActorOfferingsResponseDTO(currentOffering: nil, offerings: []),
                eTag: nil,
                requestId: "req_boot01",
                signatureVerified: false
            )
        }

        let config = AppActorPaymentConfiguration(
            apiKey: "pk_test_userid_order",
            baseURL: URL(string: "https://api.test.appactor.com")!
        )
        appactor.configureForTesting(config: config, client: mockClient, storage: storage)
        await appactor.runStartupSequence()

        XCTAssertNotNil(userIdAtOfferingsTime,
                        "appUserId must be set BEFORE the first async bootstrap step fires")
        XCTAssertTrue(userIdAtOfferingsTime?.hasPrefix("appactor-anon-") == true,
                      "appUserId should be anonymous when no explicit ID was provided")
    }

    // MARK: - BOOT-08: configure() completes all steps and swallows errors

    /// BOOT-08 (Part A): Proves configure() runs bootstrap steps — local identity,
    /// offerings warm-up, sweepUnfinished, and drainReceiptQueueAndRefreshCustomer().
    func testConfigureCompletesAllBootstrapSteps() async {
        let config = AppActorPaymentConfiguration(
            apiKey: "pk_test_all_steps",
            baseURL: URL(string: "https://api.test.appactor.com")!
        )
        appactor.configureForTesting(config: config, client: mockClient, storage: storage)
        await appactor.runStartupSequence()

        XCTAssertEqual(mockClient.identifyCalls.count, 0,
                       "Bootstrap should not perform an identify handshake")

        // Offerings API is warmed during bootstrap; StoreKit remains async/non-blocking
        XCTAssertEqual(mockClient.getOfferingsCallCount, 1,
                       "Offerings API should be warmed during bootstrap")

        XCTAssertNotNil(appactor.appUserId,
                        "Bootstrap must leave the SDK with a current local app user ID")
    }

    /// BOOT-08 (Part B): Proves configure() does NOT throw and SDK remains in .configured state
    /// even when bootstrap steps (offerings warm-up, drainReceiptQueueAndRefreshCustomer) fail.
    /// This locks the "partial-success" decision: errors are swallowed, SDK stays usable.
    func testConfigureDoesNotThrowWhenBootstrapStepsFail() async {
        mockClient.getCustomerHandler = { _, _ in
            throw AppActorError.networkError(URLError(.notConnectedToInternet))
        }

        // configure() must NOT throw — it swallows all bootstrap errors per locked decision.
        let config = AppActorPaymentConfiguration(
            apiKey: "pk_test_all_fail",
            baseURL: URL(string: "https://api.test.appactor.com")!
        )
        appactor.configureForTesting(config: config, client: mockClient, storage: storage)
        await appactor.runStartupSequence()

        // SDK must be in .configured state even though all steps failed
        XCTAssertEqual(appactor.paymentLifecycle, .configured,
                       "SDK must remain in .configured state even when all bootstrap steps fail")

        // No server snapshot set because customer refresh failed
        XCTAssertNil(appactor.paymentCurrentUser,
                     "No user should be set when customer refresh failed")

        XCTAssertNotNil(appactor.appUserId, "Local appUserId should still exist after partial bootstrap failure")
        XCTAssertEqual(mockClient.getOfferingsCallCount, 1,
                       "Offerings API warm-up should still be attempted during bootstrap")
    }

    // MARK: - BOOT-02: foreground notification behavior

    #if canImport(UIKit) && !os(watchOS)
    /// BOOT-02a: When customer cache is fresh (just bootstrapped), foreground does NOT
    /// trigger a customer refresh — only drains pending receipts.
    func testForegroundSkipsRefreshWhenCacheFresh() async throws {
        let config = AppActorPaymentConfiguration(
            apiKey: "pk_test_foreground_fresh",
            baseURL: URL(string: "https://api.test.appactor.com")!
        )
        appactor.configureForTesting(config: config, client: mockClient, storage: storage)
        // Must register lifecycle observers (configureForTesting doesn't call registerLifecycleObservers)
        appactor.registerLifecycleObservers()
        await appactor.runStartupSequence()

        // Record how many customer fetches happened during bootstrap
        let customerCallsAfterBootstrap = mockClient.getCustomerCalls.count

        // Post the foreground notification — cache was just seeded by bootstrap, so it's fresh
        NotificationCenter.default.post(
            name: UIApplication.willEnterForegroundNotification,
            object: nil
        )

        // Wait for the foreground Task to execute
        try await Task.sleep(nanoseconds: 300_000_000) // 300ms

        // Customer cache is fresh → no additional getCustomer call
        XCTAssertEqual(
            mockClient.getCustomerCalls.count,
            customerCallsAfterBootstrap,
            "Foreground must NOT refresh customer info when cache is fresh (<5 min)"
        )
    }

    /// BOOT-02b: When customer cache is stale (cleared), foreground triggers a customer refresh.
    func testForegroundRefreshesWhenCacheStale() async throws {
        let etagManager = AppActorETagManager()

        let config = AppActorPaymentConfiguration(
            apiKey: "pk_test_foreground_stale",
            baseURL: URL(string: "https://api.test.appactor.com")!
        )
        appactor.configureForTesting(
            config: config,
            client: mockClient,
            storage: storage,
            etagManager: etagManager
        )
        appactor.registerLifecycleObservers()
        await appactor.runStartupSequence()

        let customerCallsAfterBootstrap = mockClient.getCustomerCalls.count

        // Clear customer cache to simulate stale state (isFresh returns false)
        if let userId = storage.currentAppUserId {
            await etagManager.clear(.customer(appUserId: userId))
        }

        // Post the foreground notification — cache is now stale
        NotificationCenter.default.post(
            name: UIApplication.willEnterForegroundNotification,
            object: nil
        )

        // Wait for the foreground Task to execute
        try await Task.sleep(nanoseconds: 300_000_000) // 300ms

        // Customer cache is stale → getCustomer should be called
        XCTAssertGreaterThan(
            mockClient.getCustomerCalls.count,
            customerCallsAfterBootstrap,
            "Foreground must refresh customer info when cache is stale (>5 min)"
        )
    }
    #endif
}
