import Foundation
import AppActor

struct GetCachedOfferingsRequest: AppActorPluginRequest {
    static let method = "get_cached_offerings"

    @MainActor
    func execute() async throws -> AppActorPluginResult {
        guard let offerings = AppActor.shared.cachedOfferings else {
            return .success(AppActorPluginResult.nullData)
        }
        return .encoding(PluginOfferings(from: offerings))
    }
}
