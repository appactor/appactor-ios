import XCTest
import StoreKit
@testable import AppActor

// MARK: - Helpers

/// Creates a `AppActorPackage` with raw values for testing (no real StoreKit Product needed).
private func makePackage(
    id: String = "off_monthly",
    packageType: AppActorPackageType = .monthly,
    displayName: String = "Monthly",
    position: Int? = 0,
    productId: String = "com.app.monthly",
    productName: String = "Test Product",
    localizedPriceString: String = "$9.99",
    price: Decimal = 9.99,
    productType: String = "subscription"
) -> AppActorPackage {
    AppActorPackage(
        id: id,
        packageType: packageType,
        customTypeIdentifier: nil,
        productId: productId,
        localizedPriceString: localizedPriceString,
        product: nil,
        serverId: nil,
        displayName: displayName,
        metadata: nil,
        position: position,
        price: price,
        currencyCode: "USD",
        productType: productType,
        productName: productName,
        productDescription: "Description for \(productId)",
        subscriptionPeriod: nil,
        introductoryOffer: nil,
        storeProduct: nil
    )
}

/// Creates a simple `OfferingsResponseDTO` for testing.
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

// MARK: - Sendable Date Provider

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

// MARK: - Tests

final class OfferingsManagerTests: XCTestCase {

    private var client: MockPaymentClient!
    private var fetcher: MockStoreKitProductFetcher!
    private var cacheDir: URL!
    private var etagManager: AppActorETagManager!

    override func setUp() {
        super.setUp()
        client = MockPaymentClient()
        fetcher = MockStoreKitProductFetcher()

        // Isolated temp dir for disk cache tests
        cacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("appactor_test_\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        etagManager = AppActorETagManager(diskStore: AppActorCacheDiskStore(directory: cacheDir))
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: cacheDir)
        super.tearDown()
    }

    // MARK: - Empty Offerings

    func testEmptyOfferingsReturnsEmptyResult() async throws {
        client.getOfferingsHandler = { _ in
            .fresh(
                AppActorOfferingsResponseDTO(currentOffering: nil, offerings: []),
                eTag: nil,
                requestId: "req_1",
                signatureVerified: false
            )
        }

        let manager = AppActorOfferingsManager(
            client: client, productFetcher: fetcher, etagManager: etagManager
        )
        let result = try await manager.getOfferings()

        XCTAssertNil(result.current)
        XCTAssertTrue(result.all.isEmpty)
        // StoreKit should not be called for empty offerings
        XCTAssertEqual(fetcher.fetchCalls.count, 0)
    }

    func testStoreKitProductLookupUsesInjectedFetcher() async throws {
        fetcher.fetchHandler = { _ in [:] }

        let manager = AppActorOfferingsManager(
            client: client, productFetcher: fetcher, etagManager: etagManager
        )

        let product = try await manager.storeKitProduct(for: "com.app.monthly")

        XCTAssertNil(product)
        XCTAssertEqual(fetcher.fetchCalls, [Set(["com.app.monthly"])])
    }

    // MARK: - All Products Missing -> Graceful Degradation

    func testAllProductsMissingThrowsError() async throws {
        let dto = makeDTO(
            productIds: ["com.app.missing"],
            productEntitlements: ["com.app.missing": ["premium"]]
        )

        client.getOfferingsHandler = { _ in
            .fresh(dto, eTag: nil, requestId: "req_missing", signatureVerified: false)
        }
        fetcher.fetchHandler = { _ in [:] } // Return empty -- no StoreKit products

        let manager = AppActorOfferingsManager(
            client: client, productFetcher: fetcher, etagManager: etagManager
        )

        // Should throw storeKitProductsMissing when ALL products are missing
        do {
            _ = try await manager.getOfferings()
            XCTFail("Expected storeKitProductsMissing error")
        } catch let error as AppActorError {
            XCTAssertEqual(error.kind, .storeKitProductsMissing)
            XCTAssertTrue(error.message?.contains("com.app.missing") == true)
        }
    }

