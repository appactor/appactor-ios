import XCTest
@testable import AppActor

// MARK: - Doubles

@MainActor
private final class FakeScreenHost: AppActorScreenHost {
    var sent: [AppActorScreenInbound] = []
    var closedWith: AppActorScreenOutcome?
    var readyPaintConfirmed: Bool?
    var opened: [(URL, String)] = []

    /// Fulfilled every time a batch goes out, so tests can wait on work the
    /// session does in a detached task instead of sleeping.
    var onSend: (() -> Void)?

    func send(_ messages: [AppActorScreenInbound]) {
        sent.append(contentsOf: messages)
        onSend?()
    }

    func closeScreen(_ outcome: AppActorScreenOutcome) { closedWith = outcome }
    func screenBecameReady(paintConfirmed: Bool) { readyPaintConfirmed = paintConfirmed }
    func openExternal(url: URL, method: String) { opened.append((url, method)) }

    func replies(_ type: AppActorScreenInboundType) -> [AppActorScreenInbound] {
        sent.filter { $0.type == type }
    }
}

// MARK: - Tests

@MainActor
final class ScreenSessionTests: XCTestCase {

    private var host: FakeScreenHost!
    private var gateway: FakeScreenPurchaseGateway!
    private var session: AppActorScreenSession!

    override func setUp() {
        super.setUp()
        host = FakeScreenHost()
        gateway = FakeScreenPurchaseGateway()
        session = AppActorScreenSession(
            host: host,
            gateway: gateway,
            document: Self.document(),
            packages: [["id": "pkg_annual", "priceString": "$39.99"]],
            onEvent: { [weak self] event in self?.events.append(event) }
        )
    }

    private var events: [AppActorScreenEvent] = []

    override func tearDown() {
        events = []
        session = nil
        super.tearDown()
    }

    private static func document(lookupKey: String = "paywall_main") -> AppActorScreenDocument {
        AppActorScreenDocument(
            lookupKey: lookupKey,
            json: ["schemaVersion": 1, "lookupKey": lookupKey, "slots": [String: Any]()],
            comparisons: [:],
            packageIds: ["pkg_annual"],
            assetRefs: []
        )
    }

    private func message(
        _ type: AppActorScreenOutboundType,
        requestId: String? = nil,
        _ payload: [String: Any] = [:]
    ) -> AppActorScreenOutbound {
        AppActorScreenOutbound(type: type, requestId: requestId, payload: payload)
    }

    /// Waits for the session to send `count` batches. The session answers a
    /// purchase from a detached task, so tests cannot read `host.sent` straight
    /// after `handle` returns.
    private func waitForSends(_ count: Int, timeout: TimeInterval = 2) async {
        let expectation = expectation(description: "\(count) message(s) sent")
        expectation.expectedFulfillmentCount = count
        host.onSend = { expectation.fulfill() }
        await fulfillment(of: [expectation], timeout: timeout)
        host.onSend = nil
    }


    // MARK: - init

    func testInitCarriesTheDocumentAndPackages() throws {
        session.sendInit(locale: "tr_TR", assetBase: "https://cdn.example.com")
        let sent = try XCTUnwrap(host.replies(.initialise).first)

        XCTAssertNotNil(sent.payload["document"] as? [String: Any])
        XCTAssertEqual((sent.payload["packages"] as? [[String: Any]])?.count, 1)
        let context = try XCTUnwrap(sent.payload["context"] as? [String: Any])
        XCTAssertEqual(context["locale"] as? String, "tr_TR")
        XCTAssertEqual(context["assetBase"] as? String, "https://cdn.example.com")
        session.cancel()
    }

