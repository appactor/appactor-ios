import Foundation
import StoreKit

/// Builds the `package` objects the runtime interpolates as `{{package.*}}`.
///
/// The field list is frozen (`spec/package-fields.ts`, `FROZEN.md` §2) because
/// these names are written *inside published documents*: renaming one breaks
/// every screen that already shipped. The runtime is a pure pass-through — it
/// reads whatever key the document names off the object native sent and hides
/// the component when the value is missing — so every field here has to be
/// filled by this file or deliberately sent as null.
///
/// Most of it is not on ``AppActorPackage``. `AppActorPackage` carries id,
/// price and currency; subscription period, trial length, introductory offer
/// and eligibility all live on the live StoreKit `Product`. Reading them here
/// rather than adding them to the public model keeps this branch off the
/// public API surface — moving them onto `AppActorPackage` (and making Android
/// agree on what "trial" means when Play hands back an ordered phase list) is
/// its own piece of work.
enum AppActorScreenPackagePayload {

    /// Approximate day counts, used only to normalise one subscription period
    /// against another. Marketing maths, not calendar maths: "$2.50 / week" on
    /// an annual plan is the same 365/52 approximation every store in this
    /// category uses, and a calendar-exact figure would change month to month.
    private static func days(unit: Product.SubscriptionPeriod.Unit, count: Int) -> Decimal {
        let perUnit: Decimal
        switch unit {
        case .day: perUnit = 1
        case .week: perUnit = 7
        case .month: perUnit = 30
        case .year: perUnit = 365
        @unknown default: perUnit = 30
        }
        return perUnit * Decimal(max(count, 1))
    }

    private static func wireUnit(_ unit: Product.SubscriptionPeriod.Unit) -> String {
        switch unit {
        case .day: return "day"
        case .week: return "week"
        case .month: return "month"
        case .year: return "year"
        // The wire format's `periodUnit` is a closed set. An unrecognised unit
        // is reported as a month rather than as a new string the runtime and
        // the Android SDK would both have to guess at.
        @unknown default: return "month"
        }
    }

    private static func calendarComponent(_ unit: Product.SubscriptionPeriod.Unit) -> NSCalendar.Unit {
        switch unit {
        case .day: return .day
        case .week: return .weekOfMonth
        case .month: return .month
        case .year: return .year
        @unknown default: return .month
        }
    }

    /// "1 month", "3 months", "1 year" — localised by `DateComponentsFormatter`
    /// rather than hand-assembled, so a Turkish device reads "1 ay" without the
    /// SDK shipping a string table it would then have to keep in sync.
    private static func periodString(unit: Product.SubscriptionPeriod.Unit, count: Int) -> String {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .full
        formatter.allowedUnits = [calendarComponent(unit)]
        formatter.maximumUnitCount = 1

        var components = DateComponents()
        switch unit {
        case .day: components.day = count
        case .week: components.weekOfMonth = count
        case .month: components.month = count
        case .year: components.year = count
        @unknown default: components.month = count
        }

        return formatter.string(from: components) ?? "\(count) \(wireUnit(unit))"
    }

    private static func trialDays(_ offer: Product.SubscriptionOffer?) -> Int {
        guard let offer, offer.paymentMode == .freeTrial else { return 0 }
        let value = days(unit: offer.period.unit, count: offer.period.value)
        return NSDecimalNumber(decimal: value).intValue
    }

    /// Price for one day of this subscription. The common denominator behind
    /// `pricePerWeekString`, `pricePerMonthString` and `discountPercent` — a
    /// ratio between two daily rates is the same ratio their weekly or monthly
    /// rates would give, so there is one normalisation to get wrong instead of
    /// three.
    private static func dailyRate(price: Decimal, period: Product.SubscriptionPeriod?) -> Decimal? {
        guard let period else { return nil }
        let total = days(unit: period.unit, count: period.value)
        guard total > 0 else { return nil }
        return price / total
    }

    private static func money(_ amount: Decimal, _ product: Product) -> String {
        amount.formatted(product.priceFormatStyle)
    }

