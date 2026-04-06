import XCTest
@testable import AppActor

/// Phase 6 Safety Audit — Fixture generation and roundtrip verification tests.
///
/// These tests capture the pre-refactor JSON schema for all Codable types that
/// will be unified in Phases 8-10. Each test:
///   1. Constructs an object with deterministic values (fixed dates, hardcoded strings)
///   2. Encodes it to JSON and writes the fixture file to Fixtures/
///   3. Decodes the fixture back and asserts field equality
///
/// The fixture files become the regression baseline: Phase 8-10 roundtrip tests
/// verify the old JSON shape still deserializes into the new unified types.
@MainActor
final class SafetyAuditFixtureTests: XCTestCase {

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

    // MARK: - Helpers

    private func writeFixture(named name: String, data: Data) throws {
        let fileURL = fixturesURL.appendingPathComponent(name)
        try data.write(to: fileURL, options: .atomic)
    }

    private func readFixture(named name: String) throws -> Data {
        let fileURL = fixturesURL.appendingPathComponent(name)
        return try Data(contentsOf: fileURL)
    }

    // MARK: - Task 1: AppActorCustomerInfo Fixtures (unified type)

    // MARK: AppActorCustomerInfo — Typical (happy path)

    func testFixture_LocalCustomerSnapshot_Typical() throws {
        let entitlement = AppActorEntitlementInfo(
            id: "premium",
            isActive: true,
            productID: "com.app.annual",
            originalPurchaseDate: Date(timeIntervalSince1970: 1_700_000_000),
            expirationDate: Date(timeIntervalSince1970: 1_731_536_000),
            ownershipType: .purchased,
            periodType: .annual,
            willRenew: true,
            subscriptionStatus: .active
        )

        let original = AppActorCustomerInfo(
            entitlements: ["premium": entitlement],
            subscriptions: [:],
            nonSubscriptions: [:],
            consumableBalances: nil,
            snapshotDate: Date(timeIntervalSince1970: 1_700_000_000)
        )

        // Encode and write fixture
        let data = try encoder.encode(original)
        try writeFixture(named: "local_customer_snapshot_typical.json", data: data)

        // Verify fixture was written
        let fixtureData = try readFixture(named: "local_customer_snapshot_typical.json")
        XCTAssertFalse(fixtureData.isEmpty, "Fixture file should not be empty")

        // Decode and verify roundtrip
        let decoded = try decoder.decode(AppActorCustomerInfo.self, from: fixtureData)

        XCTAssertEqual(decoded.entitlements.count, 1)
        XCTAssertEqual(decoded.entitlements["premium"]?.isActive, true)
        XCTAssertEqual(decoded.entitlements["premium"]?.productID, "com.app.annual")
        XCTAssertEqual(decoded.entitlements["premium"]?.ownershipType, .purchased)
        XCTAssertEqual(decoded.entitlements["premium"]?.periodType, .annual)
        XCTAssertEqual(decoded.entitlements["premium"]?.willRenew, true)
        XCTAssertEqual(decoded.entitlements["premium"]?.subscriptionStatus, .active)
        XCTAssertTrue(decoded.subscriptions.isEmpty)
        XCTAssertNil(decoded.consumableBalances)
        XCTAssertEqual(decoded.snapshotDate, original.snapshotDate)
    }

    // MARK: AppActorCustomerInfo — Expired (edge case)

