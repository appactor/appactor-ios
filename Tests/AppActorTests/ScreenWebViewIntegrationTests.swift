#if canImport(UIKit) && canImport(WebKit) && !os(watchOS) && !os(tvOS)

import XCTest
import UIKit
import WebKit
@testable import AppActor

/// Drives the real page: the shell this SDK ships, the runtime bundle it
/// embeds, and the bridge between them.
///
/// Everything else about screens is tested against fakes on the macOS host.
/// These are the questions fakes cannot answer — whether the runtime executes
/// at all under the shell's content security policy, whether an unrecognised
/// message really does leave its neighbours alone, whether a tap on a rendered
/// button produces a purchase. They need a simulator:
///
///     xcodebuild test -scheme AppActor \
///       -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
///
/// `swift test` on macOS compiles this file to nothing.
@MainActor
final class ScreenWebViewIntegrationTests: XCTestCase {

    private var window: UIWindow!
    private var controller: AppActorScreenViewController!
    private var gateway: FakeScreenPurchaseGateway!
    private var events: [AppActorScreenEvent] = []

    override func tearDown() {
        // Before the window goes: tearing it down takes the screen out of the
        // view hierarchy, which is itself a dismissal and legitimately reports
        // one. A test that is still listening would see that as its own result.
        controller?.onFinished = nil
        window?.isHidden = true
        window = nil
        controller = nil
        events = []
        super.tearDown()
    }

    // MARK: - Fixtures

    /// A small but real paywall: a title, a price interpolated from the
    /// bridge's package, a buy button and a close button.
    private func document(lookupKey: String = "paywall_main") throws -> AppActorScreenDocument {
        let json = """
        {"schemaVersion":1,"lookupKey":"\(lookupKey)","kind":"paywall",
         "minRuntime":"1.0.0","layout":"sticky_footer",
         "slots":{
           "body":[
             {"id":"title","type":"text","value":"AppActor <b>Pro</b>","element":"h1"},
             {"id":"price","type":"text","value":"{{package.priceString}} / {{package.periodString}}"},
             {"id":"card","type":"package","packageId":"pkg_annual","children":[
               {"id":"cardLabel","type":"text","value":"Annual"}
             ]}
           ],
           "bottom":[
             {"id":"cta","type":"button","label":"Continue","action":{"type":"purchase"}},
             {"id":"restore","type":"button","label":"Restore","action":{"type":"restore"}},
             {"id":"close","type":"button","label":"Not now","action":{"type":"close"}}
           ]
         }}
        """
        return try AppActorScreenDocument.parse(
            try JSONDecoder().decode(AppActorConfigValue.self, from: Data(json.utf8)),
            lookupKey: lookupKey
        )
    }

    private static let package: [String: Any] = [
        "id": "pkg_annual",
        "priceString": "$39.99",
        "price": 39.99,
        "currencyCode": "USD",
        "periodUnit": "year",
        "periodCount": 1,
        "periodString": "1 year",
        "trialPeriodDays": 7,
        "introPriceString": NSNull(),
        "pricePerWeekString": "$0.77",
        "pricePerMonthString": "$3.33",
        "discountPercent": 34,
        "isEligibleForTrial": true,
    ]

    /// Puts the screen in a real window. A `WKWebView` outside one never gets a
    /// `requestAnimationFrame` callback, and `ready` is defined in terms of one.
    private func present(_ document: AppActorScreenDocument) {
        gateway = FakeScreenPurchaseGateway()
        controller = AppActorScreenViewController(
            document: document,
            packages: [Self.package],
            gateway: gateway,
            locale: "en_US",
            onEvent: { [weak self] event in self?.events.append(event) }
        )
        window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        window.rootViewController = controller
        window.isHidden = false
        window.makeKeyAndVisible()
    }

    // MARK: - Waiting

    private func waitUntil(
        _ description: String,
        timeout: TimeInterval = 10,
        _ condition: @MainActor () async -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("timed out waiting for: \(description)")
    }

    private func evaluate(_ javaScript: String) async throws -> Any? {
        try await controller.webView.evaluateJavaScript(javaScript)
    }

