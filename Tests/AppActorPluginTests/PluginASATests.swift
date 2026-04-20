import XCTest
@testable import AppActor
@testable import AppActorPlugin

private struct PluginASATestError: Error {}

private final class PluginASATestStorage: AppActorPaymentStorage, @unchecked Sendable {
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

private final class PluginASATestEventStore: AppActorASAEventStoreProtocol, @unchecked Sendable {
    private var events: [AppActorASAStoredEvent] = []
    private let lock = NSLock()

    func enqueue(_ event: AppActorASAStoredEvent) {
        lock.lock()
        defer { lock.unlock() }
        events.append(event)
    }

    func pending() -> [AppActorASAStoredEvent] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }

    func remove(id: String) {
        lock.lock()
        defer { lock.unlock() }
        events.removeAll { $0.id == id }
    }

    func update(_ event: AppActorASAStoredEvent) {
        lock.lock()
        defer { lock.unlock() }
        guard let index = events.firstIndex(where: { $0.id == event.id }) else { return }
        events[index] = event
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        events.removeAll()
    }

    func count() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return events.count
    }
}

private struct PluginASATestTokenProvider: AppActorASATokenProviderProtocol {
    func attributionToken() async -> AppActorASATokenResult { .unavailable }

    func fetchAppleAttribution(token: String) async -> AppActorASAAppleAttributionResult {
        .error(PluginASATestError())
    }
}

private struct PluginASATestClient: AppActorPaymentClientProtocol {
    func identify(_ request: AppActorIdentifyRequest) async throws -> AppActorIdentifyResult { fatalError("unused in PluginASATests") }
    func login(_ request: AppActorLoginRequest) async throws -> AppActorLoginResult { fatalError("unused in PluginASATests") }
    func getOfferings(eTag: String?) async throws -> AppActorOfferingsFetchResult { fatalError("unused in PluginASATests") }
    func getCustomer(appUserId: String, eTag: String?) async throws -> AppActorCustomerFetchResult { fatalError("unused in PluginASATests") }
    func getRemoteConfigs(appUserId: String?, appVersion: String?, country: String?, eTag: String?) async throws -> AppActorRemoteConfigFetchResult { fatalError("unused in PluginASATests") }
    func postReceipt(_ request: AppActorReceiptPostRequest) async throws -> AppActorReceiptPostResponse { fatalError("unused in PluginASATests") }
    func postRestore(_ request: AppActorRestoreRequest) async throws -> AppActorRestoreResult { fatalError("unused in PluginASATests") }
    func postExperimentAssignment(experimentKey: String, appUserId: String, appVersion: String?, country: String?) async throws -> AppActorExperimentFetchResult { fatalError("unused in PluginASATests") }
    func postASAAttribution(_ request: AppActorASAAttributionRequest) async throws -> AppActorASAAttributionResponseDTO { fatalError("unused in PluginASATests") }
    func postASAPurchaseEvent(_ request: AppActorASAPurchaseEventRequest) async throws -> AppActorASAPurchaseEventResponseDTO { fatalError("unused in PluginASATests") }
}

@MainActor
final class PluginASATests: XCTestCase {

    func testEnableASATrackingRequestDecodesOptions() throws {
        let json = """
        {
          "auto_track_purchases": false,
          "track_in_sandbox": true,
          "debug_mode": true
        }
        """

        let request = try AppActorPluginCoder.decoder.decode(
            EnableAppleSearchAdsTrackingRequest.self,
            from: Data(json.utf8)
        )

        XCTAssertEqual(request.autoTrackPurchases, false)
        XCTAssertEqual(request.trackInSandbox, true)
        XCTAssertEqual(request.debugMode, true)
    }

    func testGetASADiagnosticsReturnsNullWhenNotConfigured() async throws {
        let appActor = AppActor.shared
        let originalManager = appActor.asaManager

        defer {
            appActor.asaManager = originalManager
        }

        appActor.asaManager = nil

        let json = await AppActorPlugin.shared.execute(method: "get_asa_diagnostics", withJson: "{}")
        let envelope = try parseEnvelope(json)

        XCTAssertTrue(envelope["success"] is NSNull)
    }

