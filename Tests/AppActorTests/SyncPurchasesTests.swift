import XCTest
@testable import AppActor

@MainActor
final class SyncPurchasesTests: XCTestCase {

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
        appactor.storeKitSilentSyncFetcher = nil
        appactor.paymentLifecycle = .idle
        super.tearDown()
    }

    func testDrainReceiptQueueAndRefreshCustomerPreservesOldBehavior() async throws {
        let expectedUserId = storage.ensureAppUserId()
        mockClient.getCustomerHandler = { appUserId, _ in
            XCTAssertEqual(appUserId, expectedUserId)
            return .fresh(
                AppActorCustomerInfo(appUserId: appUserId),
                eTag: nil,
                requestId: "req_drain",
                signatureVerified: false
            )
        }

        appactor.configureForTesting(
            config: AppActorPaymentConfiguration(
                apiKey: "pk_test_drain",
                baseURL: URL(string: "https://api.test.appactor.com")!
            ),
            client: mockClient,
            storage: storage
        )

        let info = try await appactor.drainReceiptQueueAndRefreshCustomer()

        XCTAssertEqual(mockClient.postReceiptCalls.count, 0)
        XCTAssertEqual(mockClient.getCustomerCalls.count, 1)
        XCTAssertEqual(info.appUserId, expectedUserId)
    }

    func testSyncPurchasesPostsFirstVerifiedTransaction() async throws {
        let expectedUserId = storage.ensureAppUserId()
        let fetcher = MockStoreKitSilentSyncFetcher(
            firstVerifiedTransactionHandler: {
                AppActorSilentSyncTransaction(
                    transactionId: "tx_123",
                    originalTransactionId: "orig_123",
                    productId: "premium_lifetime",
                    bundleId: "com.appactor.test",
                    environment: "production",
                    storefront: "TUR",
                    jwsRepresentation: "signed-jws"
                )
            },
            appTransactionHandler: {
                AppActorSilentSyncAppTransaction(
                    bundleId: "com.appactor.test",
                    environment: "production",
                    jwsRepresentation: "app-transaction-jws"
                )
            }
        )

        mockClient.postReceiptHandler = { request in
            XCTAssertEqual(request.appUserId, expectedUserId)
            XCTAssertEqual(request.transactionId, "tx_123")
            XCTAssertEqual(request.productId, "premium_lifetime")
            XCTAssertEqual(request.signedTransactionInfo, "signed-jws")
            XCTAssertEqual(request.signedAppTransactionInfo, "app-transaction-jws")
            XCTAssertEqual(request.idempotencyKey, "apple:tx_123")
            return AppActorReceiptPostResponse(
                status: "ok",
                customer: AppActorCustomerDTO(
                    entitlements: [
                        "premium": AppActorEntitlementDTO(
                            isActive: true,
                            productId: "premium_lifetime"
                        )
                    ]
                ),
                requestId: "req_sync",
                signatureVerified: true
            )
        }

        appactor.configureForTesting(
            config: AppActorPaymentConfiguration(
                apiKey: "pk_test_sync",
                baseURL: URL(string: "https://api.test.appactor.com")!
            ),
            client: mockClient,
            storage: storage,
            silentSyncFetcher: fetcher
        )

        let info = try await appactor.syncPurchases()

        XCTAssertEqual(mockClient.postReceiptCalls.count, 1)
        XCTAssertEqual(mockClient.getCustomerCalls.count, 0)
        XCTAssertEqual(info.appUserId, expectedUserId)
        XCTAssertEqual(info.entitlements["premium"]?.isActive, true)
        XCTAssertEqual(info.verification, .verified)
        XCTAssertEqual(appactor.customerInfo.entitlements["premium"]?.isActive, true)
        XCTAssertEqual(appactor.customerInfo.verification, .verified)
    }

    func testSyncPurchasesFallsBackToAppTransactionWhenNoVerifiedTransactionExists() async throws {
        let expectedUserId = storage.ensureAppUserId()
        let fetcher = MockStoreKitSilentSyncFetcher(
            firstVerifiedTransactionHandler: { nil },
            appTransactionHandler: {
                AppActorSilentSyncAppTransaction(
                    bundleId: "com.appactor.test",
                    environment: "sandbox",
                    jwsRepresentation: "app-transaction-jws"
                )
            }
        )

        mockClient.postReceiptHandler = { request in
            XCTAssertEqual(request.appUserId, expectedUserId)
            XCTAssertEqual(request.bundleId, "com.appactor.test")
            XCTAssertEqual(request.environment, "sandbox")
            XCTAssertNil(request.signedTransactionInfo)
            XCTAssertEqual(request.signedAppTransactionInfo, "app-transaction-jws")
            XCTAssertNil(request.transactionId)
            return AppActorReceiptPostResponse(
                status: "ok",
                customer: AppActorCustomerDTO(
                    entitlements: [
                        "premium": AppActorEntitlementDTO(
                            isActive: true,
                            productId: "premium_lifetime"
                        )
                    ]
                ),
                requestId: "req_app_transaction"
            )
        }

        appactor.configureForTesting(
            config: AppActorPaymentConfiguration(
                apiKey: "pk_test_sync_fallback",
                baseURL: URL(string: "https://api.test.appactor.com")!
            ),
            client: mockClient,
            storage: storage,
            silentSyncFetcher: fetcher
        )

        let info = try await appactor.syncPurchases()

        XCTAssertEqual(mockClient.postReceiptCalls.count, 1)
        XCTAssertEqual(mockClient.getCustomerCalls.count, 0)
        XCTAssertEqual(info.entitlements["premium"]?.isActive, true)
        XCTAssertEqual(info.appUserId, expectedUserId)
    }

    func testSyncPurchasesReturnsSufficientCachedCustomerWhenNoStoreSyncCandidateExists() async throws {
        let expectedUserId = storage.ensureAppUserId()
        let etagManager = AppActorETagManager()
        let customerManager = AppActorCustomerManager(
            client: mockClient,
            etagManager: etagManager
        )
        let cachedInfo = AppActorCustomerInfo(
            entitlements: [:],
            subscriptions: [:],
            nonSubscriptions: [:],
            appUserId: expectedUserId,
            requestDate: "2026-04-15T10:00:00Z",
            firstSeen: "2026-04-14T10:00:00Z",
            lastSeen: "2026-04-15T10:00:00Z"
        )
        await customerManager.seedCache(info: cachedInfo, eTag: "etag_cached", appUserId: expectedUserId)

        let fetcher = MockStoreKitSilentSyncFetcher(
            firstVerifiedTransactionHandler: { nil },
            appTransactionHandler: { nil }
        )

        appactor.configureForTesting(
            config: AppActorPaymentConfiguration(
                apiKey: "pk_test_sync_cached_customer",
                baseURL: URL(string: "https://api.test.appactor.com")!
            ),
            client: mockClient,
            storage: storage,
            etagManager: etagManager,
            customerManager: customerManager,
            silentSyncFetcher: fetcher
        )

        let info = try await appactor.syncPurchases()

        XCTAssertEqual(mockClient.postReceiptCalls.count, 0)
        XCTAssertEqual(mockClient.getCustomerCalls.count, 0)
        XCTAssertEqual(info, cachedInfo)
        XCTAssertEqual(appactor.customerInfo, cachedInfo)
    }

    func testSyncPurchasesPrefersAppTransactionFallbackOverCachedCustomer() async throws {
        let expectedUserId = storage.ensureAppUserId()
        let etagManager = AppActorETagManager()
        let customerManager = AppActorCustomerManager(
            client: mockClient,
            etagManager: etagManager
        )
        let cachedInfo = AppActorCustomerInfo(
            entitlements: [:],
            subscriptions: [:],
            nonSubscriptions: [:],
            appUserId: expectedUserId,
            requestDate: "2026-04-15T10:00:00Z",
            firstSeen: "2026-04-14T10:00:00Z",
            lastSeen: "2026-04-15T10:00:00Z"
        )
        await customerManager.seedCache(info: cachedInfo, eTag: "etag_cached", appUserId: expectedUserId)

        let fetcher = MockStoreKitSilentSyncFetcher(
            firstVerifiedTransactionHandler: { nil },
            appTransactionHandler: {
                AppActorSilentSyncAppTransaction(
                    bundleId: "com.appactor.test",
                    environment: "sandbox",
                    jwsRepresentation: "app-transaction-jws"
                )
            }
        )
        mockClient.postReceiptHandler = { request in
            XCTAssertEqual(request.appUserId, expectedUserId)
            XCTAssertEqual(request.bundleId, "com.appactor.test")
            XCTAssertNil(request.signedTransactionInfo)
            XCTAssertEqual(request.signedAppTransactionInfo, "app-transaction-jws")
            return AppActorReceiptPostResponse(
                status: "ok",
                customer: AppActorCustomerDTO(entitlements: [:]),
                requestId: "req_sync_app_transaction"
            )
        }

        appactor.configureForTesting(
            config: AppActorPaymentConfiguration(
                apiKey: "pk_test_sync_cached_over_app_transaction",
                baseURL: URL(string: "https://api.test.appactor.com")!
            ),
            client: mockClient,
            storage: storage,
            etagManager: etagManager,
            customerManager: customerManager,
            silentSyncFetcher: fetcher
        )

        let info = try await appactor.syncPurchases()

        XCTAssertEqual(mockClient.postReceiptCalls.count, 1)
        XCTAssertEqual(mockClient.getCustomerCalls.count, 0)
        XCTAssertEqual(info.appUserId, expectedUserId)
        XCTAssertNil(info.requestDate)
        XCTAssertEqual(appactor.customerInfo.appUserId, expectedUserId)
        XCTAssertNil(appactor.customerInfo.requestDate)
    }

    func testSyncPurchasesFallsBackToCustomerFetchWhenNoStoreSyncCandidateExists() async throws {
        let expectedUserId = storage.ensureAppUserId()
        let fetcher = MockStoreKitSilentSyncFetcher(
            firstVerifiedTransactionHandler: { nil },
            appTransactionHandler: { nil }
        )

        mockClient.getCustomerHandler = { appUserId, _ in
            XCTAssertEqual(appUserId, expectedUserId)
            return .fresh(
                AppActorCustomerInfo(appUserId: appUserId),
                eTag: nil,
                requestId: "req_customer_fallback",
                signatureVerified: false
            )
        }

        appactor.configureForTesting(
            config: AppActorPaymentConfiguration(
                apiKey: "pk_test_sync_customer_fallback",
                baseURL: URL(string: "https://api.test.appactor.com")!
            ),
            client: mockClient,
            storage: storage,
            silentSyncFetcher: fetcher
        )

        let info = try await appactor.syncPurchases()

        XCTAssertEqual(mockClient.postReceiptCalls.count, 0)
        XCTAssertEqual(mockClient.getCustomerCalls.count, 1)
        XCTAssertEqual(info.appUserId, expectedUserId)
    }

    func testSyncPurchasesMapsRetryableStoreSyncToTransientServerError() async throws {
        let fetcher = MockStoreKitSilentSyncFetcher(
            firstVerifiedTransactionHandler: {
                AppActorSilentSyncTransaction(
                    transactionId: "tx_retry",
                    originalTransactionId: nil,
                    productId: "premium_monthly",
                    bundleId: "com.appactor.test",
                    environment: "production",
                    storefront: nil,
                    jwsRepresentation: "signed-jws"
                )
            },
            appTransactionHandler: { nil }
        )

        mockClient.postReceiptHandler = { _ in
            AppActorReceiptPostResponse(
                status: "retryable_error",
                error: AppActorReceiptErrorInfo(code: "TEMPORARY_BACKEND_FAILURE", message: "try later"),
                retryAfterSeconds: 12,
                requestId: "req_retry"
            )
        }

        appactor.configureForTesting(
            config: AppActorPaymentConfiguration(
                apiKey: "pk_test_sync_retry",
                baseURL: URL(string: "https://api.test.appactor.com")!
            ),
            client: mockClient,
            storage: storage,
            silentSyncFetcher: fetcher
        )

        do {
            _ = try await appactor.syncPurchases()
            XCTFail("Expected syncPurchases() to throw")
        } catch let error as AppActorError {
            XCTAssertEqual(error.kind, .server)
            XCTAssertEqual(error.httpStatus, 503)
            XCTAssertEqual(error.retryAfterSeconds, 12)
            XCTAssertTrue(error.isTransient)
        }
    }

    func testBridgeSyncPurchasesPreservesOldQueueDrainBehavior() async throws {
        let expectedUserId = storage.ensureAppUserId()
        mockClient.getCustomerHandler = { appUserId, _ in
            XCTAssertEqual(appUserId, expectedUserId)
            return .fresh(
                AppActorCustomerInfo(appUserId: appUserId),
                eTag: nil,
                requestId: "req_bridge_drain",
                signatureVerified: false
            )
        }

        appactor.configureForTesting(
            config: AppActorPaymentConfiguration(
                apiKey: "pk_test_bridge_drain",
                baseURL: URL(string: "https://api.test.appactor.com")!
            ),
            client: mockClient,
            storage: storage
        )

        let expectation = expectation(description: "bridge sync succeeds")
        AppActorBridge.shared.syncPurchases(onSuccess: { info in
            XCTAssertEqual(info.appUserId, expectedUserId)
            expectation.fulfill()
        }, onError: { error in
            XCTFail("Unexpected bridge error: \(error.message)")
        })

        await fulfillment(of: [expectation], timeout: 2.0)
        XCTAssertEqual(mockClient.postReceiptCalls.count, 0)
        XCTAssertEqual(mockClient.getCustomerCalls.count, 1)
    }

    func testBridgeQuietSyncPurchasesUsesQuietStoreSyncPath() async throws {
        let fetcher = MockStoreKitSilentSyncFetcher(
            firstVerifiedTransactionHandler: {
                AppActorSilentSyncTransaction(
                    transactionId: "tx_bridge_quiet",
                    originalTransactionId: nil,
                    productId: "premium_yearly",
                    bundleId: "com.appactor.test",
                    environment: "production",
                    storefront: nil,
                    jwsRepresentation: "signed-jws"
                )
            },
            appTransactionHandler: { nil }
        )

        mockClient.postReceiptHandler = { _ in
            AppActorReceiptPostResponse(
                status: "ok",
                customer: AppActorCustomerDTO(entitlements: [:]),
                requestId: "req_bridge_quiet"
            )
        }

        appactor.configureForTesting(
            config: AppActorPaymentConfiguration(
                apiKey: "pk_test_bridge_quiet",
                baseURL: URL(string: "https://api.test.appactor.com")!
            ),
            client: mockClient,
            storage: storage,
            silentSyncFetcher: fetcher
        )

        let expectation = expectation(description: "bridge quiet sync succeeds")
        AppActorBridge.shared.quietSyncPurchases(onSuccess: { _ in
            expectation.fulfill()
        }, onError: { error in
            XCTFail("Unexpected bridge error: \(error.message)")
        })

        await fulfillment(of: [expectation], timeout: 2.0)
        XCTAssertEqual(mockClient.postReceiptCalls.count, 1)
    }
}
