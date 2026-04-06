import Foundation
import AppActor

struct GetASAFirstInstallOnAccountRequest: AppActorPluginRequest {
    static let method = "get_asa_first_install_on_account"

    @MainActor
    func execute() async throws -> AppActorPluginResult {
        .encoding(AppActor.asaFirstInstallOnAccount)
    }
}