    func testInitOmitsPackagesWhenThereAreNone() throws {
        let empty = AppActorScreenSession(
            host: host, gateway: gateway, document: Self.document(), packages: [], onEvent: nil
        )
        empty.sendInit(locale: "en", assetBase: nil)
        let sent = try XCTUnwrap(host.replies(.initialise).first)
        // An empty array is not the same as absent: the runtime resets its
        // package map on every `packages` key it sees.
        XCTAssertNil(sent.payload["packages"])
        XCTAssertNil((sent.payload["context"] as? [String: Any])?["assetBase"])
        empty.cancel()
    }

    // MARK: - ready and the watchdog

    func testReadyRevealsTheScreenAndStopsTheWatchdog() async throws {
        session.onReadyTimeout = { XCTFail("the watchdog should not fire after ready") }
        session.sendInit(locale: "en", assetBase: nil)
        session.handle(message(.ready, ["runtimeVersion": "1.0.0", "paintConfirmed": true]))

        XCTAssertEqual(host.readyPaintConfirmed, true)
        try await Task.sleep(nanoseconds: UInt64(AppActorScreenProtocol.readyWatchdog * 1_500_000_000))
        session.cancel()
    }

    func testReadyWithoutPaintConfirmationStillReveals() {
        session.handle(message(.ready, ["runtimeVersion": "1.0.0", "paintConfirmed": false]))
        // `false` means rAF never fired, not that nothing rendered. Refusing to
        // reveal would blank every screen on a throttled WebView.
        XCTAssertEqual(host.readyPaintConfirmed, false)
        session.cancel()
    }

    func testASecondReadyIsIgnored() {
        session.handle(message(.ready, ["paintConfirmed": true]))
        host.readyPaintConfirmed = nil
        session.handle(message(.ready, ["paintConfirmed": false]))
        XCTAssertNil(host.readyPaintConfirmed, "ready should only be acted on once")
        session.cancel()
    }

    func testTheWatchdogFiresWhenReadyNeverArrives() async {
        let fired = expectation(description: "watchdog")
        session.onReadyTimeout = { fired.fulfill() }
        session.sendInit(locale: "en", assetBase: nil)
        await fulfillment(of: [fired], timeout: AppActorScreenProtocol.readyWatchdog + 2)
        session.cancel()
    }

    func testCancelStopsTheWatchdog() async throws {
        session.onReadyTimeout = { XCTFail("a cancelled session should not fall back") }
        session.sendInit(locale: "en", assetBase: nil)
        session.cancel()
        try await Task.sleep(nanoseconds: UInt64(AppActorScreenProtocol.readyWatchdog * 1_500_000_000))
    }

    // MARK: - purchase

    func testPurchaseWithoutARequestIdIsIgnored() {
        // Rule #14. Replying without an id produces `unmatched_purchase_result`
        // on the runtime side, which reads like a bug in the wrong place.
        session.handle(message(.purchase, ["packageId": "pkg_annual"]))
        XCTAssertTrue(host.sent.isEmpty)
        XCTAssertTrue(gateway.purchasedPackageIds.isEmpty)
        session.cancel()
    }

    func testPurchaseWithoutAPackageIdFailsImmediately() throws {
        session.handle(message(.purchase, requestId: "r1", [:]))
        let reply = try XCTUnwrap(host.replies(.purchaseResult).first)
        XCTAssertEqual(reply.requestId, "r1")
        XCTAssertEqual(reply.payload["status"] as? String, "failed")
        XCTAssertTrue(gateway.purchasedPackageIds.isEmpty)
        session.cancel()
    }

    func testConfirmedPurchaseRepliesOnceAndEndsAsPurchased() async throws {
        gateway.purchaseOutcome = .completed(serverConfirmed: true, transactionId: nil)
        session.handle(message(.purchase, requestId: "r1", ["packageId": "pkg_annual"]))
        await waitForSends(1)

        let replies = host.replies(.purchaseResult)
        XCTAssertEqual(replies.count, 1)
        XCTAssertEqual(replies[0].requestId, "r1")
        XCTAssertEqual(replies[0].payload["status"] as? String, "completed")
        XCTAssertEqual(replies[0].payload["server_confirmed"] as? Bool, true)
        XCTAssertEqual(gateway.purchasedPackageIds, ["pkg_annual"])
        XCTAssertTrue(gateway.confirmedTransactionIds.isEmpty)

        session.handle(message(.close))
        XCTAssertEqual(host.closedWith, .purchased)
        session.cancel()
    }

