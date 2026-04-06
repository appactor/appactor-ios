import XCTest
import StoreKit
@testable import AppActor

// MARK: - OfferingsUnificationTests
//
// Validates the unified AppActorOffering, AppActorOfferings, and AppActorPurchaseResult
// types introduced in Phase 10 Plan 01. Covers:
// - Codable roundtrip for payment-mode shape (all fields populated)
// - Codable roundtrip for minimal shape (lookupKey nil, metadata nil)
// - Packages exclusion verification (not in CodingKeys — always [] after decode)
// - AppActorOfferings container Codable roundtrip with productEntitlements
// - AppActorOfferings init sets current directly (not looked up by id)
// - offering(id:) and offering(lookupKey:) lookup correctness
// - offering(lookupKey:) returns nil when all lookupKeys are nil
// - AppActorPurchaseResult unified success case with labeled parameters

@MainActor
final class OfferingsUnificationTests: XCTestCase {

    // MARK: - Shared Encoder / Decoder

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    // MARK: - Test 1: Payment-Mode Shape Codable Roundtrip

    func testOfferingCodableRoundtripPaymentShape() throws {
        let original = AppActorOffering(
            id: "default",
            displayName: "Premium Plan",
            isCurrent: true,
            lookupKey: "premium",
            metadata: ["tier": "1"],
            packages: []
        )

        let data = try encoder.encode(original)
        let decoded = try decoder.decode(AppActorOffering.self, from: data)

        // All scalar fields must be preserved
        XCTAssertEqual(decoded.id, "default", "id must survive Codable roundtrip")
        XCTAssertEqual(decoded.displayName, "Premium Plan", "displayName must survive Codable roundtrip")
        XCTAssertTrue(decoded.isCurrent, "isCurrent must survive Codable roundtrip")
        XCTAssertEqual(decoded.lookupKey, "premium", "lookupKey must survive Codable roundtrip")
        XCTAssertEqual(decoded.metadata, ["tier": "1"], "metadata must survive Codable roundtrip")

        // Packages excluded from CodingKeys — always empty after decode
        XCTAssertTrue(decoded.packages.isEmpty, "packages must be empty after decode (excluded from CodingKeys)")
    }

    // MARK: - Test 2: Minimal Shape Codable Roundtrip

    func testOfferingCodableRoundtripLocalShape() throws {
        let original = AppActorOffering(
            id: "local_offering",
            displayName: "My App Offering",
            isCurrent: false,
            lookupKey: nil,
            metadata: nil,
            packages: []
        )

        let data = try encoder.encode(original)
        let decoded = try decoder.decode(AppActorOffering.self, from: data)

        XCTAssertEqual(decoded.id, "local_offering")
        XCTAssertEqual(decoded.displayName, "My App Offering")
        XCTAssertFalse(decoded.isCurrent, "isCurrent false must survive roundtrip")
        XCTAssertNil(decoded.lookupKey, "lookupKey nil must survive roundtrip")
        XCTAssertNil(decoded.metadata, "metadata nil must survive roundtrip")
        XCTAssertTrue(decoded.packages.isEmpty, "packages must be empty after decode")
    }

    // MARK: - Test 3: Packages Excluded from Encoded JSON

