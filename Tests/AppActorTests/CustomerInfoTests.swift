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

    // MARK: - Payment-mode status mapping (ios-2)

    func testServerStatusMapsOntoEntitlementHelpers() {
        let grace = AppActorEntitlementInfo(
            id: "premium",
            dto: AppActorEntitlementDTO(isActive: true, productId: "com.app.monthly", status: "grace")
        )
        XCTAssertEqual(grace.subscriptionStatus, .gracePeriod)
        XCTAssertTrue(grace.isInGracePeriod)
        XCTAssertFalse(grace.isInPaymentRetry)
        XCTAssertFalse(grace.isRevoked)

        let billingRetry = AppActorEntitlementInfo(
            id: "premium",
            dto: AppActorEntitlementDTO(isActive: false, productId: "com.app.monthly", status: "billing_retry")
        )
        XCTAssertEqual(billingRetry.subscriptionStatus, .billingRetry)
        XCTAssertTrue(billingRetry.isInPaymentRetry)
        XCTAssertFalse(billingRetry.isInGracePeriod)

        let revoked = AppActorEntitlementInfo(
            id: "premium",
            dto: AppActorEntitlementDTO(isActive: false, productId: "com.app.monthly", status: "revoked")
        )
        XCTAssertEqual(revoked.subscriptionStatus, .revoked)
        XCTAssertTrue(revoked.isRevoked)

        let active = AppActorEntitlementInfo(
            id: "premium",
            dto: AppActorEntitlementDTO(isActive: true, productId: "com.app.monthly", status: "active")
        )
        XCTAssertEqual(active.subscriptionStatus, .active)
        XCTAssertFalse(active.isInGracePeriod)
        XCTAssertFalse(active.isInPaymentRetry)
        XCTAssertFalse(active.isRevoked)

        // No server status → nil enum, helpers stay false (unchanged behavior).
        let none = AppActorEntitlementInfo(
            id: "premium",
            dto: AppActorEntitlementDTO(isActive: true, productId: "com.app.monthly", status: nil)
        )
        XCTAssertNil(none.subscriptionStatus)
        XCTAssertFalse(none.isInGracePeriod)

        // Unrecognized non-empty status → .unknown defensive fallback.
        let weird = AppActorEntitlementInfo(
            id: "premium",
            dto: AppActorEntitlementDTO(isActive: true, productId: "com.app.monthly", status: "something_new")
        )
        XCTAssertEqual(weird.subscriptionStatus, .unknown)
    }

    // MARK: - Strict collection decode (ios-16)

    func testEntitlementsShapeDriftThrowsInsteadOfSilentlyDropping() {
        // A value-type drift (isActive sent as a string) must fail loudly so
        // callers keep cached entitlements rather than treating the user as
        // having none.
        let json = """
        {
            "entitlements": { "premium": { "isActive": "yes", "productId": "com.app.monthly" } },
            "subscriptions": {},
            "nonSubscriptions": {}
        }
        """.data(using: .utf8)!

        XCTAssertThrowsError(try JSONDecoder().decode(AppActorCustomerDTO.self, from: json)) { error in
            XCTAssertTrue(error is DecodingError, "Shape drift should surface as a DecodingError")
        }
    }

    func testEntitlementsShapeDriftThrowsThroughResponseEnvelope() {
        // Real production path: PaymentClient decodes the envelope, not the bare
        // customer DTO. The envelope wraps the customer decode in `try?`, so on
        // drift it falls through to a thrown `keyNotFound` — still a DecodingError,
        // so PaymentClient.getCustomer fails loudly and the caller keeps cache.
        let json = """
        {
            "requestDate": "2026-02-14T22:42:17.027Z",
            "customer": {
                "entitlements": { "premium": { "isActive": "yes" } },
                "subscriptions": {},
                "nonSubscriptions": {}
            }
        }
        """.data(using: .utf8)!

        XCTAssertThrowsError(try JSONDecoder().decode(AppActorCustomerResponseDTO.self, from: json)) { error in
            XCTAssertTrue(error is DecodingError, "Shape drift must propagate as a DecodingError through the envelope")
        }
    }

    func testWellFormedEmptyCollectionsStillDecode() throws {
        let json = """
        { "entitlements": {}, "subscriptions": {}, "nonSubscriptions": {} }
        """.data(using: .utf8)!

        let dto = try JSONDecoder().decode(AppActorCustomerDTO.self, from: json)
        XCTAssertEqual(dto.entitlements?.count, 0)
        XCTAssertEqual(dto.subscriptions?.count, 0)
        XCTAssertEqual(dto.nonSubscriptions?.count, 0)
    }

    func testMissingCollectionsDecodeAsNil() throws {
        let json = "{}".data(using: .utf8)!
        let dto = try JSONDecoder().decode(AppActorCustomerDTO.self, from: json)
        XCTAssertNil(dto.entitlements)
        XCTAssertNil(dto.subscriptions)
        XCTAssertNil(dto.nonSubscriptions)
    }
}
