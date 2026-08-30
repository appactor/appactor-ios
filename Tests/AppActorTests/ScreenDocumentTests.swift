import XCTest
@testable import AppActor

final class ScreenDocumentTests: XCTestCase {

    // MARK: - Helpers

    /// Builds the ``AppActorConfigValue`` tree a document arrives as, by going
    /// through the same decoder the remote-config response uses.
    private func configValue(_ json: String) throws -> AppActorConfigValue {
        try JSONDecoder().decode(AppActorConfigValue.self, from: Data(json.utf8))
    }

    private func document(_ json: String, lookupKey: String = "paywall_main") throws -> AppActorScreenDocument {
        try AppActorScreenDocument.parse(configValue(json), lookupKey: lookupKey)
    }

    private func minimal(lookupKey: String = "paywall_main", slots: String = "{}") -> String {
        """
        {"schemaVersion":1,"lookupKey":"\(lookupKey)","kind":"paywall",
         "minRuntime":"1.0.0","layout":"sticky_footer","slots":\(slots)}
        """
    }

    // MARK: - Keys

    func testBuildsTheReservedRemoteConfigKey() {
        XCTAssertEqual(AppActorScreenDocument.remoteConfigKey(for: "paywall_main"), "screen.paywall_main")
    }

    func testAcceptsTheLookupKeysThePublisherCanProduce() {
        for key in ["paywall_main", "abc", "a-b_c", "onboarding2", "a1b"] {
            XCTAssertTrue(AppActorScreenDocument.isValidLookupKey(key), "\(key) should be valid")
        }
    }

    func testRefusesLookupKeysThatWouldNotSurviveAURLOrARename() {
        // Same shape the schema enforces. Checked in the SDK too because the
        // key becomes a path component of the page's origin: a space here is
        // an unbuildable URL two layers down, where the error no longer says
        // what the caller got wrong.
        for key in ["", "ab", "Paywall", "pay wall", "-paywall", "paywall-", "pay.wall", "pay/wall",
                    "pay\u{0000}wall", String(repeating: "a", count: 65)] {
            XCTAssertFalse(AppActorScreenDocument.isValidLookupKey(key), "\(key.debugDescription) should be refused")
        }
    }

    // MARK: - Parsing

    func testParsesAMinimalDocument() throws {
        let parsed = try document(minimal())
        XCTAssertEqual(parsed.lookupKey, "paywall_main")
        XCTAssertEqual(parsed.json["schemaVersion"] as? Int, 1)
        XCTAssertEqual(parsed.json["layout"] as? String, "sticky_footer")
        XCTAssertTrue(parsed.packageIds.isEmpty)
        XCTAssertTrue(parsed.comparisons.isEmpty)
    }

    func testRejectsAMissingDocument() {
        XCTAssertThrowsError(try AppActorScreenDocument.parse(nil, lookupKey: "paywall_main")) { error in
            XCTAssertEqual(error as? AppActorScreenDocumentError, .missing(lookupKey: "paywall_main"))
        }
    }

    func testRejectsAValueThatIsNotAnObject() throws {
        XCTAssertThrowsError(try document("[1,2,3]")) { error in
            XCTAssertEqual(error as? AppActorScreenDocumentError, .notAnObject)
        }
        XCTAssertThrowsError(try document("\"a string of json\"")) { error in
            XCTAssertEqual(error as? AppActorScreenDocumentError, .notAnObject)
        }
    }

    func testRejectsADocumentFiledUnderTheWrongKey() throws {
        // `lookupKey` leaves the device as `placement` on the receipt, so a
        // mismatch misattributes revenue to another screen and nothing
        // downstream ever notices.
        XCTAssertThrowsError(try document(minimal(lookupKey: "paywall_b"))) { error in
            XCTAssertEqual(
                error as? AppActorScreenDocumentError,
                .lookupKeyMismatch(expected: "paywall_main", found: "paywall_b")
            )
        }
    }

