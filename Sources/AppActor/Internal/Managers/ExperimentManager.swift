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

    /// Per-key cached assignments. Value is `nil` when user is not in the experiment.
    private var cachedAssignments: [String: CachedAssignment] = [:]
    /// Per-key in-flight tasks for single-flight coalescing.
    private var inFlightTasks: [String: Task<AppActorExperimentAssignment?, Error>] = [:]
    /// The last `request_id` from an experiment assignment response.
    private(set) var lastRequestId: String?
    private var lastCacheUserId: String?

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
        lastCacheUserId = appUserId
        // Check in-memory TTL cache
        if let cached = cachedAssignments[experimentKey] {
            let age = dateProvider().timeIntervalSince(cached.cachedAt)
            if age < Self.cacheTTL {
                return cached.assignment?.toPublic()
            }
        }

        return try await fetchCoalesced(
            experimentKey: experimentKey,
            appUserId: appUserId,
            appVersion: appVersion,
            country: country
        )
    }

    /// Returns the cached assignment for the given key, or `nil` if not cached.
    /// Does not make a network call.
    func cached(experimentKey: String) -> AppActorExperimentAssignment? {
        cachedAssignments[experimentKey]?.assignment?.toPublic()
    }

    /// Clears all cached assignments (both in-memory and disk).
    func clearCache(appUserId: String?) async {
        for (_, task) in inFlightTasks {
            task.cancel()
        }
        inFlightTasks.removeAll()
        cachedAssignments.removeAll()
        lastRequestId = nil
        guard let appUserId else {
            lastCacheUserId = nil
            return
        }
        lastCacheUserId = appUserId
        await etagManager.clear(.experiments(appUserId: appUserId))
    }

    func clearCache() async {
        await clearCache(appUserId: lastCacheUserId)
    }

    /// Clears the cached assignment for a specific experiment key.
    func clearCache(experimentKey: String) async {
        inFlightTasks[experimentKey]?.cancel()
        inFlightTasks.removeValue(forKey: experimentKey)
        cachedAssignments.removeValue(forKey: experimentKey)
        // Persist remaining assignments to disk
        if let appUserId = lastCacheUserId {
            await persistToDisk(appUserId: appUserId)
        }
    }

    // MARK: - Single-Flight Coalescing (Per-Key)

    private func fetchCoalesced(
        experimentKey: String,
        appUserId: String,
        appVersion: String?,
        country: String?
    ) async throws -> AppActorExperimentAssignment? {
        // Coalesce: if there's already an in-flight request for this key, await it
        if let existing = inFlightTasks[experimentKey] {
            return try await existing.value
        }

        let task = Task<AppActorExperimentAssignment?, Error> { [weak self] in
            guard let self else { throw AppActorError.notConfigured }
            do {
                return try await self.executeFetch(
                    experimentKey: experimentKey,
                    appUserId: appUserId,
                    appVersion: appVersion,
                    country: country
                )
            } catch let error as AppActorError where error.kind == .network || (error.kind == .server && (error.httpStatus ?? 0) >= 500) {
                // Network / 5xx fallback: return disk-cached assignment if available.
                // Use hasCachedEntry to distinguish "cached nil" from "cache miss".
                if let (found, assignment) = await self.loadFromDiskCacheWithPresence(
                    experimentKey: experimentKey,
                    appUserId: appUserId
                ) {
                    Log.sdk.debug("Network/5xx error — returning disk-cached experiment result for '\(experimentKey)' (inExperiment: \(found))")
                    return assignment
                }
                throw error
            }
        }

        inFlightTasks[experimentKey] = task

        do {
            let result = try await task.value
            inFlightTasks.removeValue(forKey: experimentKey)
            return result
        } catch {
            inFlightTasks.removeValue(forKey: experimentKey)
            throw error
        }
    }

    // MARK: - Fetch

    private func executeFetch(
        experimentKey: String,
        appUserId: String,
        appVersion: String?,
        country: String?
    ) async throws -> AppActorExperimentAssignment? {
        let result = try await client.postExperimentAssignment(
            experimentKey: experimentKey,
            appUserId: appUserId,
            appVersion: appVersion,
            country: country
        )

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

            // Update in-memory cache
            cachedAssignments[experimentKey] = CachedAssignment(
                assignment: CodableAssignment.from(assignment),
                cachedAt: dateProvider()
            )

            // Persist to disk
            await persistToDisk(appUserId: appUserId, verified: signatureVerified)

            Log.sdk.info("Experiment '\(experimentKey)' → variant '\(variant.key)'")
            return assignment
        } else {
            // User not in experiment — cache the nil result to avoid re-fetching
            cachedAssignments[experimentKey] = CachedAssignment(
                assignment: nil,
                cachedAt: dateProvider()
            )
            await persistToDisk(appUserId: appUserId)

            let reason = dto.reason ?? "unknown"
            Log.sdk.info("Experiment '\(experimentKey)' → not in experiment (reason: \(reason))")
            return nil
        }
    }

    // MARK: - Disk Persistence

    /// Persists all cached assignments to disk as a single JSON blob.
    private func persistToDisk(appUserId: String, verified: Bool = false) async {
        lastCacheUserId = appUserId
        await etagManager.storeFresh(
            cachedAssignments,
            for: .experiments(appUserId: appUserId),
            eTag: nil,
            verified: verified
        )
    }

    /// Loads a specific experiment assignment from disk cache, distinguishing
    /// "key not in cache" (returns nil) from "cached nil assignment" (returns (true, nil)).
    /// - Returns: `(keyFound: Bool, assignment: AppActorExperimentAssignment?)` or nil if cache miss.
    private func loadFromDiskCacheWithPresence(
        experimentKey: String,
        appUserId: String
    ) async -> (Bool, AppActorExperimentAssignment?)? {
        guard let allCached = await loadAllFromDisk(appUserId: appUserId) else { return nil }
        guard let entry = allCached[experimentKey] else { return nil }
        // Key exists in cache — return (true, assignment-or-nil)
        return (true, entry.assignment?.toPublic())
    }

    /// Loads all cached assignments from disk.
    private func loadAllFromDisk(appUserId: String) async -> [String: CachedAssignment]? {
        lastCacheUserId = appUserId
        guard let entry = await etagManager.cached(
            [String: CachedAssignment].self,
            for: .experiments(appUserId: appUserId)
        ) else {
            return nil
        }
        return entry.value
    }

    /// Attempts to load all experiment assignments from disk cache on cold start.
    /// Populates in-memory cache. Returns silently if no disk cache exists.
    func loadFromDiskCache(appUserId: String) async {
        guard let allCached = await loadAllFromDisk(appUserId: appUserId) else { return }
        // Only populate entries that aren't already in memory
        for (key, cached) in allCached where cachedAssignments[key] == nil {
            cachedAssignments[key] = cached
        }
        Log.sdk.debug("Loaded \(allCached.count) experiment assignment(s) from disk cache")
    }
}
