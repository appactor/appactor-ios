import Foundation

/// Core actor that manages experiment assignment pipeline:
/// network fetch → per-key caching → typed access.
///
/// Features:
/// - **Single-flight per key**: concurrent calls for the same `experimentKey` coalesce into one network request.
/// - **TTL**: in-memory per-key cache with 5-minute TTL.
/// - **Disk cache**: persists all assignments via centralized ETagManager for cold-start recovery.
/// - **No ETag**: POST endpoint — always returns fresh data (assignments are idempotent server-side).
actor AppActorExperimentManager {

    // MARK: - Dependencies

    private let client: AppActorPaymentClientProtocol
    private let etagManager: AppActorETagManager
    private let dateProvider: @Sendable () -> Date

    // MARK: - In-Memory State

    private struct CacheContext: Hashable, Sendable {
        let appUserId: String
        let appVersion: String?
        let country: String?
    }

    private struct AssignmentCacheKey: Hashable, Sendable {
        let experimentKey: String
        let context: CacheContext
    }

    /// Per-context, per-key cached assignments. Value is `nil` when user is not in the experiment.
    private var cachedAssignmentsByContext: [CacheContext: [String: CachedAssignment]] = [:]
    /// Per-context, per-key in-flight tasks for single-flight coalescing.
    private var inFlightTasks: [AssignmentCacheKey: Task<AppActorExperimentAssignment?, Error>] = [:]
    private var inFlightGenerations: [AssignmentCacheKey: UInt64] = [:]
    private var nextInFlightGeneration: UInt64 = 0
    /// The last `request_id` from an experiment assignment response.
    private(set) var lastRequestId: String?
    private var lastCacheContext: CacheContext?

    struct CachedAssignment: Codable {
        let assignment: CodableAssignment?
        let cachedAt: Date
    }

    /// Codable wrapper for disk persistence (public model is not Codable).
    struct CodableAssignment: Codable {
        let experimentId: String
        let experimentKey: String
        let variantId: String
        let variantKey: String
        let payload: AppActorConfigValue
        let valueType: String
        let assignedAt: String

        func toPublic() -> AppActorExperimentAssignment {
            AppActorExperimentAssignment(
                experimentId: experimentId,
                experimentKey: experimentKey,
                variantId: variantId,
                variantKey: variantKey,
                payload: payload,
                valueType: AppActorConfigValueType(rawValue: valueType) ?? .string,
                assignedAt: assignedAt
            )
        }

        static func from(_ assignment: AppActorExperimentAssignment) -> CodableAssignment {
            CodableAssignment(
                experimentId: assignment.experimentId,
                experimentKey: assignment.experimentKey,
                variantId: assignment.variantId,
                variantKey: assignment.variantKey,
                payload: assignment.payload,
                valueType: assignment.valueType.rawValue,
                assignedAt: assignment.assignedAt
            )
        }
    }

    // MARK: - TTL

    static let cacheTTL: TimeInterval = 5 * 60 // 5 minutes

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

    /// Fetches experiment assignment for the given key, using cache when fresh.
    ///
    /// - Returns `nil` if the user is not in the experiment (not targeted, not running, etc.).
    /// - If memory cache is fresh → returns immediately.
    /// - If no cache or stale → awaits network fetch.
    /// - On network/5xx error → falls back to disk cache.
    func getAssignment(
        experimentKey: String,
        appUserId: String,
        appVersion: String?,
        country: String?
    ) async throws -> AppActorExperimentAssignment? {
        let context = normalizedContext(appUserId: appUserId, appVersion: appVersion, country: country)
        // Check in-memory TTL cache for the full targeting context.
        if let cached = cachedAssignmentsByContext[context]?[experimentKey] {
            let age = dateProvider().timeIntervalSince(cached.cachedAt)
            if age < Self.cacheTTL {
                return cached.assignment?.toPublic()
            }
        }
        lastCacheContext = context

        return try await fetchCoalesced(
            experimentKey: experimentKey,
            context: context
        )
    }

    /// Returns the cached assignment for the given key, or `nil` if not cached.
    /// Does not make a network call.
    func cached(experimentKey: String) -> AppActorExperimentAssignment? {
        guard let lastCacheContext else { return nil }
        return cachedAssignmentsByContext[lastCacheContext]?[experimentKey]?.assignment?.toPublic()
    }

    /// Clears all cached assignments (both in-memory and disk).
    func clearCache(appUserId: String?) async {
        lastRequestId = nil
        guard let appUserId = normalizedUserId(appUserId) else {
            for (_, task) in inFlightTasks {
                task.cancel()
            }
            inFlightTasks.removeAll()
            inFlightGenerations.removeAll()
            cachedAssignmentsByContext.removeAll()
            lastCacheContext = nil
            return
        }

        let taskKeys = inFlightTasks.keys.filter { $0.context.appUserId == appUserId }
        for key in taskKeys {
            inFlightTasks[key]?.cancel()
            inFlightTasks.removeValue(forKey: key)
            inFlightGenerations.removeValue(forKey: key)
        }
        cachedAssignmentsByContext = cachedAssignmentsByContext.filter { $0.key.appUserId != appUserId }
        if lastCacheContext?.appUserId == appUserId {
            lastCacheContext = nil
        }
        await etagManager.clearExperiments(appUserId: appUserId)
    }

    func clearCache() async {
        await clearCache(appUserId: lastCacheContext?.appUserId)
    }

    /// Clears the cached assignment for a specific experiment key.
    func clearCache(experimentKey: String) async {
        let taskKeys = inFlightTasks.keys.filter { $0.experimentKey == experimentKey }
        for key in taskKeys {
            inFlightTasks[key]?.cancel()
            inFlightTasks.removeValue(forKey: key)
            inFlightGenerations.removeValue(forKey: key)
        }

        let contexts = Array(cachedAssignmentsByContext.keys)
        for context in contexts {
            guard cachedAssignmentsByContext[context]?[experimentKey] != nil else { continue }
            cachedAssignmentsByContext[context]?.removeValue(forKey: experimentKey)
            await persistToDisk(context: context)
        }
    }

    // MARK: - Single-Flight Coalescing (Per-Key)

    private func fetchCoalesced(
        experimentKey: String,
        context: CacheContext
    ) async throws -> AppActorExperimentAssignment? {
        let cacheKey = AssignmentCacheKey(experimentKey: experimentKey, context: context)
        // Coalesce: if there's already an in-flight request for this key, await it
        if let existing = inFlightTasks[cacheKey] {
            return try await existing.value
        }

        nextInFlightGeneration &+= 1
        let generation = nextInFlightGeneration
        let task = Task<AppActorExperimentAssignment?, Error> { [weak self] in
            guard let self else { throw AppActorError.notConfigured }
            do {
                return try await self.executeFetch(
                    experimentKey: experimentKey,
                    context: context,
                    cacheKey: cacheKey,
                    generation: generation
                )
            } catch let error as AppActorError where error.isNetworkOrServerError {
                // Network / 5xx fallback: return disk-cached assignment if available.
                // Use hasCachedEntry to distinguish "cached nil" from "cache miss".
                try await self.ensureFetchStillCurrent(cacheKey: cacheKey, generation: generation)
                if let (found, assignment) = try await self.loadFromDiskCacheWithPresence(
                    experimentKey: experimentKey,
                    context: context,
                    cacheKey: cacheKey,
                    generation: generation
                ) {
                    Log.sdk.debug("Network/5xx error — returning disk-cached experiment result for '\(experimentKey)' (inExperiment: \(found))")
                    return assignment
                }
                throw error
            }
        }

        inFlightTasks[cacheKey] = task
        inFlightGenerations[cacheKey] = generation

        do {
            let result = try await task.value
            if inFlightGenerations[cacheKey] == generation {
                inFlightTasks.removeValue(forKey: cacheKey)
                inFlightGenerations.removeValue(forKey: cacheKey)
            }
            return result
        } catch {
            if inFlightGenerations[cacheKey] == generation {
                inFlightTasks.removeValue(forKey: cacheKey)
                inFlightGenerations.removeValue(forKey: cacheKey)
            }
            throw error
        }
    }

    // MARK: - Fetch

    private func executeFetch(
        experimentKey: String,
        context: CacheContext,
        cacheKey: AssignmentCacheKey,
        generation: UInt64
    ) async throws -> AppActorExperimentAssignment? {
        let result = try await client.postExperimentAssignment(
            experimentKey: experimentKey,
            appUserId: context.appUserId,
            appVersion: context.appVersion,
            country: context.country
        )
        try ensureFetchStillCurrent(cacheKey: cacheKey, generation: generation)

        guard case .success(let dto, let requestId, let signatureVerified) = result else {
            return nil
        }
        lastRequestId = requestId

        if dto.inExperiment,
           let experiment = dto.experiment,
           let variant = dto.variant,
           let assignedAt = dto.assignedAt {

            let assignment = AppActorExperimentAssignment(
                experimentId: experiment.id,
                experimentKey: experiment.key,
                variantId: variant.id,
                variantKey: variant.key,
                payload: variant.payload,
                valueType: AppActorConfigValueType(rawValue: variant.valueType) ?? .string,
                assignedAt: assignedAt
            )

            try await storeAssignment(
                CachedAssignment(assignment: CodableAssignment.from(assignment), cachedAt: dateProvider()),
                forKey: experimentKey,
                context: context,
                verified: signatureVerified,
                cacheKey: cacheKey,
                generation: generation
            )

            Log.sdk.info("Experiment '\(experimentKey)' → variant '\(variant.key)'")
            return assignment
        } else {
            // User not in experiment — cache the nil result to avoid re-fetching
            try await storeAssignment(
                CachedAssignment(assignment: nil, cachedAt: dateProvider()),
                forKey: experimentKey,
                context: context,
                cacheKey: cacheKey,
                generation: generation
            )

            let reason = dto.reason ?? "unknown"
            Log.sdk.info("Experiment '\(experimentKey)' → not in experiment (reason: \(reason))")
            return nil
        }
    }

    // MARK: - Disk Persistence

    /// Adds one assignment to the context's blob, in memory and on disk.
    ///
    /// The blob is written whole, so the context's map starts from the one on disk: a map never
    /// loaded from it would erase what earlier sessions saved. The key goes into the map as it is
    /// after every await, never into a copy taken before one, which would drop a key a
    /// concurrent fetch added meanwhile. It is published to memory before the write so that a
    /// concurrent write carries it too; a clear that wins during the write removes it from memory
    /// as well, and the file is removed.
    private func storeAssignment(
        _ entry: CachedAssignment,
        forKey experimentKey: String,
        context: CacheContext,
        verified: Bool = false,
        cacheKey: AssignmentCacheKey,
        generation: UInt64
    ) async throws {
        if cachedAssignmentsByContext[context] == nil,
           let persisted = await loadAllFromDisk(context: context) {
            try ensureFetchStillCurrent(cacheKey: cacheKey, generation: generation)
            cachedAssignmentsByContext[context] = persisted.merging(cachedAssignmentsByContext[context] ?? [:]) { _, inMemory in inMemory }
        }
        try ensureFetchStillCurrent(cacheKey: cacheKey, generation: generation)
        cachedAssignmentsByContext[context, default: [:]][experimentKey] = entry
        let resource = resource(for: context)
        await etagManager.storeFresh(cachedAssignmentsByContext[context] ?? [:], for: resource, eTag: nil, verified: verified)
        do {
            try ensureFetchStillCurrent(cacheKey: cacheKey, generation: generation)
        } catch {
            await etagManager.clear(resource)
            throw error
        }
        lastCacheContext = context
    }

    /// Persists all cached assignments to disk as a single JSON blob.
    private func persistToDisk(context: CacheContext, verified: Bool = false) async {
        let assignments = cachedAssignmentsByContext[context] ?? [:]
        guard !assignments.isEmpty else {
            await etagManager.clear(resource(for: context))
            return
        }
        await etagManager.storeFresh(assignments, for: resource(for: context), eTag: nil, verified: verified)
    }

    /// Loads a specific experiment assignment from disk cache, distinguishing
    /// "key not in cache" (returns nil) from "cached nil assignment" (returns (true, nil)).
    /// - Returns: `(keyFound: Bool, assignment: AppActorExperimentAssignment?)` or nil if cache miss.
    private func loadFromDiskCacheWithPresence(
        experimentKey: String,
        context: CacheContext,
        cacheKey: AssignmentCacheKey,
        generation: UInt64
    ) async throws -> (Bool, AppActorExperimentAssignment?)? {
        try ensureFetchStillCurrent(cacheKey: cacheKey, generation: generation)
        guard let entry = await etagManager.cached(
            [String: CachedAssignment].self,
            for: resource(for: context)
        ) else {
            return nil
        }
        try ensureFetchStillCurrent(cacheKey: cacheKey, generation: generation)
        guard let cached = entry.value[experimentKey] else { return nil }
        lastCacheContext = context
        // Key exists in cache — return (true, assignment-or-nil)
        return (true, cached.assignment?.toPublic())
    }

    /// Loads all cached assignments from disk.
    private func loadAllFromDisk(context: CacheContext) async -> [String: CachedAssignment]? {
        lastCacheContext = context
        guard let entry = await etagManager.cached(
            [String: CachedAssignment].self,
            for: resource(for: context)
        ) else {
            return nil
        }
        return entry.value
    }

    private func normalizedContext(appUserId: String, appVersion: String?, country: String?) -> CacheContext {
        CacheContext(
            appUserId: normalizedUserId(appUserId) ?? appUserId,
            appVersion: normalizedOptional(appVersion),
            country: normalizedOptional(country)?.uppercased()
        )
    }

    /// The ID as the SDK stores and posts it: not trimmed, or the context would name another user.
    private func normalizedUserId(_ appUserId: String?) -> String? {
        appUserId.flatMap { AppActorPaymentValidation.isBlank($0) ? nil : $0 }
    }

    private func normalizedOptional(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }

    private func resource(for context: CacheContext) -> AppActorCacheResource {
        .experimentsContext(appUserId: context.appUserId, appVersion: context.appVersion, country: context.country)
    }

    private func ensureFetchStillCurrent(cacheKey: AssignmentCacheKey, generation: UInt64) throws {
        try Task.checkCancellation()
        guard inFlightGenerations[cacheKey] == generation else {
            throw CancellationError()
        }
    }
}
