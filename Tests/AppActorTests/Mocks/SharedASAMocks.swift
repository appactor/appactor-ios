import Foundation
@testable import AppActor

/// Mock ASA token provider for testing.
/// Moved from ASAManagerTests to shared location.
final class MockASATokenProvider: AppActorASATokenProviderProtocol, @unchecked Sendable {
    var tokenResult: AppActorASATokenResult = .token("mock-attribution-token-1234567890")
    var appleAttributionResult: AppActorASAAppleAttributionResult = .success(
        AppActorASAAppleAttributionResponse(json: ["attribution": true, "orgId": 12345, "campaignId": 67890])
    )

    func attributionToken() async -> AppActorASATokenResult {
        return tokenResult
    }

    func fetchAppleAttribution(token: String) async -> AppActorASAAppleAttributionResult {
        return appleAttributionResult
    }
}

/// In-memory implementation of `AppActorASAEventStoreProtocol` for testing.
/// Moved from ASAManagerTests to shared location.
final class InMemoryASAEventStore: AppActorASAEventStoreProtocol, @unchecked Sendable {
    private var events: [AppActorASAStoredEvent] = []
    private let lock = NSLock()

    func enqueue(_ event: AppActorASAStoredEvent) {
        lock.lock(); defer { lock.unlock() }
        events.append(event)
    }

    func pending() -> [AppActorASAStoredEvent] {
        lock.lock(); defer { lock.unlock() }
        return events
    }

    func remove(id: String) {
        lock.lock(); defer { lock.unlock() }
        events.removeAll { $0.id == id }
    }

    func update(_ event: AppActorASAStoredEvent) {
        lock.lock(); defer { lock.unlock() }
        if let idx = events.firstIndex(where: { $0.id == event.id }) {
            events[idx] = event
        }
    }

    func clear() {
        lock.lock(); defer { lock.unlock() }
        events.removeAll()
    }

    func count() -> Int {
        lock.lock(); defer { lock.unlock() }
        return events.count
    }
}
