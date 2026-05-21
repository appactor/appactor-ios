import Foundation

/// Describes how a product was acquired.
public enum AppActorOwnershipType: String, Sendable, Codable, Equatable {
    /// Purchased directly by this user.
    case purchased
    /// Shared via Family Sharing.
    case familyShared
    /// Unknown or unrecognized ownership type.
    case unknown

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        self = AppActorOwnershipType(rawValue: raw) ?? .unknown
    }
}

/// The subscription period category.
public enum AppActorPeriodType: String, Sendable, Codable, Equatable {
    case weekly
    case monthly
    case twoMonth
    case threeMonth
    case sixMonth
    case annual
    case lifetime
    /// Standard subscription period (no trial or intro pricing).
    case normal
    /// Free trial period.
    case trial
    /// Introductory offer period.
    case intro
    case unknown

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        self = AppActorPeriodType(rawValue: raw) ?? .unknown
    }
}

/// The store through which a purchase was made.
public enum AppActorStore: String, Sendable, Codable, Equatable {
    case appStore = "app_store"
    case playStore = "play_store"
    case stripe
    case promotional
    case unknown

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        self = AppActorStore(rawValue: raw) ?? .unknown
    }
}

/// Why a subscription was cancelled.
public enum AppActorCancellationReason: String, Sendable, Codable, Equatable {
    case customerCancelled = "customer_cancelled"
    case developerCancelled = "developer_cancelled"
    case unknown

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        self = AppActorCancellationReason(rawValue: raw) ?? .unknown
    }
}

/// Runtime state of a single entitlement.
///
/// Built by `EntitlementEngine` based on verified transactions (local mode)
/// or by the server (payment mode). Payment-mode-only fields are optional
/// and `nil` in local mode.
public struct AppActorEntitlementInfo: Sendable, Identifiable, Codable, Equatable {

    // MARK: - Universal Fields

    /// The entitlement identifier (e.g. `"premium"`).
    public let id: String

    /// Whether the entitlement is currently active.
    public let isActive: Bool

    /// The product ID that granted this entitlement.
    public let productID: String?

    /// When the entitlement was originally purchased.
    public let originalPurchaseDate: Date?

    /// When the current period expires (subscriptions only).
    public let expirationDate: Date?

    /// How the product was acquired.
    public let ownershipType: AppActorOwnershipType

    /// The subscription period, if applicable.
    public let periodType: AppActorPeriodType

    /// Whether the subscription will auto-renew.
    public let willRenew: Bool

    /// Detailed subscription status. `nil` for non-consumable products (not applicable).
    public let subscriptionStatus: AppActorSubscriptionStatus?

    // MARK: - Payment-mode Fields (nil in local mode)

    /// The store through which the purchase was made. `nil` in local mode.
    public let store: AppActorStore?

    /// Android base plan identifier when present.
    public let basePlanId: String?

    /// Android offer identifier when present.
    public let offerId: String?

    /// Whether the purchase was made in a sandbox environment. `nil` in local mode.
    public let isSandbox: Bool?

    /// Why the subscription was cancelled, if applicable. `nil` if not cancelled.
    public let cancellationReason: AppActorCancellationReason?

    /// When the grace period expires (payment issue, still active). `nil` if not in grace period.
    public let gracePeriodExpiresAt: Date?

    /// When a billing issue was first detected. `nil` if no billing issue.
    public let billingIssueDetectedAt: Date?

    /// When the user was detected to have unsubscribed. `nil` if still subscribed.
    public let unsubscribeDetectedAt: Date?

    /// When the subscription was last renewed. `nil` if never renewed.
    public let renewedAt: Date?

    /// When the entitlement starts (for future-dated entitlements). `nil` if already started.
    public let startsAt: Date?

    /// How the entitlement was granted (e.g. promotional). `nil` for standard purchases.
    public let grantedBy: String?

    /// The type of active promotional offer, if any.
    public let activePromotionalOfferType: String?

    /// The ID of the active promotional offer, if any.
    public let activePromotionalOfferId: String?

    // MARK: - Computed Properties

    /// Whether the user is in a grace period (payment issue, still has access).
    public var isInGracePeriod: Bool { subscriptionStatus == .gracePeriod }

    /// Whether the subscription is in billing retry (payment failed, no access).
    public var isInPaymentRetry: Bool { subscriptionStatus == .billingRetry }

    /// Whether the subscription has been revoked (refunded).
    public var isRevoked: Bool { subscriptionStatus == .revoked }

    // MARK: - Initializer

