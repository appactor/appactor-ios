import Foundation
import AppActor

struct IsConfiguredRequest: AppActorPluginRequest {
    static let method = "is_configured"

    @MainActor
    func execute() async throws -> AppActorPluginResult {
        .encoding(AppActorBridge.shared.isConfigured)
    }
}
