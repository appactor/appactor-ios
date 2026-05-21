import Foundation
import StoreKit

// MARK: - Protocol

/// Abstraction over StoreKit `Product.products(for:)` for testability.
protocol AppActorStoreKitProductFetcherProtocol: Sendable {
    func fetchProducts(for ids: Set<String>) async throws -> [String: Product]
}

// MARK: - Default Implementation

/// Caching wrapper around StoreKit 2 `Product.products(for:)`.
///
/// Keeps an in-memory cache of fetched products for the lifetime of the process.
/// Only fetches products that aren't already cached, avoiding redundant Apple API
/// calls on foreground refresh and manual `offerings()` calls.
///
/// Cache is automatically invalidated on process termination (cold start).
actor AppActorDefaultStoreKitProductFetcher: AppActorStoreKitProductFetcherProtocol {

    /// Session-level product cache keyed by product identifier.
    private var cache: [String: Product] = [:]

    func fetchProducts(for ids: Set<String>) async throws -> [String: Product] {
        guard !ids.isEmpty else { return [:] }

        let missing = ids.subtracting(cache.keys)

        if !missing.isEmpty {
            let maxAttempts = 3
            let backoffDelays: [TimeInterval] = [0, 1.0, 2.0]
            var lastError: Error?
            var fetchedProducts: [Product] = []

            for attempt in 0..<maxAttempts {
                do {
                    if attempt > 0 {
                        let delay = backoffDelays[min(attempt, backoffDelays.count - 1)]
                        if delay > 0 {
                            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                        }
                        Log.storeKit.debug("StoreKit product fetch retry \(attempt + 1)/\(maxAttempts)")
                    }
                    fetchedProducts = try await Product.products(for: missing)
                    lastError = nil
                    break
                } catch {
                    lastError = error
                    if error is CancellationError { throw error }
                    Log.storeKit.warn("StoreKit product fetch failed (attempt \(attempt + 1)/\(maxAttempts)): \(error.localizedDescription)")
                }
            }

            if let lastError { throw lastError }

            for product in fetchedProducts {
                cache[product.id] = product
            }

            let missingAfterFetch = missing.subtracting(fetchedProducts.map(\.id))
            if !missingAfterFetch.isEmpty {
                Log.storeKit.warn("StoreKit products not found: \(missingAfterFetch.sorted().joined(separator: ", "))")
            }
        }

        return cache.filter { ids.contains($0.key) }
    }
}
