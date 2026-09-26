import XCTest
@_spi(AppActorPluginSupport) @testable import AppActor

// MARK: - Bootstrap Lifecycle Correctness Tests
//
// Tests for three confirmed bug fixes:
//   BOOT-06: assertionFailure removed — configure guards log a warning and return false
//   BOOT-07: revertLifecycleIfCancelled() is async and stops watcher + processor
//   BOOT-04/05: logIn() and logOut() drain the receipt queue before clearing caches

@MainActor
final class BootstrapLifecycleTests: XCTestCase {

    private var appactor: AppActor!
    private var mockClient: MockPaymentClient!
    private var storage: InMemoryPaymentStorage!

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
        appactor.paymentConfig = nil
        appactor.paymentStorage = nil
        appactor.paymentClient = nil
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

    // MARK: - BOOT-06: Double-configure returns false without crash

    /// Verifies that calling configure() while already configured returns false and does NOT crash.
    /// The assertionFailure was removed — the guard now silently logs a warning.
    func testDoubleConfigureReturnsFalseWithoutCrash() {
        // Arrange: put the SDK into .configured state via the instance method (no startup)
        let config = AppActorPaymentConfiguration(
            apiKey: "pk_test_boot06",
            baseURL: URL(string: "https://api.test.appactor.com")!
        )
        appactor.configureForTesting(config: config, client: mockClient, storage: storage)
        XCTAssertEqual(appactor.paymentLifecycle, .configured)

        // Act: call configureInternal() again — should return false without assertionFailure crash
        let result = appactor.configureInternal(config)

        // Assert: guard rejected the call; lifecycle unchanged
        XCTAssertFalse(result, "configureInternal() must return false when already configured")
        XCTAssertEqual(appactor.paymentLifecycle, .configured,
                       "Lifecycle must remain .configured after double-configure guard fires")
    }

    /// Verifies that calling configure() during reset() (.resetting state) returns false
    /// without crashing. The assertionFailure was removed.
    func testConfigureDuringResetReturnsFalseWithoutCrash() {
        // Arrange: manually set lifecycle to .resetting
        appactor.paymentLifecycle = .resetting

        let config = AppActorPaymentConfiguration(
            apiKey: "pk_test_boot06_resetting",
            baseURL: URL(string: "https://api.test.appactor.com")!
        )

        // Act: call configureInternal() during .resetting — must return false
        let result = appactor.configureInternal(config)

        // Assert: guard rejected the call; lifecycle unchanged
        XCTAssertFalse(result, "configureInternal() must return false during reset()")
        XCTAssertEqual(appactor.paymentLifecycle, .resetting,
                       "Lifecycle must remain .resetting after configure-during-reset guard fires")
    }

    func testBlankAPIKeyValidationFailsBeforeConfigurationMutatesState() {
        let config = AppActorPaymentConfiguration(
            apiKey: "   ",
            baseURL: URL(string: "https://api.test.appactor.com")!
        )
        let validationError = config.validationError

        XCTAssertEqual(validationError?.kind, .validation,
                       "Blank apiKey values must fail canonical validation before configuration begins")
        XCTAssertEqual(validationError?.errorDescription, "[AppActor] Validation: apiKey must not be blank.")
        XCTAssertEqual(appactor.paymentLifecycle, .idle,
                       "Reading validation errors must not mutate SDK lifecycle state")
        XCTAssertNil(AppActorBridge.shared.appUserId,
                     "Bridge must not expose an appUserId before a valid configure() succeeds")
        XCTAssertNil(appactor.paymentStorage,
                     "Validation checks must not leave partially initialized storage behind")
    }

    // MARK: - BOOT-07: Cancelled bootstrap cleans up watcher and processor

    /// Verifies that after reset(), the transaction watcher and payment processor
    /// are nil — proving the cleanup path exercises the stop() teardown.
    /// This is the observable postcondition of the BOOT-07 fix.
    func testResetPaymentCleansUpWatcherAndProcessor() async {
        // Arrange: configure without running startup (instance method)
        let config = AppActorPaymentConfiguration(
            apiKey: "pk_test_boot07_reset",
            baseURL: URL(string: "https://api.test.appactor.com")!
        )
        appactor.configureForTesting(config: config, client: mockClient, storage: storage)

        // Verify setup: watcher and processor should be non-nil after configure
        XCTAssertNotNil(appactor.transactionWatcher, "transactionWatcher should be set after configure")
        XCTAssertNotNil(appactor.paymentProcessor, "paymentProcessor should be set after configure")
        XCTAssertEqual(appactor.paymentLifecycle, .configured)

        // Act: reset payment
        await appactor.reset()

        // Assert: watcher and processor must be nil after reset
        XCTAssertNil(appactor.transactionWatcher,
                     "transactionWatcher must be nil after reset()")
        XCTAssertNil(appactor.paymentProcessor,
                     "paymentProcessor must be nil after reset()")
        XCTAssertEqual(appactor.paymentLifecycle, .idle,
                       "Lifecycle must be .idle after reset()")
    }

