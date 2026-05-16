import XCTest
@testable import AppActor

@MainActor
final class CustomerAttributesTests: XCTestCase {

    private var appactor: AppActor!
    private var client: MockPaymentClient!
    private var storage: InMemoryPaymentStorage!

    override func setUp() {
        super.setUp()
        appactor = AppActor.shared
        client = MockPaymentClient()
        storage = InMemoryPaymentStorage()

        let config = AppActorPaymentConfiguration(
            apiKey: "pk_test_attributes",
            baseURL: URL(string: "https://api.test.appactor.com")!
        )
        appactor.configureForTesting(config: config, client: client, storage: storage)
    }

    override func tearDown() async throws {
        await appactor.reset()
        appactor = nil
        client = nil
        storage = nil
        try await super.tearDown()
    }

    func testAttributeDTOEncodesJSONCompatibleValues() throws {
        let date = Date(timeIntervalSince1970: 0)
        let request = AppActorSetAttributesRequest(attributes: [
            "name": .string("Ada"),
            "age": .number(42),
            "subscriber": .bool(true),
            "created_at": .date(date),
            "tags": .array([.string("ios"), .number(2), .bool(false)]),
        ])

        let data = try JSONEncoder().encode(request)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let attributes = try XCTUnwrap(object["attributes"] as? [String: Any])

        XCTAssertEqual(attributes["name"] as? String, "Ada")
        XCTAssertEqual(attributes["age"] as? Double, 42)
        XCTAssertEqual(attributes["subscriber"] as? Bool, true)
        let createdAt = try XCTUnwrap(attributes["created_at"] as? [String: Any])
        XCTAssertEqual(createdAt["value"] as? String, "1970-01-01T00:00:00.000Z")
        XCTAssertEqual(createdAt["valueType"] as? String, "date")
        let tags = try XCTUnwrap(attributes["tags"] as? [Any])
        XCTAssertEqual(tags[0] as? String, "ios")
        XCTAssertEqual(tags[1] as? Double, 2)
        XCTAssertEqual(tags[2] as? Bool, false)
    }

    func testAttributionConvenienceFieldsEncodeCanonicalBackendKeys() throws {
        let attribution = AppActorAttribution(
            network: "apple_search_ads",
            source: "search",
            medium: "paid",
            campaign: "Launch",
            adGroup: "Brand",
            ad: "Hero",
            keyword: "watch faces",
            creative: "Video",
            clickId: "click-123"
        )

        let data = try JSONEncoder().encode(attribution)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(object["provider"] as? String, "apple_search_ads")
        XCTAssertEqual(object["network"] as? String, "apple_search_ads")
        XCTAssertEqual(object["source"] as? String, "search")
        XCTAssertEqual(object["medium"] as? String, "paid")
        XCTAssertEqual(object["campaign"] as? String, "Launch")
        XCTAssertEqual(object["ad_group"] as? String, "Brand")
        XCTAssertEqual(object["ad"] as? String, "Hero")
        XCTAssertEqual(object["keyword"] as? String, "watch faces")
        XCTAssertEqual(object["creative"] as? String, "Video")
        XCTAssertEqual(object["click_id"] as? String, "click-123")
    }

    func testCustomKeysRejectReservedPrefixesAndHelpersMapReservedKeys() async throws {
        try await appactor.setEmail("ada@example.com")

        let call = try XCTUnwrap(client.patchAttributesCalls.last)
        XCTAssertEqual(call.request.attributes[AppActorAttributeKey.email], .string("ada@example.com"))

        await XCTAssertThrowsErrorAsync(try await appactor.setAttribute("$email", value: "bad")) { error in
            XCTAssertEqual((error as? AppActorError)?.kind, .validation)
        }
        await XCTAssertThrowsErrorAsync(try await appactor.setAttribute("appactor.plan", value: "bad")) { error in
            XCTAssertEqual((error as? AppActorError)?.kind, .validation)
        }
        await XCTAssertThrowsErrorAsync(try await appactor.setAttribute("bad key", value: "bad")) { error in
            XCTAssertEqual((error as? AppActorError)?.kind, .validation)
        }
        await XCTAssertThrowsErrorAsync(try await appactor.setAttribute("bad/key", value: "bad")) { error in
            XCTAssertEqual((error as? AppActorError)?.kind, .validation)
        }
    }

