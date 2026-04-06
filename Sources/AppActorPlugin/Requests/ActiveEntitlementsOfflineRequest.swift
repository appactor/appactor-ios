import Foundation
import AppActor

struct ActiveEntitlementsOfflineRequest: AppActorPluginRequest {
    static let method = "active_entitlement_keys_offline"

    @MainActor
    func execute() async throws -> AppActorPluginResult {
        let keys = await AppActor.shared.activeEntitlementKeysOffline()
        return .encoding(OfflineKeysResponse(keys: Array(keys)))
    }
}

private struct OfflineKeysResponse: Encodable {
    let keys: [String]
}
