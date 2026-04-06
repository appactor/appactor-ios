import Foundation
import AppActor

struct GetRemoteConfigRequest: AppActorPluginRequest {
    static let method = "get_remote_config"

    let key: String

    @MainActor
    func execute() async throws -> AppActorPluginResult {
        guard let configs = AppActor.shared.cachedRemoteConfigs,
              let item = configs.items.first(where: { $0.key == key }) else {
            return .success(AppActorPluginResult.nullData)
        }
        return .encoding(PluginRemoteConfigItem(from: item))
    }
}
