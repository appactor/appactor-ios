import Foundation

/// Identifies the role of a package within an offering.
public enum AppActorPackageType: String, Sendable, Codable, CaseIterable {
    case monthly
    case annual
    case weekly
    case twoMonth
    case threeMonth
    case sixMonth
    case lifetime
    case custom

    /// A human-readable label used for display purposes.
    public var displayName: String {
        switch self {
        case .monthly:    return "Monthly"
        case .annual:     return "Annual"
        case .weekly:     return "Weekly"
        case .twoMonth:   return "2 Month"
        case .threeMonth: return "3 Month"
        case .sixMonth:   return "6 Month"
        case .lifetime:   return "Lifetime"
        case .custom:     return "Custom"
        }
    }

    /// Creates from a server-sent string value.
    /// Accepts camelCase, snake_case singular, and snake_case plural variants for backward compat.
    /// Unknown strings map to `.custom`.
    init(serverString: String) {
        switch serverString {
        case "weekly":                                          self = .weekly
        case "monthly":                                         self = .monthly
        case "twoMonth", "two_month", "two_months":             self = .twoMonth
        case "threeMonth", "three_month", "three_months":       self = .threeMonth
        case "sixMonth", "six_month", "six_months":             self = .sixMonth
        case "annual":                                          self = .annual
        case "lifetime":                                        self = .lifetime
        default:                                                self = .custom
        }
    }
}
