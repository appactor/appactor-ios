import XCTest
@testable import AppActor

/// Unit tests for the StoreKit product cache expiry policy (ios-7). The policy
/// is tested in isolation because StoreKit `Product` values cannot be
/// constructed in tests, so the caching actor itself stays integration-mocked.
final class ProductCachePolicyTests: XCTestCase {

    func testEntryIsFreshBeforeTTLElapses() {
        let fetchedAt = Date(timeIntervalSince1970: 1_000)
        let ttl: TimeInterval = 60 * 60
        XCTAssertFalse(
            AppActorProductCachePolicy.isStale(
                fetchedAt: fetchedAt,
                now: fetchedAt.addingTimeInterval(ttl - 1),
                ttl: ttl
            )
        )
    }

    func testEntryIsStaleAtAndAfterTTL() {
        let fetchedAt = Date(timeIntervalSince1970: 1_000)
        let ttl: TimeInterval = 60 * 60

        // Exactly at the TTL boundary counts as stale.
        XCTAssertTrue(
            AppActorProductCachePolicy.isStale(
                fetchedAt: fetchedAt,
                now: fetchedAt.addingTimeInterval(ttl),
                ttl: ttl
            )
        )
        // Well past the TTL is stale.
        XCTAssertTrue(
            AppActorProductCachePolicy.isStale(
                fetchedAt: fetchedAt,
                now: fetchedAt.addingTimeInterval(ttl + 600),
                ttl: ttl
            )
        )
    }

    func testDefaultTTLIsOneHour() {
        XCTAssertEqual(AppActorProductCachePolicy.defaultTTL, 60 * 60)
    }
}