    private func text(of id: String) async throws -> String? {
        let result = try? await evaluate("document.querySelector('[data-id=\"\(id)\"]')?.textContent || null")
        return result as? String
    }

    /// `ready` is what reveals the web view, so its opacity is the signal.
    private func waitForReady() async throws {
        try await waitUntil("the runtime to report ready") { [weak self] in
            (self?.controller.webView.alpha ?? 0) > 0
        }
    }

    // MARK: - Boot

    func testTheRuntimeBootsUnderTheShellContentSecurityPolicy() async throws {
        // The load-bearing test for the whole approach. The shell declares
        // `script-src 'self'`, which blocks inline scripts, and there is no
        // subresource to fetch — the runtime is injected as a `WKUserScript`.
        // If WebKit ever applied the page's CSP to user scripts, every screen
        // would silently be a blank sheet and only this test would notice.
        present(try document())
        try await waitForReady()

        let installed = try await evaluate("typeof window.__appactor.receive")
        XCTAssertEqual(installed as? String, "function", "the runtime did not install its bridge")
    }

    func testTheDocumentRenders() async throws {
        present(try document())
        try await waitForReady()

        let title = try await text(of: "title")
        XCTAssertEqual(title, "AppActor Pro", "inline <b> should become a DOM node, not text")

        let label = try await text(of: "cardLabel")
        XCTAssertEqual(label, "Annual")
    }

    func testPricesFromTheBridgeAreInterpolatedIntoTheDocument() async throws {
        present(try document())
        try await waitForReady()

        let price = try await text(of: "price")
        XCTAssertEqual(price, "$39.99 / 1 year")
    }

    func testTheBuyButtonIsARealButtonElement() async throws {
        // Day-1 rule #9. A tappable `div` is invisible to VoiceOver and to
        // hardware keyboards, and it cannot be fixed after screens ship.
        present(try document())
        try await waitForReady()

        let tag = try await evaluate("document.querySelector('[data-id=\"cta\"]').tagName")
        XCTAssertEqual(tag as? String, "BUTTON")
    }

    func testImpressionAndScreenViewReachTheHostApp() async throws {
        present(try document())
        try await waitForReady()
        try await waitUntil("screen_view") { [weak self] in
            self?.events.contains { $0.name == "screen_view" } == true
        }
        XCTAssertTrue(events.contains { $0.name == "impression" })
        XCTAssertEqual(events.first?.lookupKey, "paywall_main")
    }

    // MARK: - Purchase

    func testTappingBuyPurchasesTheSelectedPackageAndClosesTheScreen() async throws {
        present(try document())
        try await waitForReady()

        gateway.purchaseOutcome = .completed(serverConfirmed: true, transactionId: nil)
        var finishedWith: AppActorScreenOutcome?
        controller.onFinished = { finishedWith = $0 }

        _ = try await evaluate("document.querySelector('[data-id=\"cta\"]').click()")

        try await waitUntil("the screen to close") { finishedWith != nil }
        XCTAssertEqual(finishedWith, .purchased)
        XCTAssertEqual(gateway.purchasedPackageIds, ["pkg_annual"])
        XCTAssertTrue(events.contains { $0.name == "purchase_started" })
        XCTAssertTrue(events.contains { $0.name == "purchase_completed" })
    }

    func testACancelledPurchaseLeavesTheScreenOpenAndTheButtonUsable() async throws {
        present(try document())
        try await waitForReady()

        gateway.purchaseOutcome = .cancelled
        var finishedWith: AppActorScreenOutcome?
        controller.onFinished = { finishedWith = $0 }

        _ = try await evaluate("document.querySelector('[data-id=\"cta\"]').click()")
        try await waitUntil("purchase_cancelled") { [weak self] in
            self?.events.contains { $0.name == "purchase_cancelled" } == true
        }

        XCTAssertNil(finishedWith, "a cancelled purchase must not close the screen")
        XCTAssertNotNil(controller.view.window, "the screen should still be on screen")
        let disabled = try await evaluate("document.querySelector('[data-id=\"cta\"]').disabled")
        XCTAssertEqual(disabled as? Bool, false, "the button should be usable again after a cancellation")
    }

