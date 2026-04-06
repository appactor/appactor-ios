import Foundation
import StoreKit

/// Holds native `PurchaseIntent` objects keyed by UUID so Flutter can
/// reference them by ID and trigger a purchase later.
///
/// Intents expire after ``ttl`` seconds and the store enforces a maximum
/// of ``maxCount`` entries to prevent unbounded memory growth.
@available(iOS 16.4, macOS 14.4, tvOS 16.4, watchOS 9.4, *)
@MainActor
final class PurchaseIntentStore {

    static let shared = PurchaseIntentStore()
    private init() {}

    private static let ttl: TimeInterval = 5 * 60   // 5 minutes
    private static let maxCount: Int = 10

    private struct Entry {
        let intent: PurchaseIntent
        let storedAt: Date
    }

    private var entries: [String: Entry] = [:]

    /// Stores an intent and returns its unique ID.
    func store(_ intent: PurchaseIntent) -> String {
        cleanupExpired()

        // Evict oldest entry if at capacity
        if entries.count >= Self.maxCount,
           let oldest = entries.min(by: { $0.value.storedAt < $1.value.storedAt }) {
            entries.removeValue(forKey: oldest.key)
        }

        let id = UUID().uuidString
        entries[id] = Entry(intent: intent, storedAt: Date())
        return id
    }

    /// Removes and returns the intent for the given ID (consume-once).
    /// Returns `nil` if the intent has expired or does not exist.
    func remove(_ id: String) -> PurchaseIntent? {
        guard let entry = entries.removeValue(forKey: id) else { return nil }
        guard Date().timeIntervalSince(entry.storedAt) <= Self.ttl else { return nil }
        return entry.intent
    }

    /// Removes all pending intents.
    func removeAll() {
        entries.removeAll()
    }

    // MARK: - Private

    private func cleanupExpired() {
        let cutoff = Date().addingTimeInterval(-Self.ttl)
        entries = entries.filter { $0.value.storedAt >= cutoff }
    }
}
