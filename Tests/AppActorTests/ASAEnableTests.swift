import XCTest
@testable import AppActor

/// Tests for `enableAppleSearchAdsTracking()` guard clauses and lifecycle.

@MainActor
final class ASAEnableTests: XCTestCase {

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
        appactor.asaManager = nil
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
        appactor.isBootstrapComplete = false
        appactor.paymentLifecycle = .idle
        super.tearDown()
    }

    // MARK: - Guard: Not Configured

    func testEnableASAThrowsWhenNotConfigured() {
        XCTAssertEqual(appactor.paymentLifecycle, .idle)

        XCTAssertThrowsError(try appactor.enableAppleSearchAdsTracking()) { error in
            XCTAssertTrue(error is AppActorError)
        }
        XCTAssertNil(appactor.asaManager)
    }

    // MARK: - Guard: Bootstrap Not Complete

    func testEnableASAThrowsWhenBootstrapNotComplete() {
        let config = AppActorPaymentConfiguration(apiKey: "pk_test_asa_boot")
        appactor.configureForTesting(config: config, client: mockClient, storage: storage)
        appactor.isBootstrapComplete = false

        XCTAssertThrowsError(try appactor.enableAppleSearchAdsTracking()) { error in
            XCTAssertTrue(error is AppActorError)
        }
        XCTAssertNil(appactor.asaManager)
    }

    // MARK: - Guard: Already Enabled (Idempotent)

    func testEnableASAIsIdempotent() throws {
        let config = AppActorPaymentConfiguration(apiKey: "pk_test_asa_idem")
        appactor.configureForTesting(config: config, client: mockClient, storage: storage)

        try appactor.enableAppleSearchAdsTracking()
        let firstManager = appactor.asaManager
        XCTAssertNotNil(firstManager)

        // Second call should be no-op
        try appactor.enableAppleSearchAdsTracking()
        XCTAssertTrue(appactor.asaManager === firstManager, "Second call should not create a new manager")
    }

    // MARK: - Happy Path

    func testEnableASACreatesManager() throws {
        let config = AppActorPaymentConfiguration(apiKey: "pk_test_asa_happy")
        appactor.configureForTesting(config: config, client: mockClient, storage: storage)

        XCTAssertNil(appactor.asaManager)

        try appactor.enableAppleSearchAdsTracking()

        XCTAssertNotNil(appactor.asaManager)
        XCTAssertNotNil(appactor.asaTask)
    }

    // MARK: - Options Propagation

    func testEnableASARespectsOptions() throws {
        let config = AppActorPaymentConfiguration(apiKey: "pk_test_asa_opts")
        appactor.configureForTesting(config: config, client: mockClient, storage: storage)

        let options = AppActorASAOptions(
            autoTrackPurchases: false,
            trackInSandbox: true,
            debugMode: true
        )
        try appactor.enableAppleSearchAdsTracking(options: options)

        XCTAssertNotNil(appactor.asaManager)
    }
}