    func testRejectsADocumentWithNoLookupKeyAtAll() throws {
        XCTAssertThrowsError(try document(#"{"schemaVersion":1,"slots":{}}"#)) { error in
            XCTAssertEqual(
                error as? AppActorScreenDocumentError,
                .lookupKeyMismatch(expected: "paywall_main", found: nil)
            )
        }
    }

    func testKeepsUnknownFieldsInsteadOfDroppingThem() throws {
        // The SDK on the device is always older than the publisher. A field it
        // has never heard of belongs to the runtime, not to this parser.
        let parsed = try document("""
        {"schemaVersion":1,"lookupKey":"paywall_main","slots":{},"experimentalThing":{"a":[1,2]}}
        """)
        XCTAssertNotNil(parsed.json["experimentalThing"] as? [String: Any])
    }

    // MARK: - Packages in the tree

    func testFindsPackagesInDocumentOrder() throws {
        let parsed = try document(minimal(slots: """
        {"body":[{"id":"s","type":"stack","children":[
          {"id":"p1","type":"package","packageId":"pkg_annual","children":[]},
          {"id":"p2","type":"package","packageId":"pkg_monthly","children":[]}
        ]}]}
        """))
        XCTAssertEqual(parsed.packageIds, ["pkg_annual", "pkg_monthly"])
    }

    func testDeduplicatesARepeatedPackage() throws {
        let parsed = try document(minimal(slots: """
        {"body":[
          {"id":"p1","type":"package","packageId":"pkg_annual","children":[]},
          {"id":"p2","type":"package","packageId":"pkg_annual","children":[]}
        ]}
        """))
        XCTAssertEqual(parsed.packageIds, ["pkg_annual"])
    }

    func testReadsCompareToForDiscounts() throws {
        let parsed = try document(minimal(slots: """
        {"body":[
          {"id":"p1","type":"package","packageId":"pkg_annual","compareTo":"pkg_monthly","children":[]},
          {"id":"p2","type":"package","packageId":"pkg_monthly","children":[]}
        ]}
        """))
        XCTAssertEqual(parsed.comparisons, ["pkg_annual": "pkg_monthly"])
    }

    func testFindsAPackageHidingInAFallback() throws {
        // An older runtime renders the `fallback` of a type it does not know,
        // so the package inside one still has to be priced.
        let parsed = try document(minimal(slots: """
        {"body":[{"id":"x","type":"toggle",
          "fallback":{"id":"p1","type":"package","packageId":"pkg_annual","children":[]}}]}
        """))
        XCTAssertEqual(parsed.packageIds, ["pkg_annual"])
    }

    func testWalksEverySlot() throws {
        let parsed = try document(minimal(slots: """
        {"body":[{"id":"p1","type":"package","packageId":"pkg_a","children":[]}],
         "bottom":[{"id":"p2","type":"package","packageId":"pkg_b","children":[]}]}
        """))
        XCTAssertEqual(Set(parsed.packageIds), ["pkg_a", "pkg_b"])
    }

    func testSlotOrderIsStableAcrossRuns() throws {
        // Dictionary iteration order is unspecified, and the runtime selects
        // the first package in document order when nothing else is chosen. A
        // default that changes between launches would be a very quiet bug.
        let json = minimal(slots: """
        {"zzz":[{"id":"p3","type":"package","packageId":"pkg_z","children":[]}],
         "aaa":[{"id":"p1","type":"package","packageId":"pkg_a","children":[]}],
         "mmm":[{"id":"p2","type":"package","packageId":"pkg_m","children":[]}]}
        """)
        for _ in 0..<20 {
            XCTAssertEqual(try document(json).packageIds, ["pkg_a", "pkg_m", "pkg_z"])
        }
    }

    func testIgnoresAPackageWithNoIdentifier() throws {
        let parsed = try document(minimal(slots: """
        {"body":[{"id":"p1","type":"package","packageId":"","children":[]},
                 {"id":"p2","type":"package","children":[]}]}
        """))
        XCTAssertTrue(parsed.packageIds.isEmpty)
    }

    private func nested(depth: Int) -> String {
        var node = #"{"id":"leaf","type":"package","packageId":"pkg_deep","children":[]}"#
        for i in 0..<depth {
            node = #"{"id":"n\#(i)","type":"stack","children":[\#(node)]}"#
        }
        return "{\"body\":[\(node)]}"
    }

    func testSurvivesADeeplyNestedDocument() throws {
        // The document is server-supplied, so depth is somebody else's choice.
        // The walk is iterative and reaches the leaf without touching the
        // stack; a recursive one would be gambling on how deep a publisher
        // nests a layout.
        let parsed = try document(minimal(slots: nested(depth: 200)))
        XCTAssertEqual(parsed.packageIds, ["pkg_deep"])
    }

    func testFoundationRefusesADocumentNestedPastItsOwnLimit() {
        // Worth pinning: `JSONDecoder` caps nesting depth itself, so a
        // pathologically nested document never reaches the walker at all. The
        // node budget is the second line of defence here, not the first --
        // and the failure it produces is a thrown error, not a crash.
        XCTAssertThrowsError(try document(minimal(slots: nested(depth: 5_000))))
    }

    func testSurvivesAVeryWideDocument() throws {
        let many = (0..<5_000)
            .map { #"{"id":"p\#($0)","type":"package","packageId":"pkg_\#($0)","children":[]}"# }
            .joined(separator: ",")
        let parsed = try document(minimal(slots: "{\"body\":[\(many)]}"))
        XCTAssertLessThanOrEqual(parsed.packageIds.count, 400)
        XCTAssertFalse(parsed.packageIds.isEmpty)
    }

    /// The budget counts components, which is what the schema's `maxNodes`
    /// counts. Counting dequeued elements instead made it stricter than publish
    /// validation: every `fallback` and every array member burned budget too,
    /// so a document well inside the schema ceiling could run out mid-walk and
    /// silently drop a `package` near the end -- a plan missing from the
    /// paywall, with nothing in the log.
    func testFallbacksDoNotEatThePackageBudget() throws {
        // 300 components, every one of them carrying a fallback subtree, and
        // the package that matters last. Comfortably inside the schema's 400.
        let filler = (0..<299)
            .map { #"{"id":"t\#($0)","type":"text","value":"x","fallback":{"id":"f\#($0)","type":"text","value":"y"}}"# }
            .joined(separator: ",")
        let parsed = try document(
            minimal(slots: #"{"body":[\#(filler),{"id":"p","type":"package","packageId":"pkg_last","children":[]}]}"#)
        )
        XCTAssertEqual(parsed.packageIds, ["pkg_last"])
    }

    /// `image { ref: … }` needs an `assetBase` the SDK has nowhere to get yet,
    /// so the refs are collected on the way past and reported rather than
    /// rendering as silent holes.
    func testCollectsAssetRefs() throws {
        let ref = String(repeating: "a", count: 32)
        let parsed = try document(
            minimal(slots: #"{"body":[{"id":"i","type":"image","src":{"ref":"\#(ref)"},"width":10,"height":10}]}"#)
        )
        XCTAssertEqual(parsed.assetRefs, [ref])

        let byUrl = try document(
            minimal(slots: #"{"body":[{"id":"i","type":"image","src":{"url":"https://example.com/a.png"},"width":10,"height":10}]}"#)
        )
        XCTAssertTrue(byUrl.assetRefs.isEmpty)
    }

    // MARK: - Value conversion

    func testConvertsEveryConfigValueShape() throws {
        let value = try configValue("""
        {"b":true,"i":7,"d":1.5,"s":"x","n":null,"a":[1,"two",false],"o":{"nested":{"deep":1}}}
        """)
        let object = try XCTUnwrap(AppActorScreenDocument.foundationValue(value) as? [String: Any])

        XCTAssertEqual(object["b"] as? Bool, true)
        XCTAssertEqual(object["i"] as? Int, 7)
        XCTAssertEqual(object["d"] as? Double, 1.5)
        XCTAssertEqual(object["s"] as? String, "x")
        XCTAssertTrue(object["n"] is NSNull)
        XCTAssertEqual((object["a"] as? [Any])?.count, 3)
        XCTAssertNotNil(((object["o"] as? [String: Any])?["nested"] as? [String: Any])?["deep"])

        // Whatever comes out has to survive re-serialisation: it becomes the
        // `init` payload, and `JSONSerialization` traps on anything it cannot
        // encode rather than returning nil.
        XCTAssertTrue(JSONSerialization.isValidJSONObject(object))
    }

    func testRoundTripsADocumentThroughTheInitEnvelope() throws {
        let parsed = try document(minimal(slots: """
        {"body":[{"id":"t","type":"text","value":"₺39,99 \\" \\\\ 🧾"}]}
        """))
        let message = AppActorScreenInbound(.initialise, payload: ["document": parsed.json])
        let base64 = try XCTUnwrap(message.base64())
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: XCTUnwrap(Data(base64Encoded: base64))) as? [String: Any]
        )
        let document = try XCTUnwrap((object["payload"] as? [String: Any])?["document"] as? [String: Any])
        XCTAssertEqual(document["lookupKey"] as? String, "paywall_main")
    }
}
