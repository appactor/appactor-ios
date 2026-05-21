import Foundation
import AppActor

struct GetAppUserIdRequest: AppActorPluginRequest {
    static let method = "get_app_user_id"

    @MainActor
    func execute() async throws -> AppActorPluginResult {
        if let userId = AppActor.shared.appUserId {
            return .encoding(userId)
        }
        return .success(AppActorPluginResult.nullData)
    }
}
