import Foundation
@testable import AppActor

/// Thread-safe in-memory implementation of `AppActorPaymentStorage` for testing.
/// Replaces the identical `InMemoryPaymentStorage`, `InMemoryASAStorage`, and `LiveTestStorage`
/// that were duplicated across PaymentIdentityTests, ASAManagerTests, and PaymentLiveIdentityTests.
final class InMemoryPaymentStorage: AppActorPaymentStorage, @unchecked Sendable {
    private var store: [String: String] = [:]
    private let lock = NSLock()

    func string(forKey key: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return store[key]
    }

    func set(_ value: String?, forKey key: String) {
        lock.lock()
        defer { lock.unlock() }
        if let value {
            store[key] = value
        } else {
            store.removeValue(forKey: key)
        }
    }

    func remove(forKey key: String) {
        lock.lock()
        defer { lock.unlock() }
        store.removeValue(forKey: key)
    }
}
