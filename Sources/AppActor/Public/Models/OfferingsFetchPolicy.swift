import Foundation

/// Controls how ``AppActor/offerings(fetchPolicy:)`` uses cached offerings data.
public enum AppActorOfferingsFetchPolicy: Sendable, Equatable {
    /// Returns fresh cache immediately. If cache is stale or missing, waits for a fresh network response.
    case freshIfStale
    /// Returns suitable cached data immediately when available and refreshes in the background.
    case returnCachedThenRefresh
    /// Returns suitable cached data only. Throws when no locale-compatible cache exists.
    case cacheOnly

    static let freshIfStaleWireValue = "freshIfStale"
    static let returnCachedThenRefreshWireValue = "returnCachedThenRefresh"
    static let cacheOnlyWireValue = "cacheOnly"
}
