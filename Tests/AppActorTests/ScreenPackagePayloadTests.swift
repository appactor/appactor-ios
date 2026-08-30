import XCTest
@testable import AppActor

/// The `{{package.*}}` field names are frozen and written inside published
/// documents, so the shape of what native sends is a contract, not an
/// implementation detail.
final class ScreenPackagePayloadTests: XCTestCase {

    private func package(
        id: String = "pkg_annual",
        price: Decimal? = 39.99,
        currency: String? = "USD",
        priceString: String = "$39.99"
    ) -> AppActorPackage {
        AppActorPackage(
            id: id,
            packageType: .annual,
            customTypeIdentifier: nil,
            productId: "com.example.annual",
            localizedPriceString: priceString,
            displayName: "Annual",
            metadata: nil,
            position: 0,
            price: price,
            currencyCode: currency,
            productType: "subscription",
            productName: "Annual",
            productDescription: nil
        )
    }

    /// Every field `FROZEN.md` §2 names. Missing one means a document
    /// interpolating it renders nothing, silently.
    private static let frozenFields = [
        "id", "priceString", "price", "currencyCode",
        "periodUnit", "periodCount", "periodString", "trialPeriodDays",
        "introPriceString", "pricePerWeekString", "pricePerMonthString",
        "discountPercent", "isEligibleForTrial",
    ]

    func testCarriesEveryFrozenField() async {
        let payload = await AppActorScreenPackagePayload.make(package: package(), product: nil)
        for field in Self.frozenFields {
            XCTAssertNotNil(payload[field], "\(field) is missing from the package payload")
        }
        XCTAssertEqual(payload.count, Self.frozenFields.count, "unexpected extra keys: \(payload.keys.sorted())")
    }

    func testFallsBackToThePackageWhenStoreKitHasNoProduct() async throws {
        // A package can outlive its StoreKit product. The document still needs
        // a price to render, and `AppActorPackage` can answer that much.
        let payload = await AppActorScreenPackagePayload.make(package: package(), product: nil)

        XCTAssertEqual(payload["id"] as? String, "pkg_annual")
        XCTAssertEqual(payload["priceString"] as? String, "$39.99")
        XCTAssertEqual(try XCTUnwrap(payload["price"] as? Double), 39.99, accuracy: 0.001)
        XCTAssertEqual(payload["currencyCode"] as? String, "USD")
        // Subscription facts degrade rather than lie.
        XCTAssertEqual(payload["periodCount"] as? Int, 0)
        XCTAssertEqual(payload["periodString"] as? String, "")
        XCTAssertEqual(payload["trialPeriodDays"] as? Int, 0)
        XCTAssertEqual(payload["isEligibleForTrial"] as? Bool, false)
        XCTAssertTrue(payload["introPriceString"] is NSNull)
    }

    func testAPriceLessPackageDoesNotProduceNaN() async {
        // `JSONSerialization` traps on a NaN, so a package with no price at all
        // has to come out as a number the envelope can encode.
        let payload = await AppActorScreenPackagePayload.make(
            package: package(price: nil, currency: nil, priceString: ""),
            product: nil
        )
        XCTAssertEqual(payload["price"] as? Double, 0)
        XCTAssertEqual(payload["currencyCode"] as? String, "")
        XCTAssertNotNil(AppActorScreenInbound(.packages, payload: ["packages": [payload]]).base64())
    }

    func testATrialIsNotClaimedWithoutOne() async {
        // `isEligibleForIntroOffer` answers for the whole subscription group and
        // is true for anyone who has never subscribed -- it says nothing about
        // whether *this* product has a free trial. Reporting it directly puts
        // "Start your free trial" on a product with no trial. With no StoreKit
        // product there is certainly no trial, so this is the floor case.
        let payload = await AppActorScreenPackagePayload.make(package: package(), product: nil)
        XCTAssertEqual(payload["isEligibleForTrial"] as? Bool, false)
        XCTAssertEqual(payload["trialPeriodDays"] as? Int, 0)
    }

