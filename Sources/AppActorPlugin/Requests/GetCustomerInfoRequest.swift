import Foundation
import AppActor

struct GetCustomerInfoRequest: AppActorPluginRequest {
    static let method = "get_customer_info"

    @MainActor
    func execute() async throws -> AppActorPluginResult {
        let info = try await AppActor.shared.getCustomerInfo()
        return .encoding(PluginCustomerInfo(from: info))
    }
}
