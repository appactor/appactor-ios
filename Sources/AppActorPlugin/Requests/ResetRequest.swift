import Foundation
import AppActor

struct ResetRequest: AppActorPluginRequest {
    static let method = "reset"

    @MainActor
    func execute() async throws -> AppActorPluginResult {
        await AppActor.shared.reset()
        return .successVoid
    }
}