    public init(
        id: String,
        isActive: Bool = false,
        productID: String? = nil,
        originalPurchaseDate: Date? = nil,
        expirationDate: Date? = nil,
        ownershipType: AppActorOwnershipType = .purchased,
        periodType: AppActorPeriodType = .unknown,
        willRenew: Bool = false,
        subscriptionStatus: AppActorSubscriptionStatus? = nil,
        store: AppActorStore? = nil,
        basePlanId: String? = nil,
        offerId: String? = nil,
        isSandbox: Bool? = nil,
        cancellationReason: AppActorCancellationReason? = nil,
        gracePeriodExpiresAt: Date? = nil,
        billingIssueDetectedAt: Date? = nil,
        unsubscribeDetectedAt: Date? = nil,
        renewedAt: Date? = nil,
        startsAt: Date? = nil,
        grantedBy: String? = nil,
        activePromotionalOfferType: String? = nil,
        activePromotionalOfferId: String? = nil
    ) {
        self.id = id
        self.isActive = isActive
        self.productID = productID
        self.originalPurchaseDate = originalPurchaseDate
        self.expirationDate = expirationDate
        self.ownershipType = ownershipType
        self.periodType = periodType
        self.willRenew = willRenew
        self.subscriptionStatus = subscriptionStatus
        self.store = store
        self.basePlanId = basePlanId
        self.offerId = offerId
        self.isSandbox = isSandbox
        self.cancellationReason = cancellationReason
        self.gracePeriodExpiresAt = gracePeriodExpiresAt
        self.billingIssueDetectedAt = billingIssueDetectedAt
        self.unsubscribeDetectedAt = unsubscribeDetectedAt
        self.renewedAt = renewedAt
        self.startsAt = startsAt
        self.grantedBy = grantedBy
        self.activePromotionalOfferType = activePromotionalOfferType
        self.activePromotionalOfferId = activePromotionalOfferId
    }

    // MARK: - Defensive Codable

    private enum CodingKeys: String, CodingKey {
        case id, isActive, productID, originalPurchaseDate, expirationDate
        case ownershipType, periodType, willRenew, subscriptionStatus
        case store, basePlanId, offerId, isSandbox, cancellationReason
        case gracePeriodExpiresAt, billingIssueDetectedAt, unsubscribeDetectedAt
        case renewedAt, startsAt, grantedBy
        case activePromotionalOfferType, activePromotionalOfferId
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decodeIfPresent(String.self, forKey: .id)) ?? ""
        isActive = (try? c.decodeIfPresent(Bool.self, forKey: .isActive)) ?? false
        productID = try? c.decodeIfPresent(String.self, forKey: .productID)
        originalPurchaseDate = try? c.decodeIfPresent(Date.self, forKey: .originalPurchaseDate)
        expirationDate = try? c.decodeIfPresent(Date.self, forKey: .expirationDate)
        ownershipType = (try? c.decodeIfPresent(AppActorOwnershipType.self, forKey: .ownershipType)) ?? .purchased
        periodType = (try? c.decodeIfPresent(AppActorPeriodType.self, forKey: .periodType)) ?? .unknown
        willRenew = (try? c.decodeIfPresent(Bool.self, forKey: .willRenew)) ?? false
        subscriptionStatus = try? c.decodeIfPresent(AppActorSubscriptionStatus.self, forKey: .subscriptionStatus)
        store = try? c.decodeIfPresent(AppActorStore.self, forKey: .store)
        basePlanId = try? c.decodeIfPresent(String.self, forKey: .basePlanId)
        offerId = try? c.decodeIfPresent(String.self, forKey: .offerId)
        isSandbox = try? c.decodeIfPresent(Bool.self, forKey: .isSandbox)
        cancellationReason = try? c.decodeIfPresent(AppActorCancellationReason.self, forKey: .cancellationReason)
        gracePeriodExpiresAt = try? c.decodeIfPresent(Date.self, forKey: .gracePeriodExpiresAt)
        billingIssueDetectedAt = try? c.decodeIfPresent(Date.self, forKey: .billingIssueDetectedAt)
        unsubscribeDetectedAt = try? c.decodeIfPresent(Date.self, forKey: .unsubscribeDetectedAt)
        renewedAt = try? c.decodeIfPresent(Date.self, forKey: .renewedAt)
        startsAt = try? c.decodeIfPresent(Date.self, forKey: .startsAt)
        grantedBy = try? c.decodeIfPresent(String.self, forKey: .grantedBy)
        activePromotionalOfferType = try? c.decodeIfPresent(String.self, forKey: .activePromotionalOfferType)
        activePromotionalOfferId = try? c.decodeIfPresent(String.self, forKey: .activePromotionalOfferId)
    }
}
