import Foundation
import AppActor

struct GetOfferingsRequest: AppActorPluginRequest {
    static let method = "get_offerings"

    let fetchPolicy: String?

    @MainActor
    func execute() async throws -> AppActorPluginResult {
        let offerings = try await AppActor.shared.offerings(fetchPolicy: resolvedFetchPolicy)
        return .encoding(PluginOfferings(from: offerings))
    }

    private var resolvedFetchPolicy: AppActorOfferingsFetchPolicy {
        switch fetchPolicy {
        case "returnCachedThenRefresh":
            return .returnCachedThenRefresh
        case "cacheOnly":
            return .cacheOnly
        default:
            return .freshIfStale
        }
    }
}