    func testStoreKitFetchFailureReturnsEmptyOfferings() async throws {
        let dto = makeDTO(productIds: ["com.app.monthly"])

        client.getOfferingsHandler = { _ in
            .fresh(dto, eTag: nil, requestId: "req_sk_fail", signatureVerified: false)
        }
        // StoreKit fetch itself throws (e.g. StoreKit unavailable)
        fetcher.fetchHandler = { _ in throw URLError(.notConnectedToInternet) }

        let manager = AppActorOfferingsManager(
            client: client, productFetcher: fetcher, etagManager: etagManager
        )

        // StoreKit fetch error should propagate (this is a hard failure, not "missing products")
        do {
            _ = try await manager.getOfferings()
            XCTFail("Expected error when StoreKit fetch throws")
        } catch {
            // Expected -- StoreKit unavailable is a real error
            XCTAssertTrue(error is URLError)
        }
    }

    func testBootstrapPrefetchDoesNotTriggerSecondApiRequestWhileStoreKitIsStillRunning() async throws {
        let dto = makeDTO(productIds: ["com.app.monthly"])
        let started = expectation(description: "StoreKit fetch started")

        client.getOfferingsHandler = { _ in
            .fresh(dto, eTag: "hash_prefetch", requestId: "req_prefetch", signatureVerified: false)
        }
        fetcher.fetchHandler = { _ in
            started.fulfill()
            try await Task.sleep(nanoseconds: 300_000_000)
            return [:]
        }

        let manager = AppActorOfferingsManager(
            client: client, productFetcher: fetcher, etagManager: etagManager
        )

        await manager.prefetchForBootstrap()
        await fulfillment(of: [started], timeout: 1.0)

        do {
            _ = try await manager.getOfferings()
            XCTFail("Expected storeKitProductsMissing error")
        } catch let error as AppActorError {
            XCTAssertEqual(error.kind, .storeKitProductsMissing)
        }

        XCTAssertEqual(client.getOfferingsCallCount, 1,
                       "getOfferings() should await the in-flight enrichment started by bootstrap instead of triggering a second API request")
    }

    func testBootstrapPrefetchOfflineDiskCacheDoesNotBlockOnStoreKit() async throws {
        let dto = makeDTO(productIds: ["com.app.monthly"])
        let started = expectation(description: "StoreKit fetch started from disk cache")

        await etagManager.storeFresh(dto, for: .offerings, eTag: "disk_hash")

        client.getOfferingsHandler = { _ in
            throw AppActorError.networkError(URLError(.notConnectedToInternet))
        }
        fetcher.fetchHandler = { _ in
            started.fulfill()
            try await Task.sleep(nanoseconds: 300_000_000)
            return [:]
        }

        let manager = AppActorOfferingsManager(
            client: client, productFetcher: fetcher, etagManager: etagManager
        )

        let start = Date()
        await manager.prefetchForBootstrap()
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertLessThan(elapsed, 0.1,
                          "Bootstrap prefetch should not wait for StoreKit enrichment when warming from disk cache offline")

        await fulfillment(of: [started], timeout: 1.0)

        do {
            _ = try await manager.getOfferings()
            XCTFail("Expected storeKitProductsMissing error")
        } catch let error as AppActorError {
            XCTAssertEqual(error.kind, .storeKitProductsMissing)
        }

        XCTAssertEqual(client.getOfferingsCallCount, 1,
                       "The explicit offerings() call should reuse the warmed disk-cache enrichment instead of issuing a second API request")
    }

    func testAllProductsMissingLogsErrorAndThrows() async throws {
        let dto = makeDTO(productIds: ["com.app.missing1", "com.app.missing2"])

        client.getOfferingsHandler = { _ in
            .fresh(dto, eTag: nil, requestId: "req_log", signatureVerified: false)
        }
        fetcher.fetchHandler = { _ in [:] }

        var capturedErrors: [String] = []
        AppActorLogger.level = .debug
        AppActorLogger.testSink = { level, message in
            if level == "error" { capturedErrors.append(message) }
        }
        defer {
            AppActorLogger.testSink = nil
            AppActorLogger.level = .info
        }

        let manager = AppActorOfferingsManager(
            client: client, productFetcher: fetcher, etagManager: etagManager
        )

        do {
            _ = try await manager.getOfferings()
            XCTFail("Expected storeKitProductsMissing error")
        } catch let error as AppActorError {
            XCTAssertEqual(error.kind, .storeKitProductsMissing)
        }

        let allMissingLog = capturedErrors.first { $0.contains("All StoreKit products missing") }
        XCTAssertNotNil(allMissingLog, "Should log error when all products missing")
        XCTAssertTrue(allMissingLog?.contains("com.app.missing1") == true)
        XCTAssertTrue(allMissingLog?.contains("com.app.missing2") == true)
    }

