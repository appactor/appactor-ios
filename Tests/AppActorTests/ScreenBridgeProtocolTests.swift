import XCTest
@testable import AppActor

/// The wire format is frozen and shared with the runtime and the Android SDK,
/// so these tests are as much a written record of the contract as a check on
/// the code.
final class ScreenBridgeProtocolTests: XCTestCase {

    // MARK: - Helpers

    private func envelope(
        version: Any? = 1,
        type: Any? = "purchase",
        requestId: Any? = "r1-abc",
        payload: Any? = ["packageId": "pkg_annual"]
    ) -> String {
        var object: [String: Any] = [:]
        if let version { object["protocol_version"] = version }
        if let type { object["type"] = type }
        if let requestId { object["requestId"] = requestId }
        if let payload { object["payload"] = payload }
        let data = try! JSONSerialization.data(withJSONObject: object)
        return String(decoding: data, as: UTF8.self)
    }

    private func decoded(_ json: String) -> AppActorScreenOutbound? {
        try? AppActorScreenOutbound.decode(json).get()
    }

    private func failure(_ body: Any) -> AppActorScreenDecodeFailure? {
        if case .failure(let reason) = AppActorScreenOutbound.decode(body) { return reason }
        return nil
    }

    // MARK: - Decoding

    func testDecodesAPurchase() throws {
        let message = try XCTUnwrap(decoded(envelope()))
        XCTAssertEqual(message.type, .purchase)
        XCTAssertEqual(message.requestId, "r1-abc")
        XCTAssertEqual(message.string("packageId"), "pkg_annual")
    }

    func testDecodesEveryOutboundTypeTheRuntimeCanSend() throws {
        // A type the runtime sends but native does not recognise is a message
        // silently dropped in production, so the two lists have to agree.
        for type in ["ready", "purchase", "restore", "close", "navigate", "openUrl", "event", "error"] {
            let message = decoded(envelope(type: type, payload: [:]))
            XCTAssertEqual(message?.type.rawValue, type, "type \"\(type)\" did not decode")
        }
        XCTAssertEqual(AppActorScreenOutboundType.allCases.count, 8)
    }

    func testRejectsANonStringBody() {
        XCTAssertEqual(failure(["type": "purchase"]), .notAString)
        XCTAssertEqual(failure(42), .notAString)
    }

    func testRejectsMalformedJSON() {
        XCTAssertEqual(failure("{not json"), .malformedJSON)
    }

    func testRejectsAJSONArray() {
        XCTAssertEqual(failure("[1,2,3]"), .notAnObject)
    }

    func testRejectsAProtocolVersionMismatch() {
        XCTAssertEqual(failure(envelope(version: 2)), .protocolMismatch(received: 2))
        XCTAssertEqual(failure(envelope(version: nil)), .protocolMismatch(received: nil))
    }

    /// JSON has one number type, so `1` and `1.0` are the same version and both
    /// have to pass. Everything else that merely *truncates* to a version we
    /// know must not: reading the field with `NSNumber.intValue` alone accepts
    /// 1.5 as 1, and `true` bridges to an NSNumber that reads as 1 as well.
    func testVersionIsComparedExactlyNotTruncated() {
        XCTAssertNotNil(decoded(envelope(version: 1.0)))

        XCTAssertEqual(failure(envelope(version: 1.5)), .protocolMismatch(received: 1))
        XCTAssertEqual(failure(envelope(version: 0.5)), .protocolMismatch(received: 0))
        XCTAssertEqual(failure(envelope(version: true)), .protocolMismatch(received: nil))
        XCTAssertEqual(failure(envelope(version: "1")), .protocolMismatch(received: nil))
    }

    func testRejectsAnUnknownType() {
        XCTAssertEqual(failure(envelope(type: "teleport")), .unknownType("teleport"))
    }

    func testRejectsAMissingPayload() {
        XCTAssertEqual(failure(envelope(payload: nil)), .missingPayload)
        // A payload that is not an object is the same defect: every reader
        // downstream subscripts it.
        XCTAssertEqual(failure(envelope(payload: "packageId=x")), .missingPayload)
    }

    func testAcceptsAMessageWithNoRequestId() throws {
        // Only `purchase` and `restore` require one, and that requirement is
        // enforced where it matters — by the session, which knows the type.
        let message = try XCTUnwrap(decoded(envelope(type: "close", requestId: nil, payload: [:])))
        XCTAssertNil(message.requestId)
    }

    func testRejectsAMessageOverTheSizeLimit() {
        let huge = String(repeating: "a", count: AppActorScreenProtocol.maxInboundMessageBytes + 1)
        guard case .tooLarge = failure(huge) else {
            return XCTFail("an oversized message should be refused before it is parsed")
        }
    }

    func testSizeLimitCountsBytesNotCharacters() {
        // Four bytes per emoji: a limit counted in characters would admit four
        // times the memory it meant to.
        let emoji = String(repeating: "🙂", count: AppActorScreenProtocol.maxInboundMessageBytes / 4 + 1)
        guard case .tooLarge = failure(emoji) else {
            return XCTFail("the limit should be measured in UTF-8 bytes")
        }
    }

    // MARK: - Encoding

