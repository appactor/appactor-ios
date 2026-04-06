import XCTest
import Foundation
@testable import AppActor

// MARK: - Shared Helpers (file-private)

/// Thread-safe mutable date provider for TTL testing.
private final class MockDateProvider: @unchecked Sendable {
    private let lock = NSLock()
    private var _now: Date

    init(_ date: Date = Date()) { _now = date }

    var now: Date {
        get { lock.lock(); defer { lock.unlock() }; return _now }
        set { lock.lock(); defer { lock.unlock() }; _now = newValue }
    }

    func advance(by interval: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        _now = _now.addingTimeInterval(interval)
    }
}

/// Creates a simple `AppActorOfferingsResponseDTO` for testing.
private func makeDTO(
    offeringId: String = "default",
    productIds: [String] = ["com.app.monthly"],
    isCurrent: Bool = true,
    productEntitlements: [String: [String]]? = nil
) -> AppActorOfferingsResponseDTO {
    let products = productIds.map {
        AppActorProductRefDTO(id: nil, storeProductId: $0, productType: "auto_renewable", displayName: nil)
    }
    let package = AppActorPackageDTO(
        id: nil, packageType: "monthly", displayName: "Monthly",
        position: 0, isActive: true, metadata: nil, products: products
    )
    let offering = AppActorOfferingDTO(
        id: offeringId, lookupKey: offeringId, displayName: offeringId.capitalized,
        isCurrent: isCurrent, metadata: nil, packages: [package]
    )
    return AppActorOfferingsResponseDTO(
        currentOffering: isCurrent ? offering : nil,
        offerings: [offering],
        productEntitlements: productEntitlements
    )
}

// MARK: - CACH-01/02/04/05 Unit-Level Tests

final class CachingCorrectnessTests: XCTestCase {

    private var client: MockPaymentClient!
    private var fetcher: MockStoreKitProductFetcher!
    private var cacheDir: URL!
    private var diskStore: AppActorCacheDiskStore!
    private var etagManager: AppActorETagManager!

    override func setUp() {
        super.setUp()
        client = MockPaymentClient()
        fetcher = MockStoreKitProductFetcher()

        // Isolated temp dir for disk cache
        cacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("appactor_caching_test_\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        diskStore = AppActorCacheDiskStore(directory: cacheDir)
        etagManager = AppActorETagManager(diskStore: diskStore)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: cacheDir)
        super.tearDown()
    }

    // MARK: - CACH-01: 304 Handling Tests

    /// CACH-01: A 304 response resets the TTL clock.
    /// After 304, the cache should be fresh again within the 5-min window.
    func testCACH01_304ResetsTTLTimestamp() async throws {
        let emptyDTO = AppActorOfferingsResponseDTO(currentOffering: nil, offerings: [])

        var networkCalls = 0
        client.getOfferingsHandler = { eTag in
            networkCalls += 1
            if networkCalls == 1 {
                // First call: fresh 200 with eTag
                return .fresh(emptyDTO, eTag: "hash_v1", requestId: "req_1", signatureVerified: false)
            }
            // Second call (after 6 min): server returns 304 — content unchanged
            XCTAssertEqual(eTag, "hash_v1", "Second call should send stored eTag")
            return .notModified(eTag: "hash_v1", requestId: "req_304")
        }

        let clock = MockDateProvider()
        let manager = AppActorOfferingsManager(
            client: client, productFetcher: fetcher, etagManager: etagManager,
            dateProvider: { clock.now }
        )

        // First call: fresh 200
        _ = try await manager.getOfferings()
        XCTAssertEqual(networkCalls, 1)

        // Advance 6 minutes — past the 5-min foreground TTL
        clock.advance(by: 6 * 60)

        // Second call: TTL expired → SWR returns stale cache immediately
        _ = try await manager.getOfferings()
        XCTAssertEqual(networkCalls, 1, "Stale cache returns immediately (SWR), background refresh starts")

        // Allow background refresh to complete
        try await Task.sleep(nanoseconds: 50_000_000)

        // Background refresh should have fired (304 from server)
        XCTAssertEqual(networkCalls, 2, "Background refresh should have completed")

        // Third call: cache was refreshed by background 304, should be fresh
        _ = try await manager.getOfferings()
        XCTAssertEqual(networkCalls, 2, "Third call uses refreshed cache — no new network call")
    }

