import Foundation

/// Centralized ETag and response cache manager.
///
/// Provides a single point of ETag storage, retrieval, and 304-handling logic
/// for all cacheable payment resources (offerings, customer).
///
/// When `responseVerificationEnabled` is `true`, cache entries with failed
/// verification are treated as untrusted and are not reused. Transitional
/// `.notRequested` entries are still allowed through until the server signs them.
actor AppActorETagManager {

    private let diskStore: AppActorCacheDiskStore
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    /// Whether the current SDK configuration requires response signature verification.
    private let responseVerificationEnabled: Bool

    init(
        diskStore: AppActorCacheDiskStore = AppActorCacheDiskStore(),
        responseVerificationEnabled: Bool = false
    ) {
        self.diskStore = diskStore
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        self.responseVerificationEnabled = responseVerificationEnabled
    }

    // MARK: - ETag Retrieval

    /// Returns the stored ETag for the resource, or nil if none/forceRefresh.
    ///
    /// When response verification is enabled, ETags from failed-verification cache
    /// entries are not returned — this forces a fresh fetch instead of a 304.
    func eTag(for resource: AppActorCacheResource, forceRefresh: Bool = false) async -> String? {
        guard !forceRefresh else { return nil }
        guard let entry = await diskStore.load(resource) else { return nil }
        // Don't reuse ETag from failed verification — force fresh fetch.
        // .notRequested (transitional unsigned) is intentionally allowed through.
        if responseVerificationEnabled && entry.resolvedVerification == .failed {
            return nil
        }
        return entry.eTag
    }

    // MARK: - Store Fresh Response

    /// Stores a fresh 200 response. The value must be Encodable.
    ///
    /// - Parameter verified: Whether this specific response was cryptographically verified.
    ///   Defaults to `responseVerificationEnabled` — pass `false` explicitly when the server
    ///   did not support signing (transitional `.signingNotSupported`).
    func storeFresh<T: Encodable>(_ value: T, for resource: AppActorCacheResource, eTag: String?, verified: Bool? = nil) async {
        guard let data = try? encoder.encode(value) else { return }
        await diskStore.save(makeCacheEntry(data: data, eTag: eTag, verified: verified), for: resource)
    }

    /// Stores raw Data as a fresh 200 response.
    func storeFreshData(_ data: Data, for resource: AppActorCacheResource, eTag: String?, verified: Bool? = nil) async {
        await diskStore.save(makeCacheEntry(data: data, eTag: eTag, verified: verified), for: resource)
    }

    /// Creates a cache entry with correctly mapped verification status.
    ///
    /// - `verified == true`  → `.verified` (signature passed)
    /// - `verified == false` → `.notRequested` (server didn't sign — transitional, NOT a failure)
    /// - `verified == nil`   → `nil` (verification wasn't relevant to the caller)
    private func makeCacheEntry(data: Data, eTag: String?, verified: Bool?) -> AppActorCacheEntry {
        AppActorCacheEntry(
            data: data, eTag: eTag, cachedAt: Date(),
            responseVerified: verified ?? responseVerificationEnabled,
            verificationResult: verified.map { AppActorVerificationResult.from(signatureVerified: $0) }
        )
    }

    // MARK: - Handle 304 Not Modified

    /// Handles a 304 response: atomically updates timestamp and optional rotated ETag,
    /// then returns the cached value with its verification status. Returns nil if cache is missing.
    func handleNotModified<T: Decodable>(
        _ type: T.Type,
        for resource: AppActorCacheResource,
        rotatedETag: String? = nil
    ) async -> (value: T, verification: AppActorVerificationResult)? {
        guard let entry = await diskStore.updateTimestampAndLoad(for: resource, rotatedETag: rotatedETag) else {
            return nil
        }
        if responseVerificationEnabled && entry.resolvedVerification == .failed { return nil }
        guard let value = try? decoder.decode(T.self, from: entry.data) else { return nil }
        return (value: value, verification: entry.resolvedVerification)
    }

    // MARK: - Read Cache

    /// Loads the cached value if available.
    ///
    /// When response verification is enabled, entries with failed verification are ignored.
    func cached<T: Decodable>(_ type: T.Type, for resource: AppActorCacheResource) async -> (value: T, eTag: String?, cachedAt: Date, verification: AppActorVerificationResult)? {
        guard let entry = await diskStore.load(resource) else { return nil }
        if responseVerificationEnabled && entry.resolvedVerification == .failed { return nil }
        guard let value = try? decoder.decode(T.self, from: entry.data) else { return nil }
        return (value: value, eTag: entry.eTag, cachedAt: entry.cachedAt, verification: entry.resolvedVerification)
    }

    /// Returns true if the resource has a cache entry fresher than the given TTL.
    func isFresh(for resource: AppActorCacheResource, ttl: TimeInterval) async -> Bool {
        guard let entry = await diskStore.load(resource) else { return false }
        if responseVerificationEnabled && entry.resolvedVerification == .failed { return false }
        return Date().timeIntervalSince(entry.cachedAt) < ttl
    }

    // MARK: - Verification-mode cache invalidation

    /// Removes all failed-verification cache entries from disk when verification is enabled.
    ///
    /// Scans every cached file and removes entries whose verification result is
    /// `.failed`. Transitional `.notRequested` entries remain available until the
    /// server signs them. This covers both offerings and all per-user customer caches.
    func clearUnverifiedIfNeeded() async {
        guard responseVerificationEnabled else { return }
        await diskStore.clearAllUnverified()
    }

    // MARK: - Clear

    /// Resets the freshness timestamp without deleting the cached data or ETag.
    /// Next fetch will treat the cache as stale but still send `If-None-Match`
    /// for a potential 304 response (bandwidth-efficient retry).
    func resetFreshness(for resource: AppActorCacheResource) async {
        await diskStore.resetFreshness(for: resource)
    }

    /// Clears cache for a specific resource.
    func clear(_ resource: AppActorCacheResource) async {
        await diskStore.clear(resource)
    }

    /// Clears every remote config cache variant for a user/context prefix.
    func clearRemoteConfigs(appUserId: String?) async {
        await diskStore.clear(prefix: AppActorCacheResource.remoteConfigsPrefix(appUserId: appUserId))
    }

    /// Clears every experiment cache variant for a user/context prefix.
    func clearExperiments(appUserId: String) async {
        await diskStore.clear(prefix: AppActorCacheResource.experimentsPrefix(appUserId: appUserId))
    }

    /// Clears all cached data.
    func clearAll() async {
        await diskStore.clearAll()
    }
}
