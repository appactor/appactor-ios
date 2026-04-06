import Foundation
import AppActor

/// Encodable wrapper for `AppActorPurchaseResult` enum.
struct PluginPurchaseResult: Encodable, Sendable {
    let status: String
    let customerInfo: PluginCustomerInfo?
    let purchaseInfo: PluginPurchaseInfo?

    init(from result: AppActorPurchaseResult) {
        switch result {
        case .success(let customerInfo, let purchaseInfo):
            self.status = "success"
            self.customerInfo = PluginCustomerInfo(from: customerInfo)
            self.purchaseInfo = purchaseInfo.map { PluginPurchaseInfo(from: $0) }
        case .cancelled:
            self.status = "cancelled"
            self.customerInfo = nil
            self.purchaseInfo = nil
        case .pending:
            self.status = "pending"
            self.customerInfo = nil
            self.purchaseInfo = nil
        }
    }
}
