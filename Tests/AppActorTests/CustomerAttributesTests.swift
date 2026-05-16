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
            "tags": .array([.string("ios"), .string("watch")]),
            "flags": .array([.bool(true), .bool(false)]),
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
        XCTAssertEqual(tags[1] as? String, "watch")
        let flags = try XCTUnwrap(attributes["flags"] as? [Any])
        XCTAssertEqual(flags[0] as? Bool, true)
        XCTAssertEqual(flags[1] as? Bool, false)
    }

    func testAttributeValueDecodesDateEnvelopeFromPluginPayload() throws {
        let data = #"{"value":"1970-01-01T00:00:00.000Z","valueType":"date"}"#.data(using: .utf8)!
        let value = try JSONDecoder().decode(AppActorAttributeValue.self, from: data)

        XCTAssertEqual(value, .date(Date(timeIntervalSince1970: 0)))
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

    func testAttributeArraysRejectMixedValuesAndDates() async throws {
        await XCTAssertThrowsErrorAsync(try await appactor.setAttribute("mixed", value: .array([.string("a"), .number(1)]))) { error in
            XCTAssertEqual((error as? AppActorError)?.kind, .validation)
        }
        await XCTAssertThrowsErrorAsync(try await appactor.setAttribute("dates", value: .array([.date(Date())]))) { error in
            XCTAssertEqual((error as? AppActorError)?.kind, .validation)
        }
    }

    func testEmailAndPhoneHelpersValidateFormats() async throws {
        await XCTAssertThrowsErrorAsync(try await appactor.setEmail("bad-email")) { error in
            XCTAssertEqual((error as? AppActorError)?.kind, .validation)
        }
        await XCTAssertThrowsErrorAsync(try await appactor.setPhoneNumber("abc")) { error in
            XCTAssertEqual((error as? AppActorError)?.kind, .validation)
        }
    }

    func testCollectDeviceIdentifiersSendsSystemAttributes() async throws {
        try await appactor.collectDeviceIdentifiers()

        let attributes = try XCTUnwrap(client.patchAttributesCalls.last?.request.attributes)
        XCTAssertEqual(attributes[AppActorAttributeKey.sdkVersion], .string(AppActorSDK.version))
        XCTAssertEqual(attributes[AppActorAttributeKey.platform], .string("macos"))
        XCTAssertNotNil(attributes[AppActorAttributeKey.locale])
        XCTAssertNotNil(attributes[AppActorAttributeKey.timezone])
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

	func testRevenueCatStyleIntegrationAndAttributionHelpers() async throws {
		try await appactor.setAppsflyerID("af_123")
		try await appactor.setAdjustID("adj_123")
		try await appactor.setMediaSource("facebook")
		try await appactor.setCampaign("spring_sale")

        XCTAssertEqual(
            client.patchIntegrationIdentifiersCalls.map { $0.request.integrationIdentifiers },
            [
                ["appsflyer_id": "af_123"],
                ["adjust_adid": "adj_123"],
            ]
        )
        XCTAssertEqual(client.patchAttributionCalls[0].request.attribution.provider, "custom")
        XCTAssertEqual(client.patchAttributionCalls[0].request.attribution.providerName, "facebook")
        XCTAssertEqual(client.patchAttributionCalls[0].request.attribution.network, "facebook")
        XCTAssertEqual(client.patchAttributionCalls[0].request.attribution.source, "facebook")
		XCTAssertEqual(client.patchAttributionCalls[1].request.attribution.provider, "custom")
		XCTAssertEqual(client.patchAttributionCalls[1].request.attribution.campaignName, "spring_sale")
		XCTAssertEqual(client.patchAttributionCalls[1].request.attribution.campaign, "spring_sale")
	}

	func testAttributionCanonicalFieldsValidateBeforeSending() async throws {
		await XCTAssertThrowsErrorAsync(
			try await appactor.updateAttribution(AppActorAttribution(
				provider: "custom",
				providerName: " facebook"
			))
		) { error in
			XCTAssertTrue(String(describing: error).contains("provider_name"))
		}

		await XCTAssertThrowsErrorAsync(
			try await appactor.updateAttribution(AppActorAttribution(
				provider: String(repeating: "x", count: 65),
				campaignName: "spring"
			))
		) { error in
			XCTAssertTrue(String(describing: error).contains("provider"))
		}

		await XCTAssertThrowsErrorAsync(
			try await appactor.updateAttribution(AppActorAttribution(
				provider: "custom",
				campaignName: String(repeating: "x", count: 1_025)
			))
		) { error in
			XCTAssertTrue(String(describing: error).contains("campaign_name"))
		}
		XCTAssertTrue(client.patchAttributionCalls.isEmpty)
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
