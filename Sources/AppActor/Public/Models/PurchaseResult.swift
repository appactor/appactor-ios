import Foundation

/// The outcome of a purchase attempt.
public enum AppActorPurchaseResult: Sendable {
    /// Purchase completed successfully. The associated `customerInfo` reflects the updated
    /// entitlement state. `purchaseInfo` carries store-agnostic transaction details
    /// when a native store purchase completed.
    case success(customerInfo: AppActorCustomerInfo, purchaseInfo: AppActorPurchaseInfo?)

    /// The user cancelled the purchase.
    case cancelled

    /// The purchase is pending external approval (Ask to Buy, SCA).
    /// The transaction will arrive via `Transaction.updates` later.
    case pending
}
