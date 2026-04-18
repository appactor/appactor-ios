import Foundation
import AppActor

struct IsReadyRequest: AppActorPluginRequest {
    static let method = "is_ready"

    @MainActor
    func execute() async throws -> AppActorPluginResult {
        .encoding(AppActorBridge.shared.isReady)
    }
}
