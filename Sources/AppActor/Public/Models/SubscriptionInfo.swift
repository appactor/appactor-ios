import Foundation

/// Top-level subscription record returned in payment mode.
///
/// Replaces the old nested `AppActorCustomerInfo.Subscription`. Contains
/// the full server-authoritative subscription state for a single subscription key.
/// Date fields are stored as String? (server format) with computed `Date?` helpers.
public struct AppActorSubscriptionInfo: Sendable, Codable, Equatable {

    /// Opaque subscription key used by the backend map. Can be compound on Android.
    public let subscriptionKey: String
    public let productIdentifier: String
    public let basePlanId: String?
    public let offerId: String?
    public let isActive: Bool
    public let expiresDate: String?
    public let purchaseDate: String?
    public let startsAt: String?
    public let periodType: AppActorPeriodType?
    public let store: AppActorStore?
    public let status: String?
    public let autoRenew: Bool?
    public let isSandbox: Bool?
    public let gracePeriodExpiresAt: String?
    public let unsubscribeDetectedAt: String?
    public let cancellationReason: AppActorCancellationReason?
    public let renewedAt: String?
    public let originalTransactionId: String?
    public let latestTransactionId: String?
    public let activePromotionalOfferType: String?
    public let activePromotionalOfferId: String?

    // MARK: - Computed Date Helpers

    /// Parsed `expiresDate` as `Date`, or `nil` if missing/unparseable.
    public var expires: Date? { expiresDate.flatMap { AppActorCustomerDateParser.date(from: $0) } }

    /// Parsed `purchaseDate` as `Date`, or `nil` if missing/unparseable.
    public var purchased: Date? { purchaseDate.flatMap { AppActorCustomerDateParser.date(from: $0) } }

    /// Parsed `startsAt` as `Date`, or `nil` if missing/unparseable.
    public var starts: Date? { startsAt.flatMap { AppActorCustomerDateParser.date(from: $0) } }

    /// Parsed `gracePeriodExpiresAt` as `Date`, or `nil` if missing/unparseable.
    public var gracePeriodExpires: Date? { gracePeriodExpiresAt.flatMap { AppActorCustomerDateParser.date(from: $0) } }

    /// Parsed `unsubscribeDetectedAt` as `Date`, or `nil` if missing/unparseable.
    public var unsubscribeDetected: Date? { unsubscribeDetectedAt.flatMap { AppActorCustomerDateParser.date(from: $0) } }

    /// Parsed `renewedAt` as `Date`, or `nil` if missing/unparseable.
    public var renewed: Date? { renewedAt.flatMap { AppActorCustomerDateParser.date(from: $0) } }

    // MARK: - Computed Convenience

    /// Whether this subscription will auto-renew.
    public var willRenew: Bool { autoRenew ?? false }

    /// Whether this subscription is currently in a grace period.
    public var isInGracePeriod: Bool { status == "grace" }

    /// Whether this subscription is a free trial.
    public var isTrial: Bool { periodType == .trial }

    // MARK: - Initializer

    public init(
        subscriptionKey: String? = nil,
        productIdentifier: String,
        basePlanId: String? = nil,
        offerId: String? = nil,
        isActive: Bool,
        expiresDate: String? = nil,
        purchaseDate: String? = nil,
        startsAt: String? = nil,
        periodType: AppActorPeriodType? = nil,
        store: AppActorStore? = nil,
        status: String? = nil,
        autoRenew: Bool? = nil,
        isSandbox: Bool? = nil,
        gracePeriodExpiresAt: String? = nil,
        unsubscribeDetectedAt: String? = nil,
        cancellationReason: AppActorCancellationReason? = nil,
        renewedAt: String? = nil,
        originalTransactionId: String? = nil,
        latestTransactionId: String? = nil,
        activePromotionalOfferType: String? = nil,
        activePromotionalOfferId: String? = nil
    ) {
        self.subscriptionKey = subscriptionKey ?? productIdentifier
        self.productIdentifier = productIdentifier
        self.basePlanId = basePlanId
        self.offerId = offerId
        self.isActive = isActive
        self.expiresDate = expiresDate
        self.purchaseDate = purchaseDate
        self.startsAt = startsAt
        self.periodType = periodType
        self.store = store
        self.status = status
        self.autoRenew = autoRenew
        self.isSandbox = isSandbox
        self.gracePeriodExpiresAt = gracePeriodExpiresAt
        self.unsubscribeDetectedAt = unsubscribeDetectedAt
        self.cancellationReason = cancellationReason
        self.renewedAt = renewedAt
        self.originalTransactionId = originalTransactionId
        self.latestTransactionId = latestTransactionId
        self.activePromotionalOfferType = activePromotionalOfferType
        self.activePromotionalOfferId = activePromotionalOfferId
    }