    func testEncodesAnEnvelopeTheRuntimeCanRead() throws {
        let message = AppActorScreenInbound(.purchaseResult, requestId: "r1-abc", payload: [
            "status": "completed",
            "server_confirmed": true,
        ])
        let base64 = try XCTUnwrap(message.base64())
        let json = try XCTUnwrap(Data(base64Encoded: base64))
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: json) as? [String: Any])

        XCTAssertEqual(object["protocol_version"] as? Int, 1)
        XCTAssertEqual(object["type"] as? String, "purchaseResult")
        XCTAssertEqual(object["requestId"] as? String, "r1-abc")
        let payload = try XCTUnwrap(object["payload"] as? [String: Any])
        XCTAssertEqual(payload["status"] as? String, "completed")
        XCTAssertEqual(payload["server_confirmed"] as? Bool, true)
    }

    func testInitIsSpelledInitNotInitialise() throws {
        // `init` is a Swift keyword, so the case is named `initialise`. If the
        // raw value ever follows the case name the runtime stops recognising
        // the first message it is ever sent.
        let base64 = try XCTUnwrap(AppActorScreenInbound(.initialise).base64())
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: XCTUnwrap(Data(base64Encoded: base64))) as? [String: Any]
        )
        XCTAssertEqual(object["type"] as? String, "init")
    }

    func testOmitsRequestIdWhenThereIsNone() throws {
        let base64 = try XCTUnwrap(AppActorScreenInbound(.dismiss).base64())
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: XCTUnwrap(Data(base64Encoded: base64))) as? [String: Any]
        )
        XCTAssertNil(object["requestId"])
    }

    func testRefusesToEncodeANonJSONPayload() {
        // A `Date` reaching the payload is a mapping bug. It must come back as
        // nil, not as a `JSONSerialization` trap inside the host app.
        XCTAssertNil(AppActorScreenInbound(.packages, payload: ["at": Date()]).base64())
        XCTAssertNil(AppActorScreenInbound(.packages, payload: ["price": Double.nan]).base64())
    }

    func testDecimalPricesEncodeFine() throws {
        // Worth pinning: `Decimal` bridges to `NSNumber`, so a price built
        // from one is valid JSON and does not need converting first.
        XCTAssertNotNil(AppActorScreenInbound(.packages, payload: ["price": Decimal(9.99)]).base64())
    }

    func testSurvivesQuotesNewlinesAndAstralCharacters() throws {
        // The reason the transport is base64 at all: these are ordinary things
        // to find in a localised price string, and every one of them breaks a
        // JSON string interpolated into `evaluateJavaScript`.
        let awkward = "\"₺9,99\" \\ \n\r\u{2028}\u{2029} 🧾 \u{0}"
        let message = AppActorScreenInbound(.purchaseResult, requestId: "r1", payload: ["message": awkward])
        let base64 = try XCTUnwrap(message.base64())
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: XCTUnwrap(Data(base64Encoded: base64))) as? [String: Any]
        )
        XCTAssertEqual((object["payload"] as? [String: Any])?["message"] as? String, awkward)
    }

    // MARK: - Batching

    func testBatchesAsAnArrayEvenForOneMessage() throws {
        let source = try XCTUnwrap(AppActorScreenInboundBatch.javaScript(for: [AppActorScreenInbound(.dismiss)]))
        XCTAssertTrue(source.hasPrefix("__appactor.receive(["))
        XCTAssertTrue(source.hasSuffix("])"))
    }

    func testBatchKeepsOrderAndCount() throws {
        let source = try XCTUnwrap(
            AppActorScreenInboundBatch.javaScript(for: [
                AppActorScreenInbound(.packages, payload: ["packages": []]),
                AppActorScreenInbound(.dismiss),
            ])
        )
        XCTAssertEqual(source.components(separatedBy: "\",\"").count, 2)
    }

    func testBatchSkipsWhatItCannotEncodeRatherThanDroppingTheRest() throws {
        // The same guarantee the runtime makes on its side: one bad message in
        // a batch must not take the good ones with it.
        let source = try XCTUnwrap(
            AppActorScreenInboundBatch.javaScript(for: [
                AppActorScreenInbound(.packages, payload: ["bad": Date()]),
                AppActorScreenInbound(.purchaseResult, requestId: "r1", payload: ["status": "completed"]),
            ])
        )
        XCTAssertEqual(source.components(separatedBy: "\",\"").count, 1)
        let base64 = source
            .replacingOccurrences(of: "__appactor.receive([\"", with: "")
            .replacingOccurrences(of: "\"])", with: "")
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: XCTUnwrap(Data(base64Encoded: base64))) as? [String: Any]
        )
        XCTAssertEqual(object["type"] as? String, "purchaseResult")
    }

    func testBatchIsNilWhenNothingSurvives() {
        XCTAssertNil(AppActorScreenInboundBatch.javaScript(for: []))
        XCTAssertNil(AppActorScreenInboundBatch.javaScript(for: [AppActorScreenInbound(.dismiss, payload: ["x": Date()])]))
    }

    func testBatchSourceCarriesNothingThatCouldEscapeAJSStringLiteral() throws {
        let source = try XCTUnwrap(
            AppActorScreenInboundBatch.javaScript(for: [
                AppActorScreenInbound(.purchaseResult, requestId: "r1", payload: ["message": "\" ; alert(1) //"]),
            ])
        )
        let payload = source
            .replacingOccurrences(of: "__appactor.receive([", with: "")
            .replacingOccurrences(of: "])", with: "")
        let inner = payload.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        XCTAssertTrue(
            inner.unicodeScalars.allSatisfy { CharacterSet.base64().contains($0) },
            "base64 payload contained something outside the base64 alphabet"
        )
    }
}

private extension CharacterSet {
    static func base64() -> CharacterSet {
        CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=")
    }
}
