import Foundation
import StoreKit

// MARK: - Protocol

/// Abstraction over StoreKit `Product.products(for:)` for testability.
protocol AppActorStoreKitProductFetcherProtocol: Sendable {
    func fetchProducts(for ids: Set<String>) async throws -> [String: Product]
}

// MARK: - Cache Expiry Policy

/// Decides whether a cached product is stale. Extracted from the fetcher so the
/// expiry policy can be unit-tested without fabricating StoreKit `Product`
/// values, which cannot be constructed in tests.
enum AppActorProductCachePolicy {
    /// Default time-to-live for a cached `Product`. Price, eligibility and
    /// storefront-derived fields can change while the process stays alive, so
    /// the cache must expire rather than live for the whole process lifetime.
    static let defaultTTL: TimeInterval = 60 * 60

    static func isStale(fetchedAt: Date, now: Date, ttl: TimeInterval) -> Bool {
        now.timeIntervalSince(fetchedAt) >= ttl
    }
}

// MARK: - Default Implementation

/// Caching wrapper around StoreKit 2 `Product.products(for:)`.
///
/// Products that have never been fetched are loaded synchronously (with retry),
/// exactly as before. Products whose cache entry has exceeded the TTL are served
/// immediately from cache and refreshed in the background, so a TTL refresh never
/// adds latency to the caller — important because this runs on the purchase hot
/// path. A background refresh that fails leaves the stale entry untouched so the
/// next call retries (ios-7).
actor AppActorDefaultStoreKitProductFetcher: AppActorStoreKitProductFetcherProtocol {

    private struct CacheEntry {
        let product: Product
        let fetchedAt: Date
    }

    /// Session-level product cache keyed by product identifier.
    private var cache: [String: CacheEntry] = [:]
    /// Identifiers with an in-flight background refresh, to avoid duplicate work.
    private var refreshing: Set<String> = []
    private let ttl: TimeInterval

    init(ttl: TimeInterval = AppActorProductCachePolicy.defaultTTL) {
        self.ttl = ttl
    }

    func fetchProducts(for ids: Set<String>) async throws -> [String: Product] {
        guard !ids.isEmpty else { return [:] }

        // Never-cached ids have nothing to serve: fetch them synchronously and
        // throw on failure, exactly as before the cache gained a TTL.
        let absent = ids.filter { cache[$0] == nil }
        if !absent.isEmpty {
            let fetched = try await fetchFromStoreKit(absent)
            store(fetched)

            let missingAfterFetch = absent.subtracting(fetched.map(\.id))
            if !missingAfterFetch.isEmpty {
                Log.storeKit.warn("StoreKit products not found: \(missingAfterFetch.sorted().joined(separator: ", "))")
            }
        }

        // Cached-but-stale ids are served immediately and refreshed off the hot
        // path; a TTL refresh must not block the caller.
        let now = Date()
        let stale = ids.filter { id in
            guard let entry = cache[id] else { return false }
            return AppActorProductCachePolicy.isStale(fetchedAt: entry.fetchedAt, now: now, ttl: ttl)
        }
        scheduleBackgroundRefresh(of: stale)

        return cache.filter { ids.contains($0.key) }.mapValues(\.product)
    }

    private func store(_ products: [Product]) {
        let fetchedAt = Date()
        for product in products {
            cache[product.id] = CacheEntry(product: product, fetchedAt: fetchedAt)
        }
    }

    private func scheduleBackgroundRefresh(of ids: Set<String>) {
        let pending = ids.subtracting(refreshing)
        guard !pending.isEmpty else { return }
        refreshing.formUnion(pending)
        Task { await self.performBackgroundRefresh(pending) }
    }

    private func performBackgroundRefresh(_ ids: Set<String>) async {
        defer { refreshing.subtract(ids) }
        // Best effort: on failure leave the stale entries untouched so the next
        // call retries, rather than suppressing refresh for another full TTL.
        if let fetched = try? await fetchFromStoreKit(ids) {
            store(fetched)
        }
    }

    private func fetchFromStoreKit(_ ids: Set<String>) async throws -> [Product] {
        let maxAttempts = 3
        let backoffDelays: [TimeInterval] = [0, 1.0, 2.0]
        var lastError: Error?

        for attempt in 0..<maxAttempts {
            do {
                if attempt > 0 {
                    let delay = backoffDelays[min(attempt, backoffDelays.count - 1)]
                    if delay > 0 {
                        try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    }
                    Log.storeKit.debug("StoreKit product fetch retry \(attempt + 1)/\(maxAttempts)")
                }
                return try await Product.products(for: ids)
            } catch {
                if error is CancellationError { throw error }
                lastError = error
                Log.storeKit.warn("StoreKit product fetch failed (attempt \(attempt + 1)/\(maxAttempts)): \(error.localizedDescription)")
            }
        }

        if let lastError { throw lastError }
        return []
    }
}
