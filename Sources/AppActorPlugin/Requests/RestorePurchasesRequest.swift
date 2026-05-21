import Foundation
import AppActor

struct RestorePurchasesRequest: AppActorPluginRequest {
    static let method = "restore_purchases"

    let syncWithAppStore: Bool?

    @MainActor
    func execute() async throws -> AppActorPluginResult {
        let info = try await AppActor.shared.restorePurchases(syncWithAppStore: syncWithAppStore ?? false)
        return .encoding(PluginCustomerInfo(from: info))
    }
}
