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
        XCTAssertFalse(AppActorBridge.shared.isConfigured,
                       "Bridge must not report configured before a valid configure() succeeds")
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
    /// Strategy: use a mock client whose identify() suspends indefinitely, give watcher time
    /// to start (which happens before identify in runStartupSequence), then cancel the task.
    func testCancelledBootstrapRevertsLifecycleAndCleansUpActors() async throws {
        // Arrange: mock client that suspends forever in identify()
        let neverIdentify = MockPaymentClient()
        neverIdentify.identifyHandler = { _ in
            try await Task.sleep(nanoseconds: UInt64.max)
            fatalError("unreachable")
        }

        // Act: start the full configure flow in a Task we can cancel
        let configTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let config = AppActorPaymentConfiguration(
                apiKey: "pk_test_boot07_cancel",
                baseURL: URL(string: "https://api.test.appactor.com")!
            )
            self.appactor.configureForTesting(config: config, client: neverIdentify, storage: self.storage)
            await self.appactor.runStartupSequence()
        }

        // Give the startup sequence enough time to start watcher, then reach identify()
        try await Task.sleep(nanoseconds: 100_000_000) // 100ms

        // Cancel the bootstrap Task
        configTask.cancel()
        await configTask.value

        // Assert: lifecycle reverted to .idle and actors cleaned up
        XCTAssertEqual(appactor.paymentLifecycle, .idle,
                       "Lifecycle must be .idle after cancelled bootstrap (BOOT-07 fix)")
        XCTAssertFalse(AppActorBridge.shared.isConfigured,
                       "Bridge must not report configured after cancelled bootstrap")
        XCTAssertNotNil(appactor.paymentStorage,
                        "Cancelled bootstrap should preserve storage so configure() can retry with the same identity")
        XCTAssertNil(appactor.transactionWatcher,
                     "transactionWatcher must be nil after cancelled bootstrap (BOOT-07 fix)")
        XCTAssertNil(appactor.paymentProcessor,
                     "paymentProcessor must be nil after cancelled bootstrap (BOOT-07 fix)")
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
        storage.setServerUserId("server-id-001")

        // Act: call logOut() — drainAll() runs on the empty processor, then caches are cleared
        let serverAcknowledged = try await appactor.logOut()

        // Assert: logout succeeded and a new anonymous identity was generated
        XCTAssertTrue(serverAcknowledged, "Server acknowledged logout should return true")
        let newUserId = storage.currentAppUserId
        XCTAssertNotNil(newUserId, "A new anonymous user ID must be generated after logout")
        XCTAssertTrue(newUserId?.hasPrefix("appactor-anon-") ?? false,
                      "Post-logout user ID must be anonymous (BOOT-05 fix)")
        XCTAssertNil(storage.serverUserId,
                     "Server user ID must be cleared after logout")
        XCTAssertEqual(mockClient.logoutCalls.count, 1,
                       "logout() should be called once on the client")
        // identify() is called after logout to establish new anonymous identity
        XCTAssertEqual(mockClient.identifyCalls.count, 1,
                       "identify() should be called once after logout to establish new anonymous ID")
    }
}
