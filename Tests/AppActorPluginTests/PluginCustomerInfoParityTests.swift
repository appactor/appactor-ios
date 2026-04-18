import XCTest
@testable import AppActorPlugin
import AppActor

@MainActor
final class PluginCustomerInfoParityTests: XCTestCase {

    func testEntitlementEncodingUsesCanonicalStatusAndPurchaseDates() throws {
        let originalPurchaseDate = Date(timeIntervalSince1970: 1_710_000_000)
        let renewedAt = Date(timeIntervalSince1970: 1_712_000_000)
        let entitlement = AppActorEntitlementInfo(
            id: "premium",
            isActive: true,
            productID: "com.app.monthly",
            originalPurchaseDate: originalPurchaseDate,
            ownershipType: .purchased,
            periodType: .monthly,
            willRenew: true,
            subscriptionStatus: .gracePeriod,
            store: .appStore,
            renewedAt: renewedAt
        )
        let payload = try encodedEntitlement(from: entitlement)

        XCTAssertEqual(payload["status"] as? String, "grace_period")
        XCTAssertEqual(payload["subscription_status"] as? String, "grace_period")
        XCTAssertEqual(payload["purchase_date"] as? String, AppActorPluginCoder.isoDateFormatter.string(from: originalPurchaseDate))
        XCTAssertEqual(payload["latest_purchase_date"] as? String, AppActorPluginCoder.isoDateFormatter.string(from: renewedAt))
        XCTAssertEqual(payload["original_purchase_date"] as? String, AppActorPluginCoder.isoDateFormatter.string(from: originalPurchaseDate))
    }

    func testActiveEntitlementWithoutSubscriptionStatusFallsBackToActiveAndOriginalPurchaseDate() throws {
        let originalPurchaseDate = Date(timeIntervalSince1970: 1_710_000_000)
        let entitlement = AppActorEntitlementInfo(
            id: "premium",
            isActive: true,
            productID: "com.app.lifetime",
            originalPurchaseDate: originalPurchaseDate,
            ownershipType: .purchased,
            periodType: .lifetime,
            willRenew: false,
            store: .appStore
        )
        let payload = try encodedEntitlement(from: entitlement)
        let expectedDate = AppActorPluginCoder.isoDateFormatter.string(from: originalPurchaseDate)

        XCTAssertEqual(payload["status"] as? String, "active")
        XCTAssertEqual(payload["purchase_date"] as? String, expectedDate)
        XCTAssertEqual(payload["latest_purchase_date"] as? String, expectedDate)
    }

    private func encodedEntitlement(from entitlement: AppActorEntitlementInfo) throws -> [String: Any] {
        let customerInfo = AppActorCustomerInfo(
            entitlements: [entitlement.id: entitlement],
            snapshotDate: .distantPast
        )
        let payload = try encodedJSONObject(PluginCustomerInfo(from: customerInfo))
        let entitlements = try XCTUnwrap(payload["entitlements"] as? [String: Any])
        return try XCTUnwrap(entitlements[entitlement.id] as? [String: Any])
    }

    private func encodedJSONObject<T: Encodable>(_ value: T) throws -> [String: Any] {
        let data = try AppActorPluginCoder.encoder.encode(value)
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