    func testUnconfirmedPurchaseIsFollowedUpUnderTheSameRequestId() async throws {
        // Rule #13. The runtime parks in `confirming` after an unconfirmed
        // `completed` and waits for a second result on the same id. Nobody but
        // this session will send it.
        gateway.purchaseOutcome = .completed(serverConfirmed: false, transactionId: "2000000123")
        gateway.confirmation = .confirmed

        session.handle(message(.purchase, requestId: "r1", ["packageId": "pkg_annual"]))
        await waitForSends(2)

        let replies = host.replies(.purchaseResult)
        XCTAssertEqual(replies.count, 2)
        XCTAssertEqual(replies[0].payload["server_confirmed"] as? Bool, false)
        XCTAssertEqual(replies[1].requestId, "r1", "the follow-up must reuse the original requestId")
        XCTAssertEqual(replies[1].payload["status"] as? String, "completed")
        XCTAssertEqual(replies[1].payload["server_confirmed"] as? Bool, true)
        XCTAssertEqual(gateway.confirmedTransactionIds, ["2000000123"])

        session.handle(message(.close))
        XCTAssertEqual(host.closedWith, .purchased)
        session.cancel()
    }

    func testAFollowUpRejectionIsReportedAsFailed() async throws {
        gateway.purchaseOutcome = .completed(serverConfirmed: false, transactionId: "2000000123")
        gateway.confirmation = .failed("Could not confirm.")

        session.handle(message(.purchase, requestId: "r1", ["packageId": "pkg_annual"]))
        await waitForSends(2)

        let replies = host.replies(.purchaseResult)
        XCTAssertEqual(replies[1].payload["status"] as? String, "failed")
        XCTAssertEqual(replies[1].payload["message"] as? String, "Could not confirm.")

        session.handle(message(.close))
        XCTAssertEqual(host.closedWith, .dismissed, "a rejected receipt is not a purchase")
        session.cancel()
    }

    func testAnUndecidedFollowUpSaysNothing() async throws {
        // A receipt still queued may well post a minute later. Claiming either
        // outcome would be a guess; the runtime releases its own controls on
        // its own timer.
        gateway.purchaseOutcome = .completed(serverConfirmed: false, transactionId: "2000000123")
        gateway.confirmation = .unknown

        session.handle(message(.purchase, requestId: "r1", ["packageId": "pkg_annual"]))
        await waitForSends(1)
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(host.replies(.purchaseResult).count, 1)
        XCTAssertEqual(gateway.confirmedTransactionIds, ["2000000123"])
        session.cancel()
    }

    func testAPendingPurchaseIsReportedAsPendingAndNotFollowedUp() async throws {
        gateway.purchaseOutcome = .pending
        session.handle(message(.purchase, requestId: "r1", ["packageId": "pkg_annual"]))
        await waitForSends(1)

        let reply = try XCTUnwrap(host.replies(.purchaseResult).first)
        XCTAssertEqual(reply.payload["status"] as? String, "pending")
        XCTAssertNil(reply.payload["server_confirmed"])
        XCTAssertTrue(gateway.confirmedTransactionIds.isEmpty)

        session.handle(message(.close))
        XCTAssertEqual(host.closedWith, .dismissed, "Ask to Buy is not a completed purchase")
        session.cancel()
    }

    func testACancelledPurchaseIsReportedAsCancelled() async throws {
        gateway.purchaseOutcome = .cancelled
        session.handle(message(.purchase, requestId: "r1", ["packageId": "pkg_annual"]))
        await waitForSends(1)
        XCTAssertEqual(host.replies(.purchaseResult)[0].payload["status"] as? String, "cancelled")
        session.cancel()
    }