    // MARK: - Bulk SK2 Fetch Assertion (called once with all IDs)

    func testBulkFetchCalledOnceWithAllIds() async throws {
        let dto = AppActorOfferingsResponseDTO(
            currentOffering: nil,
            offerings: [
                AppActorOfferingDTO(
                    id: "o1", lookupKey: "o1", displayName: "O1",
                    isCurrent: true, metadata: nil,
                    packages: [
                        AppActorPackageDTO(
                            id: nil, packageType: "monthly", displayName: "Monthly",
                            position: 0, isActive: true, metadata: nil,
                            products: [
                                AppActorProductRefDTO(id: nil, storeProductId: "com.app.monthly", productType: "auto_renewable", displayName: nil)
                            ]
                        )
                    ]
                ),
                AppActorOfferingDTO(
                    id: "o2", lookupKey: "o2", displayName: "O2",
                    isCurrent: false, metadata: nil,
                    packages: [
                        AppActorPackageDTO(
                            id: nil, packageType: "annual", displayName: "Annual",
                            position: 0, isActive: true, metadata: nil,
                            products: [
                                AppActorProductRefDTO(id: nil, storeProductId: "com.app.annual", productType: "auto_renewable", displayName: nil)
                            ]
                        )
                    ]
                )
            ]
        )

        client.getOfferingsHandler = { _ in
            .fresh(dto, eTag: nil, requestId: "req_bulk", signatureVerified: false)
        }
        // Return empty -- all products missing. Now throws storeKitProductsMissing.
        fetcher.fetchHandler = { _ in [:] }

        let manager = AppActorOfferingsManager(
            client: client, productFetcher: fetcher, etagManager: etagManager
        )

        do {
            _ = try await manager.getOfferings()
            XCTFail("Expected storeKitProductsMissing error")
        } catch {
            // Expected — all products missing throws
        }

        XCTAssertEqual(fetcher.fetchCalls.count, 1, "StoreKit fetch should be called exactly once")
        XCTAssertEqual(fetcher.fetchCalls[0], Set(["com.app.monthly", "com.app.annual"]))
    }

    // MARK: - Cache TTL (Fresh -> No Network)

    func testCacheFreshSkipsNetwork() async throws {
        let emptyDto = AppActorOfferingsResponseDTO(currentOffering: nil, offerings: [])

        var networkCalls = 0
        client.getOfferingsHandler = { _ in
            networkCalls += 1
            return .fresh(emptyDto, eTag: nil, requestId: "req_\(networkCalls)", signatureVerified: false)
        }

        let clock = MockDateProvider()
        let manager = AppActorOfferingsManager(
            client: client, productFetcher: fetcher, etagManager: etagManager,
            dateProvider: { clock.now }
        )

        // First call -- hits network
        _ = try await manager.getOfferings()
        XCTAssertEqual(networkCalls, 1)

        // Second call 1 minute later (within 5-min TTL)
        clock.advance(by: 60)
        _ = try await manager.getOfferings()
        XCTAssertEqual(networkCalls, 1, "Fresh cache should skip network")

        // Third call 6 minutes after first (past TTL) -- SWR: returns stale, refreshes in background
        clock.advance(by: 5 * 60)
        _ = try await manager.getOfferings()
        XCTAssertEqual(networkCalls, 1, "Stale cache returns immediately (SWR), background refresh starts")
    }

    // MARK: - Single-Flight (N Calls -> 1 Network)

    func testSingleFlightCoalescing() async throws {
        let dto = AppActorOfferingsResponseDTO(currentOffering: nil, offerings: [])

        var networkCalls = 0
        client.getOfferingsHandler = { _ in
            networkCalls += 1
            // Simulate network delay
            try await Task.sleep(nanoseconds: 50_000_000) // 50ms
            return .fresh(dto, eTag: nil, requestId: "req_\(networkCalls)", signatureVerified: false)
        }

        let manager = AppActorOfferingsManager(
            client: client, productFetcher: fetcher, etagManager: etagManager
        )

        // Launch 5 concurrent calls (no cache exists yet, all hit network path)
        async let r1 = manager.getOfferings()
        async let r2 = manager.getOfferings()
        async let r3 = manager.getOfferings()
        async let r4 = manager.getOfferings()
        async let r5 = manager.getOfferings()

        let results = try await [r1, r2, r3, r4, r5]

        // All 5 should return the same result
        for result in results {
            XCTAssertTrue(result.all.isEmpty)
        }

        // But network was only called once (single-flight)
        XCTAssertEqual(networkCalls, 1, "Concurrent calls should coalesce into 1 network request")
    }