    private enum CodingKeys: String, CodingKey {
        case subscriptionKey
        case productIdentifier
        case productId
        case basePlanId
        case offerId
        case isActive
        case expiresDate
        case purchaseDate
        case startsAt
        case periodType
        case store
        case status
        case autoRenew
        case isSandbox
        case gracePeriodExpiresAt
        case unsubscribeDetectedAt
        case cancellationReason
        case renewedAt
        case originalTransactionId
        case latestTransactionId
        case activePromotionalOfferType
        case activePromotionalOfferId
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedProductIdentifier = try container.decodeIfPresent(String.self, forKey: .productIdentifier)
            ?? container.decodeIfPresent(String.self, forKey: .productId)
            ?? ""

        self.init(
            subscriptionKey: try container.decodeIfPresent(String.self, forKey: .subscriptionKey) ?? decodedProductIdentifier,
            productIdentifier: decodedProductIdentifier,
            basePlanId: try container.decodeIfPresent(String.self, forKey: .basePlanId),
            offerId: try container.decodeIfPresent(String.self, forKey: .offerId),
            isActive: try container.decodeIfPresent(Bool.self, forKey: .isActive) ?? false,
            expiresDate: try container.decodeIfPresent(String.self, forKey: .expiresDate),
            purchaseDate: try container.decodeIfPresent(String.self, forKey: .purchaseDate),
            startsAt: try container.decodeIfPresent(String.self, forKey: .startsAt),
            periodType: try container.decodeIfPresent(AppActorPeriodType.self, forKey: .periodType),
            store: try container.decodeIfPresent(AppActorStore.self, forKey: .store),
            status: try container.decodeIfPresent(String.self, forKey: .status),
            autoRenew: try container.decodeIfPresent(Bool.self, forKey: .autoRenew),
            isSandbox: try container.decodeIfPresent(Bool.self, forKey: .isSandbox),
            gracePeriodExpiresAt: try container.decodeIfPresent(String.self, forKey: .gracePeriodExpiresAt),
            unsubscribeDetectedAt: try container.decodeIfPresent(String.self, forKey: .unsubscribeDetectedAt),
            cancellationReason: try container.decodeIfPresent(AppActorCancellationReason.self, forKey: .cancellationReason),
            renewedAt: try container.decodeIfPresent(String.self, forKey: .renewedAt),
            originalTransactionId: try container.decodeIfPresent(String.self, forKey: .originalTransactionId),
            latestTransactionId: try container.decodeIfPresent(String.self, forKey: .latestTransactionId),
            activePromotionalOfferType: try container.decodeIfPresent(String.self, forKey: .activePromotionalOfferType),
            activePromotionalOfferId: try container.decodeIfPresent(String.self, forKey: .activePromotionalOfferId)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(subscriptionKey, forKey: .subscriptionKey)
        try container.encode(productIdentifier, forKey: .productIdentifier)
        try container.encodeIfPresent(basePlanId, forKey: .basePlanId)
        try container.encodeIfPresent(offerId, forKey: .offerId)
        try container.encode(isActive, forKey: .isActive)
        try container.encodeIfPresent(expiresDate, forKey: .expiresDate)
        try container.encodeIfPresent(purchaseDate, forKey: .purchaseDate)
        try container.encodeIfPresent(startsAt, forKey: .startsAt)
        try container.encodeIfPresent(periodType, forKey: .periodType)
        try container.encodeIfPresent(store, forKey: .store)
        try container.encodeIfPresent(status, forKey: .status)
        try container.encodeIfPresent(autoRenew, forKey: .autoRenew)
        try container.encodeIfPresent(isSandbox, forKey: .isSandbox)
        try container.encodeIfPresent(gracePeriodExpiresAt, forKey: .gracePeriodExpiresAt)
        try container.encodeIfPresent(unsubscribeDetectedAt, forKey: .unsubscribeDetectedAt)
        try container.encodeIfPresent(cancellationReason, forKey: .cancellationReason)
        try container.encodeIfPresent(renewedAt, forKey: .renewedAt)
        try container.encodeIfPresent(originalTransactionId, forKey: .originalTransactionId)
        try container.encodeIfPresent(latestTransactionId, forKey: .latestTransactionId)
        try container.encodeIfPresent(activePromotionalOfferType, forKey: .activePromotionalOfferType)
        try container.encodeIfPresent(activePromotionalOfferId, forKey: .activePromotionalOfferId)
    }
}
