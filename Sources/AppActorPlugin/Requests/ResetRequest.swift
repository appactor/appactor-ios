import Foundation
import AppActor

struct ResetRequest: AppActorPluginRequest {
    static let method = "reset"

    @MainActor
    func execute() async throws -> AppActorPluginResult {
        await AppActor.shared.reset()
        // reset() nils most SDK handlers the event bridge installs, so re-arm it
        // to keep all event types flowing after a reset→reconfigure cycle.
        AppActorPluginEventBridge.shared.reapplyListenersAfterReset()
        return .successVoid
    }
}
