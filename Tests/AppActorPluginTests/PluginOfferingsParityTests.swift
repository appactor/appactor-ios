import XCTest
@testable import AppActorPlugin
@testable import AppActor

@MainActor
final class PluginOfferingsParityTests: XCTestCase {

    override func tearDown() {
        AppActor.shared.paymentOfferings = nil
        super.tearDown()
    }

    func testPluginOfferingsSerializesPackageLookupKeyAsSnakeCase() throws {
        let monthly = makePackage(
            id: "pkg_monthly_1",
            lookupKey: "pro_monthly",
            packageType: .monthly,
            productId: "com.app.monthly",
            offeringId: "off_main"
        )
        let keylessAnnual = makePackage(
            id: "pkg_annual_1",
            lookupKey: nil,
            packageType: .annual,
            productId: "com.app.annual",
            offeringId: "off_main"
        )
        let offering = AppActorOffering(
            id: "off_main",
            displayName: "Main Offering",
            isCurrent: true,
            lookupKey: "default_offering",
            metadata: ["tier": "pro"],
            packages: [monthly, keylessAnnual]
        )
        let offerings = AppActorOfferings(
            current: offering,
            all: [offering.id: offering],
            productEntitlements: ["com.app.monthly": ["premium"]],
            verification: .verified
        )

        let data = try AppActorPluginCoder.encoder.encode(PluginOfferings(from: offerings))
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        let current = try XCTUnwrap(json["current"] as? [String: Any])
        XCTAssertEqual(current["lookup_key"] as? String, "default_offering")

        let currentPackages = try XCTUnwrap(current["packages"] as? [[String: Any]])
        XCTAssertEqual(currentPackages.count, 2)
        XCTAssertEqual(currentPackages[0]["id"] as? String, "pkg_monthly_1")
        XCTAssertEqual(currentPackages[0]["lookup_key"] as? String, "pro_monthly")
        XCTAssertNil(currentPackages[0]["lookupKey"], "Bridge wire format must use snake_case lookup_key")

        XCTAssertEqual(currentPackages[1]["id"] as? String, "pkg_annual_1")
        XCTAssertFalse(
            currentPackages[1].keys.contains("lookup_key"),
            "Nil package lookupKey should be omitted, matching PluginOffering.lookupKey and other optional fields"
        )

        let all = try XCTUnwrap(json["all"] as? [String: Any])
        let allMain = try XCTUnwrap(all["off_main"] as? [String: Any])
        let allPackages = try XCTUnwrap(allMain["packages"] as? [[String: Any]])
        XCTAssertEqual(allPackages[0]["lookup_key"] as? String, "pro_monthly")
    }

    func testGetCachedOfferingsPluginMethodEmitsPackageLookupKey() async throws {
        let monthly = makePackage(
            id: "pkg_monthly_cached",
            lookupKey: "starter_monthly",
            packageType: .monthly,
            productId: "com.app.starter.monthly",
            offeringId: "off_cached"
        )
        let offering = AppActorOffering(
            id: "off_cached",
            displayName: "Cached",
            isCurrent: true,
            lookupKey: "cached_offering",
            metadata: nil,
            packages: [monthly]
        )
        AppActor.shared.paymentOfferings = AppActorOfferings(
            current: offering,
            all: [offering.id: offering],
            productEntitlements: nil,
            verification: .verified
        )

        let responseJSON = await AppActorPlugin.shared.execute(
            method: "get_cached_offerings",
            withJson: "{}"
        )
        let envelope = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(responseJSON.utf8)) as? [String: Any]
        )
        let success = try XCTUnwrap(envelope["success"] as? [String: Any])
        let current = try XCTUnwrap(success["current"] as? [String: Any])
        let packages = try XCTUnwrap(current["packages"] as? [[String: Any]])
        XCTAssertEqual(packages.count, 1)
        XCTAssertEqual(packages[0]["id"] as? String, "pkg_monthly_cached")
        XCTAssertEqual(packages[0]["lookup_key"] as? String, "starter_monthly")
    }

    func testPurchasePackageRequestFailsSafelyWhenPackageIdDoesNotMatch() async throws {
        let monthly = makePackage(
            id: "pkg_monthly_only",
            lookupKey: "pro_monthly",
            packageType: .monthly,
            productId: "com.app.monthly",
            offeringId: "off_main"
        )
        let offering = AppActorOffering(
            id: "off_main",
            displayName: "Main",
            isCurrent: true,
            lookupKey: "default",
            metadata: nil,
            packages: [monthly]
        )
        AppActor.shared.paymentOfferings = AppActorOfferings(
            current: offering,
            all: [offering.id: offering],
            productEntitlements: nil,
            verification: .verified
        )

        let responseJSON = await AppActorPlugin.shared.execute(
            method: "purchase_package",
            withJson: #"{"package_id":"nonexistent_pkg","offering_id":"off_main"}"#
        )
        let envelope = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(responseJSON.utf8)) as? [String: Any]
        )
        XCTAssertNil(envelope["success"])
        let error = try XCTUnwrap(envelope["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? Int, AppActorPluginError.sdkValidation)
    }

    private func makePackage(
        id: String,
        lookupKey: String?,
        packageType: AppActorPackageType,
        productId: String,
        offeringId: String
    ) -> AppActorPackage {
        AppActorPackage(
            id: id,
            lookupKey: lookupKey,
            packageType: packageType,
            customTypeIdentifier: nil,
            store: .appStore,
            productId: productId,
            storeProductId: productId,
            localizedPriceString: "$9.99",
            offeringId: offeringId,
            displayName: "Plan",
            metadata: nil,
            tokenAmount: nil,
            position: 0,
            price: Decimal(9.99),
            currencyCode: "USD",
            productType: "subscription",
            productName: "Plan",
            productDescription: "Plan description"
        )
    }
}
