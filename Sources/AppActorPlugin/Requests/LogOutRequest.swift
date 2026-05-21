import Foundation
import AppActor

struct LogOutRequest: AppActorPluginRequest {
    static let method = "log_out"

    @MainActor
    func execute() async throws -> AppActorPluginResult {
        let isAnonymous = try await AppActor.shared.logOut()
        return .encoding(LogOutResponse(value: isAnonymous))
    }
}

private struct LogOutResponse: Encodable {
    let value: Bool
}