    // MARK: - requestId Tracking

    func testRequestIdTracked() async throws {
        client.getOfferingsHandler = { _ in
            .fresh(
                AppActorOfferingsResponseDTO(currentOffering: nil, offerings: []),
                eTag: nil,
                requestId: "req_offerings_42",
                signatureVerified: false
            )
        }

        let manager = AppActorOfferingsManager(
            client: client, productFetcher: fetcher, etagManager: etagManager
        )

        _ = try await manager.getOfferings()
        let rid = await manager.requestId
        XCTAssertEqual(rid, "req_offerings_42")
    }

    func testServerFilteredSingleProductContractRemainsStable() {
        let product = AppActorProductRefDTO(
            id: "prod_ios_monthly",
            storeProductId: "com.app.ios.monthly",
            productType: "subscription",
            displayName: "iOS Monthly"
        )
        let package = AppActorPackageDTO(
            id: "pkg_monthly",
            packageType: "monthly",
            displayName: "Monthly",
            position: 0,
            isActive: true,
            metadata: nil,
            tokenAmount: 120,
            products: [product]
        )
        let offering = AppActorOfferingDTO(
            id: "off_main",
            lookupKey: "main",
            displayName: "Main",
            isCurrent: true,
            metadata: nil,
            packages: [package]
        )
        let dto = AppActorOfferingsResponseDTO(
            currentOffering: offering,
            offerings: [offering],
            productEntitlements: ["com.app.ios.monthly": ["premium"]]
        )

        XCTAssertEqual(dto.currentOffering?.lookupKey, "main")
        XCTAssertEqual(dto.offerings.count, 1)
        XCTAssertEqual(dto.offerings[0].packages.count, 1)
        XCTAssertEqual(dto.offerings[0].packages[0].products.count, 1)
        XCTAssertEqual(dto.offerings[0].packages[0].products[0].storeProductId, "com.app.ios.monthly")
        XCTAssertEqual(dto.allStoreProductIds, Set(["com.app.ios.monthly"]))
        XCTAssertEqual(dto.productEntitlements?["com.app.ios.monthly"], ["premium"])
    }

    // MARK: - Disk Cache (Save + Load)

    func testDiskCacheSaveAndLoad() async throws {
        let dto = makeDTO(offeringId: "cached", productIds: ["com.app.cached"])

        // Save to disk via etagManager
        await etagManager.storeFresh(dto, for: .offerings, eTag: nil)

        // Load from disk via etagManager
        let entry = await etagManager.cached(AppActorOfferingsResponseDTO.self, for: .offerings)
        XCTAssertNotNil(entry)
        XCTAssertEqual(entry?.value.offerings.count, 1)
        XCTAssertEqual(entry?.value.offerings[0].id, "cached")
        XCTAssertEqual(entry?.value.offerings[0].packages[0].products[0].storeProductId, "com.app.cached")
    }

    func testDiskCacheClear() async {
        let dto = makeDTO()
        await etagManager.storeFresh(dto, for: .offerings, eTag: nil)
        let afterSave = await etagManager.cached(AppActorOfferingsResponseDTO.self, for: .offerings)
        XCTAssertNotNil(afterSave)

        await etagManager.clear(.offerings)
        let afterClear = await etagManager.cached(AppActorOfferingsResponseDTO.self, for: .offerings)
        XCTAssertNil(afterClear)
    }

    // MARK: - Missing Products -> Drop Package

