import XCTest
@testable import AppActor

// MARK: - Retrying Mock (simulates PaymentClient retry behavior without sleeping)

/// A mock client whose `getCustomer` retries on 429, mimicking PaymentClient's
/// internal retry loop. This lets us test that the full pipeline (client retry + manager)
/// succeeds after transient 429s — without changing production code or actually sleeping.
final class RetrySimulatingMockClient: AppActorPaymentClientProtocol, @unchecked Sendable {

    /// Called on each attempt. Throw a 429 PaymentError to trigger retry.
    var handler: ((String, String?) async throws -> AppActorCustomerFetchResult)?
    /// Total handler invocations (including retried ones).
    private(set) var attemptCount = 0
    /// Max retries on 429 before giving up.
    let maxRetries: Int

    init(maxRetries: Int = 3) {
        self.maxRetries = maxRetries
    }

    func identify(_ request: AppActorIdentifyRequest) async throws -> AppActorIdentifyResult {
        AppActorIdentifyResult(
            appUserId: request.appUserId,
            customerInfo: AppActorCustomerInfo(appUserId: request.appUserId),
            customerETag: nil,
            requestId: nil,
            signatureVerified: false
        )
    }
    func login(_ request: AppActorLoginRequest) async throws -> AppActorLoginResult {
        AppActorLoginResult(
            appUserId: request.newAppUserId,
            customerInfo: AppActorCustomerInfo(appUserId: request.newAppUserId),
            customerETag: nil,
            requestId: nil,
            signatureVerified: false
        )
    }
    func logout(_ request: AppActorLogoutRequest) async throws -> AppActorPaymentResult<Bool> {
        AppActorPaymentResult(value: true, requestId: nil)
    }
    func getOfferings(eTag: String?) async throws -> AppActorOfferingsFetchResult {
        .fresh(AppActorOfferingsResponseDTO(currentOffering: nil, offerings: []), eTag: nil, requestId: nil, signatureVerified: false)
    }

    func getCustomer(appUserId: String, eTag: String?) async throws -> AppActorCustomerFetchResult {
        guard let handler else { fatalError("handler not set") }

        for attempt in 0...maxRetries {
            attemptCount += 1
            do {
                return try await handler(appUserId, eTag)
            } catch let error as AppActorError where error.httpStatus == 429 {
                if attempt == maxRetries { throw error }
                // No sleep — keeps the test fast
                continue
            }
        }
        fatalError("unreachable")
    }

    func postReceipt(_ request: AppActorReceiptPostRequest) async throws -> AppActorReceiptPostResponse {
        AppActorReceiptPostResponse(status: "ok", requestId: nil)
    }
    func postRestore(_ request: AppActorRestoreRequest) async throws -> AppActorRestoreResult {
        AppActorRestoreResult(
            customerInfo: AppActorCustomerInfo(appUserId: request.appUserId),
            restoredCount: 0,
            transferred: false,
            requestId: nil,
            customerETag: nil,
            signatureVerified: false
        )
    }
    func getRemoteConfigs(appUserId: String?, appVersion: String?, country: String?, eTag: String?) async throws -> AppActorRemoteConfigFetchResult {
        .fresh([], eTag: nil, requestId: "req_mock_rc", signatureVerified: false)
    }
    func postExperimentAssignment(experimentKey: String, appUserId: String, appVersion: String?, country: String?) async throws -> AppActorExperimentFetchResult { fatalError("stub") }
    func postASAAttribution(_ request: AppActorASAAttributionRequest) async throws -> AppActorASAAttributionResponseDTO { fatalError("stub") }
    func postASAPurchaseEvent(_ request: AppActorASAPurchaseEventRequest) async throws -> AppActorASAPurchaseEventResponseDTO { fatalError("stub") }
}

// MARK: - Helpers

private func makeCustomerInfo(
    appUserId: String = "user_123",
    entitlements: [String: AppActorEntitlementInfo] = [:],
    subscriptions: [String: AppActorSubscriptionInfo] = [:]
) -> AppActorCustomerInfo {
    AppActorCustomerInfo(
        entitlements: entitlements,
        subscriptions: subscriptions,
        snapshotDate: Date(),
        appUserId: appUserId,
        requestDate: "2025-01-01T00:00:00Z"
    )
}

private func makePremiumInfo(appUserId: String = "user_123") -> AppActorCustomerInfo {
    makeCustomerInfo(
        appUserId: appUserId,
        entitlements: [
            "premium": AppActorEntitlementInfo(id: "premium", isActive: true, productID: "com.app.monthly")
        ],
        subscriptions: [
            "com.app.monthly": AppActorSubscriptionInfo(productIdentifier: "com.app.monthly", isActive: true, expiresDate: "2099-12-31T23:59:59Z")
        ]
    )
}

// MARK: - Tests

final class CustomerManagerTests: XCTestCase {

    private var client: MockPaymentClient!
    private var storage: InMemoryPaymentStorage!
    private var etagManager: AppActorETagManager!
    private var skChecker: MockStoreKitEntitlementChecker!
    private var cacheDir: URL!

