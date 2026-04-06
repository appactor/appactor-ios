import Foundation
import AppActor

struct GetOfferingsRequest: AppActorPluginRequest {
    static let method = "get_offerings"

    @MainActor
    func execute() async throws -> AppActorPluginResult {
        let offerings = try await AppActor.shared.offerings()
        return .encoding(PluginOfferings(from: offerings))
    }
}