    func testAFailedPurchaseCarriesItsMessage() async throws {
        gateway.purchaseOutcome = .failed("No connection.")
        session.handle(message(.purchase, requestId: "r1", ["packageId": "pkg_annual"]))
        await waitForSends(1)
        let reply = host.replies(.purchaseResult)[0]
        XCTAssertEqual(reply.payload["status"] as? String, "failed")
        XCTAssertEqual(reply.payload["message"] as? String, "No connection.")
        session.cancel()
    }

    func testACancelledSessionDoesNotReplyToAPurchaseInFlight() async throws {
        gateway.purchaseOutcome = .completed(serverConfirmed: true, transactionId: nil)
        session.handle(message(.purchase, requestId: "r1", ["packageId": "pkg_annual"]))
        session.cancel()
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(host.replies(.purchaseResult).isEmpty, "a dismissed screen must not be written to")
    }

    // MARK: - restore

    func testRestoreWithoutARequestIdIsIgnored() {
        session.handle(message(.restore))
        XCTAssertTrue(host.sent.isEmpty)
        session.cancel()
    }

    func testASuccessfulRestoreEndsAsRestored() async throws {
        gateway.restoreOutcome = .restored
        session.handle(message(.restore, requestId: "r2"))
        await waitForSends(1)

        let reply = try XCTUnwrap(host.replies(.restoreResult).first)
        XCTAssertEqual(reply.requestId, "r2")
        XCTAssertEqual(reply.payload["status"] as? String, "restored")

        session.handle(message(.close))
        XCTAssertEqual(host.closedWith, .restored)
        session.cancel()
    }

    func testAnEmptyRestoreIsNotAFailure() async throws {
        gateway.restoreOutcome = .nothingToRestore
        session.handle(message(.restore, requestId: "r2"))
        await waitForSends(1)
        XCTAssertEqual(host.replies(.restoreResult)[0].payload["status"] as? String, "nothing_to_restore")

        session.handle(message(.close))
        XCTAssertEqual(host.closedWith, .dismissed)
        session.cancel()
    }

    func testAFailedRestoreCarriesItsMessage() async throws {
        gateway.restoreOutcome = .failed("Could not restore purchases.")
        session.handle(message(.restore, requestId: "r2"))
        await waitForSends(1)
        let reply = host.replies(.restoreResult)[0]
        XCTAssertEqual(reply.payload["status"] as? String, "failed")
        XCTAssertEqual(reply.payload["message"] as? String, "Could not restore purchases.")
        session.cancel()
    }

    // MARK: - close, navigate, events

    func testCloseWithNothingBoughtIsADismissal() {
        session.handle(message(.close))
        XCTAssertEqual(host.closedWith, .dismissed)
        session.cancel()
    }

    func testNavigateIsIgnoredWithoutClosingTheScreen() {
        session.handle(message(.navigate, ["to": "paywall_b"]))
        XCTAssertNil(host.closedWith)
        XCTAssertTrue(host.sent.isEmpty)
        session.cancel()
    }

    func testEventsReachTheHostAppWithTheirProperties() throws {
        session.handle(message(.event, ["name": "cta_tap", "props": ["id": "buy"]]))
        let event = try XCTUnwrap(events.first)
        XCTAssertEqual(event.name, "cta_tap")
        XCTAssertEqual(event.lookupKey, "paywall_main")
        XCTAssertEqual(event.properties["id"] as? String, "buy")
        session.cancel()
    }

    func testAnEventWithNoNameIsDropped() {
        session.handle(message(.event, ["props": ["id": "buy"]]))
        XCTAssertTrue(events.isEmpty)
        session.cancel()
    }

    func testDismissNotificationIsSentToTheRuntime() {
        session.notifyDismissed()
        XCTAssertEqual(host.replies(.dismiss).count, 1)
        session.cancel()
    }