    /// Verifies that when a bootstrap Task is cancelled mid-flight, the lifecycle reverts to
    /// .idle and the watcher/processor are nil (BOOT-07 fix: revertLifecycleIfCancelled is async).
    ///
    /// Strategy: block the awaited customer refresh step, cancel the outer bootstrap task,
    /// then release the mocked fetch so startup can observe cancellation and run cleanup.
    func testCancelledBootstrapRevertsLifecycleAndCleansUpActors() async throws {
        let customerRefreshStarted = AsyncSignal()
        let releaseCustomerRefresh = AsyncSignal()
        mockClient.getCustomerHandler = { _, _ in
            await customerRefreshStarted.signal()
            await releaseCustomerRefresh.wait()
            return .fresh(
                AppActorCustomerInfo(appUserId: self.storage.currentAppUserId ?? "appactor-anon-cancelled"),
                eTag: nil,
                requestId: "req_boot07_cancel",
                signatureVerified: false
            )
        }

        let config = AppActorPaymentConfiguration(
            apiKey: "pk_test_boot07_cancel",
            baseURL: URL(string: "https://api.test.appactor.com")!
        )
        appactor.configureForTesting(config: config, client: mockClient, storage: storage)
        appactor.isBootstrapComplete = false

        let startupTask = Task.detached { @MainActor [weak self] in
            guard let self else { return }
            await self.appactor.runStartupSequence()
        }

        await customerRefreshStarted.wait()
        startupTask.cancel()
        await releaseCustomerRefresh.signal()
        await startupTask.value

        // Assert: lifecycle reverted to .idle and actors cleaned up
        XCTAssertEqual(appactor.paymentLifecycle, .idle,
                       "Lifecycle must be .idle after cancelled bootstrap (BOOT-07 fix)")
        XCTAssertNil(AppActorBridge.shared.appUserId)
        XCTAssertNotNil(appactor.paymentStorage,
                        "Cancelled bootstrap should preserve storage so configure() can retry with the same identity")
        XCTAssertNil(appactor.transactionWatcher,
                     "transactionWatcher must be nil after cancelled bootstrap (BOOT-07 fix)")
        XCTAssertNil(appactor.paymentProcessor,
                     "paymentProcessor must be nil after cancelled bootstrap (BOOT-07 fix)")
        XCTAssertFalse(appactor.isBootstrapComplete,
                       "Bootstrap completion flag must reset after cancelled startup")
    }

    // MARK: - E8a: a configure() while a cancelled startup is still in flight

    /// A SwiftUI `.task(id:)` restarted by an id change: the new configure() may arrive before
    /// the old task is cancelled (SwiftUI doesn't document the order). It must not be dropped as
    /// "already configured" and then lost when the old startup reverts to idle.
    func testConfigureDuringACancelledStartupConfiguresOnceTheStartupReverts() async throws {
        let firstClient = MockPaymentClient()
        let customerFetchStarted = expectation(description: "the first startup's customer fetch sent")
        customerFetchStarted.assertForOverFulfill = false
        firstClient.getCustomerHandler = { appUserId, _ in
            customerFetchStarted.fulfill()
            try await Task.sleep(nanoseconds: 20_000_000_000) // a stalled network
            return .fresh(AppActorCustomerInfo(appUserId: appUserId), eTag: nil, requestId: nil, signatureVerified: false)
        }
        let baseURL = URL(string: "https://api.test.appactor.com")!
        let first = AppActorPaymentConfiguration(apiKey: "pk_test_e8a_first", baseURL: baseURL)
        let second = AppActorPaymentConfiguration(apiKey: "pk_test_e8a_second", baseURL: baseURL)

        let firstStartup = Task { await self.appactor.configureAndStart(first, testClient: firstClient) }
        await fulfillment(of: [customerFetchStarted], timeout: 5)
        let secondStartup = Task { await self.appactor.configureAndStart(second, testClient: self.mockClient) }
        var yields = 0
        while appactor.paymentContext.startupWaiters.isEmpty, yields < 1_000 {
            await Task.yield()
            yields += 1
        }
        XCTAssertFalse(appactor.paymentContext.startupWaiters.isEmpty, "The second configure() waits for the first startup")

        // Timed, so a regression fails the test instead of hanging the suite.
        let bothReturned = expectation(description: "both configure() calls returned")
        Task {
            await firstStartup.value
            await secondStartup.value
            bothReturned.fulfill()
        }
        firstStartup.cancel()
        await fulfillment(of: [bothReturned], timeout: 5)

        XCTAssertEqual(appactor.paymentLifecycle, .configured)
        XCTAssertTrue(appactor.isBootstrapComplete)
        XCTAssertEqual(appactor.paymentConfig?.apiKey, "pk_test_e8a_second")
        await appactor.reset()
    }

