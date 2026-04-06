import XCTest
@testable import AppActor

final class CustomerInfoTests: XCTestCase {

    // MARK: - Empty CustomerInfo

    func testEmptyCustomerInfo() {
        let info = AppActorCustomerInfo.empty
        XCTAssertTrue(info.entitlements.isEmpty)
        XCTAssertTrue(info.activeEntitlementKeys.isEmpty)
        XCTAssertNil(info.consumableBalances)
        XCTAssertNil(info.tokenBalance)
        XCTAssertNil(info.entitlements["premium"])
    }

    // MARK: - Entitlement Check

    func testEntitlementAccess() {
        let info = AppActorCustomerInfo(
            entitlements: [
                "premium": AppActorEntitlementInfo(id: "premium", isActive: true, productID: "com.test.monthly"),
                "pro": AppActorEntitlementInfo(id: "pro", isActive: false)
            ],
            subscriptions: [:],
            nonSubscriptions: [:],
            consumableBalances: nil,
            snapshotDate: Date()
        )

        XCTAssertTrue(info.entitlements["premium"]?.isActive == true)
        XCTAssertFalse(info.entitlements["pro"]?.isActive == true)
        XCTAssertNil(info.entitlements["nonexistent"])
    }

    // MARK: - Entitlement Lookup

    func testEntitlementLookup() {
        let info = AppActorCustomerInfo(
            entitlements: [
                "premium": AppActorEntitlementInfo(
                    id: "premium",
                    isActive: true,
                    productID: "com.test.monthly",
                    periodType: .monthly,
                    willRenew: true
                )
            ],
            subscriptions: [:],
            nonSubscriptions: [:],
            consumableBalances: nil,
            snapshotDate: Date()
        )

        let ent = info.entitlements["premium"]
        XCTAssertNotNil(ent)
        XCTAssertTrue(ent!.isActive)
        XCTAssertEqual(ent!.productID, "com.test.monthly")
        XCTAssertEqual(ent!.periodType, .monthly)
        XCTAssertTrue(ent!.willRenew)

        XCTAssertNil(info.entitlements["nonexistent"])
    }

    // MARK: - Codable Roundtrip

