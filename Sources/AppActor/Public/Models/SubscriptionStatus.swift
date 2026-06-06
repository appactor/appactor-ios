import Foundation

/// Detailed subscription state for a single product as resolved by StoreKit 2.
///
/// Used by `EntitlementEngine` to communicate subscription status through
/// `AppActorEntitlementInfo.subscriptionStatus`. Developers check `.isEntitled`
/// for access decisions or match specific cases for UI messaging.
public enum AppActorSubscriptionStatus: String, Sendable, Codable, Equatable {
    /// Subscription is active and in good standing.
    case active
    /// Subscription billing failed; Apple is retrying. Access continues temporarily.
    /// Per Apple's recommendation, grace period users retain full access.
    case gracePeriod
    /// Grace period ended; billing still failing. No access.
    /// Exposed for developer messaging (e.g., "Please update your payment method").
    case billingRetry
    /// Subscription expired naturally (or grace/billing retry exhausted).
    case expired
    /// Subscription was refunded or revoked by Apple.
    case revoked
    /// Subscription superseded by upgrade to higher tier in same subscription group.
    case upgraded
    /// Unknown or unrecognized status (defensive fallback for future server values).
    case unknown

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        self = AppActorSubscriptionStatus(rawValue: raw) ?? .unknown
    }

    /// Maps a server-provided status string (payment mode) onto a typed status.
    ///
    /// The backend reports status as a string (e.g. `"grace"`, `"billing_retry"`,
    /// `"revoked"`, `"active"`). This bridges those strings onto the enum so the
    /// payment-mode entitlement helpers (`isInGracePeriod` / `isInPaymentRetry` /
    /// `isRevoked`) reflect the real billing state. Returns `nil` when the server
    /// supplies no status, and `.unknown` for an unrecognized non-empty value.
    init?(serverStatus: String?) {
        guard let serverStatus, !serverStatus.isEmpty else { return nil }
        switch serverStatus {
        case "active":
            self = .active
        case "grace", "grace_period":
            self = .gracePeriod
        case "billing_retry", "billing-retry", "billingRetry":
            self = .billingRetry
        case "expired":
            self = .expired
        case "revoked", "refunded":
            self = .revoked
        case "upgraded":
            self = .upgraded
        default:
            self = AppActorSubscriptionStatus(rawValue: serverStatus) ?? .unknown
        }
    }

    /// Whether the user is entitled to access under this status.
    ///
    /// - `true` for `.active` and `.gracePeriod`
    /// - `false` for `.billingRetry`, `.expired`, `.revoked`, `.upgraded`, `.unknown`
    public var isEntitled: Bool {
        switch self {
        case .active, .gracePeriod: return true
        case .billingRetry, .expired, .revoked, .upgraded, .unknown: return false
        }
    }
}