    // MARK: - E8b: reset() doesn't wait out a stalled fetch

    func testResetCancelsStalledManagerFetchesInsteadOfWaitingForThem() async throws {
        let customerFetchStarted = expectation(description: "customer fetch sent")
        customerFetchStarted.assertForOverFulfill = false
        let offeringsFetchStarted = expectation(description: "offerings fetch sent")
        offeringsFetchStarted.assertForOverFulfill = false
        mockClient.getCustomerHandler = { appUserId, _ in
            customerFetchStarted.fulfill()
            try await Task.sleep(nanoseconds: 20_000_000_000)
            return .fresh(AppActorCustomerInfo(appUserId: appUserId), eTag: nil, requestId: nil, signatureVerified: false)
        }
        mockClient.getOfferingsHandler = { _ in
            offeringsFetchStarted.fulfill()
            try await Task.sleep(nanoseconds: 20_000_000_000)
            return .fresh(AppActorOfferingsResponseDTO(currentOffering: nil, offerings: []), eTag: nil, requestId: nil, signatureVerified: false)
        }
        appactor.configureForTesting(
            config: AppActorPaymentConfiguration(apiKey: "pk_test_e8b", baseURL: URL(string: "https://api.test.appactor.com")!),
            client: mockClient,
            storage: storage
        )
        // What a foreground refresh and the launch prefetch leave in flight.
        appactor.foregroundTask = Task { _ = try? await self.appactor.getCustomerInfo() }
        let offeringsManager = try XCTUnwrap(appactor.offeringsManager)
        appactor.offeringsPrefetchTask = Task { await offeringsManager.prefetchForBootstrap() }
        await fulfillment(of: [customerFetchStarted, offeringsFetchStarted], timeout: 5)

        let start = Date()
        await appactor.reset()

        XCTAssertLessThan(Date().timeIntervalSince(start), 5, "reset() must not wait out the fetches' network cycle")
        XCTAssertEqual(appactor.paymentLifecycle, .idle)
    }

    // MARK: - BOOT-04: logIn() drains receipt queue before cache clear

    /// Verifies that logIn() completes successfully when a processor exists.
    /// The drain happens before cache clearing — this test confirms the overall
    /// logIn flow works correctly with the BOOT-04 fix in place.
    func testLoginCompletesSuccessfullyWithDrainFix() async throws {
        // Arrange: configure with instance method (no startup, no pending receipts)
        let config = AppActorPaymentConfiguration(
            apiKey: "pk_test_boot04",
            baseURL: URL(string: "https://api.test.appactor.com")!
        )
        appactor.configureForTesting(config: config, client: mockClient, storage: storage)
        storage.setAppUserId("anon-user-001")

        // Act: call logIn() — drainAll() runs on the empty processor, then cache is cleared
        let customerInfo = try await appactor.logIn(newAppUserId: "logged-in-user-001")

        // Assert: login succeeded and identity was updated
        XCTAssertEqual(customerInfo.appUserId, "logged-in-user-001",
                       "logIn() must return customer info for the new user ID")
        XCTAssertEqual(mockClient.loginCalls.count, 1,
                       "login() should be called exactly once on the client")
        XCTAssertEqual(storage.currentAppUserId, "logged-in-user-001",
                       "Storage must be updated to the new app user ID after logIn()")
    }

    // MARK: - BOOT-05: logOut() drains receipt queue before cache clear

    /// Verifies that logOut() completes successfully when a processor exists.
    /// The drain runs before the new anonymous identity is generated — this test
    /// confirms the overall logOut flow works correctly with the BOOT-05 fix in place.
    func testLogoutCompletesSuccessfullyWithDrainFix() async throws {
        // Arrange: configure with instance method (no startup, no pending receipts)
        let config = AppActorPaymentConfiguration(
            apiKey: "pk_test_boot05",
            baseURL: URL(string: "https://api.test.appactor.com")!
        )
        appactor.configureForTesting(config: config, client: mockClient, storage: storage)
        storage.setAppUserId("authenticated-user-001")

        // Act: call logOut() — drainAll() runs on the empty processor, then caches are cleared
        let logoutSucceeded = try await appactor.logOut()

        // Assert: logout succeeded and a new anonymous identity was generated
        XCTAssertTrue(logoutSucceeded, "Local logout should still return true")
        let newUserId = storage.currentAppUserId
        XCTAssertNotNil(newUserId, "A new anonymous user ID must be generated after logout")
        XCTAssertTrue(newUserId?.hasPrefix("appactor-anon-") ?? false,
                      "Post-logout user ID must be anonymous (BOOT-05 fix)")
        XCTAssertEqual(mockClient.identifyCalls.count, 0,
                       "RC-style logout should not re-identify")
    }
}
