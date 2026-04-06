import Foundation
import AppActor

struct GetSDKVersionRequest: AppActorPluginRequest {
    static let method = "get_sdk_version"

    @MainActor
    func execute() async throws -> AppActorPluginResult {
        .encoding(AppActor.sdkVersion)
    }
}
