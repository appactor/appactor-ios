import Foundation
import AppActor

struct SyncPurchasesRequest: AppActorPluginRequest {
    static let method = "sync_purchases"

    @MainActor
    func execute() async throws -> AppActorPluginResult {
        let info = try await AppActor.shared.syncPurchases()
        return .encoding(PluginCustomerInfo(from: info))
    }
}
