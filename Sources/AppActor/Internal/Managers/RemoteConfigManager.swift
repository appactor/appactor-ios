import Foundation

/// Core actor that manages the remote config pipeline:
/// network fetch → caching → typed access.
///
/// Features:
/// - **Single-flight**: concurrent `getRemoteConfigs()` calls coalesce into one network request.
/// - **TTL**: in-memory cache with 5-minute TTL.
/// - **Disk cache**: persists raw DTOs via centralized ETagManager for cold-start recovery.
/// - **ETag**: conditional requests (If-None-Match) to avoid redundant downloads.
actor AppActorRemoteConfigManager {

    // MARK: - Dependencies

    private let client: AppActorPaymentClientProtocol
    private let etagManager: AppActorETagManager
    private let dateProvider: @Sendable () -> Date

    // MARK: - In-Memory State

    private var cachedConfigs: AppActorRemoteConfigs?
    private var cachedAt: Date?
    private var lastRequestId: String?
    private var inFlightTask: Task<AppActorRemoteConfigs, Error>?
    /// Generation counter for safe in-flight bookkeeping (avoids stale task clearing).
    private var inFlightGeneration: UInt64 = 0
    private var lastCacheUserId: String?

    // MARK: - TTL

    private static let cacheTTL: TimeInterval = 5 * 60 // 5 minutes

    // MARK: - Init

    init(
        client: AppActorPaymentClientProtocol,
        etagManager: AppActorETagManager,
        dateProvider: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.client = client
        self.etagManager = etagManager
        self.dateProvider = dateProvider
    }

    // MARK: - Public API

    /// Returns remote configs, using cache when fresh or fetching from network.
    ///
    /// - If memory cache is fresh → returns immediately.
    /// - If no cache or stale → awaits network fetch.
    /// - On network/5xx error → falls back to disk cache.
    func getRemoteConfigs(
        appUserId: String?,
        appVersion: String?,
        country: String?
    ) async throws -> AppActorRemoteConfigs {
        lastCacheUserId = normalizedUserId(appUserId)
        if let cached = cachedConfigs, let at = cachedAt {
            let age = dateProvider().timeIntervalSince(at)
            if age < Self.cacheTTL {
                return cached
            }
        }

        return try await fetchCoalesced(appUserId: appUserId, appVersion: appVersion, country: country)
    }

    /// Returns the current in-memory cached configs, or `nil`.
    var cached: AppActorRemoteConfigs? { cachedConfigs }

    /// The last `request_id` from a remote config response.
    var requestId: String? { lastRequestId }

    /// Clears both in-memory and disk caches.
    /// Cancels any in-flight fetch to prevent actor-reentrancy stale writes.
    func clearCache(appUserId: String?) async {
        inFlightTask?.cancel()
        inFlightTask = nil
        cachedConfigs = nil
        cachedAt = nil
        lastRequestId = nil
        let normalized = normalizedUserId(appUserId)
        lastCacheUserId = normalized
        await etagManager.clear(resource(for: normalized))
    }

    func clearCache() async {
        await clearCache(appUserId: lastCacheUserId)
    }

    // MARK: - Single-Flight Coalescing

    private func fetchCoalesced(appUserId: String?, appVersion: String?, country: String?) async throws -> AppActorRemoteConfigs {
        if let existing = inFlightTask {
            return try await existing.value
        }

        let task = Task<AppActorRemoteConfigs, Error> { [weak self] in
            guard let self else { throw AppActorError.notConfigured }
            do {
                return try await self.executePipeline(appUserId: appUserId, appVersion: appVersion, country: country)
            } catch let error as AppActorError where error.kind == .network || (error.kind == .server && (error.httpStatus ?? 0) >= 500) {
                // Network / 5xx fallback: return disk-cached configs if available
                if let cached = await self.loadFromDiskCache(appUserId: appUserId) {
                    Log.sdk.debug("Network/5xx error — returning disk-cached remote configs")
                    return cached
                }
                throw error
            }
        }

        inFlightGeneration &+= 1
        let generation = inFlightGeneration
        inFlightTask = task

        do {
            let result = try await task.value
            // Only clear if still our generation (clearCache may have replaced it)
            if inFlightGeneration == generation { inFlightTask = nil }
            return result
        } catch {
            if inFlightGeneration == generation { inFlightTask = nil }
            throw error
        }
    }

    // MARK: - Pipeline

    private func executePipeline(appUserId: String?, appVersion: String?, country: String?) async throws -> AppActorRemoteConfigs {
        let normalizedUserId = normalizedUserId(appUserId)
        let cacheResource = resource(for: normalizedUserId)

        // 1. Load cached eTag for conditional request
        let lastETag = await etagManager.eTag(for: cacheResource)

        // 2. Fetch remote configs from API (conditional)
        let result = try await client.getRemoteConfigs(
            appUserId: appUserId,
            appVersion: appVersion,
            country: country,
            eTag: lastETag
        )

        switch result {
        case .fresh(let dtos, let eTag, let requestId, let signatureVerified):
            lastRequestId = requestId

            // Save DTOs + eTag to centralized cache
            await etagManager.storeFresh(dtos, for: cacheResource, eTag: eTag, verified: signatureVerified)

            // Build public model
            let configs = buildPublicModel(from: dtos)

            // Update in-memory cache
            cachedConfigs = configs
            cachedAt = dateProvider()

            Log.sdk.info("Remote configs loaded: \(configs.items.count) item(s)")
            return configs

        case .notModified(let eTag, let requestId):
            lastRequestId = requestId

            // If we have in-memory cache, just update its timestamp
            if let existing = cachedConfigs {
                _ = await etagManager.handleNotModified(
                    [AppActorRemoteConfigItemDTO].self, for: cacheResource, rotatedETag: eTag
                )
                cachedAt = dateProvider()
                Log.sdk.debug("Remote configs not modified (304), using in-memory cache")
                return existing
            }

            // No in-memory cache — try disk cache via ETagManager
            if let dtos = await etagManager.handleNotModified(
                [AppActorRemoteConfigItemDTO].self, for: cacheResource, rotatedETag: eTag
            ) {
                let configs = buildPublicModel(from: dtos)
                cachedConfigs = configs
                cachedAt = dateProvider()
                Log.sdk.debug("Remote configs not modified (304), loaded from disk cache")
                return configs
            }

            // 304 but no cache available — retry without eTag (force 200)
            Log.sdk.debug("Cache miss on 304, refreshing remote configs")
            let retry = try await client.getRemoteConfigs(
                appUserId: appUserId, appVersion: appVersion, country: country, eTag: nil
            )
            guard case .fresh(let dtos, let retryETag, let retryReqId, let retryVerified) = retry else {
                throw AppActorError.serverError(
                    httpStatus: 304,
                    code: "CACHE_INCONSISTENCY",
                    message: "Server returned 304 but local remote config cache is unavailable",
                    details: nil,
                    requestId: requestId
                )
            }
            lastRequestId = retryReqId
            await etagManager.storeFresh(dtos, for: cacheResource, eTag: retryETag, verified: retryVerified)
            let configs = buildPublicModel(from: dtos)
            cachedConfigs = configs
            cachedAt = dateProvider()
            Log.sdk.debug("Remote configs refreshed: \(configs.items.count) item(s)")
            return configs
        }
    }

    // MARK: - Model Building

    private func buildPublicModel(from dtos: [AppActorRemoteConfigItemDTO]) -> AppActorRemoteConfigs {
        let items = dtos.map { dto in
            AppActorRemoteConfigItem(
                key: dto.key,
                value: dto.value,
                valueType: AppActorConfigValueType(rawValue: dto.valueType) ?? .string
            )
        }
        return AppActorRemoteConfigs(items: items)
    }

    // MARK: - Cold Start (Disk Cache)

    /// Attempts to load remote configs from disk cache.
    /// Returns `nil` if no cache exists. Does not throw.
    func loadFromDiskCache(appUserId: String?) async -> AppActorRemoteConfigs? {
        let normalized = normalizedUserId(appUserId)
        lastCacheUserId = normalized
        guard let entry = await etagManager.cached(
            [AppActorRemoteConfigItemDTO].self,
            for: resource(for: normalized)
        ) else {
            return nil
        }

        let configs = buildPublicModel(from: entry.value)
        cachedConfigs = configs
        cachedAt = entry.cachedAt
        Log.sdk.debug("Loaded remote configs from disk cache (cached at \(entry.cachedAt))")
        return configs
    }

    private func normalizedUserId(_ appUserId: String?) -> String? {
        guard let appUserId, !appUserId.isEmpty else { return nil }
        return appUserId
    }

    private func resource(for appUserId: String?) -> AppActorCacheResource {
        .remoteConfigs(appUserId: appUserId)
    }
}
