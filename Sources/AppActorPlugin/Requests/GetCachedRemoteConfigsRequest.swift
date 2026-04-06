import Foundation
import AppActor

struct GetCachedRemoteConfigsRequest: AppActorPluginRequest {
    static let method = "get_cached_remote_configs"

    @MainActor
    func execute() async throws -> AppActorPluginResult {
        guard let configs = AppActor.shared.cachedRemoteConfigs else {
            return .success(AppActorPluginResult.nullData)
        }
        return .encoding(PluginRemoteConfigs(from: configs))
    }
}