    func testMissingProductsThrowsWhenAllMissing() async throws {
        // Two products: neither will be found by StoreKit
        let dto = AppActorOfferingsResponseDTO(
            currentOffering: nil,
            offerings: [
                AppActorOfferingDTO(
                    id: "default", lookupKey: "default", displayName: "Default",
                    isCurrent: true, metadata: nil,
                    packages: [
                        AppActorPackageDTO(
                            id: nil, packageType: "monthly", displayName: "Monthly",
                            position: 0, isActive: true, metadata: nil,
                            products: [
                                AppActorProductRefDTO(id: nil, storeProductId: "com.app.found", productType: "auto_renewable", displayName: nil)
                            ]
                        ),
                        AppActorPackageDTO(
                            id: nil, packageType: "annual", displayName: "Annual",
                            position: 1, isActive: true, metadata: nil,
                            products: [
                                AppActorProductRefDTO(id: nil, storeProductId: "com.app.notfound", productType: "auto_renewable", displayName: nil)
                            ]
                        )
                    ]
                )
            ]
        )

        client.getOfferingsHandler = { _ in
            .fresh(dto, eTag: nil, requestId: "req_partial", signatureVerified: false)
        }

        fetcher.fetchHandler = { ids in
            XCTAssertEqual(ids, Set(["com.app.found", "com.app.notfound"]))
            return [:] // No real products
        }

        let manager = AppActorOfferingsManager(
            client: client, productFetcher: fetcher, etagManager: etagManager
        )

        // All products missing -> now throws storeKitProductsMissing
        do {
            _ = try await manager.getOfferings()
            XCTFail("Expected storeKitProductsMissing error")
        } catch let error as AppActorError {
            XCTAssertEqual(error.kind, .storeKitProductsMissing)
        }
    }

    // MARK: - Inactive Packages Skipped

    func testInactivePackagesSkipped() async throws {
        let dto = AppActorOfferingsResponseDTO(
            currentOffering: nil,
            offerings: [
                AppActorOfferingDTO(
                    id: "default", lookupKey: "default", displayName: "Default",
                    isCurrent: true, metadata: nil,
                    packages: [
                        AppActorPackageDTO(
                            id: nil, packageType: "monthly", displayName: "Monthly",
                            position: 0, isActive: true, metadata: nil,
                            products: [
                                AppActorProductRefDTO(id: nil, storeProductId: "com.app.monthly", productType: "auto_renewable", displayName: nil)
                            ]
                        ),
                        AppActorPackageDTO(
                            id: nil, packageType: "legacy", displayName: "Legacy",
                            position: 1, isActive: false, metadata: nil,
                            products: [
                                AppActorProductRefDTO(id: nil, storeProductId: "com.app.legacy", productType: "auto_renewable", displayName: nil)
                            ]
                        )
                    ]
                )
            ]
        )

        // Even though both product IDs are extracted from the DTO,
        // the enrichment pipeline should skip the inactive package.
        client.getOfferingsHandler = { _ in
            .fresh(dto, eTag: nil, requestId: "req_inactive", signatureVerified: false)
        }
        fetcher.fetchHandler = { _ in [:] }

        let manager = AppActorOfferingsManager(
            client: client, productFetcher: fetcher, etagManager: etagManager
        )

        // All products missing -> now throws storeKitProductsMissing
        do {
            _ = try await manager.getOfferings()
            XCTFail("Expected storeKitProductsMissing error")
        } catch {
            // Expected — all products missing throws
        }

        // The DTO extraction includes ALL product IDs (active and inactive)
        XCTAssertEqual(fetcher.fetchCalls.count, 1)
        XCTAssertEqual(fetcher.fetchCalls[0], Set(["com.app.monthly", "com.app.legacy"]))
    }

    // MARK: - Background Mode TTL

    func testBackgroundModeLongerTTL() async throws {
        let dto = AppActorOfferingsResponseDTO(currentOffering: nil, offerings: [])

        var networkCalls = 0
        client.getOfferingsHandler = { _ in
            networkCalls += 1
            return .fresh(dto, eTag: nil, requestId: "req_\(networkCalls)", signatureVerified: false)
        }

        let clock = MockDateProvider()
        let manager = AppActorOfferingsManager(
            client: client, productFetcher: fetcher, etagManager: etagManager,
            dateProvider: { clock.now }
        )

        _ = try await manager.getOfferings()
        XCTAssertEqual(networkCalls, 1)

        // Switch to background mode
        await manager.setBackground(true)

        // 6 minutes later (past foreground TTL, within background TTL)
        clock.advance(by: 6 * 60)
        _ = try await manager.getOfferings()
        XCTAssertEqual(networkCalls, 1, "Background TTL (24h) should keep cache fresh at 6 min")

        // 25 hours later (past background TTL) -- SWR: returns stale, refreshes in background
        clock.advance(by: 25 * 60 * 60)
        _ = try await manager.getOfferings()
        XCTAssertEqual(networkCalls, 1, "Stale cache returns immediately (SWR), background refresh starts")
    }