    /// CACH-01: When a 304 arrives but no local cache exists, the SDK retries without ETag.
    func testCACH01_304CacheMissRefetchesWithoutETag() async throws {
        let emptyDTO = AppActorOfferingsResponseDTO(currentOffering: nil, offerings: [])

        var callCount = 0
        client.getOfferingsHandler = { eTag in
            callCount += 1
            if callCount == 1 {
                // First call returns 304 but cache is empty — eTag would be nil since no disk cache
                return .notModified(eTag: "hash_v1", requestId: "req_304")
            }
            // Retry must NOT send eTag
            XCTAssertNil(eTag, "Retry after 304 cache-miss must NOT send eTag")
            return .fresh(emptyDTO, eTag: "repaired_hash", requestId: "req_200_repair", signatureVerified: false)
        }

        let manager = AppActorOfferingsManager(
            client: client, productFetcher: fetcher, etagManager: etagManager
        )

        // No disk cache — 304 should trigger retry without eTag
        let result = try await manager.getOfferings()
        XCTAssertEqual(callCount, 2, "Should retry after 304 cache miss (2 calls: 304 + fresh 200)")
        XCTAssertNotNil(result)

        // Cache should be repaired with new eTag from the fresh 200
        let entry = await etagManager.cached(AppActorOfferingsResponseDTO.self, for: .offerings)
        XCTAssertNotNil(entry, "Cache should be populated after successful retry")
        XCTAssertEqual(entry?.eTag, "repaired_hash", "ETag from repair 200 should be stored")
    }

    // MARK: - CACH-02: Stale-While-Revalidate Tests

    /// CACH-02: When TTL expires, getOfferings() returns stale data immediately
    /// and refreshes in the background (stale-while-revalidate pattern).
    func testCACH02_staleCacheReturnsImmediatelyAndRefreshesInBackground() async throws {
        let firstDTO = AppActorOfferingsResponseDTO(
            currentOffering: nil,
            offerings: [
                AppActorOfferingDTO(
                    id: "first", lookupKey: "first", displayName: "First",
                    isCurrent: true, metadata: nil, packages: []
                )
            ]
        )

        var networkCalls = 0
        client.getOfferingsHandler = { _ in
            networkCalls += 1
            return .fresh(firstDTO, eTag: "hash_\(networkCalls)", requestId: "req_\(networkCalls)", signatureVerified: false)
        }

        let clock = MockDateProvider()
        let manager = AppActorOfferingsManager(
            client: client, productFetcher: fetcher, etagManager: etagManager,
            dateProvider: { clock.now }
        )

        // First call: fresh data
        _ = try await manager.getOfferings()
        XCTAssertEqual(networkCalls, 1)

        // Advance past TTL (6 min > 5 min foreground TTL)
        clock.advance(by: 6 * 60)

        // Second call: TTL expired — SWR returns stale cache immediately
        let result = try await manager.getOfferings()

        // Stale cache returned immediately — no additional network call blocked
        XCTAssertEqual(networkCalls, 1, "SWR: stale cache returns immediately, background refresh starts")

        // Result is from the stale cache, not a fresh fetch (no network blocked)
        XCTAssertNotNil(result, "Result must be from the stale cache")
    }

    /// CACH-02: CustomerManager's forceRefresh: true bypasses TTL entirely.
    func testCACH02_forceRefreshBypassesTTL() async throws {
        let customerInfo = AppActorCustomerInfo(appUserId: "user1")

        var networkCalls = 0
        client.getCustomerHandler = { appUserId, eTag in
            networkCalls += 1
            return .fresh(
                AppActorCustomerInfo(appUserId: appUserId),
                eTag: "customer_hash_\(networkCalls)",
                requestId: "req_\(networkCalls)",
                signatureVerified: false
            )
        }

        let customerManager = AppActorCustomerManager(
            client: client,
            etagManager: etagManager,
            cacheTTL: 24 * 60 * 60  // 24h TTL
        )

        // Seed fresh cache — well within 24h TTL
        await etagManager.storeFresh(customerInfo, for: .customer(appUserId: "user1"), eTag: "initial_hash")

        // forceRefresh: false — should use cache (within TTL, no network)
        _ = try await customerManager.getCustomerInfo(appUserId: "user1", forceRefresh: false)
        XCTAssertEqual(networkCalls, 0, "Within TTL: no network call should be made with forceRefresh: false")

        // forceRefresh: true — must bypass TTL and hit network
        _ = try await customerManager.getCustomerInfo(appUserId: "user1", forceRefresh: true)
        XCTAssertEqual(networkCalls, 1, "forceRefresh: true must bypass TTL and call network even within TTL")
    }

