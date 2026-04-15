import XCTest
@testable import AppActor

@MainActor
final class RestorePurchasesTests: XCTestCase {

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
        appactor.onCustomerInfoChanged = nil
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

    // MARK: - Not Configured

    func testRestorePurchasesThrowsWhenNotConfigured() async {
        // AppActor is idle — restorePurchases should throw notConfigured
        do {
            _ = try await appactor.restorePurchases()
            XCTFail("Expected AppActorError.notConfigured")
        } catch let error as AppActorError {
            XCTAssertEqual(error.kind, .notConfigured)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    // MARK: - Empty Transactions

    func testRestorePurchasesWithNoTransactionsSkipsBulkRestore() async throws {
        // In a unit test environment, Transaction.currentEntitlements is empty,
        // so collectCurrentEntitlements returns []. The method should skip
        // the bulk restore call and just fetch customer info.
        let config = AppActorPaymentConfiguration(
            apiKey: "pk_test_restore",
            baseURL: URL(string: "https://api.test.appactor.com")!
        )
        appactor.configureForTesting(config: config, client: mockClient, storage: storage)

        let info = try await appactor.restorePurchases()

        // No postRestore call should have been made
        XCTAssertEqual(mockClient.postRestoreCalls.count, 0,
                       "Should not call postRestore when there are no transactions")

        // getCustomer should have been called (via getCustomerInfo)
        XCTAssertEqual(mockClient.getCustomerCalls.count, 1,
                       "Should fetch fresh customer info")

        XCTAssertNotNil(info.appUserId)
    }

    func testRestorePurchasesWithNoTransactionsPostsAppTransactionFallback() async throws {
        let config = AppActorPaymentConfiguration(
            apiKey: "pk_test_restore_app_transaction",
            baseURL: URL(string: "https://api.test.appactor.com")!
        )
        let fetcher = MockStoreKitSilentSyncFetcher(
            firstVerifiedTransactionHandler: nil,
            appTransactionHandler: {
                AppActorSilentSyncAppTransaction(
                    bundleId: "com.test.app",
                    environment: "sandbox",
                    jwsRepresentation: "app-transaction-jws"
                )
            }
        )
        let expected = AppActorCustomerInfo(appUserId: storage.ensureAppUserId())
        mockClient.postRestoreHandler = { request in
            XCTAssertEqual(request.transactions.count, 0)
            XCTAssertEqual(request.signedAppTransactionInfo, "app-transaction-jws")
            return AppActorRestoreResult(
                customerInfo: expected,
                restoredCount: 0,
                transferred: false,
                requestId: "req_restore_app_transaction",
                customerETag: nil,
                signatureVerified: true
            )
        }
        appactor.configureForTesting(
            config: config,
            client: mockClient,
            storage: storage,
            silentSyncFetcher: fetcher
        )

        let info = try await appactor.restorePurchases()

        XCTAssertEqual(info.appUserId, expected.appUserId)
        XCTAssertEqual(mockClient.postRestoreCalls.count, 1)
    }

    func testOnCustomerInfoChangedFiresWhenCustomerInfoRefreshes() async throws {
        let config = AppActorPaymentConfiguration(
            apiKey: "pk_test_callback",
            baseURL: URL(string: "https://api.test.appactor.com")!
        )
        let expected = AppActorCustomerInfo(
            appUserId: "callback_user",
            requestDate: "2026-03-15T00:00:00Z"
        )
        mockClient.getCustomerHandler = { _, _ in
            .fresh(expected, eTag: "etag_callback", requestId: "req_callback", signatureVerified: false)
        }
        appactor.configureForTesting(config: config, client: mockClient, storage: storage)

        let callbackExpectation = expectation(description: "onCustomerInfoChanged fired")
        var captured: AppActorCustomerInfo?
        appactor.onCustomerInfoChanged = { info in
            captured = info
            callbackExpectation.fulfill()
        }

        let info = try await appactor.getCustomerInfo()

        await fulfillment(of: [callbackExpectation], timeout: 1.0)
        XCTAssertEqual(info, expected)
        XCTAssertEqual(captured, expected)
    }

    func testResolveRestoreCustomerInfoForceRefreshesWhenOverflowExists() async throws {
        let config = AppActorPaymentConfiguration(
            apiKey: "pk_test_restore_overflow",
            baseURL: URL(string: "https://api.test.appactor.com")!
        )
        let stale = AppActorCustomerInfo(
            appUserId: "restore_user",
            requestDate: "stale"
        )
        let fresh = AppActorCustomerInfo(
            appUserId: "restore_user",
            requestDate: "fresh"
        )
        mockClient.getCustomerHandler = { appUserId, eTag in
            XCTAssertEqual(appUserId, "restore_user")
            XCTAssertNil(eTag, "Overflow reconciliation should force a fresh fetch")
            return .fresh(fresh, eTag: "etag_fresh", requestId: "req_fresh", signatureVerified: false)
        }
        appactor.configureForTesting(config: config, client: mockClient, storage: storage)

        guard let customerManager = appactor.customerManager else {
            return XCTFail("Customer manager should be configured for testing")
        }

        let bulkResult = AppActorRestoreResult(
            customerInfo: stale,
            restoredCount: 500,
            transferred: false,
            requestId: "req_bulk",
            customerETag: "etag_bulk",
            signatureVerified: false
        )

        let resolved = try await appactor.resolveRestoreCustomerInfo(
            from: bulkResult,
            appUserId: "restore_user",
            hasOverflow: true,
            customerManager: customerManager
        )

        XCTAssertEqual(resolved, fresh)
        XCTAssertEqual(mockClient.getCustomerCalls.count, 1)
    }

    // MARK: - Published State Update

    func testRestorePurchasesUpdatesPublishedCustomerInfo() async throws {
        let expected = AppActorCustomerInfo(
            appUserId: "restore_published",
            requestDate: "2026-04-01T00:00:00Z"
        )
        mockClient.getCustomerHandler = { _, _ in
            .fresh(expected, eTag: "etag_pub", requestId: "req_pub", signatureVerified: false)
        }
        let config = AppActorPaymentConfiguration(
            apiKey: "pk_test_restore_publish",
            baseURL: URL(string: "https://api.test.appactor.com")!
        )
        appactor.configureForTesting(config: config, client: mockClient, storage: storage)

        let info = try await appactor.restorePurchases()

        XCTAssertEqual(info, expected)
        XCTAssertEqual(appactor.customerInfo, expected,
                       "restorePurchases must update the @Published customerInfo property")
    }

    // MARK: - Error Propagation

    func testRestorePurchasesPropagatesNetworkError() async {
        mockClient.getCustomerHandler = { _, _ in
            throw AppActorError.networkError(URLError(.notConnectedToInternet))
        }
        let config = AppActorPaymentConfiguration(
            apiKey: "pk_test_restore_error",
            baseURL: URL(string: "https://api.test.appactor.com")!
        )
        appactor.configureForTesting(config: config, client: mockClient, storage: storage)

        do {
            _ = try await appactor.restorePurchases()
            XCTFail("Expected network error to propagate")
        } catch let error as AppActorError {
            XCTAssertEqual(error.kind, .network,
                           "Network errors during restore must propagate to the caller")
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    // MARK: - Resolve Restore (No Overflow)

    func testResolveRestoreCustomerInfoReturnsBulkResultWhenNoOverflow() async throws {
        let config = AppActorPaymentConfiguration(
            apiKey: "pk_test_no_overflow",
            baseURL: URL(string: "https://api.test.appactor.com")!
        )
        appactor.configureForTesting(config: config, client: mockClient, storage: storage)

        guard let customerManager = appactor.customerManager else {
            return XCTFail("Customer manager should be configured for testing")
        }

        let bulkInfo = AppActorCustomerInfo(
            appUserId: "no_overflow_user",
            requestDate: "bulk_date"
        )
        let bulkResult = AppActorRestoreResult(
            customerInfo: bulkInfo,
            restoredCount: 3,
            transferred: false,
            requestId: "req_no_overflow",
            customerETag: "etag_no_overflow",
            signatureVerified: false
        )

        let resolved = try await appactor.resolveRestoreCustomerInfo(
            from: bulkResult,
            appUserId: "no_overflow_user",
            hasOverflow: false,
            customerManager: customerManager
        )

        XCTAssertEqual(resolved, bulkInfo,
                       "No overflow should return the bulk result directly without an extra fetch")
        XCTAssertEqual(mockClient.getCustomerCalls.count, 0,
                       "No overflow should skip the extra getCustomer call")
    }

    // MARK: - Bulk Restore DTO Encoding

    func testRestoreRequestEncoding() throws {
        let request = AppActorRestoreRequest(
            appUserId: "user_123",
            transactions: [
                AppActorRestoreTransactionItem(transactionId: "100", jwsRepresentation: "jws_a"),
                AppActorRestoreTransactionItem(transactionId: "200", jwsRepresentation: "jws_b"),
            ],
            signedAppTransactionInfo: "app-transaction-jws"
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(request)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertEqual(json["appUserId"] as? String, "user_123")
        XCTAssertEqual(json["signedAppTransactionInfo"] as? String, "app-transaction-jws")
        let txns = json["transactions"] as? [[String: Any]]
        XCTAssertEqual(txns?.count, 2)
        XCTAssertEqual(txns?[0]["transactionId"] as? String, "100")
        XCTAssertEqual(txns?[0]["jwsRepresentation"] as? String, "jws_a")
        XCTAssertEqual(txns?[1]["transactionId"] as? String, "200")
    }

    // MARK: - Restore Response Decoding

    func testRestoreResponseDecoding() throws {
        let json = """
        {
            "data": {
                "user": {
                    "entitlements": {
                        "premium": {
                            "isActive": true,
                            "productId": "com.app.premium.monthly"
                        }
                    },
                    "subscriptions": {},
                    "nonSubscriptions": {}
                },
                "restoredCount": 2,
                "transferred": false
            },
            "requestId": "req_abc"
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        let envelope = try decoder.decode(
            AppActorPaymentResponse<AppActorRestoreResponseData>.self,
            from: json
        )

        XCTAssertEqual(envelope.data.restoredCount, 2)
        XCTAssertFalse(envelope.data.transferred)
        XCTAssertEqual(envelope.requestId, "req_abc")
        XCTAssertNotNil(envelope.data.user.entitlements?["premium"])
        XCTAssertEqual(envelope.data.user.entitlements?["premium"]?.isActive, true)
    }

    // MARK: - Mock Default Behavior

    func testMockPostRestoreDefaultReturnsCorrectCount() async throws {
        let request = AppActorRestoreRequest(
            appUserId: "user_456",
            transactions: [
                AppActorRestoreTransactionItem(transactionId: "1", jwsRepresentation: "jws1"),
                AppActorRestoreTransactionItem(transactionId: "2", jwsRepresentation: "jws2"),
                AppActorRestoreTransactionItem(transactionId: "3", jwsRepresentation: "jws3"),
            ],
            signedAppTransactionInfo: "app-transaction-jws"
        )

        let result = try await mockClient.postRestore(request)

        XCTAssertEqual(result.restoredCount, 3)
        XCTAssertFalse(result.transferred)
        XCTAssertEqual(result.customerInfo.appUserId, "user_456")
        XCTAssertEqual(mockClient.postRestoreCalls.count, 1)
        XCTAssertEqual(mockClient.postRestoreCalls[0].transactions.count, 3)
        XCTAssertEqual(mockClient.postRestoreCalls[0].signedAppTransactionInfo, "app-transaction-jws")
    }

    // MARK: - Mock Handler Override

    func testMockPostRestoreHandlerOverride() async throws {
        let expectedInfo = AppActorCustomerInfo(appUserId: "restored_user")
        mockClient.postRestoreHandler = { request in
            return AppActorRestoreResult(
                customerInfo: expectedInfo,
                restoredCount: 5,
                transferred: true,
                requestId: "req_custom",
                customerETag: "etag_custom",
                signatureVerified: true
            )
        }

        let request = AppActorRestoreRequest(
            appUserId: "user_789",
            transactions: [
                AppActorRestoreTransactionItem(transactionId: "1", jwsRepresentation: "jws")
            ],
            signedAppTransactionInfo: "app-transaction-jws"
        )
        let result = try await mockClient.postRestore(request)

        XCTAssertEqual(result.restoredCount, 5)
        XCTAssertTrue(result.transferred)
        XCTAssertEqual(result.customerInfo.appUserId, "restored_user")
        XCTAssertEqual(result.requestId, "req_custom")
    }
}
