import Foundation
import AppActor

struct LogInRequest: AppActorPluginRequest {
    static let method = "log_in"

    let newAppUserId: String

    @MainActor
    func execute() async throws -> AppActorPluginResult {
        let info = try await AppActor.shared.logIn(newAppUserId: newAppUserId)
        return .encoding(PluginCustomerInfo(from: info))
    }
}