    // MARK: - openUrl

    private func openUrl(_ url: String, _ method: String) {
        session.handle(message(.openUrl, ["url": url, "method": method]))
    }

    func testOpensAnHTTPSLinkInTheInAppBrowser() {
        openUrl("https://example.com/terms", "in_app_browser")
        XCTAssertEqual(host.opened.count, 1)
        XCTAssertEqual(host.opened.first?.1, "in_app_browser")
        session.cancel()
    }

    func testRefusesPlainHTTPInTheInAppBrowser() {
        openUrl("http://example.com/terms", "in_app_browser")
        XCTAssertTrue(host.opened.isEmpty)
        session.cancel()
    }

    func testAllowsPlainHTTPInAnExternalBrowser() {
        // The system browser shows the user the scheme; an embedded sheet does
        // not, which is the whole reason the two differ.
        openUrl("http://example.com", "external_browser")
        XCTAssertEqual(host.opened.count, 1)
        session.cancel()
    }

    func testRefusesEverySchemeTheSharedPolicyForbids() {
        // `FORBIDDEN_DEEP_LINK_SCHEMES` in `spec/open-url.ts`. The runtime
        // applies this list too, but it applies it inside the page; this copy
        // is the one a compromised document cannot reach, so "at least as
        // strict" has to mean the same list and not a shorter one.
        for scheme in ["javascript", "data", "file", "blob", "vbscript", "about", "filesystem", "http", "https", "ws", "wss"] {
            openUrl("\(scheme)://anything/x", "deep_link")
            XCTAssertTrue(host.opened.isEmpty, "\(scheme) reached the host as a deep link")
        }
        openUrl("javascript:alert(1)", "external_browser")
        XCTAssertTrue(host.opened.isEmpty)
        session.cancel()
    }

    func testRefusesADeepLinkThatIsNotSchemeSlashSlash() {
        // The shared policy requires `<scheme>://<rest>`. Without that check a
        // document could dial a number or open a mail composer.
        for url in ["tel:+15551234", "sms:+15551234", "mailto:x@example.com"] {
            openUrl(url, "deep_link")
        }
        XCTAssertTrue(host.opened.isEmpty)
        session.cancel()
    }

    func testRefusesAWebURLCarryingCredentials() {
        // `https://apple.com@evil.example/` reads as Apple's domain in a
        // Safari sheet and loads someone else's page.
        openUrl("https://apple.com@evil.example/", "in_app_browser")
        openUrl("https://user:pass@evil.example/", "external_browser")
        XCTAssertTrue(host.opened.isEmpty)
        session.cancel()
    }

    func testRefusesAURLWithControlCharactersOrOverTheLengthLimit() {
        openUrl("https://example.com/\u{0}x", "external_browser")
        openUrl("https://example.com/a\\b", "external_browser")
        openUrl("https://example.com/" + String(repeating: "a", count: 2100), "external_browser")
        // Measured in UTF-16 units, like the shared policy. Counting graphemes
        // made this copy *looser* than the one it exists to backstop: 2048
        // family emoji are ~8 KB of UTF-16 and would have sailed through.
        openUrl("https://example.com/" + String(repeating: "👨‍👩‍👧‍👦", count: 400), "external_browser")
        XCTAssertTrue(host.opened.isEmpty)
        session.cancel()
    }

    func testAllowsARealDeepLink() {
        openUrl("myapp://settings", "deep_link")
        XCTAssertEqual(host.opened.count, 1)
        session.cancel()
    }

    func testRefusesAnUnknownMethod() {
        openUrl("https://example.com", "teleport")
        XCTAssertTrue(host.opened.isEmpty)
        session.cancel()
    }

    func testRefusesAnUnparseableURL() {
        session.handle(message(.openUrl, ["method": "external_browser"]))
        XCTAssertTrue(host.opened.isEmpty)
        session.cancel()
    }
}