    // MARK: - Foreground/Background TTL Toggle

    func testForegroundBackgroundTTLToggle() async throws {
        let dto = AppActorOfferingsResponseDTO(currentOffering: nil, offerings: [])

        var networkCalls = 0
        client.getOfferingsHandler = { _ in
            networkCalls += 1
            return .fresh(dto, eTag: nil, requestId: "req_\(networkCalls)", signatureVerified: false)
        }

        let clock = MockDateProvider()
        let manager = AppActorOfferingsManager(
            client: client, productFetcher: fetcher, etagManager: etagManager,
            dateProvider: { clock.now }
        )

        // Initial fetch in foreground
        _ = try await manager.getOfferings()
        XCTAssertEqual(networkCalls, 1)

        // Switch to background
        await manager.setBackground(true)

        // 10 minutes later (past foreground 5m, within background 24h) -- still cached
        clock.advance(by: 10 * 60)
        _ = try await manager.getOfferings()
        XCTAssertEqual(networkCalls, 1, "Background TTL should keep cache fresh at 10 min")

        // Switch back to foreground
        await manager.setBackground(false)

        // Same 10-minute-old cache is now stale for foreground TTL (5m) -- SWR: returns stale
        _ = try await manager.getOfferings()
        XCTAssertEqual(networkCalls, 1, "Stale cache returns immediately (SWR), background refresh starts")
    }

    // MARK: - AppActorOfferings Model

    func testOfferingsModelLookup() {
        let offering1 = AppActorOffering(
            id: "o1", displayName: "Premium", isCurrent: true,
            lookupKey: "premium", metadata: nil, packages: []
        )
        let offering2 = AppActorOffering(
            id: "o2", displayName: "Basic", isCurrent: false,
            lookupKey: "basic", metadata: nil, packages: []
        )

        let offerings = AppActorOfferings(
            current: offering1,
            all: ["o1": offering1, "o2": offering2],
            productEntitlements: [:]
        )

        XCTAssertEqual(offerings.current?.id, "o1")
        XCTAssertEqual(offerings.offering(id: "o2")?.displayName, "Basic")
        XCTAssertEqual(offerings.offering(lookupKey: "premium")?.id, "o1")
        XCTAssertNil(offerings.offering(id: "nonexistent"))
        XCTAssertNil(offerings.offering(lookupKey: "nonexistent"))
    }

    // MARK: - AppActorPackage Quick Access

    func testOfferingQuickAccess() {
        let monthly = makePackage(
            id: "o1_monthly", packageType: .monthly, displayName: "Monthly", position: 0
        )
        let annual = makePackage(
            id: "o1_annual", packageType: .annual, displayName: "Annual", position: 1
        )
        let weekly = makePackage(
            id: "o1_weekly", packageType: .weekly, displayName: "Weekly", position: 2
        )
        let lifetime = makePackage(
            id: "o1_lifetime", packageType: .lifetime, displayName: "Lifetime", position: 3
        )

        let offering = AppActorOffering(
            id: "o1", displayName: "Offering", isCurrent: true,
            lookupKey: "o1", metadata: nil,
            packages: [monthly, annual, weekly, lifetime]
        )

        XCTAssertEqual(offering.monthly?.id, "o1_monthly")
        XCTAssertEqual(offering.annual?.id, "o1_annual")
        XCTAssertEqual(offering.weekly?.id, "o1_weekly")
        XCTAssertEqual(offering.lifetime?.id, "o1_lifetime")
    }

    // MARK: - AppActorPackage Product Data

    func testPackageProductData() {
        let pkg = makePackage(
            id: "off_test",
            productId: "com.app.test",
            productName: "Test",
            localizedPriceString: "$4.99",
            price: Decimal(string: "4.99")!,
            productType: "subscription"
        )

        XCTAssertEqual(pkg.productId, "com.app.test")
        XCTAssertEqual(pkg.productName, "Test")
        XCTAssertEqual(pkg.price, Decimal(string: "4.99")!)
        XCTAssertEqual(pkg.localizedPriceString, "$4.99")
        XCTAssertEqual(pkg.currencyCode, "USD")
        XCTAssertEqual(pkg.productType, "subscription")
        XCTAssertEqual(pkg.store, .appStore)
        XCTAssertEqual(pkg.storeProductId, "com.app.test")
        XCTAssertNil(pkg.basePlanId)
        XCTAssertNil(pkg.offerId)
    }