    func testQueueCoalescesTransientFailuresAndFlushesLatestValues() async throws {
        let offline = AppActorError.networkError(URLError(.notConnectedToInternet))
        client.patchAttributesHandler = { _, _ in throw offline }

        try await appactor.setAttribute("plan", value: "free")
        try await appactor.setAttribute("plan", value: "pro")
        try await appactor.unsetAttribute("legacy")

        let appUserId = try XCTUnwrap(storage.currentAppUserId)
        var pending = try XCTUnwrap(appactor.customerAttributesManager.pendingBucket(appUserId: appUserId))
        XCTAssertEqual(pending.attributes["plan"], .string("pro"))
        XCTAssertEqual(pending.unsetAttributeKeys, ["legacy"])

        client.patchAttributesHandler = nil
        try await appactor.flushPendingCustomerAttributeWritesForCurrentUser()

        pending = appactor.customerAttributesManager.pendingBucket(appUserId: appUserId) ?? .init()
        XCTAssertTrue(pending.isEmpty)
        XCTAssertEqual(client.patchAttributesCalls.last?.request.attributes["plan"], .string("pro"))
        XCTAssertEqual(client.deleteAttributeCalls.last?.key, "legacy")
    }

    func testFlushPreservesConcurrentAttributeMutationForSameKey() async throws {
        let manager = appactor.customerAttributesManager
        let injectionState = AttributeFlushInjectionState()
        client.patchAttributesHandler = { appUserId, request in
            guard
                injectionState.shouldInject(),
                request.attributes["plan"] == .string("free")
            else {
                return AppActorMutationResult(requestId: "req_mock_attributes")
            }

            try manager.enqueueAttributes(
                appUserId: appUserId,
                attributes: ["plan": .string("pro")]
            )
            return AppActorMutationResult(requestId: "req_mock_attributes")
        }

        try await appactor.setAttribute("plan", value: "free")

        XCTAssertEqual(client.patchAttributesCalls.count, 2)
        XCTAssertEqual(client.patchAttributesCalls[0].request.attributes["plan"], .string("free"))
        XCTAssertEqual(client.patchAttributesCalls[1].request.attributes["plan"], .string("pro"))

        let appUserId = try XCTUnwrap(storage.currentAppUserId)
        let pending = appactor.customerAttributesManager.pendingBucket(appUserId: appUserId) ?? .init()
        XCTAssertTrue(pending.isEmpty)
    }

    func testQueuedAnonymousAttributesFlushBeforeLoginWithOldIdentity() async throws {
        storage.setAppUserId("anon_user")
        let offline = AppActorError.networkError(URLError(.notConnectedToInternet))
        client.patchAttributesHandler = { _, _ in throw offline }

        try await appactor.setEmail("anon@example.com")

        client.patchAttributesHandler = nil
        client.loginHandler = { request in
            XCTAssertEqual(request.currentAppUserId, "anon_user")
            return AppActorLoginResult(
                appUserId: "identified_user",
                customerInfo: AppActorCustomerInfo(appUserId: "identified_user"),
                customerETag: nil,
                requestId: "req_login",
                signatureVerified: false
            )
        }

        _ = try await appactor.logIn(newAppUserId: "identified_user")

        XCTAssertEqual(storage.currentAppUserId, "identified_user")
        XCTAssertEqual(client.patchAttributesCalls.map(\.appUserId), ["anon_user", "anon_user"])
        XCTAssertFalse(client.patchAttributesCalls.contains { call in
            call.appUserId == "identified_user" && call.request.attributes[AppActorAttributeKey.email] != nil
        })
    }

    func testIntegrationIdentifierAndAttributionUseSeparateQueues() async throws {
        try await appactor.setIntegrationIdentifier("firebase_app_instance_id", value: "fid_123")
        try await appactor.updateAttribution(
            network: "apple_search_ads",
            campaign: "Launch",
            metadata: ["source_detail": "exact"]
        )

        XCTAssertEqual(
            client.patchIntegrationIdentifiersCalls.last?.request.integrationIdentifiers["firebase_app_instance_id"],
            "fid_123"
        )
        XCTAssertEqual(client.patchAttributionCalls.last?.request.attribution.network, "apple_search_ads")
        XCTAssertEqual(client.patchAttributionCalls.last?.request.attribution.metadata["source_detail"], .string("exact"))
    }
}

private final class AttributeFlushInjectionState: @unchecked Sendable {
    private let lock = NSLock()
    private var didInject = false

    func shouldInject() -> Bool {
        lock.withLock {
            guard !didInject else { return false }
            didInject = true
            return true
        }
    }
}

private func XCTAssertThrowsErrorAsync(
    _ expression: @autoclosure () async throws -> Void,
    _ handler: (Error) -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected error to be thrown", file: file, line: line)
    } catch {
        handler(error)
    }
}