    override func setUp() {
        super.setUp()
        client = MockPaymentClient()
        storage = InMemoryPaymentStorage()
        skChecker = MockStoreKitEntitlementChecker()

        cacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("appactor_cm_test_\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)

        let diskStore = AppActorCacheDiskStore(directory: cacheDir)
        etagManager = AppActorETagManager(diskStore: diskStore)
    }

    override func tearDown() {
        if let cacheDir {
            try? FileManager.default.removeItem(at: cacheDir)
        }
        client = nil
        storage = nil
        etagManager = nil
        skChecker = nil
        cacheDir = nil
        super.tearDown()
    }

    private func makeManager(
        cacheTTL: TimeInterval = 24 * 60 * 60
    ) -> AppActorCustomerManager {
        AppActorCustomerManager(
            client: client,
            etagManager: etagManager,
            entitlementChecker: skChecker,
            cacheTTL: cacheTTL
        )
    }

    // MARK: - 200 Response -> Caches JSON + ETag

    func testFreshResponseCachesData() async throws {
        let premium = makePremiumInfo()
        client.getCustomerHandler = { userId, _ in
            .fresh(premium, eTag: "abc123", requestId: "req_1", signatureVerified: false)
        }

        let manager = makeManager()
        let info = try await manager.getCustomerInfo(appUserId: "user_123")

        XCTAssertEqual(info.appUserId, "user_123")
        XCTAssertFalse(info.activeEntitlements.isEmpty)
        XCTAssertEqual(info.entitlements.count, 1)
        XCTAssertEqual(info.entitlements["premium"]?.id, "premium")

        // Verify cached
        let cachedInfo = await manager.cachedInfo()
        XCTAssertEqual(cachedInfo?.appUserId, "user_123")

        // Verify eTag stored
        let loaded = await etagManager.cached(AppActorCustomerInfo.self, for: .customer(appUserId: "user_123"))
        XCTAssertEqual(loaded?.eTag, "abc123")
    }

    // MARK: - 304 -> Returns Cached, Updates Timestamp

    func testNotModifiedReturnsCached() async throws {
        // Pre-populate cache
        let premium = makePremiumInfo()
        await etagManager.storeFresh(premium, for: .customer(appUserId: "user_123"), eTag: "abc123")

        // Server returns 304
        client.getCustomerHandler = { _, _ in
            .notModified(eTag: nil, requestId: "req_304")
        }

        let manager = makeManager()
        let info = try await manager.getCustomerInfo(appUserId: "user_123")

        XCTAssertEqual(info.appUserId, "user_123")
        XCTAssertFalse(info.activeEntitlements.isEmpty)
    }

    // MARK: - 404 -> Throws customerNotFound

    func testNotFoundThrows() async {
        client.getCustomerHandler = { userId, _ in
            throw AppActorError.customerNotFound(appUserId: userId, requestId: "req_404")
        }

        let manager = makeManager()

        do {
            _ = try await manager.getCustomerInfo(appUserId: "unknown_user")
            XCTFail("Expected customerNotFound error")
        } catch let error as AppActorError {
            XCTAssertEqual(error.kind, .customerNotFound)
            XCTAssertEqual(error.message, "unknown_user")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    // MARK: - Offline Entitlement Keys: SK2 + Mapping -> Derives Keys

    func testOfflineEntitlementKeysFromSK2WithMapping() async throws {
        skChecker.productIds = ["com.app.monthly"]

        let dto = AppActorOfferingsResponseDTO(
            currentOffering: nil,
            offerings: [],
            productEntitlements: ["com.app.monthly": ["premium", "ad_free"]]
        )
        await etagManager.storeFresh(dto, for: .offerings, eTag: nil)

        let manager = makeManager()
        let keys = await manager.activeEntitlementKeysOffline()

        XCTAssertEqual(keys, ["premium", "ad_free"])
    }

    // MARK: - Offline Entitlement Keys: No SK2 + Fresh Cache -> Uses Cached Keys

    func testOfflineEntitlementKeysFallsToCache() async throws {
        let premiumInfo = makePremiumInfo()
        await etagManager.storeFresh(premiumInfo, for: .customer(appUserId: "user_123"), eTag: nil)

        let manager = makeManager(cacheTTL: 3600)
        // Seed the manager's currentAppUserId by fetching once
        // or by calling seedCache
        await manager.seedCache(info: premiumInfo, eTag: nil, appUserId: "user_123")
        let keys = await manager.activeEntitlementKeysOffline()

        XCTAssertEqual(keys, ["premium"])
    }

    func testOfflineEntitlementKeysUsesExplicitAppUserIdForCacheFallback() async throws {
        let requestedUserInfo = makePremiumInfo(appUserId: "user_requested")
        let currentUserInfo = makeCustomerInfo(
            appUserId: "user_current",
            entitlements: [
                "vip": AppActorEntitlementInfo(id: "vip", isActive: true, productID: "com.app.vip")
            ]
        )

        await etagManager.storeFresh(requestedUserInfo, for: .customer(appUserId: "user_requested"), eTag: nil)
        await etagManager.storeFresh(currentUserInfo, for: .customer(appUserId: "user_current"), eTag: nil)

        let manager = makeManager(cacheTTL: 3600)
        await manager.seedCache(info: currentUserInfo, eTag: nil, appUserId: "user_current")

        let keys = await manager.activeEntitlementKeysOffline(appUserId: "user_requested")

        XCTAssertEqual(keys, ["premium"])
    }

    // MARK: - Offline Entitlement Keys: No SK2 + Stale Cache -> Empty Set

    func testOfflineEntitlementKeysStaleCacheReturnsEmpty() async throws {
        let premiumInfo = makePremiumInfo()
        await etagManager.storeFresh(premiumInfo, for: .customer(appUserId: "user_123"), eTag: nil)

        // Use cacheTTL: 0 so any cache is immediately stale
        let manager = makeManager(cacheTTL: 0)
        await manager.seedCache(info: premiumInfo, eTag: nil, appUserId: "user_123")

        // Give a tiny delay so cachedAt is definitely in the past
        try await Task.sleep(nanoseconds: 10_000_000) // 10ms

        let keys = await manager.activeEntitlementKeysOffline()

        XCTAssertTrue(keys.isEmpty, "Stale cache beyond TTL should return empty set")
    }

    // MARK: - Dedup: 2 Concurrent Calls -> 1 HTTP Request

    func testDedupCoalescing() async throws {
        let premium = makePremiumInfo()

        client.getCustomerHandler = { userId, _ in
            // Simulate network delay
            try await Task.sleep(nanoseconds: 50_000_000) // 50ms
            return .fresh(premium, eTag: "hash1", requestId: "req_dedup", signatureVerified: false)
        }

        let manager = makeManager()

        async let r1 = manager.getCustomerInfo(appUserId: "user_123")
        async let r2 = manager.getCustomerInfo(appUserId: "user_123")

        let results = try await [r1, r2]

        XCTAssertEqual(results[0].appUserId, "user_123")
        XCTAssertEqual(results[1].appUserId, "user_123")
        XCTAssertEqual(client.getCustomerCalls.count, 1, "Should coalesce into 1 HTTP request")
    }

    // MARK: - forceRefresh=true -> No eTag Sent

    func testForceRefreshSkipsETag() async throws {
        // Pre-populate cache with eTag
        let info = makePremiumInfo()
        await etagManager.storeFresh(info, for: .customer(appUserId: "user_123"), eTag: "old_hash")

        client.getCustomerHandler = { userId, eTag in
            XCTAssertNil(eTag, "forceRefresh should not send eTag")
            return .fresh(info, eTag: "new_hash", requestId: "req_force", signatureVerified: false)
        }

        let manager = makeManager()
        _ = try await manager.getCustomerInfo(appUserId: "user_123", forceRefresh: true)

        XCTAssertEqual(client.getCustomerCalls.count, 1)
        XCTAssertNil(client.getCustomerCalls[0].eTag)
    }

    // MARK: - Non-forceRefresh -> eTag Sent

    func testConditionalRequestSendsETag() async throws {
        // Pre-populate cache with eTag
        let info = makePremiumInfo()
        await etagManager.storeFresh(info, for: .customer(appUserId: "user_123"), eTag: "cached_hash")

        client.getCustomerHandler = { _, eTag in
            .notModified(eTag: nil, requestId: "req_cond")
        }

        // cacheTTL=0 for offline fallback tests; getCustomerInfo always hits network.
        let manager = makeManager(cacheTTL: 0)
        _ = try await manager.getCustomerInfo(appUserId: "user_123", forceRefresh: false)

        XCTAssertEqual(client.getCustomerCalls.count, 1)
        XCTAssertEqual(client.getCustomerCalls[0].eTag, "cached_hash")
    }

    // MARK: - CustomerInfo Computed Properties

    func testCustomerInfoComputedProperties() {
        let info = AppActorCustomerInfo(
            entitlements: [
                "premium": AppActorEntitlementInfo(id: "premium", isActive: true, productID: "com.app.monthly"),
                "trial": AppActorEntitlementInfo(id: "trial", isActive: false, productID: "com.app.trial"),
                "addon": AppActorEntitlementInfo(id: "addon", isActive: true, productID: "com.app.addon")
            ],
            subscriptions: [
                "com.app.monthly": AppActorSubscriptionInfo(productIdentifier: "com.app.monthly", isActive: true),
                "com.app.trial": AppActorSubscriptionInfo(productIdentifier: "com.app.trial", isActive: false)
            ],
            appUserId: "user_1"
        )

        XCTAssertEqual(info.activeEntitlements.count, 2)
        XCTAssertEqual(info.activeEntitlementKeys, Set(["premium", "addon"]))
        XCTAssertTrue(info.hasActiveEntitlement("premium"))
        XCTAssertTrue(info.hasActiveEntitlement("addon"))
        XCTAssertFalse(info.hasActiveEntitlement("trial"))
        XCTAssertFalse(info.hasActiveEntitlement("nonexistent"))

        // No active entitlements
        let free = AppActorCustomerInfo(
            entitlements: [
                "premium": AppActorEntitlementInfo(id: "premium", isActive: false)
            ],
            appUserId: "user_2"
        )
        XCTAssertTrue(free.activeEntitlements.isEmpty)
        XCTAssertTrue(free.activeEntitlementKeys.isEmpty)
        XCTAssertFalse(free.hasActiveEntitlement("premium"))
    }

    // MARK: - CustomerInfo Codable Roundtrip

    func testCustomerInfoCodableRoundtrip() throws {
        let info = makePremiumInfo()

        let data = try JSONEncoder().encode(info)
        let decoded = try JSONDecoder().decode(AppActorCustomerInfo.self, from: data)

        XCTAssertEqual(info, decoded)
        XCTAssertEqual(decoded.appUserId, "user_123")
        XCTAssertEqual(decoded.entitlements.count, 1)
        XCTAssertFalse(decoded.activeEntitlements.isEmpty)
    }

    // MARK: - DTO -> Model Conversion (dict-based)

    func testDTOToModelConversion() {
        let dto = AppActorCustomerDTO(
            entitlements: [
                "pro": AppActorEntitlementDTO(
                    isActive: true,
                    productId: "com.app.pro",
                    expiresAt: "2099-12-31T23:59:59Z",
                    purchaseDate: "2025-01-01T00:00:00Z"
                )
            ],
            subscriptions: [
                "com.app.pro": AppActorSubscriptionDTO(
                    productId: "com.app.pro",
                    isActive: true,
                    expiresAt: "2099-12-31T23:59:59Z",
                    purchaseDate: "2025-01-01T00:00:00Z",
                    periodType: "normal",
                    store: "app_store"
                )
            ],
            nonSubscriptions: nil,
            managementUrl: nil,
            firstSeen: "2025-01-01T00:00:00Z",
            lastSeen: "2025-06-01T12:00:00Z"
        )

        let info = AppActorCustomerInfo(dto: dto, appUserId: "dto_user", requestDate: "2025-06-01T12:00:00Z")

        XCTAssertEqual(info.appUserId, "dto_user")
        XCTAssertEqual(info.requestDate, "2025-06-01T12:00:00Z")
        XCTAssertEqual(info.entitlements.count, 1)
        XCTAssertEqual(info.entitlements["pro"]?.id, "pro")
        XCTAssertTrue(info.entitlements["pro"]?.isActive == true)
        XCTAssertEqual(info.entitlements["pro"]?.productID, "com.app.pro")
        XCTAssertEqual(info.subscriptions.count, 1)
        XCTAssertEqual(info.subscriptions["com.app.pro"]?.periodType, .normal)
        XCTAssertEqual(info.subscriptions["com.app.pro"]?.store, .appStore)
    }

    // MARK: - Decode Real Backend Customer Response (empty user)

    func testDecodeRealBackendCustomerResponseEmpty() throws {
        let json = """
        {
            "requestDate": "2026-02-14T22:42:17.027Z",
            "requestDateMs": 1771108937027,
            "customer": {
                "managementUrl": null,
                "firstSeen": "2026-02-14T22:42:04.583Z",
                "lastSeen": "2026-02-14T22:42:04.583Z",
                "entitlements": {},
                "subscriptions": {},
                "nonSubscriptions": {}
            }
        }
        """.data(using: .utf8)!

        let dto = try JSONDecoder().decode(AppActorCustomerResponseDTO.self, from: json)

        XCTAssertEqual(dto.requestDate, "2026-02-14T22:42:17.027Z")
        XCTAssertEqual(dto.requestDateMs, 1771108937027)
        XCTAssertNil(dto.requestId)
        XCTAssertNotNil(dto.customer)
        XCTAssertEqual(dto.customer.entitlements?.count ?? 0, 0)
        XCTAssertEqual(dto.customer.subscriptions?.count ?? 0, 0)
        XCTAssertEqual(dto.customer.firstSeen, "2026-02-14T22:42:04.583Z")
        XCTAssertNil(dto.customer.managementUrl)

        let info = AppActorCustomerInfo(dto: dto.customer, appUserId: "test-user-001", requestDate: dto.requestDate)

        XCTAssertEqual(info.appUserId, "test-user-001")
        XCTAssertTrue(info.entitlements.isEmpty)
        XCTAssertTrue(info.subscriptions.isEmpty)
        XCTAssertTrue(info.activeEntitlements.isEmpty)
    }

    // MARK: - Decode Real Backend Customer Response (with entitlements)

    func testDecodeRealBackendCustomerResponseWithEntitlements() throws {
        let json = """
        {
            "requestDate": "2026-02-14T22:42:17.027Z",
            "requestDateMs": 1771108937027,
            "customer": {
                "managementUrl": null,
                "firstSeen": "2026-02-14T22:42:04.583Z",
                "lastSeen": "2026-02-14T22:42:04.583Z",
                "entitlements": {
                    "premium": {
                        "isActive": true,
                        "productId": "com.app.monthly",
                        "expiresAt": "2099-12-31T23:59:59Z",
                        "purchaseDate": "2025-01-01T00:00:00Z"
                    },
                    "trial_bonus": {
                        "isActive": false,
                        "productId": "com.app.trial"
                    }
                },
                "subscriptions": {
                    "com.app.monthly": {
                        "productId": "com.app.monthly",
                        "isActive": true,
                        "expiresAt": "2099-12-31T23:59:59Z",
                        "purchaseDate": "2025-01-01T00:00:00Z",
                        "periodType": "normal",
                        "store": "app_store"
                    }
                },
                "nonSubscriptions": {}
            }
        }
        """.data(using: .utf8)!

        let dto = try JSONDecoder().decode(AppActorCustomerResponseDTO.self, from: json)
        let info = AppActorCustomerInfo(dto: dto.customer, appUserId: "premium-user", requestDate: dto.requestDate)

        XCTAssertEqual(info.appUserId, "premium-user")
        XCTAssertEqual(info.entitlements.count, 2)
        XCTAssertEqual(info.activeEntitlements.count, 1)
        XCTAssertTrue(info.activeEntitlements["premium"]?.id == "premium")
        XCTAssertFalse(info.activeEntitlements.isEmpty)

        XCTAssertEqual(info.subscriptions.count, 1)
        XCTAssertTrue(info.subscriptions["com.app.monthly"]?.isActive == true)
        XCTAssertEqual(info.subscriptions["com.app.monthly"]?.store, .appStore)
    }

    func testDecodeCustomerResponseFromDataEnvelopeWithTokenBalance() throws {
        let json = """
        {
            "requestId": "req_customer_v2",
            "data": {
                "managementUrl": null,
                "tokenBalance": {
                    "renewable": 500,
                    "nonRenewable": 200,
                    "total": 700
                },
                "firstSeen": "2026-01-15T00:00:00.000Z",
                "lastSeen": "2026-03-06T12:00:00.000Z",
                "entitlements": {},
                "subscriptions": {},
                "nonSubscriptions": {}
            }
        }
        """.data(using: .utf8)!

        let dto = try JSONDecoder().decode(AppActorCustomerResponseDTO.self, from: json)
        XCTAssertEqual(dto.requestId, "req_customer_v2")
        XCTAssertEqual(dto.customer.tokenBalance?.renewable, 500)
        XCTAssertEqual(dto.customer.tokenBalance?.nonRenewable, 200)
        XCTAssertEqual(dto.customer.tokenBalance?.total, 700)

        let info = AppActorCustomerInfo(dto: dto.customer, appUserId: "token-user", requestDate: dto.requestDate)
        XCTAssertEqual(info.tokenBalance?.renewable, 500)
        XCTAssertEqual(info.tokenBalance?.nonRenewable, 200)
        XCTAssertEqual(info.tokenBalance?.total, 700)
        XCTAssertEqual(info.firstSeen, "2026-01-15T00:00:00.000Z")
        XCTAssertEqual(info.lastSeen, "2026-03-06T12:00:00.000Z")
    }

    // MARK: - ETagManager Save and Load

    func testETagManagerSaveAndLoad() async {
        let info = makePremiumInfo()
        await etagManager.storeFresh(info, for: .customer(appUserId: "user_123"), eTag: "test_hash")

        let loaded = await etagManager.cached(AppActorCustomerInfo.self, for: .customer(appUserId: "user_123"))
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.value.appUserId, "user_123")
        XCTAssertEqual(loaded?.eTag, "test_hash")
        XCTAssertNotNil(loaded?.cachedAt)
    }

    func testETagManagerClear() async {
        let info = makePremiumInfo()
        await etagManager.storeFresh(info, for: .customer(appUserId: "user_123"), eTag: "hash")
        let loaded = await etagManager.cached(AppActorCustomerInfo.self, for: .customer(appUserId: "user_123"))
        XCTAssertNotNil(loaded)

        await etagManager.clear(.customer(appUserId: "user_123"))
        let cleared = await etagManager.cached(AppActorCustomerInfo.self, for: .customer(appUserId: "user_123"))
        XCTAssertNil(cleared)
    }

    func testETagManagerIsFresh() async throws {
        let info = makePremiumInfo()
        await etagManager.storeFresh(info, for: .customer(appUserId: "user_123"), eTag: nil)

        let isFresh = await etagManager.isFresh(for: .customer(appUserId: "user_123"), ttl: 3600)
        XCTAssertTrue(isFresh, "Fresh cache should be valid")

        // Use TTL=0 to make it stale
        try await Task.sleep(nanoseconds: 10_000_000) // 10ms
        let isStale = await etagManager.isFresh(for: .customer(appUserId: "user_123"), ttl: 0)
        XCTAssertFalse(isStale, "Stale cache should be invalid")
    }

    // MARK: - 304 Cache-Miss -> Forces Fresh Fetch

    func test304CacheMissForcesRefresh() async throws {
        var callCount = 0
        let premium = makePremiumInfo()

        client.getCustomerHandler = { userId, eTag in
            callCount += 1
            if callCount == 1 {
                // First call: return 304 (but cache is empty)
                return .notModified(eTag: nil, requestId: "req_304")
            }
            // Second call (retry without eTag): return fresh
            return .fresh(premium, eTag: "new_hash", requestId: "req_fresh", signatureVerified: false)
        }

        let manager = makeManager()
        // No cache pre-populated — 304 should trigger a fresh retry
        let info = try await manager.getCustomerInfo(appUserId: "user_123")

        XCTAssertEqual(info.appUserId, "user_123")
        XCTAssertFalse(info.activeEntitlements.isEmpty)
        XCTAssertEqual(callCount, 2, "Should retry with fresh fetch after 304 cache miss")
    }

    // MARK: - Offline Keys with SK2 Mapping (5xx scenario — getCustomerInfo throws, offline still works)

    func testOfflineKeysAvailableEvenWhenServerDown() async throws {
        skChecker.productIds = ["com.app.monthly"]

        let dto = AppActorOfferingsResponseDTO(
            currentOffering: nil,
            offerings: [],
            productEntitlements: ["com.app.monthly": ["premium"]]
        )
        await etagManager.storeFresh(dto, for: .offerings, eTag: nil)

        let manager = makeManager()
        let keys = await manager.activeEntitlementKeysOffline()

        XCTAssertEqual(keys, ["premium"], "Offline keys should derive from SK2 + mapping even when server is down")
    }

    func testOfflineKeysEmptyWithoutSK2OrCache() async throws {
        let manager = makeManager()
        let keys = await manager.activeEntitlementKeysOffline()

        XCTAssertTrue(keys.isEmpty, "No SK2 products + no cache = empty set")
    }

    // MARK: - forceRefresh Bypasses In-Flight Dedup

    func testForceRefreshBypassesInflight() async throws {
        let premium = makePremiumInfo()

        client.getCustomerHandler = { _, _ in
            try await Task.sleep(nanoseconds: 50_000_000)
            return .fresh(premium, eTag: nil, requestId: "req_x", signatureVerified: false)
        }

        let manager = makeManager()

        // Launch a normal request, then immediately a forceRefresh
        async let r1 = manager.getCustomerInfo(appUserId: "user_123", forceRefresh: false)
        // Small delay to ensure r1 sets inflight first
        try await Task.sleep(nanoseconds: 10_000_000)
        async let r2 = manager.getCustomerInfo(appUserId: "user_123", forceRefresh: true)

        _ = try await [r1, r2]

        // forceRefresh should NOT reuse the in-flight task -> 2 HTTP calls
        XCTAssertEqual(client.getCustomerCalls.count, 2,
                       "forceRefresh=true should start a new request, not reuse in-flight")
    }

    // MARK: - Date Parsing

    func testDateParsingOnEntitlement() {
        // AppActorEntitlementInfo stores dates as Date? not String?
        // Use expirationDate and originalPurchaseDate for expiry/purchase
        let entitlement = AppActorEntitlementInfo(
            id: "pro",
            isActive: true,
            originalPurchaseDate: Date(timeIntervalSince1970: 1736937000), // 2025-01-15
            expirationDate: Date(timeIntervalSince1970: 4070908800) // 2099-06-15
        )

        XCTAssertNotNil(entitlement.expirationDate)
        XCTAssertNotNil(entitlement.originalPurchaseDate)

        // Check year roundtrip (use UTC calendar to avoid timezone shifts)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        XCTAssertEqual(cal.component(.year, from: entitlement.expirationDate!), 2099)
        XCTAssertEqual(cal.component(.year, from: entitlement.originalPurchaseDate!), 2025)
    }

    func testDateParsingNilOnMissingEntitlement() {
        let entitlement = AppActorEntitlementInfo(id: "x", isActive: false)

        XCTAssertNil(entitlement.expirationDate)
        XCTAssertNil(entitlement.originalPurchaseDate)
    }

    // MARK: - End-to-End Smoke Test

    /// Exercises the full customer lifecycle:
    ///   200 -> cache saved -> 304 -> cache reused -> forceRefresh -> offline fallback
    func testSmokeTestFullLifecycle() async throws {
        let appUserId = "smoke_user"
        var callCount = 0

        // --- Phase 1: 200 with active + inactive entitlements + eTag ---

        let freshInfo = AppActorCustomerInfo(
            entitlements: [
                "premium": AppActorEntitlementInfo(
                    id: "premium", isActive: true, productID: "com.app.monthly",
                    originalPurchaseDate: Date(timeIntervalSince1970: 1735689600), // 2025-01-01
                    expirationDate: Date(timeIntervalSince1970: 4102444799) // 2099-12-31
                ),
                "trial_bonus": AppActorEntitlementInfo(
                    id: "trial_bonus", isActive: false, productID: "com.app.trial",
                    expirationDate: Date(timeIntervalSince1970: 1738368000) // 2025-02-01
                )
            ],
            subscriptions: [
                "com.app.monthly": AppActorSubscriptionInfo(
                    productIdentifier: "com.app.monthly", isActive: true,
                    expiresDate: "2099-12-31T23:59:59Z",
                    store: .appStore
                )
            ],
            appUserId: appUserId,
            requestDate: "2025-06-15T12:00:00Z"
        )

        client.getCustomerHandler = { userId, eTag in
            callCount += 1
            // First call: fresh 200 with eTag
            XCTAssertEqual(userId, appUserId)
            return .fresh(freshInfo, eTag: "smoke_hash_v1", requestId: "req_smoke_\(callCount)", signatureVerified: false)
        }

        let manager = makeManager()

        // --- Assert Phase 1: 200 parses correctly ---

        let info1 = try await manager.getCustomerInfo(appUserId: appUserId)

        XCTAssertEqual(info1.appUserId, appUserId)
        XCTAssertEqual(info1.entitlements.count, 2)
        XCTAssertEqual(info1.activeEntitlements.count, 1)
        XCTAssertTrue(info1.activeEntitlements["premium"]?.id == "premium")
        XCTAssertFalse(info1.activeEntitlements.isEmpty)
        XCTAssertEqual(info1.subscriptions.count, 1)
        XCTAssertEqual(info1.subscriptions["com.app.monthly"]?.store, .appStore)
        XCTAssertEqual(info1.requestDate, "2025-06-15T12:00:00Z")

        // Verify cache saved with eTag + cachedAt
        let cached1 = await etagManager.cached(AppActorCustomerInfo.self, for: .customer(appUserId: appUserId))
        XCTAssertNotNil(cached1, "Cache should be populated after 200")
        XCTAssertEqual(cached1?.eTag, "smoke_hash_v1")
        XCTAssertNotNil(cached1?.cachedAt)

        XCTAssertEqual(callCount, 1)

        // --- Assert Phase 2: Second call always hits network (ETag for 304) ---

        let info2 = try await manager.getCustomerInfo(appUserId: appUserId)

        XCTAssertEqual(info2, info1, "Should return identical CustomerInfo")
        XCTAssertEqual(callCount, 2, "Every getCustomerInfo call hits network (ETag handles bandwidth)")

        // --- Assert Phase 3: forceRefresh skips ETag -> guarantees fresh 200 ---

        let info3 = try await manager.getCustomerInfo(appUserId: appUserId, forceRefresh: true)
        XCTAssertEqual(info3, info1, "forceRefresh should return fresh data")
        XCTAssertEqual(callCount, 3, "forceRefresh also hits network")

        // --- Assert Phase 4: offline entitlement keys from cache ---

        let offlineKeys = await manager.activeEntitlementKeysOffline()
        XCTAssertEqual(offlineKeys, ["premium"], "Cached customer info has 'premium' entitlement")
        XCTAssertEqual(callCount, 3, "Offline keys use cache, no extra network call")
    }

    // MARK: - Offline Entitlement Keys: Stale Cache in Smoke Test

    func testSmokeTestStaleCacheOfflineKeysEmpty() async throws {
        let premium = makePremiumInfo()
        await etagManager.storeFresh(premium, for: .customer(appUserId: "user_123"), eTag: "hash_v1")

        // Use cacheTTL: 0 so cache is always stale
        let manager = makeManager(cacheTTL: 0)
        await manager.seedCache(info: premium, eTag: "hash_v1", appUserId: "user_123")

        try await Task.sleep(nanoseconds: 10_000_000) // 10ms

        let expiredKeys = await manager.activeEntitlementKeysOffline()
        XCTAssertTrue(expiredKeys.isEmpty, "Stale cache -> empty offline keys")
    }

    // MARK: - 429 Retry / Backoff Behavior

    func test429RetrySucceedsWithoutFallback() async throws {
        let premium = makePremiumInfo()
        var handlerCallCount = 0

        let retryClient = RetrySimulatingMockClient(maxRetries: 3)
        retryClient.handler = { userId, eTag in
            handlerCallCount += 1
            if handlerCallCount <= 2 {
                throw AppActorError.serverError(
                    httpStatus: 429,
                    code: "RATE_LIMITED",
                    message: "Too many requests",
                    details: nil,
                    requestId: "req_429_\(handlerCallCount)"
                )
            }
            return .fresh(premium, eTag: "hash_after_429", requestId: "req_200", signatureVerified: false)
        }

        let manager = AppActorCustomerManager(
            client: retryClient,
            etagManager: etagManager,
            entitlementChecker: skChecker,
            cacheTTL: 24 * 60 * 60
        )

        let info = try await manager.getCustomerInfo(appUserId: "user_123")

        XCTAssertEqual(info.appUserId, "user_123")
        XCTAssertFalse(info.activeEntitlements.isEmpty)
        XCTAssertEqual(handlerCallCount, 3)
        XCTAssertEqual(retryClient.attemptCount, 3)

        let cached = await etagManager.cached(AppActorCustomerInfo.self, for: .customer(appUserId: "user_123"))
        XCTAssertNotNil(cached)
        XCTAssertEqual(cached?.eTag, "hash_after_429")
    }

    func test429ExhaustedThrows() async {
        client.getCustomerHandler = { _, _ in
            throw AppActorError.serverError(
                httpStatus: 429,
                code: "RATE_LIMITED",
                message: "Too many requests",
                details: nil,
                requestId: "req_429_final"
            )
        }

        let manager = makeManager()

        do {
            _ = try await manager.getCustomerInfo(appUserId: "user_123")
            XCTFail("Expected 429 error to throw")
        } catch let error as AppActorError {
            XCTAssertEqual(error.kind, .server)
            XCTAssertEqual(error.httpStatus, 429)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    // MARK: - Offline SK2 + Product-Entitlement Mapping

    func testOfflineKeysDerivesFromSK2Mapping() async throws {
        skChecker.productIds = ["com.app.monthly"]

        let dto = AppActorOfferingsResponseDTO(
            currentOffering: nil,
            offerings: [],
            productEntitlements: ["com.app.monthly": ["premium"]]
        )
        await etagManager.storeFresh(dto, for: .offerings, eTag: nil)

        let manager = makeManager()
        let keys = await manager.activeEntitlementKeysOffline()

        XCTAssertEqual(keys, ["premium"], "SK2 product mapped to 'premium' should derive that key")
    }

    func testOfflineKeysDerivesMultipleFromMapping() async throws {
        skChecker.productIds = ["com.app.addon"]

        let dto = AppActorOfferingsResponseDTO(
            currentOffering: nil,
            offerings: [],
            productEntitlements: ["com.app.addon": ["extras", "vip"]]
        )
        await etagManager.storeFresh(dto, for: .offerings, eTag: nil)

        let manager = makeManager()
        let keys = await manager.activeEntitlementKeysOffline()

        XCTAssertEqual(keys, ["extras", "vip"], "SK2 product should derive all mapped entitlement keys")
    }

    func testOfflineKeysNoMappingFallsToCache() async throws {
        skChecker.productIds = ["com.app.monthly"]

        // Pre-populate customer cache with active entitlements
        let premiumInfo = makePremiumInfo()
        await etagManager.storeFresh(premiumInfo, for: .customer(appUserId: "user_123"), eTag: nil)

        // No offerings cache -> mapping path skipped, falls to cached customer info
        let manager = makeManager(cacheTTL: 3600)
        await manager.seedCache(info: premiumInfo, eTag: nil, appUserId: "user_123")
        let keys = await manager.activeEntitlementKeysOffline()

        XCTAssertEqual(keys, ["premium"], "No offerings cache -> falls to cached customer info keys")
    }

    // MARK: - 304 + Empty Cache -> Forces Fresh (simulates corruption scenario)

    func test304WithEmptyCacheTriggersRefreshAndRepair() async throws {
        let premium = makePremiumInfo()

        // Do NOT pre-populate the cache -- simulate a corrupted/missing state
        var callCount = 0
        client.getCustomerHandler = { userId, eTag in
            callCount += 1
            if callCount == 1 {
                return .notModified(eTag: nil, requestId: "req_304_corrupt")
            }
            XCTAssertNil(eTag, "Retry after cache-miss should NOT send eTag")
            return .fresh(premium, eTag: "repaired_hash", requestId: "req_200_repair", signatureVerified: false)
        }

        let manager = makeManager()
        let info = try await manager.getCustomerInfo(appUserId: "user_123")

        XCTAssertEqual(info.appUserId, "user_123")
        XCTAssertFalse(info.activeEntitlements.isEmpty)
        XCTAssertEqual(callCount, 2)

        let repairedCache = await etagManager.cached(AppActorCustomerInfo.self, for: .customer(appUserId: "user_123"))
        XCTAssertNotNil(repairedCache)
        XCTAssertEqual(repairedCache?.value.appUserId, "user_123")
        XCTAssertEqual(repairedCache?.eTag, "repaired_hash")
    }

    // MARK: - Phase 1: Date Accessors

    func testCustomerInfoDateAccessors() {
        let info = AppActorCustomerInfo(
            appUserId: "user_dates",
            requestDate: "2025-06-15T12:00:00Z",
            firstSeen: "2025-01-01T00:00:00.000Z",
            lastSeen: "2025-06-15T12:00:00Z"
        )
        XCTAssertNotNil(info.firstSeenDate)
        XCTAssertNotNil(info.lastSeenDate)
        XCTAssertNotNil(info.requestDateParsed)

        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        XCTAssertEqual(cal.component(.year, from: info.firstSeenDate!), 2025)
        XCTAssertEqual(cal.component(.month, from: info.firstSeenDate!), 1)
    }

    func testCustomerInfoDateAccessorsNilOnMissing() {
        let info = AppActorCustomerInfo(appUserId: "user_nil")
        XCTAssertNil(info.firstSeenDate)
        XCTAssertNil(info.lastSeenDate)
    }

    func testEntitlementAllDateAccessors() {
        // AppActorEntitlementInfo stores Date? directly (not String?)
        let gracePeriod = Date(timeIntervalSince1970: 1751328000)   // 2025-07-01
        let billing = Date(timeIntervalSince1970: 1751068800)        // 2025-06-28
        let unsub = Date(timeIntervalSince1970: 1750809600)          // 2025-06-25
        let renewed = Date(timeIntervalSince1970: 1750032000)        // 2025-06-15
        let starts = Date(timeIntervalSince1970: 1735689600)         // 2025-01-01

        let ent = AppActorEntitlementInfo(
            id: "test",
            isActive: true,
            gracePeriodExpiresAt: gracePeriod,
            billingIssueDetectedAt: billing,
            unsubscribeDetectedAt: unsub,
            renewedAt: renewed,
            startsAt: starts
        )
        XCTAssertNotNil(ent.gracePeriodExpiresAt)
        XCTAssertNotNil(ent.billingIssueDetectedAt)
        XCTAssertNotNil(ent.unsubscribeDetectedAt)
        XCTAssertNotNil(ent.renewedAt)
        XCTAssertNotNil(ent.startsAt)
    }

    func testSubscriptionAllDateAccessors() {
        // AppActorSubscriptionInfo stores dates as String? with computed Date? helpers
        let sub = AppActorSubscriptionInfo(
            productIdentifier: "com.app.monthly",
            isActive: true,
            gracePeriodExpiresAt: "2025-07-01T00:00:00Z",
            unsubscribeDetectedAt: "2025-06-25T08:30:00Z",
            renewedAt: "2025-06-15T10:00:00.123Z"
        )
        XCTAssertNotNil(sub.gracePeriodExpires)
        XCTAssertNotNil(sub.unsubscribeDetected)
        XCTAssertNotNil(sub.renewed)
    }

    func testDateAccessorsNilOnInvalidString() {
        // For subscription's string-based dates, invalid strings return nil
        let sub = AppActorSubscriptionInfo(
            productIdentifier: "bad",
            isActive: false,
            gracePeriodExpiresAt: "not-a-date",
            unsubscribeDetectedAt: "garbage"
        )
        XCTAssertNil(sub.gracePeriodExpires)
        XCTAssertNil(sub.unsubscribeDetected)
    }

    // MARK: - Phase 2: NonSubscription Model

    func testNonSubscriptionDecoding() throws {
        let json = """
        {
            "requestDate": "2026-02-14T22:42:17.027Z",
            "customer": {
                "entitlements": {},
                "subscriptions": {},
                "nonSubscriptions": {
                    "com.app.gems_100": [
                        { "purchaseDate": "2025-06-01T10:00:00Z", "store": "app_store", "isSandbox": false },
                        { "purchaseDate": "2025-06-15T14:30:00Z", "store": "app_store", "isSandbox": true }
                    ],
                    "com.app.unlock_level": [
                        { "purchaseDate": "2025-07-01T08:00:00Z", "store": "app_store", "isSandbox": false }
                    ]
                }
            }
        }
        """.data(using: .utf8)!

        let dto = try JSONDecoder().decode(AppActorCustomerResponseDTO.self, from: json)
        let info = AppActorCustomerInfo(dto: dto.customer, appUserId: "ns_user", requestDate: dto.requestDate)

        // nonSubscriptions is now [String: [AppActorNonSubscription]] — check dict structure
        XCTAssertEqual(info.nonSubscriptions.count, 2)

        let gems = info.nonSubscriptions["com.app.gems_100"]
        XCTAssertNotNil(gems)
        XCTAssertEqual(gems?.count, 2)
        XCTAssertEqual(gems?[0].store, .appStore)
        XCTAssertNotNil(gems?[0].purchased)

        let unlock = info.nonSubscriptions["com.app.unlock_level"]
        XCTAssertNotNil(unlock)
        XCTAssertEqual(unlock?.count, 1)
        XCTAssertEqual(unlock?[0].isSandbox, false)
    }

    func testNonSubscriptionEmptyDict() throws {
        let json = """
        {
            "customer": {
                "entitlements": {},
                "subscriptions": {},
                "nonSubscriptions": {}
            }
        }
        """.data(using: .utf8)!

        let dto = try JSONDecoder().decode(AppActorCustomerResponseDTO.self, from: json)
        let info = AppActorCustomerInfo(dto: dto.customer, appUserId: "ns_empty", requestDate: nil)

        XCTAssertTrue(info.nonSubscriptions.isEmpty)
    }

    func testNonSubscriptionMissingField() {
        let info = AppActorCustomerInfo(appUserId: "ns_default")
        XCTAssertTrue(info.nonSubscriptions.isEmpty)
    }

    func testNonSubscriptionCodableRoundtrip() throws {
        let info = AppActorCustomerInfo(
            nonSubscriptions: [
                "com.app.item": [
                    AppActorNonSubscription(
                        productIdentifier: "com.app.item",
                        purchaseDate: "2025-01-01T00:00:00Z",
                        store: .appStore,
                        isSandbox: false
                    )
                ]
            ],
            appUserId: "ns_roundtrip"
        )
        let data = try JSONEncoder().encode(info)
        let decoded = try JSONDecoder().decode(AppActorCustomerInfo.self, from: data)
        XCTAssertEqual(decoded.nonSubscriptions.count, 1)
        XCTAssertEqual(decoded.nonSubscriptions["com.app.item"]?.count, 1)
        XCTAssertEqual(decoded.nonSubscriptions["com.app.item"]?[0].productIdentifier, "com.app.item")
        XCTAssertNotNil(decoded.nonSubscriptions["com.app.item"]?[0].purchased)
    }

    func testNonSubscriptionMissingStoreTransactionIdentifierRemainsNil() {
        let dto = AppActorNonSubscriptionDTO(
            productId: "com.app.item",
            purchaseDate: "2025-01-01T00:00:00Z",
            store: "app_store"
        )

        let mapped = AppActorNonSubscription(
            productIdentifier: "com.app.item",
            fallbackKey: "fallback_key",
            dto: dto
        )

        XCTAssertNil(mapped.storeTransactionIdentifier)
    }

    // MARK: - Phase 3: New DTO Fields

    func testNewEntitlementFieldsPassthrough() {
        let dto = AppActorEntitlementDTO(
            isActive: true,
            productId: "com.app.pro",
            cancellationReason: "CUSTOMER_CANCEL",
            renewedAt: "2025-06-15T10:00:00Z",
            startsAt: "2025-01-01T00:00:00Z",
            activePromotionalOfferType: "FREE_TRIAL",
            activePromotionalOfferId: "offer_7day"
        )
        let ent = AppActorEntitlementInfo(id: "pro", dto: dto)

        // cancellationReason is now AppActorCancellationReason? (typed enum)
        // "CUSTOMER_CANCEL" does not match raw values ("customer_cancelled") — returns nil from DTO mapping
        XCTAssertNil(ent.cancellationReason)
        // renewedAt and startsAt are Date? in AppActorEntitlementInfo
        XCTAssertNotNil(ent.renewedAt)
        XCTAssertNotNil(ent.startsAt)
        XCTAssertEqual(ent.activePromotionalOfferType, "FREE_TRIAL")
        XCTAssertEqual(ent.activePromotionalOfferId, "offer_7day")
    }

    func testNewSubscriptionFieldsPassthrough() {
        let dto = AppActorSubscriptionDTO(
            productId: "com.app.monthly",
            isActive: true,
            cancellationReason: "BILLING_ERROR",
            renewedAt: "2025-06-15T10:00:00Z",
            originalTransactionId: "1000000123456789",
            latestTransactionId: "1000000987654321",
            activePromotionalOfferType: "PAY_UP_FRONT",
            activePromotionalOfferId: "promo_annual_50off"
        )
        let sub = AppActorSubscriptionInfo(productIdentifier: "com.app.monthly", dto: dto)

        // cancellationReason is AppActorCancellationReason? — "BILLING_ERROR" has no matching raw value → nil
        XCTAssertNil(sub.cancellationReason)
        XCTAssertEqual(sub.renewedAt, "2025-06-15T10:00:00Z")
        XCTAssertNotNil(sub.renewed)
        XCTAssertEqual(sub.originalTransactionId, "1000000123456789")
        XCTAssertEqual(sub.latestTransactionId, "1000000987654321")
        XCTAssertEqual(sub.activePromotionalOfferType, "PAY_UP_FRONT")
        XCTAssertEqual(sub.activePromotionalOfferId, "promo_annual_50off")
    }

    func testNewFieldsNilByDefault() {
        let ent = AppActorEntitlementInfo(id: "basic", isActive: true)
        XCTAssertNil(ent.cancellationReason)
        XCTAssertNil(ent.renewedAt)
        XCTAssertNil(ent.startsAt)
        XCTAssertNil(ent.activePromotionalOfferType)
        XCTAssertNil(ent.activePromotionalOfferId)

        let sub = AppActorSubscriptionInfo(productIdentifier: "com.app.sub", isActive: true)
        XCTAssertNil(sub.cancellationReason)
        XCTAssertNil(sub.renewedAt)
        XCTAssertNil(sub.originalTransactionId)
        XCTAssertNil(sub.latestTransactionId)
        XCTAssertNil(sub.activePromotionalOfferType)
        XCTAssertNil(sub.activePromotionalOfferId)
    }

    func testNewFieldsDecodeFromJSON() throws {
        let json = """
        {
            "customer": {
                "entitlements": {
                    "premium": {
                        "isActive": true,
                        "productId": "com.app.monthly",
                        "cancellationReason": "DEVELOPER_CANCEL",
                        "renewedAt": "2025-06-15T10:00:00Z",
                        "startsAt": "2025-01-01T00:00:00Z",
                        "activePromotionalOfferType": "FREE_TRIAL",
                        "activePromotionalOfferId": "trial_7d"
                    }
                },
                "subscriptions": {
                    "com.app.monthly": {
                        "isActive": true,
                        "cancellationReason": "DEVELOPER_CANCEL",
                        "renewedAt": "2025-06-15T10:00:00Z",
                        "originalTransactionId": "100000099",
                        "latestTransactionId": "200000099",
                        "activePromotionalOfferType": "FREE_TRIAL",
                        "activePromotionalOfferId": "trial_7d"
                    }
                },
                "nonSubscriptions": {}
            }
        }
        """.data(using: .utf8)!

        let dto = try JSONDecoder().decode(AppActorCustomerResponseDTO.self, from: json)
        let info = AppActorCustomerInfo(dto: dto.customer, appUserId: "field_user", requestDate: nil)

        let ent = info.entitlements["premium"]
        // "DEVELOPER_CANCEL" doesn't match raw values ("developer_cancelled") → nil from DTO mapping
        XCTAssertNil(ent?.cancellationReason)
        // startsAt is stored as Date? after DTO mapping
        XCTAssertNotNil(ent?.startsAt)
        XCTAssertEqual(ent?.activePromotionalOfferId, "trial_7d")

        let sub = info.subscriptions["com.app.monthly"]
        XCTAssertEqual(sub?.originalTransactionId, "100000099")
        XCTAssertEqual(sub?.latestTransactionId, "200000099")
        XCTAssertEqual(sub?.activePromotionalOfferType, "FREE_TRIAL")
    }

    // MARK: - Always-network + clearCache (TTL gap fix)

    func testGetCustomerInfoAlwaysHitsNetwork() async throws {
        let info = makePremiumInfo()
        let manager = makeManager()

        // Seed cache so ETag is available
        await manager.seedCache(info: info, eTag: "hash1", appUserId: "user_123")

        client.getCustomerHandler = { _, eTag in
            // Should receive ETag for conditional request
            .notModified(eTag: nil, requestId: "req_1")
        }

        // Even with fresh cache, getCustomerInfo always makes a network call
        _ = try await manager.getCustomerInfo(appUserId: "user_123")
        XCTAssertEqual(client.getCustomerCalls.count, 1,
                       "getCustomerInfo should always make a network request, not return from cache")
    }

    func testGetCustomerInfoSendsETagForBandwidthOptimization() async throws {
        let info = makePremiumInfo()
        let manager = makeManager()
        await manager.seedCache(info: info, eTag: "cached_hash", appUserId: "user_123")

        client.getCustomerHandler = { _, eTag in
            .notModified(eTag: nil, requestId: "req_etag")
        }

        _ = try await manager.getCustomerInfo(appUserId: "user_123")

        XCTAssertEqual(client.getCustomerCalls[0].eTag, "cached_hash",
                       "Should send ETag for 304 bandwidth optimization")
    }

    func testClearCacheResetsFreshness() async throws {
        let info = makePremiumInfo()
        let manager = makeManager()
        await manager.seedCache(info: info, eTag: "hash1", appUserId: "user_123")

        let freshBefore = await manager.isCustomerCacheFresh(appUserId: "user_123")
        XCTAssertTrue(freshBefore)

        await manager.clearCache(appUserId: "user_123")

        let freshAfter = await manager.isCustomerCacheFresh(appUserId: "user_123")
        XCTAssertFalse(freshAfter, "clearCache should reset freshness timestamp")
    }

    func testClearCachePreservesETagForConditionalRequest() async throws {
        let info = makePremiumInfo()
        let manager = makeManager()
        await manager.seedCache(info: info, eTag: "original_etag", appUserId: "user_123")

        await manager.clearCache(appUserId: "user_123")

        client.getCustomerHandler = { _, eTag in
            .notModified(eTag: nil, requestId: "req_304")
        }

        _ = try await manager.getCustomerInfo(appUserId: "user_123")

        XCTAssertEqual(client.getCustomerCalls[0].eTag, "original_etag",
                       "clearCache should preserve ETag for conditional 304 requests")
    }
}