    func testThePayloadAlwaysSurvivesTheEnvelope() async throws {
        let payload = await AppActorScreenPackagePayload.make(package: package(), product: nil)
        XCTAssertTrue(JSONSerialization.isValidJSONObject(["packages": [payload]]))
    }

    // MARK: - Discounts

    private func payloads(_ ids: [String]) -> [[String: Any]] {
        ids.map { ["id": $0, "discountPercent": NSNull()] }
    }

    func testComputesADiscountAgainstTheComparedPackage() {
        // $39.99/year vs $4.99/month: the annual plan costs about a third as
        // much per day, so the badge should read 33% off.
        let rates: [String: Decimal] = [
            "pkg_annual": Decimal(39.99) / 365,
            "pkg_monthly": Decimal(4.99) / 30,
        ]
        let result = AppActorScreenPackagePayload.attachDiscounts(
            to: payloads(["pkg_annual", "pkg_monthly"]),
            comparisons: ["pkg_annual": "pkg_monthly"],
            dailyRates: rates
        )
        XCTAssertEqual(result[0]["discountPercent"] as? Int, 34)
        XCTAssertTrue(result[1]["discountPercent"] is NSNull, "the package compared against gets no badge")
    }

    func testNormalisesAcrossPeriodsRatherThanComparingStickerPrices() {
        // The case that makes naive comparison useless: $39.99 is twelve times
        // *more* than $4.99, and a sticker-price comparison would report the
        // annual plan as an increase.
        let annual = Decimal(39.99) / 365
        let monthly = Decimal(4.99) / 30
        XCTAssertLessThan(annual, monthly)
    }

    func testANonPositiveDiscountIsLeftNull() {
        // "0% off" and "-8% off" are both worse than no badge, and the runtime
        // hides a component whose variable is null.
        let result = AppActorScreenPackagePayload.attachDiscounts(
            to: payloads(["a", "b", "c"]),
            comparisons: ["a": "b", "c": "b"],
            dailyRates: ["a": 1.0, "b": 1.0, "c": 1.2]
        )
        XCTAssertTrue(result[0]["discountPercent"] is NSNull, "equal prices are not a discount")
        XCTAssertTrue(result[2]["discountPercent"] is NSNull, "a higher price is not a discount")
    }

    func testIgnoresAComparisonToAPackageWithNoRate() {
        let result = AppActorScreenPackagePayload.attachDiscounts(
            to: payloads(["a"]),
            comparisons: ["a": "missing"],
            dailyRates: ["a": 1.0]
        )
        XCTAssertTrue(result[0]["discountPercent"] is NSNull)
    }

    func testIgnoresAPackageComparedToItself() {
        let result = AppActorScreenPackagePayload.attachDiscounts(
            to: payloads(["a"]),
            comparisons: ["a": "a"],
            dailyRates: ["a": 1.0]
        )
        XCTAssertTrue(result[0]["discountPercent"] is NSNull)
    }

    func testIgnoresAZeroPricedComparison() {
        // A free comparison package would divide by zero.
        let result = AppActorScreenPackagePayload.attachDiscounts(
            to: payloads(["a"]),
            comparisons: ["a": "free"],
            dailyRates: ["a": 1.0, "free": 0]
        )
        XCTAssertTrue(result[0]["discountPercent"] is NSNull)
    }

    func testNoComparisonsMeansNoWork() {
        let input = payloads(["a", "b"])
        let result = AppActorScreenPackagePayload.attachDiscounts(
            to: input, comparisons: [:], dailyRates: ["a": 1.0, "b": 2.0]
        )
        XCTAssertEqual(result.count, 2)
        XCTAssertTrue(result.allSatisfy { $0["discountPercent"] is NSNull })
    }

    func testDailyRatesAreEmptyWithoutSubscriptionProducts() {
        // Without a StoreKit product there is no subscription period, and
        // without a period there is no daily rate to normalise against. A
        // one-time purchase is correctly absent rather than assumed monthly.
        let rates = AppActorScreenPackagePayload.dailyRates(for: [(package: package(), product: nil)])
        XCTAssertTrue(rates.isEmpty)
    }
}
