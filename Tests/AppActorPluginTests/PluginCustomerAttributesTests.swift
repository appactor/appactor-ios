import XCTest
@testable import AppActor
@testable import AppActorPlugin

private final class PluginAttributesTestStorage: AppActorPaymentStorage, @unchecked Sendable {
    private var store: [String: String] = [:]
    private let lock = NSLock()

    func string(forKey key: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return store[key]
    }

    func set(_ value: String?, forKey key: String) {
        lock.lock()
        defer { lock.unlock() }
        if let value {
            store[key] = value
        } else {
            store.removeValue(forKey: key)
        }
    }

    func remove(forKey key: String) {
        lock.lock()
        defer { lock.unlock() }
        store.removeValue(forKey: key)
    }
}

private final class PluginAttributesTestClient: AppActorPaymentClientProtocol, @unchecked Sendable {
    private let queue = DispatchQueue(label: "plugin.attributes.client")

    private var _attributeCalls: [(String, AppActorSetAttributesRequest)] = []
    var attributeCalls: [(String, AppActorSetAttributesRequest)] { queue.sync { _attributeCalls } }

    private var _attributionCalls: [(String, AppActorUpdateAttributionRequest)] = []
    var attributionCalls: [(String, AppActorUpdateAttributionRequest)] { queue.sync { _attributionCalls } }

    func identify(_ request: AppActorIdentifyRequest) async throws -> AppActorIdentifyResult {
        AppActorIdentifyResult(appUserId: request.appUserId, customerInfo: AppActorCustomerInfo(appUserId: request.appUserId), customerETag: nil, requestId: nil, signatureVerified: false)
    }

    func login(_ request: AppActorLoginRequest) async throws -> AppActorLoginResult {
        AppActorLoginResult(appUserId: request.newAppUserId, customerInfo: AppActorCustomerInfo(appUserId: request.newAppUserId), customerETag: nil, requestId: nil, signatureVerified: false)
    }

    func getOfferings(eTag: String?) async throws -> AppActorOfferingsFetchResult {
        .fresh(AppActorOfferingsResponseDTO(currentOffering: nil, offerings: []), eTag: nil, requestId: nil, signatureVerified: false)
    }

    func getCustomer(appUserId: String, eTag: String?) async throws -> AppActorCustomerFetchResult {
        .fresh(AppActorCustomerInfo(appUserId: appUserId), eTag: nil, requestId: nil, signatureVerified: false)
    }

    func getRemoteConfigs(appUserId: String?, appVersion: String?, country: String?, eTag: String?) async throws -> AppActorRemoteConfigFetchResult {
        .fresh([], eTag: nil, requestId: nil, signatureVerified: false)
    }

    func postReceipt(_ request: AppActorReceiptPostRequest) async throws -> AppActorReceiptPostResponse {
        AppActorReceiptPostResponse(status: "ok", requestId: nil)
    }

    func postRestore(_ request: AppActorRestoreRequest) async throws -> AppActorRestoreResult {
        AppActorRestoreResult(customerInfo: AppActorCustomerInfo(appUserId: request.appUserId), restoredCount: 0, transferred: false, requestId: nil, customerETag: nil, signatureVerified: false)
    }

    func patchAttributes(appUserId: String, request: AppActorSetAttributesRequest) async throws -> AppActorMutationResult {
        queue.sync { _attributeCalls.append((appUserId, request)) }
        return AppActorMutationResult(requestId: nil)
    }

    func deleteAttribute(appUserId: String, key: String) async throws -> AppActorMutationResult {
        AppActorMutationResult(requestId: nil)
    }

    func patchIntegrationIdentifiers(appUserId: String, request: AppActorSetIntegrationIdentifiersRequest) async throws -> AppActorMutationResult {
        AppActorMutationResult(requestId: nil)
    }

    func deleteIntegrationIdentifier(appUserId: String, key: String) async throws -> AppActorMutationResult {
        AppActorMutationResult(requestId: nil)
    }

    func patchAttribution(appUserId: String, request: AppActorUpdateAttributionRequest) async throws -> AppActorMutationResult {
        queue.sync { _attributionCalls.append((appUserId, request)) }
        return AppActorMutationResult(requestId: nil)
    }

    func postExperimentAssignment(experimentKey: String, appUserId: String, appVersion: String?, country: String?) async throws -> AppActorExperimentFetchResult {
        fatalError("unused")
    }

    func postASAAttribution(_ request: AppActorASAAttributionRequest) async throws -> AppActorASAAttributionResponseDTO {
        fatalError("unused")
    }

    func postASAPurchaseEvent(_ request: AppActorASAPurchaseEventRequest) async throws -> AppActorASAPurchaseEventResponseDTO {
        fatalError("unused")
    }
}

@MainActor
final class PluginCustomerAttributesTests: XCTestCase {
    private var client: PluginAttributesTestClient!
    private var storage: PluginAttributesTestStorage!

