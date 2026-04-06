import XCTest
@testable import AppActor

// MARK: - Helpers

private func makeDTOs(_ configs: [(String, AppActorConfigValue, String)]) -> [AppActorRemoteConfigItemDTO] {
    configs.map { AppActorRemoteConfigItemDTO(key: $0.0, value: $0.1, valueType: $0.2) }
}

// MARK: - Tests

final class RemoteConfigManagerTests: XCTestCase {

    private let defaultUserId = "user_123"

    private var client: MockPaymentClient!
    private var etagManager: AppActorETagManager!
    private var currentDate: Date!
    private var manager: AppActorRemoteConfigManager!

    override func setUp() {
        super.setUp()
        client = MockPaymentClient()
        etagManager = AppActorETagManager()
        currentDate = Date()
        manager = AppActorRemoteConfigManager(
            client: client,
            etagManager: etagManager,
            dateProvider: { [unowned self] in self.currentDate }
        )
    }

    // MARK: - Basic Fetch

    func testFreshFetchReturnsItems() async throws {
        let dtos = makeDTOs([
            ("has_rating", .bool(true), "boolean"),
            ("min_version", .string("2.0.0"), "string"),
            ("max_retries", .int(5), "number"),
        ])
        client.getRemoteConfigsHandler = { _, _, _, _ in
            .fresh(dtos, eTag: "etag_1", requestId: "req_1", signatureVerified: false)
        }

        let configs = try await manager.getRemoteConfigs(appUserId: defaultUserId, appVersion: nil, country: nil)

        XCTAssertEqual(configs.items.count, 3)
        XCTAssertEqual(configs["has_rating"]?.boolValue, true)
        XCTAssertEqual(configs["min_version"]?.stringValue, "2.0.0")
        XCTAssertEqual(configs["max_retries"]?.intValue, 5)
    }

    // MARK: - TTL Cache

    func testReturnsCachedWithinTTL() async throws {
        let dtos = makeDTOs([("flag", .bool(true), "boolean")])
        client.getRemoteConfigsHandler = { _, _, _, _ in
            .fresh(dtos, eTag: "etag_1", requestId: "req_1", signatureVerified: false)
        }

        // First call: fetches from network
        _ = try await manager.getRemoteConfigs(appUserId: defaultUserId, appVersion: nil, country: nil)
        XCTAssertEqual(client.getRemoteConfigsCalls.count, 1)

        // Advance 2 minutes (within 5min TTL)
        currentDate = currentDate.addingTimeInterval(120)

        // Second call: returns from cache, no network call
        let cached = try await manager.getRemoteConfigs(appUserId: defaultUserId, appVersion: nil, country: nil)
        XCTAssertEqual(client.getRemoteConfigsCalls.count, 1) // Still 1
        XCTAssertEqual(cached["flag"]?.boolValue, true)
    }

    func testRefetchesAfterTTLExpiry() async throws {
        let dtos = makeDTOs([("flag", .bool(true), "boolean")])
        client.getRemoteConfigsHandler = { _, _, _, _ in
            .fresh(dtos, eTag: "etag_1", requestId: "req_1", signatureVerified: false)
        }

        _ = try await manager.getRemoteConfigs(appUserId: defaultUserId, appVersion: nil, country: nil)
        XCTAssertEqual(client.getRemoteConfigsCalls.count, 1)

        // Advance 6 minutes (past 5min TTL)
        currentDate = currentDate.addingTimeInterval(360)

        _ = try await manager.getRemoteConfigs(appUserId: defaultUserId, appVersion: nil, country: nil)
        XCTAssertEqual(client.getRemoteConfigsCalls.count, 2)
    }

    // MARK: - 304 Not Modified

    func testNotModifiedReturnsInMemoryCache() async throws {
        let dtos = makeDTOs([("flag", .bool(true), "boolean")])
        var callCount = 0
        client.getRemoteConfigsHandler = { _, _, _, _ in
            callCount += 1
            if callCount == 1 {
                return .fresh(dtos, eTag: "etag_1", requestId: "req_1", signatureVerified: false)
            }
            return .notModified(eTag: "etag_1", requestId: "req_2")
        }

        // First call: fresh
        _ = try await manager.getRemoteConfigs(appUserId: nil, appVersion: nil, country: nil)

        // Expire TTL
        currentDate = currentDate.addingTimeInterval(360)

        // Second call: 304, should return cached
        let result = try await manager.getRemoteConfigs(appUserId: defaultUserId, appVersion: nil, country: nil)
        XCTAssertEqual(result["flag"]?.boolValue, true)
        XCTAssertEqual(callCount, 2)
    }

    // MARK: - Clear Cache