    func testGetASADiagnosticsReturnsSnapshot() async throws {
        let appActor = AppActor.shared
        let originalManager = appActor.asaManager

        defer {
            appActor.asaManager = originalManager
        }

        appActor.asaManager = makeASAManager(
            pendingPurchaseEventCount: 2,
            options: AppActorASAOptions(
                autoTrackPurchases: false,
                trackInSandbox: true,
                debugMode: true
            ),
            attributionCompleted: true
        )

        let json = await AppActorPlugin.shared.execute(method: "get_asa_diagnostics", withJson: "{}")
        let envelope = try parseEnvelope(json)
        let success = try XCTUnwrap(envelope["success"] as? [String: Any])

        XCTAssertEqual(success["attribution_completed"] as? Bool, true)
        XCTAssertEqual(success["pending_purchase_event_count"] as? Int, 2)
        XCTAssertEqual(success["debug_mode"] as? Bool, true)
        XCTAssertEqual(success["auto_track_purchases"] as? Bool, false)
        XCTAssertEqual(success["track_in_sandbox"] as? Bool, true)
    }

    func testGetPendingASAPurchaseEventCountReturnsCount() async throws {
        let appActor = AppActor.shared
        let originalManager = appActor.asaManager

        defer {
            appActor.asaManager = originalManager
        }

        appActor.asaManager = makeASAManager(pendingPurchaseEventCount: 3)

        let json = await AppActorPlugin.shared.execute(
            method: "get_pending_asa_purchase_event_count",
            withJson: "{}"
        )
        let envelope = try parseEnvelope(json)

        XCTAssertEqual(envelope["success"] as? Int, 3)
    }

    func testASAInstallStateRequestsReturnBooleans() async throws {
        let deviceJson = await AppActorPlugin.shared.execute(
            method: "get_asa_first_install_on_device",
            withJson: "{}"
        )
        let accountJson = await AppActorPlugin.shared.execute(
            method: "get_asa_first_install_on_account",
            withJson: "{}"
        )

        let deviceEnvelope = try parseEnvelope(deviceJson)
        let accountEnvelope = try parseEnvelope(accountJson)

        XCTAssertNotNil(deviceEnvelope["success"] as? Bool)
        XCTAssertNotNil(accountEnvelope["success"] as? Bool)
    }

    private func makeASAManager(
        pendingPurchaseEventCount: Int,
        options: AppActorASAOptions = AppActorASAOptions(),
        attributionCompleted: Bool = false
    ) -> AppActorASAManager {
        let storage = PluginASATestStorage()
        storage.set("user_123", forKey: AppActorPaymentStorageKey.appUserId)
        storage.setAsaAttributionCompleted(attributionCompleted)

        let eventStore = PluginASATestEventStore()
        for index in 0..<pendingPurchaseEventCount {
            let request = AppActorASAPurchaseEventRequest(
                userId: "user_123",
                productId: "product_\(index)",
                transactionId: nil,
                originalTransactionId: nil,
                purchaseDate: "2025-01-01T00:00:00Z",
                countryCode: nil,
                storekit2Json: nil,
                appVersion: "1.0.0",
                osVersion: "18.0",
                libVersion: "1.0.0"
            )
            eventStore.enqueue(
                AppActorASAStoredEvent(
                    id: "event_\(index)",
                    request: request,
                    retryCount: 0,
                    createdAt: Date()
                )
            )
        }

        return AppActorASAManager(
            client: PluginASATestClient(),
            storage: storage,
            eventStore: eventStore,
            tokenProvider: PluginASATestTokenProvider(),
            options: options,
            sdkVersion: "1.0.0"
        )
    }

    private func parseEnvelope(_ json: String) throws -> [String: Any] {
        let data = Data(json.utf8)
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
