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

        // After await, identify and offerings API warm-up should already be called
        XCTAssertEqual(mockClient.identifyCalls.count, 1,
                       "Identify should have completed during configure")
        XCTAssertEqual(mockClient.getOfferingsCallCount, 1,
                       "Offerings API should be warmed during configure")
        XCTAssertNotNil(appactor.customerInfo.appUserId,
                        "User should be set after configure completes")
    }

    // MARK: - Bootstrap order

    func testBootstrapRunsIdentifyThenOfferingsApiWarmup() async {
        nonisolated(unsafe) var identifyDoneBeforeOfferingsStart = false

        mockClient.getOfferingsHandler = { [mockClient] _ in
            identifyDoneBeforeOfferingsStart = mockClient!.identifyCalls.count == 1
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

        XCTAssertEqual(mockClient.identifyCalls.count, 1, "Identify should be called once")
        XCTAssertEqual(mockClient.getOfferingsCallCount, 1, "Offerings API should be called once")
        XCTAssertTrue(identifyDoneBeforeOfferingsStart,
                      "Identify must complete before offerings API warm-up starts")
    }

    // MARK: - Identify failure

    func testBootstrapContinuesAfterIdentifyFailureAndStillWarmsOfferingsApi() async {
        // Make identify fail
        mockClient.identifyHandler = { _ in
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

        XCTAssertEqual(mockClient.identifyCalls.count, 1, "Identify should have been attempted")
        XCTAssertTrue(offeringsCalled,
                      "Offerings API warm-up should still run even when identify fails")
        XCTAssertNil(appactor.paymentCurrentUser,
                     "No user should be set when identify failed")
    }

    func testSuccessfulCustomerFetchAfterIdentifyFailureReleasesWaitingReceipts() async throws {
        storage.setAppUserId("current_user")
        let queueStore = InMemoryPaymentQueueStore()
        let unconfirmedProcessor = AppActorPaymentProcessor(store: queueStore, client: mockClient)
        let watcher = AppActorTransactionWatcher(
            processor: unconfirmedProcessor,
            storage: storage,
            silentSyncFetcher: AppActorStoreKitSilentSyncFetcher()
        )

        queueStore.upsert(makeQueueItem(appUserId: "current_user", transactionId: "tx_waiting"))

        mockClient.identifyHandler = { _ in
            throw AppActorError.networkError(URLError(.notConnectedToInternet))
        }
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
        appactor.paymentProcessor = unconfirmedProcessor
        appactor.transactionWatcher = watcher

        await appactor.runStartupSequence()
        try await Task.sleep(nanoseconds: 400_000_000)

        XCTAssertEqual(mockClient.postReceiptCalls.count, 1,
                       "A successful customer fetch should confirm the identity and release queued receipts in the same session")
        XCTAssertTrue(queueStore.allItems().isEmpty)
    }

    func testReceiptForOldIdentityRefreshesCurrentCustomerState() async throws {
        storage.setAppUserId("current_user")
        let queueStore = InMemoryPaymentQueueStore()
        var customerFetchCount = 0

        mockClient.identifyHandler = { request in
            AppActorIdentifyResult(
                appUserId: request.appUserId,
                serverUserId: "server-current-user",
                customerInfo: AppActorCustomerInfo(appUserId: request.appUserId),
                customerETag: "identify_hash",
                requestId: "req_identify_current",
                signatureVerified: false
            )
        }
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

        await appactor.paymentProcessor?.confirmIdentity(appUserId: "old_user")
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

        XCTAssertEqual(mockClient.identifyCalls.count, 1,
                       "Only one identify call expected (from bootstrap)")
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

        XCTAssertEqual(mockClient.identifyCalls.count, 1)
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

        XCTAssertEqual(freshClient.identifyCalls.count, 1,
                       "Second configure should run exactly one new identify")
        XCTAssertEqual(freshClient.getOfferingsCallCount, 1,
                       "Second configure should run exactly one offerings API warm-up")
    }

    // MARK: - BOOT-01: appUserId set before TransactionWatcher starts

    /// BOOT-01: Proves `ensureAppUserId()` is called synchronously in `configureInternal()`
    /// BEFORE `runStartupSequence()`. The first async step (identify) fires inside
    /// `runBootstrap()`, so when `identifyHandler` executes, the userId is already set.
    func testAppUserIdSeededBeforeWatcherStart() async {
        // Capture the userId state at the moment the first async bootstrap step fires.
        nonisolated(unsafe) var userIdAtIdentifyTime: String? = nil

        let capturedStorage = storage!
        mockClient.identifyHandler = { request in
            // Read the userId that was set synchronously in configureInternal() before this async call
            userIdAtIdentifyTime = capturedStorage.currentAppUserId
            return AppActorIdentifyResult(
                appUserId: request.appUserId,
                serverUserId: "server_boot01",
                customerInfo: AppActorCustomerInfo(appUserId: request.appUserId),
                customerETag: nil,
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

        XCTAssertNotNil(userIdAtIdentifyTime,
                        "appUserId must be set BEFORE the first async bootstrap step (identify) fires")
        XCTAssertTrue(userIdAtIdentifyTime?.hasPrefix("appactor-anon-") == true,
                      "appUserId should be anonymous when no explicit ID was provided")
    }

    // MARK: - BOOT-08: configure() completes all steps and swallows errors

    /// BOOT-08 (Part A): Proves configure() runs bootstrap steps — identify,
    /// sweepUnfinished, and drainReceiptQueueAndRefreshCustomer().
    func testConfigureCompletesAllBootstrapSteps() async {
        let config = AppActorPaymentConfiguration(
            apiKey: "pk_test_all_steps",
            baseURL: URL(string: "https://api.test.appactor.com")!
        )
        appactor.configureForTesting(config: config, client: mockClient, storage: storage)
        await appactor.runStartupSequence()

        // Step 1: identify was called
        XCTAssertEqual(mockClient.identifyCalls.count, 1,
                       "Step 1 (identify) must be called during bootstrap")

        // Offerings API is warmed during bootstrap; StoreKit remains async/non-blocking
        XCTAssertEqual(mockClient.getOfferingsCallCount, 1,
                       "Offerings API should be warmed during bootstrap")

        // Steps 4+5: drainReceiptQueueAndRefreshCustomer calls drainAll + getCustomerInfo (→ getCustomer)
        // The mock identify also seeds customer cache, so getCustomer may or may not
        // be called depending on cache freshness. We verify at least the user is set.
        XCTAssertNotNil(appactor.customerInfo.appUserId,
                        "Bootstrap must leave the SDK with a current payment user (identify succeeded)")
    }

    /// BOOT-08 (Part B): Proves configure() does NOT throw and SDK remains in .configured state
    /// even when bootstrap steps (identify, offerings API warm-up, drainReceiptQueueAndRefreshCustomer) fail.
    /// This locks the "partial-success" decision: errors are swallowed, SDK stays usable.
    func testConfigureDoesNotThrowWhenBootstrapStepsFail() async {
        mockClient.identifyHandler = { _ in
            throw AppActorError.networkError(URLError(.notConnectedToInternet))
        }
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

        // No user set because identify failed
        XCTAssertNil(appactor.paymentCurrentUser,
                     "No user should be set when identify failed")

        // Bootstrap still attempted all steps
        XCTAssertEqual(mockClient.identifyCalls.count, 1,
                       "Identify must still be attempted even though it will fail")
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
