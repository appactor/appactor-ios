import Foundation
import AppActor

struct SetLogLevelRequest: AppActorPluginRequest {
    static let method = "set_log_level"

    let logLevel: String

    @MainActor
    func execute() async throws -> AppActorPluginResult {
        AppActor.logLevel = AppActorLogLevel(stringLiteral: logLevel)
        return .successVoid
    }
}