    func testAPendingPurchaseKeepsTheButtonLocked() async throws {
        // Ask to Buy. A second tap would open a second store transaction for
        // the same package and orphan the first request's approval.
        present(try document())
        try await waitForReady()

        gateway.purchaseOutcome = .pending
        _ = try await evaluate("document.querySelector('[data-id=\"cta\"]').click()")

        try await waitUntil("the pending result to land") { [weak self] in
            guard let self else { return false }
            let disabled = try? await self.evaluate("document.querySelector('[data-id=\"cta\"]').disabled")
            return (disabled as? Bool) == true
        }
        XCTAssertEqual(gateway.purchasedPackageIds.count, 1)

        // A second tap must not reach the gateway at all.
        _ = try? await evaluate("document.querySelector('[data-id=\"cta\"]').click()")
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(gateway.purchasedPackageIds.count, 1, "a locked button must not start a second purchase")
    }

    func testTheCloseButtonDismissesTheScreen() async throws {
        present(try document())
        try await waitForReady()

        var finishedWith: AppActorScreenOutcome?
        controller.onFinished = { finishedWith = $0 }
        _ = try await evaluate("document.querySelector('[data-id=\"close\"]').click()")

        try await waitUntil("the screen to close") { finishedWith != nil }
        XCTAssertEqual(finishedWith, .dismissed)
        XCTAssertTrue(events.contains { $0.name == "dismiss" })
    }

    func testRestoreRoundTrips() async throws {
        present(try document())
        try await waitForReady()

        gateway.restoreOutcome = .restored
        var finishedWith: AppActorScreenOutcome?
        controller.onFinished = { finishedWith = $0 }

        _ = try await evaluate("document.querySelector('[data-id=\"restore\"]').click()")
        try await waitUntil("the screen to close after a restore") { finishedWith != nil }
        XCTAssertEqual(finishedWith, .restored)
    }

    // MARK: - The batch guarantee

