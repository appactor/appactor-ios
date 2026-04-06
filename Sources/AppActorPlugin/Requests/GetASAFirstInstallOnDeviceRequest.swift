import Foundation
import AppActor

struct GetASAFirstInstallOnDeviceRequest: AppActorPluginRequest {
    static let method = "get_asa_first_install_on_device"

    @MainActor
    func execute() async throws -> AppActorPluginResult {
        .encoding(AppActor.asaFirstInstallOnDevice)
    }
}
