import Foundation

/// Token balance snapshot returned by the payment backend.
///
/// `renewable` tracks tokens that replenish on renewal, while `nonRenewable`
/// tracks one-time or manually granted tokens. `total` is the backend-reported
/// sum exposed for convenience.
public struct AppActorTokenBalance: Sendable, Codable, Equatable {
    public let renewable: Int
    public let nonRenewable: Int
    public let total: Int

    public init(renewable: Int, nonRenewable: Int, total: Int? = nil) {
        self.renewable = renewable
        self.nonRenewable = nonRenewable
        self.total = total ?? (renewable + nonRenewable)
    }
}