    func testAnUnknownMessageInABatchDoesNotStopThePurchaseResultBesideIt() async throws {
        // Day-1 rule #12, and the reason results are sent as an array of
        // separately-encoded messages. Decoding a batch as one unit means a
        // single message type the runtime has not heard of takes the
        // `purchaseResult` next to it down with it, and the user is left
        // looking at a spinner over a purchase that already went through.
        present(try document())
        try await waitForReady()

        // Watch the wire. The request id is generated inside the runtime, and
        // the runtime refuses any result it cannot match to one (rule #14), so
        // the test has to read the real id rather than invent one.
        _ = try await evaluate("""
        window.__test_sent = [];
        (function () {
          var channel = window.webkit.messageHandlers.appactorScreens;
          var original = channel.postMessage;
          channel.postMessage = function (message) {
            window.__test_sent.push(message);
            return original.call(channel, message);
          };
        })();
        """)

        // Hold the purchase open so the runtime still has a request in flight
        // when the batch lands.
        gateway.purchaseOutcome = .cancelled
        gateway.stall = true

        _ = try await evaluate("document.querySelector('[data-id=\"cta\"]').click()")
        try await waitUntil("the runtime to send its purchase request") { [weak self] in
            self?.gateway.purchasedPackageIds.isEmpty == false
        }

        let raw = try await evaluate("JSON.stringify(window.__test_sent)")
        let sent = try XCTUnwrap(raw as? String)
        let envelopes = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(sent.utf8)) as? [String]
        )
        let purchase = try XCTUnwrap(
            envelopes
                .compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
                .first { $0["type"] as? String == "purchase" }
        )
        let requestId = try XCTUnwrap(purchase["requestId"] as? String)

        // One message of a type nothing recognises, then the real result.
        let unknown = try XCTUnwrap(
            AppActorScreenInbound(.packages, payload: ["__test_unknown__": true]).base64()
        )
        let broken = Data("{not even json}".utf8).base64EncodedString()
        let result = try XCTUnwrap(
            AppActorScreenInbound(.purchaseResult, requestId: requestId, payload: [
                "status": "completed", "server_confirmed": true,
            ]).base64()
        )
        _ = try await evaluate(
            "__appactor.receive([\"\(broken)\", \"\(unknown)\", \"\(result)\"])"
        )

        try await waitUntil("purchase_completed despite the batch") { [weak self] in
            self?.events.contains { $0.name == "purchase_completed" } == true
        }
        let completed = try XCTUnwrap(events.first { $0.name == "purchase_completed" })
        XCTAssertEqual(completed.properties["status"] as? String, "completed")
        XCTAssertEqual(completed.properties["server_confirmed"] as? Bool, true)

        gateway.stall = false
    }

    func testTheRuntimeRefusesAProtocolVersionItDoesNotSpeak() async throws {
        // Both directions carry `protocol_version`, and a mismatch is a drop
        // rather than a guess at what the fields mean.
        present(try document())
        try await waitForReady()

        let envelope: [String: Any] = [
            "protocol_version": 99,
            "type": "dismiss",
            "payload": [:] as [String: Any],
        ]
        let base64 = try JSONSerialization.data(withJSONObject: envelope).base64EncodedString()
        _ = try await evaluate("__appactor.receive([\"\(base64)\"])")
        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertFalse(
            events.contains { $0.name == "dismiss" },
            "a message from a protocol the runtime does not speak must not be acted on"
        )
    }

    // MARK: - Navigation

    func testTheScreenCannotNavigateAwayFromItself() async throws {
        present(try document())
        try await waitForReady()

        // Every one of these is a real origin the page can name and a string
        // prefix test would admit. In the first, everything before the `@` is
        // userinfo and the host is `example.org`; the second and third only
        // *start* with the origin. Any of them landing would put an
        // attacker-controlled page inside the paywall's web view, holding a
        // live bridge that can post `purchase` and read the replies.
        for target in [
            "https://screens.appactor.com@example.org/",
            "https://screens.appactor.com.evil.example/",
            "https://screens.appactor.comx/",
            "https://example.com/",
            "http://screens.appactor.com/",
        ] {
            _ = try? await evaluate("window.location.href = '\(target)'")
            try await Task.sleep(nanoseconds: 300_000_000)

            let host = try await evaluate("window.location.host")
            XCTAssertEqual(host as? String, "screens.appactor.com", "the page escaped to \(target)")
        }

        // The bridge is still the screen's own, not a stranger's.
        let channel = try await evaluate("typeof window.webkit.messageHandlers.appactorScreens.postMessage")
        XCTAssertEqual(channel as? String, "function")
    }

    func testABlockedNavigationIsNotTreatedAsAFailureToRender() async throws {
        // Cancelling a navigation must not make the screen look broken --
        // `presentScreen` turns that into a thrown error and the host app
        // falls back to its own paywall.
        present(try document())
        try await waitForReady()

        _ = try? await evaluate("window.location.href = 'https://example.com/'")
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertFalse(controller.failedToRender)
    }

    func testTheHostAppDismissingTheScreenStillReportsAnOutcome() async throws {
        // The runtime never asks to close here: the app takes the screen down
        // itself. Without a `viewDidDisappear` hook the caller awaiting
        // `presentScreen` would stay suspended for the life of the process.
        present(try document())
        try await waitForReady()

        var finishedWith: AppActorScreenOutcome?
        controller.onFinished = { finishedWith = $0 }

        window.rootViewController = UIViewController()
        try await waitUntil("the screen to report it was dismissed") { finishedWith != nil }
        XCTAssertEqual(finishedWith, .dismissed)
    }

    // MARK: - Failure modes

    func testADocumentNeedingANewerRuntimeFallsBackInsteadOfRenderingHalfAScreen() async throws {
        let json = """
        {"schemaVersion":1,"lookupKey":"paywall_main","kind":"paywall",
         "minRuntime":"99.0.0","layout":"fill",
         "slots":{"body":[{"id":"t","type":"text","value":"should never appear"}]}}
        """
        let document = try AppActorScreenDocument.parse(
            try JSONDecoder().decode(AppActorConfigValue.self, from: Data(json.utf8)),
            lookupKey: "paywall_main"
        )
        present(document)

        try await waitUntil("the runtime to report a fallback") { [weak self] in
            self?.events.contains { $0.name == "fallback_shown" } == true
        }
        let rendered = try await text(of: "t")
        XCTAssertNil(rendered, "a document the runtime cannot satisfy must render nothing at all")
    }
}

// MARK: - Doubles

#endif
