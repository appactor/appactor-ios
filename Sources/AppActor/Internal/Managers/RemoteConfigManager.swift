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

    private struct CacheContext: Hashable, Sendable {
        let appUserId: String?
        let appVersion: String?
        let country: String?
    }

    private var cachedConfigs: [CacheContext: AppActorRemoteConfigs] = [:]
    private var cachedAt: [CacheContext: Date] = [:]
    private var lastRequestId: String?
    private var inFlightTasks: [CacheContext: Task<AppActorRemoteConfigs, Error>] = [:]
    private var inFlightGenerations: [CacheContext: UInt64] = [:]
    private var nextInFlightGeneration: UInt64 = 0
    private var lastCacheContext: CacheContext?

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
        let context = normalizedContext(appUserId: appUserId, appVersion: appVersion, country: country)
        if let cached = cachedConfigs[context], let at = cachedAt[context] {
            let age = dateProvider().timeIntervalSince(at)
            if age < Self.cacheTTL {
                return cached
            }
        }
        lastCacheContext = context

        return try await fetchCoalesced(context: context)
    }

    /// Returns the current in-memory cached configs, or `nil`.
    var cached: AppActorRemoteConfigs? {
        guard let lastCacheContext else { return nil }
        return cachedConfigs[lastCacheContext]
    }

    /// The last `request_id` from a remote config response.
    var requestId: String? { lastRequestId }

    /// Clears both in-memory and disk caches.
    /// Cancels any in-flight fetch to prevent actor-reentrancy stale writes.
    func clearCache(appUserId: String?) async {
        let normalized = normalizedUserId(appUserId)
        let taskContexts = inFlightTasks.keys.filter { $0.appUserId == normalized }
        for context in taskContexts {
            inFlightTasks[context]?.cancel()
            inFlightTasks.removeValue(forKey: context)
            inFlightGenerations.removeValue(forKey: context)
        }
        cachedConfigs = cachedConfigs.filter { $0.key.appUserId != normalized }
        cachedAt = cachedAt.filter { $0.key.appUserId != normalized }
        lastRequestId = nil
        if lastCacheContext?.appUserId == normalized {
            lastCacheContext = nil
        }
        await etagManager.clearRemoteConfigs(appUserId: normalized)
    }

    func clearCache() async {
        await clearCache(appUserId: lastCacheContext?.appUserId)
    }

    // MARK: - Single-Flight Coalescing

    private func fetchCoalesced(context: CacheContext) async throws -> AppActorRemoteConfigs {
        if let existing = inFlightTasks[context] {
            return try await existing.value
        }

        nextInFlightGeneration &+= 1
        let generation = nextInFlightGeneration
        let task = Task<AppActorRemoteConfigs, Error> { [weak self] in
            guard let self else { throw AppActorError.notConfigured }
            do {
                return try await self.executePipeline(context: context, generation: generation)
            } catch let error as AppActorError where error.kind == .network || (error.kind == .server && (error.httpStatus ?? 0) >= 500) {
                // Network / 5xx fallback: return disk-cached configs if available
                try await self.ensureFetchStillCurrent(context: context, generation: generation)
                if let cached = try await self.loadFromDiskCache(context: context, generation: generation) {
                    Log.sdk.debug("Network/5xx error — returning disk-cached remote configs")
                    return cached
                }
                throw error
            }
        }

        inFlightTasks[context] = task
        inFlightGenerations[context] = generation

        do {
            let result = try await task.value
            if inFlightGenerations[context] == generation {
                inFlightTasks.removeValue(forKey: context)
                inFlightGenerations.removeValue(forKey: context)
            }
            return result
        } catch {
            if inFlightGenerations[context] == generation {
                inFlightTasks.removeValue(forKey: context)
                inFlightGenerations.removeValue(forKey: context)
            }
            throw error
        }
    }

    // MARK: - Pipeline

    private func executePipeline(context: CacheContext, generation: UInt64) async throws -> AppActorRemoteConfigs {
        let cacheResource = resource(for: context)

        // 1. Load cached eTag for conditional request
        let lastETag = await etagManager.eTag(for: cacheResource)

        // 2. Fetch remote configs from API (conditional)
        let result = try await client.getRemoteConfigs(
            appUserId: context.appUserId,
            appVersion: context.appVersion,
            country: context.country,
            eTag: lastETag
        )
        try ensureFetchStillCurrent(context: context, generation: generation)

        switch result {
        case .fresh(let dtos, let eTag, let requestId, let signatureVerified):
            lastRequestId = requestId

            let configs = buildPublicModel(from: dtos)

            // Save DTOs + eTag to centralized cache. If invalidation wins while
            // persistence is in progress, remove the just-written context entry.
            try await storeFreshIfCurrent(
                dtos,
                for: cacheResource,
                eTag: eTag,
                verified: signatureVerified,
                context: context,
                generation: generation
            )

            // Update in-memory cache
            cachedConfigs[context] = configs
            cachedAt[context] = dateProvider()
            lastCacheContext = context

            Log.sdk.info("Remote configs loaded: \(configs.items.count) item(s)")
            return configs

        case .notModified(let eTag, let requestId):
            lastRequestId = requestId

            // If we have in-memory cache, just update its timestamp
            if let existing = cachedConfigs[context] {
                _ = try await handleNotModifiedIfCurrent(
                    [AppActorRemoteConfigItemDTO].self,
                    for: cacheResource,
                    rotatedETag: eTag,
                    context: context,
                    generation: generation
                )
                cachedAt[context] = dateProvider()
                lastCacheContext = context
                Log.sdk.debug("Remote configs not modified (304), using in-memory cache")
                return existing
            }

            // No in-memory cache — try disk cache via ETagManager
            if let result = try await handleNotModifiedIfCurrent(
                [AppActorRemoteConfigItemDTO].self,
                for: cacheResource,
                rotatedETag: eTag,
                context: context,
                generation: generation
            ) {
                let configs = buildPublicModel(from: result.value)
                cachedConfigs[context] = configs
                cachedAt[context] = dateProvider()
                lastCacheContext = context
                Log.sdk.debug("Remote configs not modified (304), loaded from disk cache")
                return configs
            }

            // 304 but no cache available — retry without eTag (force 200)
            Log.sdk.debug("Cache miss on 304, refreshing remote configs")
            let retry = try await client.getRemoteConfigs(
                appUserId: context.appUserId, appVersion: context.appVersion, country: context.country, eTag: nil
            )
            try ensureFetchStillCurrent(context: context, generation: generation)
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
            let configs = buildPublicModel(from: dtos)
            try await storeFreshIfCurrent(
                dtos,
                for: cacheResource,
                eTag: retryETag,
                verified: retryVerified,
                context: context,
                generation: generation
            )
            cachedConfigs[context] = configs
            cachedAt[context] = dateProvider()
            lastCacheContext = context
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
    private func loadFromDiskCache(context: CacheContext, generation: UInt64) async throws -> AppActorRemoteConfigs? {
        try ensureFetchStillCurrent(context: context, generation: generation)
        lastCacheContext = context
        guard let entry = await etagManager.cached(
            [AppActorRemoteConfigItemDTO].self,
            for: resource(for: context)
        ) else {
            return nil
        }
        try ensureFetchStillCurrent(context: context, generation: generation)

        let configs = buildPublicModel(from: entry.value)
        cachedConfigs[context] = configs
        cachedAt[context] = entry.cachedAt
        Log.sdk.debug("Loaded remote configs from disk cache (cached at \(entry.cachedAt))")
        return configs
    }

    private func normalizedContext(appUserId: String?, appVersion: String?, country: String?) -> CacheContext {
        CacheContext(
            appUserId: normalizedUserId(appUserId),
            appVersion: normalizedOptional(appVersion),
            country: normalizedOptional(country)?.uppercased()
        )
    }

    private func normalizedUserId(_ appUserId: String?) -> String? {
        normalizedOptional(appUserId)
    }

    private func normalizedOptional(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }

    private func resource(for context: CacheContext) -> AppActorCacheResource {
        .remoteConfigsContext(appUserId: context.appUserId, appVersion: context.appVersion, country: context.country)
    }

    private func storeFreshIfCurrent<T: Encodable>(
        _ value: T,
        for resource: AppActorCacheResource,
        eTag: String?,
        verified: Bool,
        context: CacheContext,
        generation: UInt64
    ) async throws {
        try ensureFetchStillCurrent(context: context, generation: generation)
        await etagManager.storeFresh(value, for: resource, eTag: eTag, verified: verified)
        do {
            try ensureFetchStillCurrent(context: context, generation: generation)
        } catch {
            await etagManager.clear(resource)
            throw error
        }
    }

    private func handleNotModifiedIfCurrent<T: Decodable>(
        _ type: T.Type,
        for resource: AppActorCacheResource,
        rotatedETag: String?,
        context: CacheContext,
        generation: UInt64
    ) async throws -> (value: T, verification: AppActorVerificationResult)? {
        try ensureFetchStillCurrent(context: context, generation: generation)
        let result = await etagManager.handleNotModified(type, for: resource, rotatedETag: rotatedETag)
        do {
            try ensureFetchStillCurrent(context: context, generation: generation)
        } catch {
            await etagManager.clear(resource)
            throw error
        }
        return result
    }

    private func ensureFetchStillCurrent(context: CacheContext, generation: UInt64) throws {
        try Task.checkCancellation()
        guard inFlightGenerations[context] == generation else {
            throw CancellationError()
        }
    }
}