    func testPackageEquality() {
        let a = makePackage(id: "off_same", productName: "A", price: 1.99)
        let b = makePackage(id: "off_same", productName: "B", price: 2.99)
        let c = makePackage(id: "off_different")

        XCTAssertEqual(a, b, "Equality is by ID only")
        XCTAssertNotEqual(a, c)
        XCTAssertEqual(a.hashValue, b.hashValue)
    }

    // MARK: - ETag Manager Round-Trip

    func testETagManagerRoundTrip() async throws {
        let dto = makeDTO(offeringId: "test_cache")

        // Store with eTag
        await etagManager.storeFresh(dto, for: .offerings, eTag: "hash_v1")

        // Retrieve and verify
        let entry = await etagManager.cached(AppActorOfferingsResponseDTO.self, for: .offerings)
        XCTAssertNotNil(entry)
        XCTAssertEqual(entry?.value.offerings.count, 1)
        XCTAssertEqual(entry?.value.offerings[0].id, "test_cache")
        XCTAssertNotNil(entry?.cachedAt)
        XCTAssertEqual(entry?.eTag, "hash_v1")
    }

    // MARK: - productEntitlements Passthrough

    func testProductEntitlementsPassthrough() async throws {
        let dto = makeDTO(
            productIds: ["com.app.monthly"],
            productEntitlements: ["com.app.monthly": ["premium"]]
        )

        client.getOfferingsHandler = { _ in
            .fresh(dto, eTag: nil, requestId: "req_pe", signatureVerified: false)
        }
        // StoreKit returns empty (no real products) -> will throw, but we test disk cache passthrough
        fetcher.fetchHandler = { _ in [:] }

        // Save DTO to disk cache manually to test load path
        await etagManager.storeFresh(dto, for: .offerings, eTag: nil)

        let entry = await etagManager.cached(AppActorOfferingsResponseDTO.self, for: .offerings)
        XCTAssertNotNil(entry)
        XCTAssertEqual(entry?.value.productEntitlements?["com.app.monthly"], ["premium"])
    }

    // MARK: - Conditional Caching (ETag / 304)

    func testFreshResponseSavesETagAndCache() async throws {
        let dto = AppActorOfferingsResponseDTO(currentOffering: nil, offerings: [])

        client.getOfferingsHandler = { eTag in
            XCTAssertNil(eTag, "First call should have no eTag")
            return .fresh(dto, eTag: "offerings_hash_v1", requestId: "req_1", signatureVerified: false)
        }

        let manager = AppActorOfferingsManager(
            client: client, productFetcher: fetcher, etagManager: etagManager
        )
        _ = try await manager.getOfferings()

        // Verify eTag saved to disk cache
        let entry = await etagManager.cached(AppActorOfferingsResponseDTO.self, for: .offerings)
        XCTAssertNotNil(entry)
        XCTAssertEqual(entry?.eTag, "offerings_hash_v1")
    }

    func test304ReturnsCacheAndUpdatesFetchedAt() async throws {
        let dto = AppActorOfferingsResponseDTO(currentOffering: nil, offerings: [])

        var callCount = 0
        client.getOfferingsHandler = { eTag in
            callCount += 1
            if callCount == 1 {
                return .fresh(dto, eTag: "hash_v1", requestId: "req_1", signatureVerified: false)
            }
            XCTAssertEqual(eTag, "hash_v1", "Second call should send cached eTag")
            return .notModified(eTag: "hash_v1", requestId: "req_304")
        }

        let clock = MockDateProvider()
        let manager = AppActorOfferingsManager(
            client: client, productFetcher: fetcher, etagManager: etagManager,
            dateProvider: { clock.now }
        )

        // First call -- fresh 200
        let first = try await manager.getOfferings()
        XCTAssertEqual(callCount, 1)

        let entryAfterFirst = await etagManager.cached(AppActorOfferingsResponseDTO.self, for: .offerings)
        let firstCachedAt = entryAfterFirst!.cachedAt

        // Advance past TTL to trigger a new fetch
        clock.advance(by: 10 * 60) // 10 min -- past foreground TTL
        // Clear in-memory cache to force network path
        await manager.clearCache()
        // Re-save disk cache so the manager can load eTag from it
        await etagManager.storeFresh(dto, for: .offerings, eTag: "hash_v1")

        // Second call -- 304
        let second = try await manager.getOfferings()
        XCTAssertEqual(callCount, 2)

        // Should return same offerings
        XCTAssertEqual(first.all.count, second.all.count)

        // fetchedAt should be updated
        let entryAfterSecond = await etagManager.cached(AppActorOfferingsResponseDTO.self, for: .offerings)
        XCTAssertNotNil(entryAfterSecond)
        XCTAssertGreaterThan(entryAfterSecond!.cachedAt, firstCachedAt)
        XCTAssertEqual(entryAfterSecond?.eTag, "hash_v1")
    }

