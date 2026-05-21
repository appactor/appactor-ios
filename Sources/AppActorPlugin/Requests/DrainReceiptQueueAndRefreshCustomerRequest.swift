import Foundation
import AppActor

struct DrainReceiptQueueAndRefreshCustomerRequest: AppActorPluginRequest {
    static let method = "drain_receipt_queue_and_refresh_customer"

    @MainActor
    func execute() async throws -> AppActorPluginResult {
        let info = try await AppActor.shared.drainReceiptQueueAndRefreshCustomer()
        return .encoding(PluginCustomerInfo(from: info))
    }
}
