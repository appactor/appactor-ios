import XCTest
@testable import AppActor

// MARK: - CustomerInfoUnificationTests
//
// Validates the unified AppActorCustomerInfo and AppActorEntitlementInfo types
// introduced in Phase 9 Plan 01. Covers:
// - Full Codable roundtrip with dict-shape collections and payment-mode fields
// - Empty-state roundtrip for AppActorCustomerInfo.empty
// - Backward-compat array-shape decode (old payment-mode JSON shape)
// - Typed enum (store, cancellationReason, periodType) roundtrip
// - Unknown enum value fallback to .unknown
// - AppActorSubscriptionInfo Codable roundtrip
// - AppActorNonSubscription Codable roundtrip
// - Shape roundtrip (consumableBalances populated, payment fields nil)

@MainActor
final class CustomerInfoUnificationTests: XCTestCase {

    // MARK: - Shared Encoder / Decoder

    private let encoder: JSONEncoder = {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return enc
    }()

    private let decoder = JSONDecoder()

    // MARK: - Fixtures Directory

    /// Resolves the `Fixtures/` directory relative to this source file.
    /// Works regardless of working directory at test time.
    private var fixturesURL: URL {
        URL(fileURLWithPath: #file)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
    }

    private func writeFixture(named name: String, data: Data) throws {
        let fileURL = fixturesURL.appendingPathComponent(name)
        try data.write(to: fileURL, options: .atomic)
    }

    private func readFixture(named name: String) throws -> Data {
        let fileURL = fixturesURL.appendingPathComponent(name)
        return try Data(contentsOf: fileURL)
    }

    // MARK: - Deterministic Test Dates

    private let purchaseDate = Date(timeIntervalSince1970: 1_700_000_000)   // 2023-11-14
    private let expirationDate = Date(timeIntervalSince1970: 1_731_536_000) // 2024-11-14
    private let snapshotDate = Date(timeIntervalSince1970: 1_700_000_000)   // 2023-11-14
    private let gracePeriodDate = Date(timeIntervalSince1970: 1_702_000_000) // 2023-12-07

    // MARK: - Task 1: Full Unified CustomerInfo Codable Roundtrip

    func testUnifiedCustomerInfoCodableRoundtrip() throws {
        let entitlement = AppActorEntitlementInfo(
            id: "premium",
            isActive: true,
            productID: "com.app.annual",
            originalPurchaseDate: purchaseDate,
            expirationDate: expirationDate,
            ownershipType: .purchased,
            periodType: .annual,
            willRenew: true,
            subscriptionStatus: .active,
            store: .appStore,
            isSandbox: false,
            cancellationReason: nil,
            gracePeriodExpiresAt: nil,
            billingIssueDetectedAt: nil,
            unsubscribeDetectedAt: nil,
            renewedAt: purchaseDate,
            startsAt: nil,
            grantedBy: nil,
            activePromotionalOfferType: nil,
            activePromotionalOfferId: nil
        )

        let subscription = AppActorSubscriptionInfo(
            productIdentifier: "com.app.annual",
            isActive: true,
            expiresDate: "2024-11-14T00:00:00Z",
            purchaseDate: "2023-11-14T00:00:00Z",
            periodType: .annual,
            store: .appStore,
            status: "active",
            autoRenew: true,
            isSandbox: false
        )

        let nonSubscription = AppActorNonSubscription(
            productIdentifier: "com.app.gems_100",
            purchaseDate: "2023-11-14T00:00:00Z",
            store: .appStore,
            isSandbox: false,
            isConsumable: true,
            isRefund: false
        )

        let original = AppActorCustomerInfo(
            entitlements: ["premium": entitlement],
            subscriptions: ["com.app.annual": subscription],
            nonSubscriptions: ["com.app.gems_100": [nonSubscription]],
            consumableBalances: nil,
            snapshotDate: snapshotDate,
            appUserId: "user_roundtrip_001",
            requestDate: "2023-11-14T00:00:00Z",
            firstSeen: "2023-11-01T00:00:00Z",
            lastSeen: "2023-11-14T00:00:00Z",
            managementUrl: "https://apps.apple.com/account/subscriptions"
        )

        // Encode and write fixture
        let data = try encoder.encode(original)
        try writeFixture(named: "customer_info_unified_roundtrip.json", data: data)

        // Decode from written fixture
        let fixtureData = try readFixture(named: "customer_info_unified_roundtrip.json")
        XCTAssertFalse(fixtureData.isEmpty, "Fixture file should not be empty")

        let decoded = try decoder.decode(AppActorCustomerInfo.self, from: fixtureData)

        // Entitlements dict preserved
        XCTAssertEqual(decoded.entitlements.count, 1, "entitlements dict should have 1 entry")
        XCTAssertNotNil(decoded.entitlements["premium"], "entitlements should contain 'premium' key")
        let decodedEnt = try XCTUnwrap(decoded.entitlements["premium"])
        XCTAssertEqual(decodedEnt.id, "premium")
        XCTAssertTrue(decodedEnt.isActive)
        XCTAssertEqual(decodedEnt.productID, "com.app.annual")
        XCTAssertEqual(decodedEnt.ownershipType, .purchased)
        XCTAssertEqual(decodedEnt.periodType, .annual)
        XCTAssertTrue(decodedEnt.willRenew)
        XCTAssertEqual(decodedEnt.subscriptionStatus, .active)
        XCTAssertEqual(decodedEnt.store, .appStore)
        XCTAssertEqual(decodedEnt.isSandbox, false)
        XCTAssertEqual(decodedEnt.originalPurchaseDate, purchaseDate)
        XCTAssertEqual(decodedEnt.expirationDate, expirationDate)
        XCTAssertEqual(decodedEnt.renewedAt, purchaseDate)

        // Subscriptions dict preserved
        XCTAssertEqual(decoded.subscriptions.count, 1, "subscriptions dict should have 1 entry")
        let decodedSub = try XCTUnwrap(decoded.subscriptions["com.app.annual"])
        XCTAssertEqual(decodedSub.productIdentifier, "com.app.annual")
        XCTAssertTrue(decodedSub.isActive)

        // NonSubscriptions dict preserved
        XCTAssertEqual(decoded.nonSubscriptions.count, 1, "nonSubscriptions dict should have 1 entry")
        let decodedNonSubs = try XCTUnwrap(decoded.nonSubscriptions["com.app.gems_100"])
        XCTAssertEqual(decodedNonSubs.count, 1)
        XCTAssertEqual(decodedNonSubs.first?.productIdentifier, "com.app.gems_100")

        // Payment-mode fields preserved
        XCTAssertEqual(decoded.appUserId, "user_roundtrip_001")
        XCTAssertEqual(decoded.requestDate, "2023-11-14T00:00:00Z")
        XCTAssertEqual(decoded.firstSeen, "2023-11-01T00:00:00Z")
        XCTAssertEqual(decoded.lastSeen, "2023-11-14T00:00:00Z")
        XCTAssertEqual(decoded.managementUrl, "https://apps.apple.com/account/subscriptions")

        // No consumable balances in payment mode
        XCTAssertNil(decoded.consumableBalances)

        // snapshotDate preserved
        XCTAssertEqual(decoded.snapshotDate, snapshotDate)
    }

    // MARK: - Task 2: Empty CustomerInfo Roundtrip

    func testUnifiedCustomerInfoEmptyRoundtrip() throws {
        let data = try encoder.encode(AppActorCustomerInfo.empty)
        let decoded = try decoder.decode(AppActorCustomerInfo.self, from: data)

        XCTAssertTrue(decoded.entitlements.isEmpty, "empty roundtrip: entitlements should be empty")
        XCTAssertTrue(decoded.subscriptions.isEmpty, "empty roundtrip: subscriptions should be empty")
        XCTAssertTrue(decoded.nonSubscriptions.isEmpty, "empty roundtrip: nonSubscriptions should be empty")
        XCTAssertNil(decoded.consumableBalances, "empty roundtrip: consumableBalances should be nil")
        XCTAssertNil(decoded.appUserId, "empty roundtrip: appUserId should be nil")
        XCTAssertNil(decoded.requestDate, "empty roundtrip: requestDate should be nil")
        XCTAssertNil(decoded.firstSeen, "empty roundtrip: firstSeen should be nil")
        XCTAssertNil(decoded.lastSeen, "empty roundtrip: lastSeen should be nil")
        XCTAssertNil(decoded.managementUrl, "empty roundtrip: managementUrl should be nil")
        XCTAssertTrue(decoded.activeEntitlements.isEmpty)
        XCTAssertTrue(decoded.activeEntitlementKeys.isEmpty)
    }

    // MARK: - Task 3: Backward-Compat Array-Shape Decode

    func testBackwardCompatDecodeArrayShape() throws {
        // Craft old array-shape JSON (pre-Phase-9 payment-mode format).
        // The unified AppActorCustomerInfo.init(from:) has an array fallback
        // path that rebuilds a dict keyed by "id".
        let arrayShapeJSON = """
        {
            "appUserId": "app_user_legacy_001",
            "requestDate": "2024-01-15T10:30:00Z",
            "firstSeen": "2023-11-14T00:00:00Z",
            "lastSeen": "2024-01-15T10:30:00Z",
            "snapshotDate": 1700000000,
            "entitlements": [
                {
                    "id": "premium",
                    "isActive": true,
                    "productID": "com.app.annual",
                    "ownershipType": "purchased",
                    "periodType": "annual",
                    "willRenew": true,
                    "store": "app_store"
                }
            ],
            "subscriptions": [
                {
                    "productIdentifier": "com.app.annual",
                    "isActive": true,
                    "expiresDate": "2024-11-14T00:00:00Z",
                    "purchaseDate": "2023-11-14T00:00:00Z",
                    "periodType": "annual",
                    "store": "app_store",
                    "status": "active",
                    "autoRenew": true
                }
            ],
            "nonSubscriptions": [
                {
                    "productIdentifier": "com.app.gems_100",
                    "purchaseDate": "2023-11-14T00:00:00Z",
                    "store": "app_store",
                    "isSandbox": false,
                    "isConsumable": true,
                    "isRefund": false
                }
            ]
        }
        """

        let data = arrayShapeJSON.data(using: .utf8)!
        let decoded = try decoder.decode(AppActorCustomerInfo.self, from: data)

        // appUserId must be populated
        XCTAssertEqual(decoded.appUserId, "app_user_legacy_001", "backward-compat: appUserId should be populated")

        // At least one entitlement must exist
        XCTAssertFalse(decoded.entitlements.isEmpty, "backward-compat: entitlements dict should be non-empty")

        // Verify key fields on the entitlement
        let premium = try XCTUnwrap(decoded.entitlements["premium"], "backward-compat: 'premium' entitlement should be keyed by id")
        XCTAssertTrue(premium.isActive, "backward-compat: premium entitlement should be active")
        XCTAssertEqual(premium.periodType, .annual, "backward-compat: periodType should decode as .annual")
        XCTAssertEqual(premium.store, .appStore, "backward-compat: store should decode as .appStore")

        // At least one subscription must exist
        XCTAssertFalse(decoded.subscriptions.isEmpty, "backward-compat: subscriptions should be non-empty")

        // At least one nonSubscription must exist
        XCTAssertFalse(decoded.nonSubscriptions.isEmpty, "backward-compat: nonSubscriptions should be non-empty")
    }

    // MARK: - Task 4: Typed Enum Roundtrip for EntitlementInfo

    func testEntitlementInfoTypedEnumRoundtrip() throws {
        let original = AppActorEntitlementInfo(
            id: "trial_premium",
            isActive: true,
            productID: "com.app.monthly",
            ownershipType: .familyShared,
            periodType: .trial,
            willRenew: false,
            subscriptionStatus: .gracePeriod,
            store: .appStore,
            isSandbox: true,
            cancellationReason: .customerCancelled
        )

        let data = try encoder.encode(original)
        let decoded = try decoder.decode(AppActorEntitlementInfo.self, from: data)

        // All typed enums must survive roundtrip
        XCTAssertEqual(decoded.store, .appStore, "store enum must survive roundtrip")
        XCTAssertEqual(decoded.cancellationReason, .customerCancelled, "cancellationReason enum must survive roundtrip")
        XCTAssertEqual(decoded.periodType, .trial, "periodType enum must survive roundtrip")
        XCTAssertEqual(decoded.ownershipType, .familyShared, "ownershipType enum must survive roundtrip")
        XCTAssertEqual(decoded.subscriptionStatus, .gracePeriod, "subscriptionStatus enum must survive roundtrip")

        // Other fields preserved
        XCTAssertEqual(decoded.id, "trial_premium")
        XCTAssertTrue(decoded.isActive)
        XCTAssertEqual(decoded.productID, "com.app.monthly")
        XCTAssertFalse(decoded.willRenew)
        XCTAssertEqual(decoded.isSandbox, true)
    }

    // MARK: - Task 5: Unknown Enum Fallback

    func testEntitlementInfoUnknownEnumFallback() throws {
        let unknownJSON = """
        {
            "id": "premium",
            "isActive": true,
            "productID": "com.app.annual",
            "ownershipType": "purchased",
            "periodType": "hourly",
            "willRenew": false,
            "store": "brand_new_store",
            "cancellationReason": "cosmic_ray",
            "subscriptionStatus": "interdimensional"
        }
        """

        let data = unknownJSON.data(using: .utf8)!
        let decoded = try decoder.decode(AppActorEntitlementInfo.self, from: data)

        // All unknown values must fall back to .unknown without crashing
        XCTAssertEqual(decoded.store, .unknown, "unknown store value should fall back to .unknown")
        XCTAssertEqual(decoded.cancellationReason, .unknown, "unknown cancellationReason should fall back to .unknown")
        XCTAssertEqual(decoded.periodType, .unknown, "unknown periodType should fall back to .unknown")
        XCTAssertEqual(decoded.subscriptionStatus, .unknown, "unknown subscriptionStatus should fall back to .unknown")

        // Non-enum fields still decode correctly
        XCTAssertEqual(decoded.id, "premium")
        XCTAssertTrue(decoded.isActive)
        XCTAssertEqual(decoded.productID, "com.app.annual")
        XCTAssertFalse(decoded.willRenew)
    }

    // MARK: - Task 6: SubscriptionInfo Codable Roundtrip

    func testSubscriptionInfoCodableRoundtrip() throws {
        let original = AppActorSubscriptionInfo(
            productIdentifier: "com.app.annual",
            isActive: true,
            expiresDate: "2024-11-14T00:00:00Z",
            purchaseDate: "2023-11-14T00:00:00Z",
            periodType: .annual,
            store: .appStore,
            status: "active",
            autoRenew: true,
            isSandbox: false,
            gracePeriodExpiresAt: nil,
            unsubscribeDetectedAt: nil,
            cancellationReason: nil,
            renewedAt: nil,
            originalTransactionId: "txn_original_001",
            latestTransactionId: "txn_latest_002",
            activePromotionalOfferType: nil,
            activePromotionalOfferId: nil
        )

        let data = try encoder.encode(original)
        let decoded = try decoder.decode(AppActorSubscriptionInfo.self, from: data)

        XCTAssertEqual(decoded.productIdentifier, "com.app.annual")
        XCTAssertTrue(decoded.isActive)
        XCTAssertEqual(decoded.expiresDate, "2024-11-14T00:00:00Z")
        XCTAssertEqual(decoded.purchaseDate, "2023-11-14T00:00:00Z")
        XCTAssertEqual(decoded.periodType, .annual)
        XCTAssertEqual(decoded.store, .appStore)
        XCTAssertEqual(decoded.status, "active")
        XCTAssertEqual(decoded.autoRenew, true)
        XCTAssertEqual(decoded.isSandbox, false)
        XCTAssertEqual(decoded.originalTransactionId, "txn_original_001")
        XCTAssertEqual(decoded.latestTransactionId, "txn_latest_002")
        XCTAssertNil(decoded.gracePeriodExpiresAt)
        XCTAssertNil(decoded.cancellationReason)

        // Computed convenience properties
        XCTAssertTrue(decoded.willRenew)
        XCTAssertFalse(decoded.isInGracePeriod)
        XCTAssertFalse(decoded.isTrial)
    }

    // MARK: - Task 7: NonSubscription Codable Roundtrip

    func testNonSubscriptionCodableRoundtrip() throws {
        let original = AppActorNonSubscription(
            productIdentifier: "com.app.gems_500",
            purchaseDate: "2023-11-14T00:00:00Z",
            store: .appStore,
            isSandbox: false,
            isConsumable: true,
            isRefund: false
        )

        let data = try encoder.encode(original)
        let decoded = try decoder.decode(AppActorNonSubscription.self, from: data)

        XCTAssertEqual(decoded.productIdentifier, "com.app.gems_500")
        XCTAssertEqual(decoded.purchaseDate, "2023-11-14T00:00:00Z")
        XCTAssertEqual(decoded.store, .appStore)
        XCTAssertEqual(decoded.isSandbox, false)
        XCTAssertEqual(decoded.isConsumable, true)
        XCTAssertEqual(decoded.isRefund, false)
    }

    // MARK: - Task 8: Minimal Shape Roundtrip

    func testCustomerInfoLocalModeShape() throws {
        // Minimal shape: consumableBalances populated, payment fields nil, subscriptions/nonSubscriptions empty
        let entitlement = AppActorEntitlementInfo(
            id: "premium",
            isActive: true,
            productID: "com.app.annual",
            originalPurchaseDate: purchaseDate,
            expirationDate: expirationDate,
            ownershipType: .purchased,
            periodType: .annual,
            willRenew: true,
            subscriptionStatus: .active
            // store, isSandbox, etc. are nil when not provided by server
        )

        let original = AppActorCustomerInfo(
            entitlements: ["premium": entitlement],
            subscriptions: [:],
            nonSubscriptions: [:],
            consumableBalances: ["com.app.coins": 100, "com.app.gems": 250],
            snapshotDate: snapshotDate,
            appUserId: nil,
            requestDate: nil,
            firstSeen: nil,
            lastSeen: nil,
            managementUrl: nil
        )

        let data = try encoder.encode(original)
        let decoded = try decoder.decode(AppActorCustomerInfo.self, from: data)

        // Local-mode shape preserved
        XCTAssertTrue(decoded.subscriptions.isEmpty, "subscriptions should be empty when not provided")
        XCTAssertTrue(decoded.nonSubscriptions.isEmpty, "nonSubscriptions should be empty when not provided")
        XCTAssertNil(decoded.appUserId, "appUserId should be nil when not provided by server")
        XCTAssertNil(decoded.requestDate, "requestDate should be nil when not provided by server")
        XCTAssertNil(decoded.firstSeen, "firstSeen should be nil when not provided by server")
        XCTAssertNil(decoded.lastSeen, "lastSeen should be nil when not provided by server")
        XCTAssertNil(decoded.managementUrl, "managementUrl should be nil when not provided")

        // Consumable balances preserved
        XCTAssertEqual(decoded.consumableBalances?["com.app.coins"], 100, "coin balance should round-trip")
        XCTAssertEqual(decoded.consumableBalances?["com.app.gems"], 250, "gem balance should round-trip")

        // Entitlement preserved (store/isSandbox nil when not provided)
        let decodedEnt = try XCTUnwrap(decoded.entitlements["premium"])
        XCTAssertTrue(decodedEnt.isActive)
        XCTAssertEqual(decodedEnt.periodType, .annual)
        XCTAssertNil(decodedEnt.store, "store should be nil when not provided by server")
        XCTAssertNil(decodedEnt.isSandbox, "isSandbox should be nil when not provided by server")
        XCTAssertNil(decodedEnt.cancellationReason, "cancellationReason should be nil when not provided")
    }
}
