import Foundation

/// Actor responsible for fetching and caching customer info.
///
/// Features:
/// - **Conditional requests**: sends `If-None-Match` ETag to avoid redundant data transfer.
/// - **In-flight deduplication**: concurrent callers share a single network request.
/// - **Offline entitlement derivation**: StoreKit 2 + offerings mapping → entitlement keys.
actor AppActorCustomerManager {

    /// TTL used for foreground staleness checks (matches OfferingsManager pattern).
    static let foregroundTTL: TimeInterval = 5 * 60

    private let client: any AppActorPaymentClientProtocol
    private let etagManager: AppActorETagManager
    private let entitlementChecker: any AppActorStoreKitEntitlementCheckerProtocol
    private let cacheTTL: TimeInterval

    /// The app user ID this manager is currently caching for.
    private var currentAppUserId: String?

    /// In-flight dedup: only one fetch at a time, keyed by userId to prevent cross-user coalescing.
    private var inflight: (userId: String, task: Task<AppActorCustomerInfo, Error>)?
    /// Generation counter for safe inflight bookkeeping (avoids `===` on Task).
    private var inflightGeneration: UInt64 = 0

    /// Last `request_id` from the server, for debugging.
    private(set) var lastRequestId: String?

    init(
        client: any AppActorPaymentClientProtocol,
        etagManager: AppActorETagManager,
        entitlementChecker: any AppActorStoreKitEntitlementCheckerProtocol = AppActorStoreKitEntitlementChecker(),
        cacheTTL: TimeInterval = 24 * 60 * 60
    ) {
        self.client = client
        self.etagManager = etagManager
        self.entitlementChecker = entitlementChecker
        self.cacheTTL = cacheTTL
    }

    /// The currently cached customer info, if any.
    func cachedInfo() async -> AppActorCustomerInfo? {
        guard let userId = currentAppUserId else { return nil }
        return await etagManager.cached(AppActorCustomerInfo.self, for: .customer(appUserId: userId))?.value
    }

    /// Whether the customer cache is fresh enough to skip a network fetch on foreground.
    func isCustomerCacheFresh(appUserId: String, ttl: TimeInterval = foregroundTTL) async -> Bool {
        await etagManager.isFresh(for: .customer(appUserId: appUserId), ttl: ttl)
    }

    /// Seeds the customer cache from an external source (e.g. identify response).
    ///
    /// This allows the identify flow to populate the customer cache so that
    /// a subsequent `getCustomerInfo()` can benefit from ETag/304 responses.
    func seedCache(info: AppActorCustomerInfo, eTag: String?, appUserId: String, verified: Bool = false) async {
        currentAppUserId = appUserId
        await etagManager.storeFresh(info, for: .customer(appUserId: appUserId), eTag: eTag, verified: verified)
    }

    /// Resets the cache freshness timestamp so the next fetch goes to the server.
    /// Preserves cached data and ETag for conditional requests (304 optimization).
    /// Cancels any in-flight fetch to prevent stale writes after the reset.
    func clearCache(appUserId: String) async {
        inflight?.task.cancel()
        inflight = nil
        await etagManager.resetFreshness(for: .customer(appUserId: appUserId))
    }

    func clearCache() async {
        guard let userId = currentAppUserId else { return }
        await clearCache(appUserId: userId)
    }

    // MARK: - Public API

    /// Fetches customer info, using conditional requests and in-flight dedup.
    ///
    /// Always makes a network request (with `If-None-Match` ETag for 304 optimization).
    /// Concurrent callers for the same user are coalesced into a single request.
    ///
    /// - Parameters:
    ///   - appUserId: The user ID to fetch info for.
    ///   - forceRefresh: If `true`, skips the conditional ETag (always fetches fresh 200).
    /// - Returns: The latest `AppActorCustomerInfo`.
    func getCustomerInfo(appUserId: String, forceRefresh: Bool = false) async throws -> AppActorCustomerInfo {
        currentAppUserId = appUserId
        let resource = AppActorCacheResource.customer(appUserId: appUserId)

        // Coalesce only if same userId and not a force refresh.
        if !forceRefresh, let inflight, inflight.userId == appUserId {
            return try await inflight.task.value
        }

        let client = self.client
        let etagManager = self.etagManager

        let task = Task<AppActorCustomerInfo, Error> {
            // Send conditional eTag if we have cached data (even expired).
            // forceRefresh always skips the eTag to guarantee a fresh 200.
            let lastETag = await etagManager.eTag(for: resource, forceRefresh: forceRefresh)

            let result = try await client.getCustomer(appUserId: appUserId, eTag: lastETag)

            switch result {
            case .fresh(let info, let eTag, let requestId, let signatureVerified):
                self.lastRequestId = requestId
                await etagManager.storeFresh(info, for: resource, eTag: eTag, verified: signatureVerified)
                return info

            case .notModified(let eTag, let requestId):
                self.lastRequestId = requestId
                if let cached = await etagManager.handleNotModified(
                    AppActorCustomerInfo.self, for: resource, rotatedETag: eTag
                ) {
                    return cached
                }
                // 304 but cache is missing/corrupt — force a fresh fetch (no eTag)
                let retry = try await client.getCustomer(appUserId: appUserId, eTag: nil)
                guard case .fresh(let info, let retryETag, _, let retryVerified) = retry else {
                    throw AppActorError.serverError(
                        httpStatus: 304,
                        code: "CACHE_INCONSISTENCY",
                        message: "Server returned 304 but local cache is unavailable",
                        details: nil,
                        requestId: nil
                    )
                }
                await etagManager.storeFresh(info, for: resource, eTag: retryETag, verified: retryVerified)
                return info
            }
        }

        inflightGeneration &+= 1
        let generation = inflightGeneration
        inflight = (userId: appUserId, task: task)

        do {
            let info = try await task.value
            // Only clear if still our task (forceRefresh may have replaced it)
            if inflightGeneration == generation { inflight = nil }
            return info
        } catch {
            if inflightGeneration == generation { inflight = nil }
            throw error
        }
    }

    /// Derives active entitlement keys offline from StoreKit 2 transactions and
    /// the cached offerings `productEntitlements` mapping.
    ///
    /// Fallback order:
    /// 1. SK2 `Transaction.currentEntitlements` → product IDs + offerings mapping → entitlement keys.
    /// 2. Cached `CustomerInfo` within TTL → `activeEntitlementKeys`.
    /// 3. Empty set (no data available).
    ///
    /// - Important: Offline entitlements are derived from StoreKit 2 local transaction state
    ///   and the cached offerings mapping. They may disagree with the server-authoritative state
    ///   (e.g., server-side revocations, promotional entitlements, grace periods). Always prefer
    ///   ``getCustomerInfo(appUserId:forceRefresh:)`` for authoritative entitlement checks.
    ///
    /// - Returns: Set of entitlement keys that are active offline.
    func activeEntitlementKeysOffline() async -> Set<String> {
        let appUserId = currentAppUserId
        return await activeEntitlementKeysOffline(appUserId: appUserId)
    }

    /// Derives active entitlement keys offline for a specific identity.
    ///
    /// The StoreKit derivation remains global, but the cached-customer fallback is
    /// explicitly bound to the provided `appUserId` so callers can avoid cross-user
    /// offline snapshots during login/logout races.
    func activeEntitlementKeysOffline(appUserId: String?) async -> Set<String> {
        // 1. SK2 product IDs + offerings mapping → derive entitlement keys
        let derivedKeys = await derivedEntitlementKeysFromStoreKit()
        if !derivedKeys.isEmpty {
            return derivedKeys
        }

        // 2. Cached customer info within TTL
        if let appUserId, let cachedKeys = await cachedActiveEntitlementKeys(appUserId: appUserId) {
            return cachedKeys
        }

        // 3. No data available
        return []
    }

    private func derivedEntitlementKeysFromStoreKit() async -> Set<String> {
        let activeIds = await entitlementChecker.activeProductIds()
        guard !activeIds.isEmpty,
              let entry = await etagManager.cached(AppActorOfferingsResponseDTO.self, for: .offerings) else {
            return []
        }

        let mapping = entry.value.productEntitlements ?? [:]
        return Set(activeIds.flatMap { productId in
            mapping["ios:\(productId)"] ?? mapping[productId] ?? []
        })
    }

    private func cachedActiveEntitlementKeys(appUserId: String) async -> Set<String>? {
        let resource = AppActorCacheResource.customer(appUserId: appUserId)
        guard await etagManager.isFresh(for: resource, ttl: cacheTTL),
              let cached = await etagManager.cached(AppActorCustomerInfo.self, for: resource) else {
            return nil
        }
        return cached.value.activeEntitlementKeys
    }
}
