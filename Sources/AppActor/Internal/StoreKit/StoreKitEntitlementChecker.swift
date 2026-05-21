import Foundation
import StoreKit

/// Protocol for checking active entitlements via StoreKit 2.
/// Enables mocking in tests (real SK2 transactions aren't available in unit tests).
protocol AppActorStoreKitEntitlementCheckerProtocol: Sendable {
    /// Returns `true` if there is at least one active, verified entitlement in StoreKit.
    func hasActiveEntitlement() async -> Bool
    /// Returns the set of product IDs with active, verified entitlements in StoreKit.
    func activeProductIds() async -> Set<String>
}

/// Default implementation that reads `Transaction.currentEntitlements`.
struct AppActorStoreKitEntitlementChecker: AppActorStoreKitEntitlementCheckerProtocol {
    func hasActiveEntitlement() async -> Bool {
        for await result in Transaction.currentEntitlements {
            if case .verified(let txn) = result, txn.revocationDate == nil {
                return true
            }
        }
        return false
    }

    func activeProductIds() async -> Set<String> {
        var ids = Set<String>()
        for await result in Transaction.currentEntitlements {
            if case .verified(let txn) = result, txn.revocationDate == nil {
                ids.insert(txn.productID)
            }
        }
        return ids
    }
}