    func testOfferingCodablePackagesExcluded() throws {
        // Construct an offering with packages via a helper that builds packages inline.
        // We can't construct non-empty packages without StoreKit products,
        // but we can verify the encoded JSON has no "packages" key.
        let original = AppActorOffering(
            id: "offering_with_packages_check",
            displayName: "With Packages",
            isCurrent: false,
            lookupKey: nil,
            metadata: nil,
            packages: []
        )

        let data = try encoder.encode(original)

        // Parse raw JSON and verify "packages" key does NOT exist
        let raw = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any],
            "Encoded JSON should be a dictionary"
        )
        XCTAssertNil(raw["packages"], "packages key must NOT appear in encoded JSON (excluded from CodingKeys)")

        // Verify the keys that ARE encoded
        XCTAssertNotNil(raw["id"])
        XCTAssertNotNil(raw["displayName"])
        XCTAssertNotNil(raw["isCurrent"])

        // Decode and verify packages is empty
        let decoded = try decoder.decode(AppActorOffering.self, from: data)
        XCTAssertTrue(decoded.packages.isEmpty, "packages must be [] after decode (excluded from CodingKeys)")
    }

    // MARK: - Test 4: AppActorOfferings Container Codable Roundtrip

    func testOfferingsCodableRoundtrip() throws {
        let offering1 = AppActorOffering(
            id: "default",
            displayName: "Default",
            isCurrent: true,
            lookupKey: "default_key",
            metadata: nil,
            packages: []
        )
        let offering2 = AppActorOffering(
            id: "annual",
            displayName: "Annual",
            isCurrent: false,
            lookupKey: "annual_key",
            metadata: ["discount": "20pct"],
            packages: []
        )

        let original = AppActorOfferings(
            current: offering1,
            all: ["default": offering1, "annual": offering2],
            productEntitlements: ["com.app.annual": ["premium"]]
        )

        let data = try encoder.encode(original)
        let decoded = try decoder.decode(AppActorOfferings.self, from: data)

        // current offering id preserved
        XCTAssertEqual(decoded.current?.id, "default", "current offering id must survive roundtrip")
        XCTAssertEqual(decoded.current?.displayName, "Default")
        XCTAssertTrue(decoded.current?.isCurrent == true)

        // all dict count preserved
        XCTAssertEqual(decoded.all.count, 2, "all dict must have 2 offerings after roundtrip")
        XCTAssertNotNil(decoded.all["default"])
        XCTAssertNotNil(decoded.all["annual"])

        // Offerings in all have empty packages after decode (expected behavior)
        XCTAssertTrue(decoded.all["default"]?.packages.isEmpty == true, "packages in all offerings empty after decode")

        // productEntitlements preserved
        XCTAssertEqual(
            decoded.productEntitlements?["com.app.annual"],
            ["premium"],
            "productEntitlements must survive roundtrip"
        )
    }

    // MARK: - Test 5: init(current:all:productEntitlements:) Sets Current Directly

    func testOfferingsInitCurrentDirect() {
        let offering1 = AppActorOffering(
            id: "special",
            displayName: "Special Offering",
            isCurrent: false,  // isCurrent=false in the instance
            lookupKey: nil,
            metadata: nil,
            packages: []
        )
        let offering2 = AppActorOffering(
            id: "other",
            displayName: "Other",
            isCurrent: false,
            lookupKey: nil,
            metadata: nil,
            packages: []
        )

        // Pass offering1 as current directly (not a lookup by id)
        let offerings = AppActorOfferings(
            current: offering1,
            all: ["special": offering1, "other": offering2]
            // productEntitlements omitted — should default to nil
        )

        // current is the exact offering passed (verified by id)
        XCTAssertEqual(offerings.current?.id, "special", "current must be the exact offering passed to init")

        // productEntitlements defaults to nil when omitted
        XCTAssertNil(offerings.productEntitlements, "productEntitlements must be nil when omitted from init")

        // all dict is correctly set
        XCTAssertEqual(offerings.all.count, 2)
    }

    // MARK: - Test 6: offering(id:) and offering(lookupKey:) Lookup

    func testOfferingLookupByIdAndKey() {
        let offeringA = AppActorOffering(
            id: "plan_a",
            displayName: "Plan A",
            isCurrent: true,
            lookupKey: "plan_a_key",
            metadata: nil,
            packages: []
        )
        let offeringB = AppActorOffering(
            id: "plan_b",
            displayName: "Plan B",
            isCurrent: false,
            lookupKey: "plan_b_key",
            metadata: nil,
            packages: []
        )

        let offerings = AppActorOfferings(
            current: offeringA,
            all: ["plan_a": offeringA, "plan_b": offeringB]
        )

        // offering(id:) returns the correct offering
        XCTAssertEqual(offerings.offering(id: "plan_a")?.id, "plan_a", "offering(id:) must return correct match")
        XCTAssertEqual(offerings.offering(id: "plan_b")?.id, "plan_b", "offering(id:) must return correct match")
        XCTAssertNil(offerings.offering(id: "nonexistent"), "offering(id:) must return nil for unknown id")

        // offering(lookupKey:) returns the correct offering
        XCTAssertEqual(offerings.offering(lookupKey: "plan_a_key")?.id, "plan_a", "offering(lookupKey:) must return correct match")
        XCTAssertEqual(offerings.offering(lookupKey: "plan_b_key")?.id, "plan_b", "offering(lookupKey:) must return correct match")
        XCTAssertNil(offerings.offering(lookupKey: "nonexistent"), "offering(lookupKey:) must return nil for unknown key")
    }

    // MARK: - Test 7: offering(lookupKey:) Returns Nil When lookupKey is Nil

    func testOfferingLookupKeyNilLocalMode() {
        // Offerings with lookupKey: nil
        let localOffering1 = AppActorOffering(
            id: "offering_1",
            displayName: "Offering 1",
            isCurrent: true,
            lookupKey: nil,
            metadata: nil,
            packages: []
        )
        let localOffering2 = AppActorOffering(
            id: "offering_2",
            displayName: "Offering 2",
            isCurrent: false,
            lookupKey: nil,
            metadata: nil,
            packages: []
        )

        let offerings = AppActorOfferings(
            current: localOffering1,
            all: ["offering_1": localOffering1, "offering_2": localOffering2]
        )

        // offering(lookupKey:) must return nil for any key when all offerings have nil lookupKey
        XCTAssertNil(offerings.offering(lookupKey: "anything"), "offering(lookupKey:) must return nil when all lookupKeys are nil")
        XCTAssertNil(offerings.offering(lookupKey: "offering_1"), "offering(lookupKey:) must return nil — id is not a lookupKey")
        XCTAssertNil(offerings.offering(lookupKey: ""), "offering(lookupKey:) must return nil for empty string")

        // offering(id:) still works correctly
        XCTAssertNotNil(offerings.offering(id: "offering_1"), "offering(id:) must still work")
    }

    // MARK: - Test 8: AppActorPurchaseResult Unified Success Case

    func testPurchaseResultUnifiedSuccessCase() {
        // Test success case with purchaseInfo: nil
        let result = AppActorPurchaseResult.success(customerInfo: .empty, purchaseInfo: nil)

        switch result {
        case .success(let customerInfo, let purchaseInfo):
            XCTAssertEqual(customerInfo.entitlements.count, 0, "customerInfo.empty has no entitlements")
            XCTAssertNil(purchaseInfo, "purchaseInfo must be nil in success case without native purchase metadata")
        case .cancelled:
            XCTFail("Expected .success but got .cancelled")
        case .pending:
            XCTFail("Expected .success but got .pending")
        }

        // Test .cancelled switches correctly
        let cancelledResult = AppActorPurchaseResult.cancelled
        if case .cancelled = cancelledResult {
            // correct
        } else {
            XCTFail("Expected .cancelled to switch correctly")
        }

        // Test .pending switches correctly
        let pendingResult = AppActorPurchaseResult.pending
        if case .pending = pendingResult {
            // correct
        } else {
            XCTFail("Expected .pending to switch correctly")
        }
    }
}
