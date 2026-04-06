import Foundation
import AppActor

struct GetPendingASAPurchaseEventCountRequest: AppActorPluginRequest {
    static let method = "get_pending_asa_purchase_event_count"

    @MainActor
    func execute() async throws -> AppActorPluginResult {
        let count = await AppActor.shared.pendingASAPurchaseEventCount
        return .encoding(count)
    }
}
