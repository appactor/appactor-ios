import XCTest
@testable import AppActor

@MainActor
final class PackageUnificationTests: XCTestCase {

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    func testPackageTypeServerStringMapping() {
        XCTAssertEqual(AppActorPackageType(serverString: "monthly"), .monthly)
        XCTAssertEqual(AppActorPackageType(serverString: "two_month"), .twoMonth)
        XCTAssertEqual(AppActorPackageType(serverString: "premium_plus"), .custom)
    }

    func testPackageCodableRoundtripPreservesStoreAgnosticFields() throws {
        let original = makePackage(
            id: "default_monthly",
            packageType: .monthly,
            store: .appStore,
            productId: "com.app.monthly",
            storeProductId: "com.app.monthly",
            basePlanId: nil,
            offerId: nil,
            localizedPriceString: "$9.99",
            displayName: "Monthly Plan",
            metadata: ["tier": "pro"],
            productType: "auto_renewable",
            productName: "Monthly Subscription",
            productDescription: "Access for one month"
        )

        let data = try encoder.encode(original)
        let decoded = try decoder.decode(AppActorPackage.self, from: data)

        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.packageType, .monthly)
        XCTAssertEqual(decoded.store, .appStore)
        XCTAssertEqual(decoded.productId, "com.app.monthly")
        XCTAssertEqual(decoded.storeProductId, "com.app.monthly")
        XCTAssertEqual(decoded.localizedPriceString, "$9.99")
        XCTAssertEqual(decoded.displayName, "Monthly Plan")
        XCTAssertEqual(decoded.metadata?["tier"], "pro")
        XCTAssertEqual(decoded.productType, "auto_renewable")
        XCTAssertEqual(decoded.productName, "Monthly Subscription")
        XCTAssertEqual(decoded.productDescription, "Access for one month")
    }

    func testPackageCodableRoundtripPreservesAndroidFields() throws {
        let original = makePackage(
            id: "default_android",
            packageType: .monthly,
            store: .playStore,
            productId: "com.appactor.pro.monthly",
            storeProductId: "com.appactor.pro.monthly",
            basePlanId: "monthly001",
            offerId: "intro7d",
            localizedPriceString: "TRY 99.99"
        )

        let data = try encoder.encode(original)
        let decoded = try decoder.decode(AppActorPackage.self, from: data)

        XCTAssertEqual(decoded.store, .playStore)
        XCTAssertEqual(decoded.productId, "com.appactor.pro.monthly")
        XCTAssertEqual(decoded.storeProductId, "com.appactor.pro.monthly")
        XCTAssertEqual(decoded.basePlanId, "monthly001")
        XCTAssertEqual(decoded.offerId, "intro7d")
    }

    func testPackageDecodeDefaultsStoreToAppStoreAndLeavesStoreSpecificFieldsNil() throws {
        let json = """
        {
            "id": "legacy_package",
            "packageType": "monthly",
            "productId": "com.app.legacy",
            "localizedPriceString": "$4.99"
        }
        """.data(using: .utf8)!

        let decoded = try decoder.decode(AppActorPackage.self, from: json)

        XCTAssertEqual(decoded.store, .appStore)
        XCTAssertEqual(decoded.productId, "com.app.legacy")
        XCTAssertNil(decoded.storeProductId)
        XCTAssertNil(decoded.basePlanId)
        XCTAssertNil(decoded.offerId)
    }

    func testLegacyServerBackedPackageDecodesCanonicalIdFromServerId() throws {
        let json = """
        {
            "id": "default_monthly",
            "packageType": "monthly",
            "productId": "com.app.monthly",
            "localizedPriceString": "$9.99",
            "offeringId": "off_default",
            "serverId": "pkg_123e4567-e89b-12d3-a456-426614174000"
        }
        """.data(using: .utf8)!

        let decoded = try decoder.decode(AppActorPackage.self, from: json)

        XCTAssertEqual(decoded.id, "pkg_123e4567-e89b-12d3-a456-426614174000")
        XCTAssertEqual(decoded.offeringId, "off_default")
    }

    func testPackageHashableByIdOnly() {
        let lhs = makePackage(id: "same_id", productId: "com.app.monthly")
        let rhs = makePackage(id: "same_id", store: .playStore, productId: "com.app.annual")
        let other = makePackage(id: "other_id", productId: "com.app.monthly")

        XCTAssertEqual(lhs, rhs)
        XCTAssertEqual(lhs.hashValue, rhs.hashValue)
        XCTAssertNotEqual(lhs, other)
    }

    private func makePackage(
        id: String = "default_monthly",
        packageType: AppActorPackageType = .monthly,
        store: AppActorStore = .appStore,
        productId: String = "com.app.monthly",
        storeProductId: String? = "com.app.monthly",
        basePlanId: String? = nil,
        offerId: String? = nil,
        localizedPriceString: String = "$9.99",
        displayName: String? = "Monthly Plan",
        metadata: [String: String]? = nil,
        productType: String? = "auto_renewable",
        productName: String? = "Monthly Subscription",
        productDescription: String? = "Access for one month"
    ) -> AppActorPackage {
        AppActorPackage(
            id: id,
            packageType: packageType,
            customTypeIdentifier: packageType == .custom ? "custom" : nil,
            store: store,
            productId: productId,
            storeProductId: storeProductId,
            basePlanId: basePlanId,
            offerId: offerId,
            localizedPriceString: localizedPriceString,
            displayName: displayName,
            metadata: metadata,
            tokenAmount: nil,
            position: 0,
            price: Decimal(string: "9.99"),
            currencyCode: "USD",
            productType: productType,
            productName: productName,
            productDescription: productDescription
        )
    }
}