    func testFixture_LocalCustomerSnapshot_Expired() throws {
        let entitlement = AppActorEntitlementInfo(
            id: "premium",
            isActive: false,
            productID: "com.app.monthly",
            originalPurchaseDate: Date(timeIntervalSince1970: 1_688_000_000),
            expirationDate: Date(timeIntervalSince1970: 1_690_000_000),
            ownershipType: .purchased,
            periodType: .monthly,
            willRenew: false,
            subscriptionStatus: .expired
        )

        let original = AppActorCustomerInfo(
            entitlements: ["premium": entitlement],
            subscriptions: [:],
            nonSubscriptions: [:],
            consumableBalances: nil,
            snapshotDate: Date(timeIntervalSince1970: 1_700_000_000)
        )

        // Encode and write fixture
        let data = try encoder.encode(original)
        try writeFixture(named: "local_customer_snapshot_expired.json", data: data)

        // Verify fixture was written
        let fixtureData = try readFixture(named: "local_customer_snapshot_expired.json")
        XCTAssertFalse(fixtureData.isEmpty, "Fixture file should not be empty")

        // Decode and verify roundtrip
        let decoded = try decoder.decode(AppActorCustomerInfo.self, from: fixtureData)

        XCTAssertEqual(decoded.entitlements.count, 1)
        XCTAssertEqual(decoded.entitlements["premium"]?.isActive, false)
        XCTAssertEqual(decoded.entitlements["premium"]?.productID, "com.app.monthly")
        XCTAssertEqual(decoded.entitlements["premium"]?.subscriptionStatus, .expired)
        XCTAssertEqual(decoded.entitlements["premium"]?.willRenew, false)
        XCTAssertTrue(decoded.subscriptions.isEmpty)
        XCTAssertEqual(decoded.snapshotDate, original.snapshotDate)
    }

    // MARK: AppActorEntitlementInfo — Active (happy path)

    func testFixture_EntitlementInfo_Active() throws {
        let original = AppActorEntitlementInfo(
            id: "premium",
            isActive: true,
            productID: "com.app.annual",
            originalPurchaseDate: Date(timeIntervalSince1970: 1_700_000_000),
            expirationDate: Date(timeIntervalSince1970: 1_731_536_000),
            ownershipType: .purchased,
            periodType: .annual,
            willRenew: true,
            subscriptionStatus: .active
        )

        // Encode and write fixture
        let data = try encoder.encode(original)
        try writeFixture(named: "entitlement_info_active.json", data: data)

        // Verify fixture was written
        let fixtureData = try readFixture(named: "entitlement_info_active.json")
        XCTAssertFalse(fixtureData.isEmpty, "Fixture file should not be empty")

        // Decode and verify roundtrip
        let decoded = try decoder.decode(AppActorEntitlementInfo.self, from: fixtureData)

        XCTAssertEqual(decoded.id, "premium")
        XCTAssertEqual(decoded.isActive, true)
        XCTAssertEqual(decoded.productID, "com.app.annual")
        XCTAssertEqual(decoded.ownershipType, .purchased)
        XCTAssertEqual(decoded.periodType, .annual)
        XCTAssertEqual(decoded.willRenew, true)
        XCTAssertEqual(decoded.subscriptionStatus, .active)
        XCTAssertEqual(decoded.originalPurchaseDate, original.originalPurchaseDate)
        XCTAssertEqual(decoded.expirationDate, original.expirationDate)
    }

    // MARK: AppActorEntitlementInfo — Revoked (edge case)

    func testFixture_EntitlementInfo_Revoked() throws {
        let original = AppActorEntitlementInfo(
            id: "premium",
            isActive: false,
            productID: "com.app.monthly",
            originalPurchaseDate: Date(timeIntervalSince1970: 1_688_000_000),
            expirationDate: Date(timeIntervalSince1970: 1_690_000_000),
            ownershipType: .purchased,
            periodType: .monthly,
            willRenew: false,
            subscriptionStatus: .revoked
        )

        // Encode and write fixture
        let data = try encoder.encode(original)
        try writeFixture(named: "entitlement_info_revoked.json", data: data)

        // Verify fixture was written
        let fixtureData = try readFixture(named: "entitlement_info_revoked.json")
        XCTAssertFalse(fixtureData.isEmpty, "Fixture file should not be empty")

        // Decode and verify roundtrip
        let decoded = try decoder.decode(AppActorEntitlementInfo.self, from: fixtureData)

        XCTAssertEqual(decoded.id, "premium")
        XCTAssertEqual(decoded.isActive, false)
        XCTAssertEqual(decoded.subscriptionStatus, .revoked)
        XCTAssertEqual(decoded.willRenew, false)
        XCTAssertTrue(decoded.isRevoked)
    }