    func testCodableRoundtrip() throws {
        let original = AppActorCustomerInfo(
            entitlements: [
                "premium": AppActorEntitlementInfo(
                    id: "premium",
                    isActive: true,
                    productID: "com.test.annual",
                    originalPurchaseDate: Date(timeIntervalSince1970: 1700000000),
                    expirationDate: Date(timeIntervalSince1970: 1731536000),
                    ownershipType: .purchased,
                    periodType: .annual,
                    willRenew: true,
                    subscriptionStatus: .active
                )
            ],
            subscriptions: [:],
            nonSubscriptions: [:],
            consumableBalances: ["com.test.coins": 42],
            tokenBalance: AppActorTokenBalance(renewable: 500, nonRenewable: 200),
            snapshotDate: Date(timeIntervalSince1970: 1700000000)
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(original)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(AppActorCustomerInfo.self, from: data)

        XCTAssertEqual(decoded.entitlements.count, original.entitlements.count)
        XCTAssertTrue(decoded.entitlements["premium"]?.isActive == true)
        XCTAssertEqual(decoded.consumableBalances?["com.test.coins"], 42)
        XCTAssertEqual(decoded.tokenBalance?.renewable, 500)
        XCTAssertEqual(decoded.tokenBalance?.nonRenewable, 200)
        XCTAssertEqual(decoded.tokenBalance?.total, 700)

        let decodedEnt = decoded.entitlements["premium"]!
        XCTAssertEqual(decodedEnt.productID, "com.test.annual")
        XCTAssertEqual(decodedEnt.ownershipType, .purchased)
        XCTAssertEqual(decodedEnt.periodType, .annual)
        XCTAssertTrue(decodedEnt.willRenew)
        XCTAssertEqual(decodedEnt.subscriptionStatus, .active)
    }

    func testTokenBalanceInitComputesTotalWhenOmitted() {
        let balance = AppActorTokenBalance(renewable: 120, nonRenewable: 30)
        XCTAssertEqual(balance.renewable, 120)
        XCTAssertEqual(balance.nonRenewable, 30)
        XCTAssertEqual(balance.total, 150)
    }

    func testCodableRoundtripSubscriptionStatusNil() throws {
        // Simulate loading an old persisted snapshot without subscriptionStatus
        let jsonString = """
        {
            "id": "premium",
            "isActive": true,
            "ownershipType": "purchased",
            "periodType": "annual",
            "willRenew": false
        }
        """
        let data = jsonString.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(AppActorEntitlementInfo.self, from: data)
        XCTAssertNil(decoded.subscriptionStatus, "Old JSON without subscriptionStatus should decode as nil")
        XCTAssertFalse(decoded.isInGracePeriod)
        XCTAssertFalse(decoded.isInPaymentRetry)
        XCTAssertFalse(decoded.isRevoked)
    }

    // MARK: - EntitlementInfo Properties

    func testEntitlementInfoDefaults() {
        let info = AppActorEntitlementInfo(id: "test")
        XCTAssertFalse(info.isActive)
        XCTAssertNil(info.productID)
        XCTAssertNil(info.originalPurchaseDate)
        XCTAssertNil(info.expirationDate)
        XCTAssertEqual(info.ownershipType, .purchased)
        XCTAssertEqual(info.periodType, .unknown)
        XCTAssertFalse(info.willRenew)
        XCTAssertNil(info.subscriptionStatus)
        XCTAssertFalse(info.isInGracePeriod)
        XCTAssertFalse(info.isInPaymentRetry)
        XCTAssertFalse(info.isRevoked)
    }

    func testEntitlementInfoGracePeriod() {
        let info = AppActorEntitlementInfo(
            id: "premium",
            isActive: true,
            productID: "com.test.monthly",
            subscriptionStatus: .gracePeriod
        )
        XCTAssertTrue(info.isActive)
        XCTAssertTrue(info.isInGracePeriod)
    }

    func testEntitlementInfoRevoked() {
        let info = AppActorEntitlementInfo(
            id: "premium",
            isActive: false,
            productID: "com.test.monthly",
            subscriptionStatus: .revoked
        )
        XCTAssertFalse(info.isActive)
        XCTAssertTrue(info.isRevoked)
    }

    func testEntitlementInfoBillingRetry() {
        let info = AppActorEntitlementInfo(
            id: "premium",
            isActive: false,
            productID: "com.test.monthly",
            subscriptionStatus: .billingRetry
        )
        XCTAssertFalse(info.isActive)
        XCTAssertTrue(info.isInPaymentRetry)
        XCTAssertEqual(info.subscriptionStatus, .billingRetry)
    }

    func testEntitlementInfoFamilyShared() {
        let info = AppActorEntitlementInfo(
            id: "premium",
            isActive: true,
            productID: "com.test.annual",
            ownershipType: .familyShared
        )
        XCTAssertEqual(info.ownershipType, .familyShared)
    }

    // MARK: - activeEntitlementKeys

    func testActiveEntitlementKeys() {
        let info = AppActorCustomerInfo(
            entitlements: [
                "premium": AppActorEntitlementInfo(id: "premium", isActive: true, productID: "com.test.monthly"),
                "pro": AppActorEntitlementInfo(id: "pro", isActive: false),
                "lifetime": AppActorEntitlementInfo(id: "lifetime", isActive: true, productID: "com.test.lifetime")
            ],
            subscriptions: [:],
            nonSubscriptions: [:],
            snapshotDate: Date()
        )

        XCTAssertEqual(info.activeEntitlementKeys.count, 2)
        XCTAssertTrue(info.activeEntitlementKeys.contains("premium"))
        XCTAssertTrue(info.activeEntitlementKeys.contains("lifetime"))
        XCTAssertFalse(info.activeEntitlementKeys.contains("pro"))
    }

    // MARK: - hasActiveEntitlement

    func testHasActiveEntitlement() {
        let info = AppActorCustomerInfo(
            entitlements: [
                "premium": AppActorEntitlementInfo(id: "premium", isActive: true),
                "pro": AppActorEntitlementInfo(id: "pro", isActive: false)
            ],
            snapshotDate: Date()
        )

        XCTAssertTrue(info.hasActiveEntitlement("premium"))
        XCTAssertFalse(info.hasActiveEntitlement("pro"))
        XCTAssertFalse(info.hasActiveEntitlement("nonexistent"))
    }
}
