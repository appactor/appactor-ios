import Foundation
import StoreKit

/// Builds the `package` objects the runtime interpolates as `{{package.*}}`.
///
/// The field list is frozen (`spec/package-fields.ts`, `FROZEN.md` §2): these
/// names live inside published documents. The runtime is a pure pass-through
/// that hides a component when its value is missing, so every field here must
/// be filled or deliberately null.
///
/// Period, trial and offer come from the live StoreKit `Product`, not from
/// ``AppActorPackage``. Moving them onto the public model -- and making Android
/// agree what "trial" means given Play's ordered phase list -- is its own work.
enum AppActorScreenPackagePayload {

    /// One subscription period unit, resolved once. Four separate switches used
    /// to answer these questions with four `@unknown default`s that had to stay
    /// consistent by hand -- a wire unit of `"month"` beside a day count of 7
    /// is a wrong price per week.
    ///
    /// `perUnitDays` is marketing maths, not calendar maths: the 365/52
    /// approximation every store in this category uses.
    private struct PeriodShape {
        let wire: String
        let perUnitDays: Decimal
        let allowedUnit: NSCalendar.Unit
        let component: Calendar.Component
    }

    private static func shape(_ unit: Product.SubscriptionPeriod.Unit) -> PeriodShape {
        switch unit {
        case .day: return PeriodShape(wire: "day", perUnitDays: 1, allowedUnit: .day, component: .day)
        case .week: return PeriodShape(wire: "week", perUnitDays: 7, allowedUnit: .weekOfMonth, component: .weekOfMonth)
        case .month: return PeriodShape(wire: "month", perUnitDays: 30, allowedUnit: .month, component: .month)
        case .year: return PeriodShape(wire: "year", perUnitDays: 365, allowedUnit: .year, component: .year)
        // `periodUnit` is a closed set: an unrecognised unit is reported as a
        // month rather than a new string both renderers would have to guess at.
        @unknown default: return PeriodShape(wire: "month", perUnitDays: 30, allowedUnit: .month, component: .month)
        }
    }

    private static func days(unit: Product.SubscriptionPeriod.Unit, count: Int) -> Decimal {
        shape(unit).perUnitDays * Decimal(max(count, 1))
    }

    private static func wireUnit(_ unit: Product.SubscriptionPeriod.Unit) -> String {
        shape(unit).wire
    }

    /// "1 month", "1 year" — via `DateComponentsFormatter`, so a Turkish device
    /// reads "1 ay" without the SDK shipping a string table.
    private static func periodString(unit: Product.SubscriptionPeriod.Unit, count: Int) -> String {
        let shape = shape(unit)

        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .full
        formatter.allowedUnits = [shape.allowedUnit]
        formatter.maximumUnitCount = 1

        var components = DateComponents()
        components.setValue(count, for: shape.component)

        return formatter.string(from: components) ?? "\(count) \(shape.wire)"
    }

    private static func trialDays(_ offer: Product.SubscriptionOffer?) -> Int {
        guard let offer, offer.paymentMode == .freeTrial else { return 0 }
        let value = days(unit: offer.period.unit, count: offer.period.value)
        return NSDecimalNumber(decimal: value).intValue
    }

    /// Price for one day: the common denominator behind `pricePerWeekString`,
    /// `pricePerMonthString` and `discountPercent`, so there is one
    /// normalisation to get wrong instead of three.
    private static func dailyRate(price: Decimal, period: Product.SubscriptionPeriod?) -> Decimal? {
        guard let period else { return nil }
        // `days` cannot return zero: `perUnitDays` and the clamped count are
        // both at least 1.
        return price / days(unit: period.unit, count: period.value)
    }

    private static func money(_ amount: Decimal, _ product: Product) -> String {
        amount.formatted(product.priceFormatStyle)
    }

    /// `product` is optional so this owns the whole fallback chain.
    private static func currencyCode(_ package: AppActorPackage, _ product: Product?) -> String {
        if let code = package.currencyCode, !code.isEmpty { return code }
        if #available(iOS 16.0, macOS 13.0, tvOS 16.0, watchOS 9.0, *), let product {
            return product.priceFormatStyle.currencyCode
        }
        // iOS 15 exposes no currency code on the format style, and the frozen
        // contract types this as a string -- the runtime hides an empty value
        // the same way it hides a missing one.
        return ""
    }

    /// One package as the runtime will see it. `product` is optional because a
    /// package can outlive its StoreKit product; every subscription field then
    /// degrades rather than dropping the package, since the document still
    /// needs `{{package.priceString}}` and `AppActorPackage` can answer that.
    static func make(package: AppActorPackage, product: Product?) async -> [String: Any] {
        let price = product?.price ?? package.price ?? 0
        let priceString = product.map { money(price, $0) } ?? package.localizedPriceString
        let period = product?.subscription?.subscriptionPeriod
        let offer = product?.subscription?.introductoryOffer

        var payload: [String: Any] = [
            "id": package.id,
            "priceString": priceString,
            "price": NSDecimalNumber(decimal: price).doubleValue,
            "currencyCode": currencyCode(package, product),
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
