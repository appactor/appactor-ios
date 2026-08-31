#if canImport(UIKit) && canImport(WebKit) && !os(watchOS) && !os(tvOS)

import XCTest
@testable import AppActor

/// Covers the glue `presentScreen` puts between remote config, offerings and
/// the WebView: which document it reads, what it does when that document is
/// missing or misfiled, and — the case with a hard acceptance criterion behind
/// it — whether a screen still opens with no network.
///
/// Presentation itself stops at the same place in every one of these: a
/// SwiftPM test bundle has no app host, so there is no window scene to present
/// from. That is what makes the error message useful here. "No screen document
/// found" and "none of which are in your offerings" are different failures, and
/// which one comes back says exactly how far the glue got.
@MainActor
final class ScreenPresentationTests: XCTestCase {

    private var appactor: AppActor!
    private var client: MockPaymentClient!
    private var storage: InMemoryPaymentStorage!
    private var cacheDirectory: URL!
    private var etagManager: AppActorETagManager!

    override func setUp() {
        super.setUp()
        appactor = AppActor.shared
        client = MockPaymentClient()
        storage = InMemoryPaymentStorage()
        cacheDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("appactor_screens_test_\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        etagManager = AppActorETagManager(diskStore: AppActorCacheDiskStore(directory: cacheDirectory))
    }

    override func tearDown() {
        appactor.paymentLifecycle = .idle
        appactor.paymentRemoteConfigs = nil
        try? FileManager.default.removeItem(at: cacheDirectory)
        super.tearDown()
    }

    // MARK: - Helpers

    private func document(lookupKey: String) -> AppActorConfigValue {
        let json = """
        {"schemaVersion":1,"lookupKey":"\(lookupKey)","kind":"paywall",
         "minRuntime":"1.0.0","layout":"fill",
         "slots":{"body":[{"id":"t","type":"text","value":"Pro"}]}}
        """
        return try! JSONDecoder().decode(AppActorConfigValue.self, from: Data(json.utf8))
    }

    private func serveDocument(key: String, lookupKey: String) {
        client.getRemoteConfigsHandler = { [document] _, _, _, _ in
            .fresh(
                [AppActorRemoteConfigItemDTO(key: key, value: document(lookupKey), valueType: "json")],
                eTag: "v1",
                requestId: "req_screen",
                // The API sets this header on every response
                // (`routes/remote-config/index.ts:63`), and whether it is
                // present changes how many round trips the SDK makes.
                signatureVerified: false,
                requiresUserContext: false
            )
        }
    }

    private func configure(apiKey: String) {
        appactor.configureForTesting(
            config: AppActorPaymentConfiguration(apiKey: apiKey),
            client: client,
            storage: storage,
            etagManager: etagManager
        )
    }

    /// Runs `presentScreen` and returns the message it failed with.
    private func failureMessage(_ lookupKey: String) async -> String {
        do {
            _ = try await appactor.presentScreen(lookupKey)
            return "<presented>"
        } catch let error as AppActorError {
            return error.message ?? "<no message>"
        } catch {
            return error.localizedDescription
        }
    }

    // MARK: - Guards

    func testRefusesWhenNotConfigured() async {
        appactor.paymentLifecycle = .idle
        do {
            _ = try await appactor.presentScreen("paywall_main")
            XCTFail("an unconfigured SDK should not present anything")
        } catch let error as AppActorError {
            XCTAssertEqual(error.kind, .notConfigured)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testRefusesAKeyThatIsNotAValidLookupKey() async {
        configure(apiKey: "pk_test_screen_key")
        // Checked before anything is fetched: the key becomes a path component
        // of the page's origin, and the caller deserves to be told which of
        // their arguments is wrong.
        let message = await failureMessage("Paywall Main")
        XCTAssertTrue(message.contains("not a valid screen key"), "got: \(message)")
        XCTAssertTrue(client.getRemoteConfigsCalls.isEmpty, "an invalid key should not cost a round trip")
    }

    // MARK: - Document resolution

    func testReportsAMissingDocument() async {
        configure(apiKey: "pk_test_screen_missing")
        client.getRemoteConfigsHandler = { _, _, _, _ in
            .fresh([], eTag: nil, requestId: "req", signatureVerified: false)
        }
        let message = await failureMessage("paywall_main")
        XCTAssertTrue(message.contains("No screen document found"), "got: \(message)")
    }

    func testReportsADocumentFiledUnderTheWrongKey() async {
        // The document says it is `paywall_b` but lives at `screen.paywall_main`.
        // Rendering it would attribute its purchases to the wrong screen.
        configure(apiKey: "pk_test_screen_mismatch")
        serveDocument(key: "screen.paywall_main", lookupKey: "paywall_b")
        let message = await failureMessage("paywall_main")
        XCTAssertTrue(message.contains("declares lookupKey"), "got: \(message)")
    }

    func testReadsTheDocumentFromTheReservedNamespace() async {
        // Getting as far as "no packages" is the proof: the document was found,
        // parsed, and its lookup key agreed with its remote config key.
        configure(apiKey: "pk_test_screen_found")
        serveDocument(key: "screen.paywall_main", lookupKey: "paywall_main")
        let message = await failureMessage("paywall_main")
        XCTAssertTrue(message.contains("names no packages"), "got: \(message)")
    }

    func testUsesAnAlreadyFetchedDocumentWithoutASecondRoundTrip() async throws {
        configure(apiKey: "pk_test_screen_warm")
        serveDocument(key: "screen.paywall_main", lookupKey: "paywall_main")
        _ = try await appactor.getRemoteConfigs()
        let before = client.getRemoteConfigsCalls.count

        _ = await failureMessage("paywall_main")
        XCTAssertEqual(
            client.getRemoteConfigsCalls.count, before,
            "a document already in memory should not be fetched again on the path to first paint"
        )
    }

    // MARK: - Offline

    func testOpensWithNoNetworkOnceTheDocumentHasBeenFetched() async throws {
        // Airplane mode within a session -- the app was online at some point,
        // then the connection went away. The document is already resolved, and
        // `presentScreen` does not go back to the network for it at all.
        configure(apiKey: "pk_test_screen_offline")
        serveDocument(key: "screen.paywall_main", lookupKey: "paywall_main")
        _ = try await appactor.getRemoteConfigs()
        let before = client.getRemoteConfigsCalls.count

        client.getRemoteConfigsHandler = { _, _, _, _ in
            throw AppActorError.networkError(URLError(.notConnectedToInternet))
        }

        let message = await failureMessage("paywall_main")
        XCTAssertTrue(message.contains("names no packages"), "the document should still resolve; got: \(message)")
        XCTAssertEqual(client.getRemoteConfigsCalls.count, before, "no network call should have been attempted")
    }

    func testAColdLaunchWithNoNetworkStillReachesTheDiskCachedDocument() async throws {
        // A relaunch in airplane mode: same disk, empty memory, nothing
        // answering the network.
        //
        // This used to fail with `.network` before the document was even read.
        // `RemoteConfigManager` recorded "this response does not need user
        // context" in memory only, so a fresh process always followed the
        // public result with a user-context refetch -- and offline, that
        // refetch's failure threw away the public result the disk fallback had
        // already produced.
        //
        // Now the public result survives, so the document is reached. The call
        // still fails, but one stage later and for a different reason: the
        // prices are not on disk. That distinction is the point of this test —
        // "we cannot read the screen" and "we can read the screen but not
        // price it" need different fixes, and only the second one is left.
        configure(apiKey: "pk_test_screen_cold_disk")
        serveDocument(key: "screen.paywall_main", lookupKey: "paywall_main")
        _ = try await appactor.getRemoteConfigs()

        client.getRemoteConfigsHandler = { _, _, _, _ in
            throw AppActorError.networkError(URLError(.notConnectedToInternet))
        }
        configure(apiKey: "pk_test_screen_cold_disk")
        XCTAssertNil(appactor.cachedRemoteConfigs, "memory must be cold for this to prove anything")

        let message = await failureMessage("paywall_main")
        XCTAssertTrue(
            message.contains("names no packages"),
            "the disk-cached document should be reached; got: \(message)"
        )
    }

    func testAFirstLaunchWithNoNetworkAndNoCacheFailsHonestly() async {
        // Nothing cached and nothing reachable. Better to throw — the host app
        // can fall back to its bundled paywall — than to present a screen with
        // the prices missing.
        configure(apiKey: "pk_test_screen_cold")
        client.getRemoteConfigsHandler = { _, _, _, _ in
            throw AppActorError.networkError(URLError(.notConnectedToInternet))
        }
        do {
            _ = try await appactor.presentScreen("paywall_main")
            XCTFail("a cold offline launch has no document to present")
        } catch let error as AppActorError {
            XCTAssertEqual(error.kind, .network)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    // MARK: - One at a time

    func testTheEventHandlerIsReadableAndWritable() {
        configure(apiKey: "pk_test_screen_events")
        var seen: [String] = []
        appactor.onScreenEvent = { seen.append($0.name) }
        XCTAssertNotNil(appactor.onScreenEvent)

        appactor.onScreenEvent?(AppActorScreenEvent(name: "cta_tap", lookupKey: "paywall_main", properties: [:]))
        XCTAssertEqual(seen, ["cta_tap"])

        appactor.onScreenEvent = nil
        XCTAssertNil(appactor.onScreenEvent)
    }
}

#endif