    func test304CacheMissRetriesWithoutETag() async throws {
        let dto = AppActorOfferingsResponseDTO(currentOffering: nil, offerings: [])

        var callCount = 0
        client.getOfferingsHandler = { eTag in
            callCount += 1
            if callCount == 1 {
                // First call returns 304 but cache is empty
                return .notModified(eTag: "hash_v1", requestId: "req_304")
            }
            // Retry without eTag should get fresh data
            XCTAssertNil(eTag, "Retry after 304 cache-miss should NOT send eTag")
            return .fresh(dto, eTag: "repaired_hash", requestId: "req_200_repair", signatureVerified: false)
        }

        let manager = AppActorOfferingsManager(
            client: client, productFetcher: fetcher, etagManager: etagManager
        )

        // No disk cache -- 304 should trigger retry
        let result = try await manager.getOfferings()
        XCTAssertEqual(callCount, 2, "Should retry after 304 cache miss")
        XCTAssertNotNil(result)

        // Cache should be repaired with new eTag
        let entry = await etagManager.cached(AppActorOfferingsResponseDTO.self, for: .offerings)
        XCTAssertNotNil(entry)
        XCTAssertEqual(entry?.eTag, "repaired_hash")
    }

    func testConditionalDedupCoalescing() async throws {
        let dto = AppActorOfferingsResponseDTO(currentOffering: nil, offerings: [])

        var networkCalls = 0
        client.getOfferingsHandler = { _ in
            networkCalls += 1
            try await Task.sleep(nanoseconds: 50_000_000) // 50ms
            return .fresh(dto, eTag: "hash_dedup", requestId: "req_\(networkCalls)", signatureVerified: false)
        }

        let manager = AppActorOfferingsManager(
            client: client, productFetcher: fetcher, etagManager: etagManager
        )

        async let r1 = manager.getOfferings()
        async let r2 = manager.getOfferings()

        _ = try await [r1, r2]
        XCTAssertEqual(networkCalls, 1, "Concurrent calls should coalesce into 1 HTTP request")
    }

    func test304KeepsETagFromServer() async throws {
        let dto = AppActorOfferingsResponseDTO(currentOffering: nil, offerings: [])

        var callCount = 0
        client.getOfferingsHandler = { eTag in
            callCount += 1
            if callCount == 1 {
                return .fresh(dto, eTag: "hash_v1", requestId: "req_1", signatureVerified: false)
            }
            // Server rotates eTag on 304
            return .notModified(eTag: "hash_v2_rotated", requestId: "req_304")
        }

        let clock = MockDateProvider()
        let manager = AppActorOfferingsManager(
            client: client, productFetcher: fetcher, etagManager: etagManager,
            dateProvider: { clock.now }
        )

        // First call -- fresh 200
        _ = try await manager.getOfferings()
        let entryV1 = await etagManager.cached(AppActorOfferingsResponseDTO.self, for: .offerings)
        XCTAssertEqual(entryV1?.eTag, "hash_v1")

        // Advance past TTL and clear in-memory to force network
        clock.advance(by: 10 * 60)
        await manager.clearCache()
        await etagManager.storeFresh(dto, for: .offerings, eTag: "hash_v1")

        // Second call -- 304 with rotated eTag
        _ = try await manager.getOfferings()

        // SDK should store the new eTag from the 304
        let entryV2 = await etagManager.cached(AppActorOfferingsResponseDTO.self, for: .offerings)
        XCTAssertEqual(entryV2?.eTag, "hash_v2_rotated", "SDK should store eTag from 304 response")
    }
}