    func testClearCacheRemovesInMemoryState() async throws {
        let dtos = makeDTOs([("flag", .bool(true), "boolean")])
        client.getRemoteConfigsHandler = { _, _, _, _ in
            .fresh(dtos, eTag: "etag_1", requestId: "req_1", signatureVerified: false)
        }

        _ = try await manager.getRemoteConfigs(appUserId: defaultUserId, appVersion: nil, country: nil)
        let cached = await manager.cached
        XCTAssertNotNil(cached)

        await manager.clearCache(appUserId: defaultUserId)
        let after = await manager.cached
        XCTAssertNil(after)
    }

    // MARK: - Query Params Forwarding

    func testPassesQueryParamsToClient() async throws {
        _ = try await manager.getRemoteConfigs(
            appUserId: "user_123",
            appVersion: "2.1.0",
            country: "TR"
        )

        XCTAssertEqual(client.getRemoteConfigsCalls.count, 1)
        let call = client.getRemoteConfigsCalls[0]
        XCTAssertEqual(call.appUserId, "user_123")
        XCTAssertEqual(call.appVersion, "2.1.0")
        XCTAssertEqual(call.country, "TR")
    }

    // MARK: - Value Type Parsing

    func testConfigValueTypes() async throws {
        let dtos = makeDTOs([
            ("bool_flag", .bool(false), "boolean"),
            ("str_flag", .string("hello"), "string"),
            ("int_flag", .int(42), "number"),
            ("double_flag", .double(3.14), "number"),
        ])
        client.getRemoteConfigsHandler = { _, _, _, _ in
            .fresh(dtos, eTag: nil, requestId: nil, signatureVerified: false)
        }

        let configs = try await manager.getRemoteConfigs(appUserId: defaultUserId, appVersion: nil, country: nil)

        XCTAssertEqual(configs["bool_flag"]?.boolValue, false)
        XCTAssertEqual(configs["str_flag"]?.stringValue, "hello")
        XCTAssertEqual(configs["int_flag"]?.intValue, 42)
        XCTAssertEqual(configs["double_flag"]?.doubleValue, 3.14)

        // Cross-type coercion
        XCTAssertEqual(configs["int_flag"]?.doubleValue, 42.0) // Int → Double
        XCTAssertNil(configs["double_flag"]?.intValue) // 3.14 is not a whole number

        // Wrong type returns nil
        XCTAssertNil(configs["bool_flag"]?.stringValue)
        XCTAssertNil(configs["str_flag"]?.boolValue)
    }

    // MARK: - Empty Response

    func testEmptyResponseReturnsEmptyConfigs() async throws {
        client.getRemoteConfigsHandler = { _, _, _, _ in
            .fresh([], eTag: nil, requestId: nil, signatureVerified: false)
        }

        let configs = try await manager.getRemoteConfigs(appUserId: nil, appVersion: nil, country: nil)
        XCTAssertEqual(configs.items.count, 0)
        XCTAssertNil(configs["anything"])
    }

    // MARK: - ETag Forwarding

    func testSendsETagOnSubsequentCalls() async throws {
        // Clear any disk-persisted eTag from previous test runs
        await etagManager.clear(.remoteConfigs(appUserId: defaultUserId))

        let dtos = makeDTOs([("flag", .bool(true), "boolean")])
        client.getRemoteConfigsHandler = { _, _, _, _ in
            .fresh(dtos, eTag: "etag_abc", requestId: "req_1", signatureVerified: false)
        }

        // First call: no eTag
        _ = try await manager.getRemoteConfigs(appUserId: defaultUserId, appVersion: nil, country: nil)
        XCTAssertNil(client.getRemoteConfigsCalls[0].eTag)

        // Expire TTL
        currentDate = currentDate.addingTimeInterval(360)

        // Second call: should send cached eTag
        _ = try await manager.getRemoteConfigs(appUserId: defaultUserId, appVersion: nil, country: nil)
        XCTAssertEqual(client.getRemoteConfigsCalls[1].eTag, "etag_abc")
    }

    // MARK: - Request ID Tracking

    func testTracksLastRequestId() async throws {
        client.getRemoteConfigsHandler = { _, _, _, _ in
            .fresh([], eTag: nil, requestId: "req_xyz", signatureVerified: false)
        }

        _ = try await manager.getRemoteConfigs(appUserId: defaultUserId, appVersion: nil, country: nil)
        let rid = await manager.requestId
        XCTAssertEqual(rid, "req_xyz")
    }

    func testDiskFallbackDoesNotLeakAnotherUsersRemoteConfigCache() async throws {
        let cachedDTOs = makeDTOs([("from_old_user", .string("A"), "string")])
        await etagManager.storeFresh(
            cachedDTOs,
            for: .remoteConfigs(appUserId: "user_A"),
            eTag: "etag_user_A"
        )
        client.getRemoteConfigsHandler = { _, _, _, _ in
            throw AppActorError.networkError(URLError(.notConnectedToInternet))
        }

        do {
            _ = try await manager.getRemoteConfigs(appUserId: "user_B", appVersion: nil, country: nil)
            XCTFail("Expected user-scoped disk fallback to miss for a different user")
        } catch let error as AppActorError {
            XCTAssertEqual(error.kind, .network)
        }
    }
}
