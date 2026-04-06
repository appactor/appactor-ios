import Foundation
import AppActor

struct GetIsAnonymousRequest: AppActorPluginRequest {
    static let method = "get_is_anonymous"

    @MainActor
    func execute() async throws -> AppActorPluginResult {
        .encoding(AppActor.shared.isAnonymous)
    }
}
