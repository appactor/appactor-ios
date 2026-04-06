import Foundation

/// Centralized ETag and response cache manager.
///
/// Provides a single point of ETag storage, retrieval, and 304-handling logic
/// for all cacheable payment resources (offerings, customer).
///
/// When `responseVerificationEnabled` is `true`, cached entries that were stored
/// without response signature verification are treated as untrusted: their ETags
/// are not reused and their data is not returned to callers.
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
    /// When response verification is enabled, ETags from unverified cache entries
    /// are not returned — this forces a fresh (verified) fetch instead of a 304.
    func eTag(for resource: AppActorCacheResource, forceRefresh: Bool = false) async -> String? {
        guard !forceRefresh else { return nil }
        guard let entry = await diskStore.load(resource) else { return nil }
        // Don't reuse ETag from unverified cache when verification is now required
        if responseVerificationEnabled && !entry.responseVerified {
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
        let entry = AppActorCacheEntry(data: data, eTag: eTag, cachedAt: Date(), responseVerified: verified ?? responseVerificationEnabled)
        await diskStore.save(entry, for: resource)
    }

    /// Stores raw Data as a fresh 200 response.
    func storeFreshData(_ data: Data, for resource: AppActorCacheResource, eTag: String?, verified: Bool? = nil) async {
        let entry = AppActorCacheEntry(data: data, eTag: eTag, cachedAt: Date(), responseVerified: verified ?? responseVerificationEnabled)
        await diskStore.save(entry, for: resource)
    }

    // MARK: - Handle 304 Not Modified

    /// Handles a 304 response: atomically updates timestamp and optional rotated ETag,
    /// then returns the cached value. Returns nil if cache is missing.
    func handleNotModified<T: Decodable>(
        _ type: T.Type,
        for resource: AppActorCacheResource,
        rotatedETag: String? = nil
    ) async -> T? {
        guard let entry = await diskStore.updateTimestampAndLoad(for: resource, rotatedETag: rotatedETag) else {
            return nil
        }
        // Defense-in-depth: eTag() already prevents sending If-None-Match for
        // unverified entries, so a 304 for unverified cache shouldn't occur.
        // Guard anyway to prevent returning unverified data.
        if responseVerificationEnabled && !entry.responseVerified { return nil }
        return try? decoder.decode(T.self, from: entry.data)
    }

    // MARK: - Read Cache

    /// Loads the cached value if available.
    ///
    /// When response verification is enabled, unverified cache entries are ignored.
    func cached<T: Decodable>(_ type: T.Type, for resource: AppActorCacheResource) async -> (value: T, eTag: String?, cachedAt: Date)? {
        guard let entry = await diskStore.load(resource) else { return nil }
        if responseVerificationEnabled && !entry.responseVerified { return nil }
        guard let value = try? decoder.decode(T.self, from: entry.data) else { return nil }
        return (value: value, eTag: entry.eTag, cachedAt: entry.cachedAt)
    }

    /// Returns true if the resource has a cache entry fresher than the given TTL.
    func isFresh(for resource: AppActorCacheResource, ttl: TimeInterval) async -> Bool {
        guard let entry = await diskStore.load(resource) else { return false }
        if responseVerificationEnabled && !entry.responseVerified { return false }
        return Date().timeIntervalSince(entry.cachedAt) < ttl
    }

    // MARK: - Verification-mode cache invalidation

    /// Removes all unverified cache entries from disk when verification is enabled.
    ///
    /// Scans every cached file and removes entries that were stored without
    /// response signature verification. This covers both offerings and all
    /// per-user customer caches — no orphaned unverified data remains on disk.
    func clearUnverifiedIfNeeded() async {
        guard responseVerificationEnabled else { return }
        await diskStore.clearAllUnverified()
    }

    // MARK: - Clear

    /// Clears cache for a specific resource.
    func clear(_ resource: AppActorCacheResource) async {
        await diskStore.clear(resource)
    }

    /// Clears all cached data.
    func clearAll() async {
        await diskStore.clearAll()
    }
}