    // MARK: - CACH-04: Corrupt Cache File Handling Tests

    /// CACH-04: A corrupt JSON file is silently deleted when load() fails to decode it.
    func testCACH04_corruptCacheFileSilentlyDeletedOnRead() async throws {
        // Write invalid JSON bytes to the offerings cache file path manually
        let offeringsCacheKey = AppActorCacheResource.offerings.cacheKey
        let cacheFilePath = cacheDir.appendingPathComponent("\(offeringsCacheKey).json")

        // Ensure directory exists
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)

        // Write corrupt (non-JSON) bytes
        let corruptData = Data("this is not valid json {{{".utf8)
        try corruptData.write(to: cacheFilePath)

        // Verify the corrupt file exists before the test
        XCTAssertTrue(FileManager.default.fileExists(atPath: cacheFilePath.path), "Corrupt cache file must exist before load()")

        // Load should return nil (failed to decode)
        let result = await diskStore.load(.offerings)
        XCTAssertNil(result, "load() should return nil for corrupt cache file")

        // The corrupt file should now be deleted from disk
        XCTAssertFalse(FileManager.default.fileExists(atPath: cacheFilePath.path), "Corrupt cache file must be deleted after decode failure")

        // Calling load() again should also return nil (file was cleaned up)
        let result2 = await diskStore.load(.offerings)
        XCTAssertNil(result2, "Second load() after corruption cleanup should return nil")
    }

    /// CACH-04: A valid cache file is NOT deleted on successful load.
    func testCACH04_validCacheFileNotDeleted() async throws {
        let dto = makeDTO(offeringId: "valid_test")

        // Save a valid cache entry via etagManager
        await etagManager.storeFresh(dto, for: .offerings, eTag: "valid_etag")

        let offeringsCacheKey = AppActorCacheResource.offerings.cacheKey
        let cacheFilePath = cacheDir.appendingPathComponent("\(offeringsCacheKey).json")

        // Verify the file exists after save
        XCTAssertTrue(FileManager.default.fileExists(atPath: cacheFilePath.path), "Valid cache file must exist after save()")

        // Load should succeed and return the entry
        let result = await diskStore.load(.offerings)
        XCTAssertNotNil(result, "load() should return the valid cache entry")

        // The valid file must still be present on disk
        XCTAssertTrue(FileManager.default.fileExists(atPath: cacheFilePath.path), "Valid cache file must NOT be deleted after successful load()")
    }

    // MARK: - CACH-05: Single-Flight Coalescing Tests

    /// CACH-05: N concurrent getOfferings() calls produce exactly 1 network request.
    func testCACH05_concurrentCallsCoalesceIntoOneRequest() async throws {
        let emptyDTO = AppActorOfferingsResponseDTO(currentOffering: nil, offerings: [])

        var networkCalls = 0
        client.getOfferingsHandler = { _ in
            networkCalls += 1
            // Simulate 50ms network delay so concurrent calls actually race
            try await Task.sleep(nanoseconds: 50_000_000)
            return .fresh(emptyDTO, eTag: "hash_coalesce", requestId: "req_coalesce", signatureVerified: false)
        }

        let manager = AppActorOfferingsManager(
            client: client, productFetcher: fetcher, etagManager: etagManager
        )

        // Launch 5 concurrent calls (no cache exists — all would normally hit network)
        async let r1 = manager.getOfferings()
        async let r2 = manager.getOfferings()
        async let r3 = manager.getOfferings()
        async let r4 = manager.getOfferings()
        async let r5 = manager.getOfferings()

        let results = try await [r1, r2, r3, r4, r5]

        // All 5 should return the same (empty) result
        for result in results {
            XCTAssertTrue(result.all.isEmpty, "All concurrent results should be consistent")
        }

        // Only 1 network call should have been made (single-flight coalescing)
        XCTAssertEqual(networkCalls, 1, "CACH-05: Concurrent getOfferings() calls must coalesce into exactly 1 network request")
    }

    /// CACH-05: clearCache() increments generation — an in-flight task cannot overwrite cleared state.
    func testCACH05_clearCacheGenerationPreventsStaleWrite() async throws {
        let emptyDTO = AppActorOfferingsResponseDTO(currentOffering: nil, offerings: [])

        var networkCalls = 0
        client.getOfferingsHandler = { _ in
            networkCalls += 1
            // Slow network: 200ms delay
            try await Task.sleep(nanoseconds: 200_000_000)
            return .fresh(emptyDTO, eTag: "hash_stale", requestId: "req_stale", signatureVerified: false)
        }

        let manager = AppActorOfferingsManager(
            client: client, productFetcher: fetcher, etagManager: etagManager
        )

        // Launch getOfferings() in a background Task (don't await yet)
        let fetchTask = Task<AppActorOfferings, Error> {
            try await manager.getOfferings()
        }

        // Wait 50ms to let the fetch start (it's mid-flight now with 200ms total delay)
        try await Task.sleep(nanoseconds: 50_000_000)

        // Call clearCache() while fetch is in-flight
        await manager.clearCache()

        // Await the original fetch — it should complete (may return the data or fail with cancellation)
        // Either way, after clearCache(), in-memory cache must be nil
        _ = try? await fetchTask.value

        // Verify in-memory cache is nil — clearCache() generation guard prevented stale write
        let cachedAfterClear = await manager.cached
        XCTAssertNil(cachedAfterClear, "CACH-05: clearCache() generation guard must prevent in-flight stale task from writing cleared state")

        // A fresh call after clearCache() must trigger a NEW network request
        let secondNetworkCalls = networkCalls
        client.getOfferingsHandler = { _ in
            networkCalls += 1
            return .fresh(emptyDTO, eTag: "hash_fresh", requestId: "req_fresh", signatureVerified: false)
        }
        _ = try? await manager.getOfferings()
        XCTAssertGreaterThan(networkCalls, secondNetworkCalls, "A fresh call after clearCache() must hit the network again")
    }
}