    override func setUp() {
        super.setUp()
        client = PluginAttributesTestClient()
        storage = PluginAttributesTestStorage()
        let config = AppActorPaymentConfiguration(
            apiKey: "pk_test_plugin_attrs",
            baseURL: URL(string: "https://api.test.appactor.com")!
        )
        AppActor.shared.configureForTesting(config: config, client: client, storage: storage)
    }

    override func tearDown() async throws {
        await AppActor.shared.reset()
        client = nil
        storage = nil
        try await super.tearDown()
    }

    func testSetAttributeRequestRoutesToNativeSDK() async throws {
        let json = await AppActorPlugin.shared.execute(
            method: "set_attribute",
            withJson: #"{"key":"tier","value":"gold"}"#
        )
        let envelope = try parseEnvelope(json)

        XCTAssertEqual(envelope["success"] as? Bool, true)
        XCTAssertEqual(client.attributeCalls.last?.1.attributes["tier"], .string("gold"))
    }

    func testUpdateAttributionRequestRoutesToNativeSDK() async throws {
        let json = await AppActorPlugin.shared.execute(
            method: "update_attribution",
            withJson: #"{"attribution":{"network":"apple_search_ads","campaign":"Launch","metadata":{"keyword":"swift"}}}"#
        )
        let envelope = try parseEnvelope(json)

        XCTAssertEqual(envelope["success"] as? Bool, true)
        XCTAssertEqual(client.attributionCalls.last?.1.attribution.network, "apple_search_ads")
        XCTAssertEqual(client.attributionCalls.last?.1.attribution.metadata["keyword"], .string("swift"))
    }

    func testCollectProfileContextRequestRoutesToNativeSDK() async throws {
        let json = await AppActorPlugin.shared.execute(
            method: "collect_profile_context",
            withJson: #"{}"#
        )
        let envelope = try parseEnvelope(json)
        let attributes = try XCTUnwrap(client.attributeCalls.last?.1.attributes)

        XCTAssertEqual(envelope["success"] as? Bool, true)
        XCTAssertEqual(attributes[AppActorAttributeKey.sdkVersion], .string(AppActorSDK.version))
        XCTAssertEqual(attributes[AppActorAttributeKey.platform], .string("macos"))
        XCTAssertNotNil(attributes[AppActorAttributeKey.locale])
        XCTAssertNotNil(attributes[AppActorAttributeKey.timezone])
        XCTAssertNil(attributes[AppActorAttributeKey.idfv])
    }

    func testUpdateAttributionRequestPreservesSnakeCaseAcquisitionFields() async throws {
        let json = await AppActorPlugin.shared.execute(
            method: "update_attribution",
            withJson: #"{"provider":"custom","provider_name":"facebook","campaign_id":"cmp_123","campaign_name":"Spring","ad_group":"Retargeting","click_id":"click_123","attributed_at":"2026-05-16T12:00:00.000Z"}"#
        )
        let envelope = try parseEnvelope(json)
        let attribution = try XCTUnwrap(client.attributionCalls.last?.1.attribution)

        XCTAssertEqual(envelope["success"] as? Bool, true)
        XCTAssertEqual(attribution.provider, "custom")
        XCTAssertEqual(attribution.providerName, "facebook")
        XCTAssertEqual(attribution.campaignId, "cmp_123")
        XCTAssertEqual(attribution.campaignName, "Spring")
        XCTAssertEqual(attribution.campaign, "Spring")
        XCTAssertEqual(attribution.adGroup, "Retargeting")
        XCTAssertEqual(attribution.clickId, "click_123")
        XCTAssertEqual(attribution.attributedAt, "2026-05-16T12:00:00.000Z")
    }

    func testAttributionHelperRequestsRouteThroughNativeMergeState() async throws {
        let mediaSource = await AppActorPlugin.shared.execute(
            method: "set_media_source",
            withJson: #"{"value":"facebook"}"#
        )
        let campaign = await AppActorPlugin.shared.execute(
            method: "set_campaign",
            withJson: #"{"value":"spring_sale"}"#
        )
        let mediaSourceEnvelope = try parseEnvelope(mediaSource)
        let campaignEnvelope = try parseEnvelope(campaign)
        let attribution = try XCTUnwrap(client.attributionCalls.last?.1.attribution)

        XCTAssertEqual(mediaSourceEnvelope["success"] as? Bool, true)
        XCTAssertEqual(campaignEnvelope["success"] as? Bool, true)
        XCTAssertEqual(attribution.provider, "custom")
        XCTAssertEqual(attribution.providerName, "facebook")
        XCTAssertEqual(attribution.network, "facebook")
        XCTAssertEqual(attribution.source, "facebook")
        XCTAssertEqual(attribution.campaignName, "spring_sale")
        XCTAssertEqual(attribution.campaign, "spring_sale")
    }

    private func parseEnvelope(_ json: String) throws -> [String: Any] {
        let data = Data(json.utf8)
        let object = try JSONSerialization.jsonObject(with: data)
        return try XCTUnwrap(object as? [String: Any])
    }
}
