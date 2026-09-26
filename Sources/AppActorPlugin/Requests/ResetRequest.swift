import Foundation
import AppActor

struct ResetRequest: AppActorPluginRequest {
    static let method = "reset"

    @MainActor
    func execute() async throws -> AppActorPluginResult {
        await AppActor.shared.reset()
        // A reset forgets the user, App Store purchase intents still waiting for the host
        // included (one stored while reset() ran too). purchase(intent:) refused them meanwhile.
        if #available(iOS 16.4, macOS 14.4, tvOS 16.4, watchOS 9.4, *) {
            PurchaseIntentStore.shared.removeAll()
        }
        // reset() nils most SDK handlers the event bridge installs, so re-arm it
        // to keep all event types flowing after a reset→reconfigure cycle.
        AppActorPluginEventBridge.shared.reapplyListenersAfterReset()
        return .successVoid
    }
}