    // MARK: - Task 2: Payment Mode Types (unified AppActorCustomerInfo)

    // MARK: AppActorCustomerInfo — Active (happy path)

    func testFixture_CustomerInfo_Active() throws {
        let entitlement = AppActorEntitlementInfo(
            id: "premium",
            isActive: true,
            productID: "com.app.annual",
            periodType: .annual,
            willRenew: true,
            store: .appStore
        )

        let subscription = AppActorSubscriptionInfo(
            productIdentifier: "com.app.annual",
            isActive: true,
            expiresDate: "2024-11-14T00:00:00Z",
            purchaseDate: "2023-11-14T00:00:00Z",
            periodType: .annual,
            store: .appStore,
            status: "active",
            autoRenew: true
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
            snapshotDate: Date(timeIntervalSince1970: 1_700_000_000),
            appUserId: "app_user_test_123",
            requestDate: "2024-01-15T10:30:00Z",
            firstSeen: "2023-11-14T00:00:00Z",
            lastSeen: "2024-01-15T10:30:00Z"
        )

        // Encode and write fixture
        let data = try encoder.encode(original)
        try writeFixture(named: "customer_info_active.json", data: data)

        // Verify fixture was written
        let fixtureData = try readFixture(named: "customer_info_active.json")
        XCTAssertFalse(fixtureData.isEmpty, "Fixture file should not be empty")

        // Decode and verify roundtrip
        let decoded = try decoder.decode(AppActorCustomerInfo.self, from: fixtureData)

        XCTAssertEqual(decoded.appUserId, "app_user_test_123")
        XCTAssertEqual(decoded.entitlements.count, 1)
        XCTAssertEqual(decoded.entitlements["premium"]?.isActive, true)
        XCTAssertEqual(decoded.entitlements["premium"]?.id, "premium")
        XCTAssertEqual(decoded.subscriptions.count, 1)
        XCTAssertEqual(decoded.subscriptions["com.app.annual"]?.isActive, true)
        XCTAssertEqual(decoded.nonSubscriptions.count, 1)
        XCTAssertEqual(decoded.requestDate, "2024-01-15T10:30:00Z")
        XCTAssertEqual(decoded.firstSeen, "2023-11-14T00:00:00Z")
        XCTAssertEqual(decoded.lastSeen, "2024-01-15T10:30:00Z")
    }

    // MARK: AppActorCustomerInfo — Empty (edge case)

    func testFixture_CustomerInfo_Empty() throws {
        let original = AppActorCustomerInfo(
            entitlements: [:],
            subscriptions: [:],
            nonSubscriptions: [:],
            consumableBalances: nil,
            snapshotDate: Date(timeIntervalSince1970: 1_700_000_000),
            appUserId: "app_user_empty_456",
            requestDate: nil,
            firstSeen: nil,
            lastSeen: nil
        )

        // Encode and write fixture
        let data = try encoder.encode(original)
        try writeFixture(named: "customer_info_empty.json", data: data)

        // Verify fixture was written
        let fixtureData = try readFixture(named: "customer_info_empty.json")
        XCTAssertFalse(fixtureData.isEmpty, "Fixture file should not be empty")

        // Decode and verify roundtrip
        let decoded = try decoder.decode(AppActorCustomerInfo.self, from: fixtureData)

        XCTAssertEqual(decoded.appUserId, "app_user_empty_456")
        XCTAssertTrue(decoded.entitlements.isEmpty)
        XCTAssertTrue(decoded.subscriptions.isEmpty)
        XCTAssertTrue(decoded.nonSubscriptions.isEmpty)
        XCTAssertNil(decoded.requestDate)
        XCTAssertNil(decoded.firstSeen)
        XCTAssertNil(decoded.lastSeen)
    }
}