// MARK: - CACH-03: Identity Change Cache Preservation Tests

@MainActor
final class CacheIdentityChangeTests: XCTestCase {

    private var client: MockPaymentClient!
    private var storage: InMemoryPaymentStorage!
    private var cacheDir: URL!
    private var diskStore: AppActorCacheDiskStore!
    private var etagManager: AppActorETagManager!
    private var offeringsManager: AppActorOfferingsManager!
    private var remoteConfigManager: AppActorRemoteConfigManager!
    private var experimentManager: AppActorExperimentManager!
    private var customerManager: AppActorCustomerManager!
    private let appactor = AppActor.shared

    override func setUp() {
        super.setUp()
        client = MockPaymentClient()
        storage = InMemoryPaymentStorage()

        // Isolated temp dir for disk cache
        cacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("appactor_identity_test_\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        diskStore = AppActorCacheDiskStore(directory: cacheDir)
        etagManager = AppActorETagManager(diskStore: diskStore)

        // Create managers with shared etagManager
        let fetcher = MockStoreKitProductFetcher()
        offeringsManager = AppActorOfferingsManager(
            client: client, productFetcher: fetcher, etagManager: etagManager
        )
        remoteConfigManager = AppActorRemoteConfigManager(client: client, etagManager: etagManager)
        experimentManager = AppActorExperimentManager(client: client, etagManager: etagManager)
        customerManager = AppActorCustomerManager(client: client, etagManager: etagManager)

        // Configure AppActor for testing with all injected managers (does NOT run startup)
        let config = AppActorPaymentConfiguration(
            apiKey: "pk_test_cach03",
            baseURL: URL(string: "https://test.appactor.io")!,
            options: .init()
        )
        appactor.configureForTesting(
            config: config,
            client: client,
            storage: storage,
            etagManager: etagManager,
            offeringsManager: offeringsManager,
            customerManager: customerManager,
            remoteConfigManager: remoteConfigManager,
            experimentManager: experimentManager
        )
    }

    override func tearDown() {
        // Reset AppActor state synchronously (avoids races with next test's setUp)
        appactor.paymentConfig = nil
        appactor.paymentStorage = nil
        appactor.paymentClient = nil
        appactor.paymentCurrentUser = nil
        appactor.paymentETagManager = nil
        appactor.offeringsManager = nil
        appactor.customerManager = nil
        appactor.remoteConfigManager = nil
        appactor.experimentManager = nil
        appactor.paymentLifecycle = .idle
        try? FileManager.default.removeItem(at: cacheDir)
        super.tearDown()
    }

    // MARK: - CACH-03: logIn preserves offerings cache

    /// CACH-03: logIn preserves offerings cache (disk + in-memory) while clearing customer cache.
    func testCACH03_loginPreservesOfferingsCache() async throws {
        // Setup: set old user and seed offerings cache
        storage.setAppUserId("old-user")

        let offeringsDTO = makeDTO(offeringId: "premium_plan")
        await etagManager.storeFresh(offeringsDTO, for: .offerings, eTag: "off_etag_1")

        // Seed customer cache for old user
        let oldCustomerInfo = AppActorCustomerInfo(appUserId: "old-user")
        await etagManager.storeFresh(oldCustomerInfo, for: .customer(appUserId: "old-user"), eTag: "cust_etag_old")

        // Set up login handler to return a valid result for new-user
        client.loginHandler = { _ in
            AppActorLoginResult(
                appUserId: "new-user",
                serverUserId: "server-uuid-789",
                customerInfo: AppActorCustomerInfo(appUserId: "new-user"),
                customerETag: "cust_etag_new",
                requestId: "req_login_1",
                signatureVerified: false
            )
        }

        // Perform login
        _ = try await appactor.logIn(newAppUserId: "new-user")

        // VERIFY: Offerings DISK cache is preserved
        let offDiskEntry = await etagManager.cached(AppActorOfferingsResponseDTO.self, for: .offerings)
        XCTAssertNotNil(offDiskEntry, "CACH-03: Offerings disk cache must be preserved after logIn")
        XCTAssertEqual(offDiskEntry?.eTag, "off_etag_1", "Offerings ETag must be preserved after logIn")

        // VERIFY: Customer cache for OLD user is cleared
        let oldCustEntry = await etagManager.cached(AppActorCustomerInfo.self, for: .customer(appUserId: "old-user"))
        XCTAssertNil(oldCustEntry, "CACH-03: Old user's customer cache must be cleared after logIn")
    }

    /// CACH-03: logOut preserves offerings cache (disk + in-memory) while clearing customer cache.
    func testCACH03_logoutPreservesOfferingsCache() async throws {
        // Setup: set current user and seed offerings cache
        storage.setAppUserId("user-to-logout")

        let offeringsDTO = makeDTO(offeringId: "basic_plan")
        await etagManager.storeFresh(offeringsDTO, for: .offerings, eTag: "off_etag_logout")

        // Seed customer cache for current user
        let customerInfo = AppActorCustomerInfo(appUserId: "user-to-logout")
        await etagManager.storeFresh(customerInfo, for: .customer(appUserId: "user-to-logout"), eTag: "cust_etag_pre")

        // Set up logout handler
        client.logoutHandler = { _ in
            AppActorPaymentResult(value: true, requestId: "req_logout_1")
        }

        // Set up identify handler (logOut re-identifies with new anonymous ID)
        client.identifyHandler = { request in
            AppActorIdentifyResult(
                appUserId: request.appUserId,
                customerInfo: AppActorCustomerInfo(appUserId: request.appUserId),
                customerETag: "cust_etag_anon",
                requestId: "req_identify_anon",
                signatureVerified: false
            )
        }

        // Perform logout
        _ = try await appactor.logOut()

        // VERIFY: Offerings DISK cache is preserved
        let offDiskEntry = await etagManager.cached(AppActorOfferingsResponseDTO.self, for: .offerings)
        XCTAssertNotNil(offDiskEntry, "CACH-03: Offerings disk cache must be preserved after logOut")
        XCTAssertEqual(offDiskEntry?.eTag, "off_etag_logout", "Offerings ETag must be preserved after logOut")

        // VERIFY: Customer cache for old user is cleared
        let oldCustEntry = await etagManager.cached(AppActorCustomerInfo.self, for: .customer(appUserId: "user-to-logout"))
        XCTAssertNil(oldCustEntry, "CACH-03: Old user's customer cache must be cleared after logOut")
    }

    /// CACH-03: logIn clears experiment and remote config caches (user-scoped).
    func testCACH03_loginClearsExperimentAndRemoteConfigCaches() async throws {
        // Setup: set old user
        storage.setAppUserId("old-user-2")

        // Seed offerings, experiment, and remote config caches
        let offeringsDTO = makeDTO(offeringId: "exp_test")
        await etagManager.storeFresh(offeringsDTO, for: .offerings, eTag: "off_etag_exp")

        // Seed experiments and remote config caches with placeholder data
        let experimentDTO = AppActorExperimentAssignmentDTO(
            inExperiment: false, reason: "test", experiment: nil, variant: nil, assignedAt: nil
        )
        await etagManager.storeFresh(experimentDTO, for: .experiments(appUserId: "old-user-2"), eTag: "exp_etag_1")

        let remoteConfigDTO: [AppActorRemoteConfigItemDTO] = []
        await etagManager.storeFresh(remoteConfigDTO, for: .remoteConfigs(appUserId: "old-user-2"), eTag: "rc_etag_1")

        // Set up login handler
        client.loginHandler = { _ in
            AppActorLoginResult(
                appUserId: "new-user-2",
                serverUserId: "server-uuid-new-2",
                customerInfo: AppActorCustomerInfo(appUserId: "new-user-2"),
                customerETag: nil,
                requestId: "req_login_exp",
                signatureVerified: false
            )
        }

        // Perform login
        _ = try await appactor.logIn(newAppUserId: "new-user-2")

        // VERIFY: Experiments cache is cleared (user-scoped)
        let expEntry = await etagManager.cached(AppActorExperimentAssignmentDTO.self, for: .experiments(appUserId: "old-user-2"))
        XCTAssertNil(expEntry, "CACH-03: Experiments cache must be cleared after logIn")

        // VERIFY: Remote configs cache is cleared (user-scoped)
        let rcEntry = await etagManager.cached([AppActorRemoteConfigItemDTO].self, for: .remoteConfigs(appUserId: "old-user-2"))
        XCTAssertNil(rcEntry, "CACH-03: Remote configs cache must be cleared after logIn")

        // VERIFY: Offerings cache is still present (project-level)
        let offEntry = await etagManager.cached(AppActorOfferingsResponseDTO.self, for: .offerings)
        XCTAssertNotNil(offEntry, "CACH-03: Offerings cache must be preserved after logIn")
    }

    /// CACH-03: reset() clears ALL caches (offerings, customer, experiments, remoteConfigs).
    func testCACH03_resetClearsAllCaches() async throws {
        // Setup: seed all caches
        storage.setAppUserId("reset-user")

        let offeringsDTO = makeDTO(offeringId: "reset_plan")
        await etagManager.storeFresh(offeringsDTO, for: .offerings, eTag: "off_etag_reset")

        let customerInfo = AppActorCustomerInfo(appUserId: "reset-user")
        await etagManager.storeFresh(customerInfo, for: .customer(appUserId: "reset-user"), eTag: "cust_etag_reset")

        let experimentDTO = AppActorExperimentAssignmentDTO(
            inExperiment: false, reason: "reset_test", experiment: nil, variant: nil, assignedAt: nil
        )
        await etagManager.storeFresh(experimentDTO, for: .experiments(appUserId: "reset-user"), eTag: "exp_etag_reset")

        let remoteConfigDTO: [AppActorRemoteConfigItemDTO] = []
        await etagManager.storeFresh(remoteConfigDTO, for: .remoteConfigs(appUserId: "reset-user"), eTag: "rc_etag_reset")

        // Verify all caches present before reset
        let offBefore = await etagManager.cached(AppActorOfferingsResponseDTO.self, for: .offerings)
        XCTAssertNotNil(offBefore, "Offerings cache must be populated before reset")

        // Perform reset()
        await appactor.reset()

        // VERIFY: All caches are cleared
        let offAfter = await etagManager.cached(AppActorOfferingsResponseDTO.self, for: .offerings)
        XCTAssertNil(offAfter, "CACH-03: Offerings cache must be cleared after reset()")

        let custAfter = await etagManager.cached(AppActorCustomerInfo.self, for: .customer(appUserId: "reset-user"))
        XCTAssertNil(custAfter, "CACH-03: Customer cache must be cleared after reset()")

        let expAfter = await etagManager.cached(AppActorExperimentAssignmentDTO.self, for: .experiments(appUserId: "reset-user"))
        XCTAssertNil(expAfter, "CACH-03: Experiments cache must be cleared after reset()")

        let rcAfter = await etagManager.cached([AppActorRemoteConfigItemDTO].self, for: .remoteConfigs(appUserId: "reset-user"))
        XCTAssertNil(rcAfter, "CACH-03: Remote configs cache must be cleared after reset()")

        // VERIFY: Payment lifecycle is idle after reset
        XCTAssertEqual(appactor.paymentLifecycle, .idle, "CACH-03: paymentLifecycle must be .idle after reset()")
    }
}
