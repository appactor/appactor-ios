import Foundation
import AppActor

struct GetCachedCustomerInfoRequest: AppActorPluginRequest {
    static let method = "get_cached_customer_info"

    @MainActor
    func execute() async throws -> AppActorPluginResult {
        .encoding(PluginCustomerInfo(from: AppActor.shared.customerInfo))
    }
}
