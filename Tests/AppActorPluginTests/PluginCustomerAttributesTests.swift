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

    private func parseEnvelope(_ json: String) throws -> [String: Any] {
        let data = Data(json.utf8)
        let object = try JSONSerialization.jsonObject(with: data)
        return try XCTUnwrap(object as? [String: Any])
    }
}
