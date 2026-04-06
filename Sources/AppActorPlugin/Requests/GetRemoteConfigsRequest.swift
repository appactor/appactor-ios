import Foundation
import AppActor

struct GetRemoteConfigsRequest: AppActorPluginRequest {
    static let method = "get_remote_configs"

    @MainActor
    func execute() async throws -> AppActorPluginResult {
        let configs = try await AppActor.shared.getRemoteConfigs()
        return .encoding(PluginRemoteConfigs(from: configs))
    }
}