    private static func currencyCode(_ package: AppActorPackage, _ product: Product) -> String {
        if let code = package.currencyCode, !code.isEmpty { return code }
        if #available(iOS 16.0, macOS 13.0, tvOS 16.0, watchOS 9.0, *) {
            return product.priceFormatStyle.currencyCode
        }
        // iOS 15 exposes no currency code on the format style. The frozen
        // contract types this as a string, so the honest answer for "unknown"
        // is the empty one — the runtime hides a component whose variable
        // resolves to an empty string the same way it hides a missing one.
        return ""
    }

    /// One package as the runtime will see it.
    ///
    /// `product` is optional because a package can outlive its StoreKit
    /// product — pulled from App Store Connect, or simply not returned by a
    /// flaky `Product.products(for:)`. When it is missing every subscription
    /// field degrades to its "not a subscription" value rather than dropping
    /// the package: the document still needs `{{package.priceString}}` to
    /// render, and `AppActorPackage` alone can answer that.
    static func make(package: AppActorPackage, product: Product?) async -> [String: Any] {
        let price = product?.price ?? package.price ?? 0
        let priceString = product.map { money(price, $0) } ?? package.localizedPriceString
        let period = product?.subscription?.subscriptionPeriod
        let offer = product?.subscription?.introductoryOffer

        var payload: [String: Any] = [
            "id": package.id,
            "priceString": priceString,
            "price": NSDecimalNumber(decimal: price).doubleValue,
            "currencyCode": product.map { currencyCode(package, $0) } ?? (package.currencyCode ?? ""),
            "periodUnit": period.map { wireUnit($0.unit) } ?? "month",
            "periodCount": period?.value ?? 0,
            "periodString": period.map { periodString(unit: $0.unit, count: $0.value) } ?? "",
            "trialPeriodDays": trialDays(offer),
            "introPriceString": NSNull(),
            "pricePerWeekString": "",
            "pricePerMonthString": "",
            // Filled by `attachDiscounts` once every package is known: a
            // discount is a comparison, and one package cannot compute it alone.
            "discountPercent": NSNull(),
            "isEligibleForTrial": false,
        ]

        if let product, let offer, offer.paymentMode != .freeTrial {
            payload["introPriceString"] = money(offer.price, product)
        }

        if let product, let daily = dailyRate(price: price, period: period) {
            payload["pricePerWeekString"] = money(daily * 7, product)
            payload["pricePerMonthString"] = money(daily * 30, product)
        }

        // Two conditions, because `isEligibleForIntroOffer` answers a different
        // question than the field name asks. It is a per-Apple-ID answer about
        // the whole *subscription group* -- true for anyone who has never
        // subscribed -- and says nothing about whether this product offers a
        // free trial at all. On its own it would put "Start your free trial" on
        // a product with no trial, and on one whose intro offer is pay-up-front.
        if let subscription = product?.subscription, offer?.paymentMode == .freeTrial {
            payload["isEligibleForTrial"] = await subscription.isEligibleForIntroOffer
        }

        return payload
    }

    /// Fills in `discountPercent` for every package the document asks to
    /// compare, then returns the list.
    ///
    /// `compareTo` lives on the document's `package` component (the schema
    /// documents it as "`discountPercent` is computed against this one"), and
    /// the runtime treats every `package.*` field as pass-through. So the
    /// comparison has to happen on this side, and it happens against the daily
    /// rate: annual-versus-monthly is the case worth showing, and comparing
    /// their sticker prices would report a 12× *increase*.
    ///
    /// A non-positive result becomes null rather than "0% off" or "-8% off" —
    /// the runtime hides a component whose variable is null, which is the
    /// correct outcome for a badge with nothing to boast about.
    static func attachDiscounts(
        to payloads: [[String: Any]],
        comparisons: [String: String],
        dailyRates: [String: Decimal]
    ) -> [[String: Any]] {
        guard !comparisons.isEmpty else { return payloads }

        return payloads.map { payload in
            guard let id = payload["id"] as? String,
                  let against = comparisons[id],
                  against != id,
                  let mine = dailyRates[id],
                  let theirs = dailyRates[against],
                  theirs > 0
            else { return payload }

            let saved = (1 - (mine / theirs)) * 100
            let rounded = NSDecimalNumber(decimal: saved).rounding(
                accordingToBehavior: NSDecimalNumberHandler(
                    roundingMode: .plain, scale: 0,
                    raiseOnExactness: false, raiseOnOverflow: false,
                    raiseOnUnderflow: false, raiseOnDivideByZero: false
                )
            ).intValue

            guard rounded > 0 else { return payload }
            var updated = payload
            updated["discountPercent"] = rounded
            return updated
        }
    }

    /// Daily rate per package id, for `attachDiscounts`.
    static func dailyRates(for pairs: [(package: AppActorPackage, product: Product?)]) -> [String: Decimal] {
        var rates: [String: Decimal] = [:]
        for pair in pairs {
            let price = pair.product?.price ?? pair.package.price ?? 0
            guard let rate = dailyRate(price: price, period: pair.product?.subscription?.subscriptionPeriod) else {
                continue
            }
            rates[pair.package.id] = rate
        }
        return rates
    }
}
