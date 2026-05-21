import Foundation
import StoreKit
@testable import AppActor

/// Mock StoreKit product fetcher for testing.
/// Moved from OfferingsManagerTests to shared location.
final class MockStoreKitProductFetcher: AppActorStoreKitProductFetcherProtocol, @unchecked Sendable {
    var fetchHandler: ((Set<String>) async throws -> [String: Product])?
    var fetchCalls: [Set<String>] = []

    func fetchProducts(for ids: Set<String>) async throws -> [String: Product] {
        fetchCalls.append(ids)
        if let handler = fetchHandler {
            return try await handler(ids)
        }
        // Default: return empty (no real StoreKit products in unit tests)
        return [:]
    }
}

/// Mock StoreKit entitlement checker for testing.
/// Moved from CustomerManagerTests to shared location.
final class MockStoreKitEntitlementChecker: AppActorStoreKitEntitlementCheckerProtocol, @unchecked Sendable {
    var result: Bool = false
    var productIds: Set<String> = []
    var activeProductIdsHandler: (() async -> Set<String>)?

    func hasActiveEntitlement() async -> Bool {
        result
    }

    func activeProductIds() async -> Set<String> {
        if let activeProductIdsHandler {
            return await activeProductIdsHandler()
        }
        return productIds
    }
}
