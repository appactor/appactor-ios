import Foundation
import AppActor

struct EnableAppleSearchAdsTrackingRequest: AppActorPluginRequest {
    static let method = "enable_apple_search_ads_tracking"

    let autoTrackPurchases: Bool?
    let trackInSandbox: Bool?
    let debugMode: Bool?

    @MainActor
    func execute() async throws -> AppActorPluginResult {
        var options = AppActorASAOptions()
        if let autoTrack = autoTrackPurchases { options.autoTrackPurchases = autoTrack }
        if let sandbox = trackInSandbox { options.trackInSandbox = sandbox }
        if let debug = debugMode { options.debugMode = debug }
        try AppActor.shared.enableAppleSearchAdsTracking(options: options)
        return .successVoid
    }
}
