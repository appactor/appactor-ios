import Foundation
@testable import AppActor

/// In-memory implementation of `AppActorPaymentQueueStoreProtocol` for testing.
/// Moved from PaymentProcessorTests to shared location.
final class InMemoryPaymentQueueStore: AppActorPaymentQueueStoreProtocol, @unchecked Sendable {
    private var items: [String: AppActorPaymentQueueItem] = [:]
    private var purgedDeadLetters: [AppActorPurgedDeadLetterSummary] = []

    func upsert(_ item: AppActorPaymentQueueItem) {
        if var existing = items[item.key] {
            existing.mergeFrom(item)
            items[item.key] = existing
        } else {
            items[item.key] = item
        }
    }

    func claimReady(limit: Int, now: Date) -> [AppActorPaymentQueueItem] {
        let staleThreshold = now.addingTimeInterval(-120)
        var claimed: [AppActorPaymentQueueItem] = []

        for (key, item) in items {
            guard claimed.count < limit else { break }

            let shouldClaim: Bool
            switch item.phase {
            case .needsPost:
                shouldClaim = item.nextRetryAt <= now
            case .posting:
                shouldClaim = item.claimedAt.map { $0 < staleThreshold } ?? true
            case .needsFinish:
                shouldClaim = false
            case .deadLettered:
                shouldClaim = false
            }

            if shouldClaim {
                var updated = item
                updated.phase = .posting
                updated.claimedAt = now
                items[key] = updated
                claimed.append(updated)
            }
        }

        return claimed
    }

    func update(_ item: AppActorPaymentQueueItem) {
        items[item.key] = item
    }

    func remove(key: String) {
        items.removeValue(forKey: key)
    }

    func clear() {
        items = [:]
    }

    func pendingCount() -> Int {
        items.values.filter { $0.phase == .needsPost || $0.phase == .posting }.count
    }

    func deadLetteredCount() -> Int {
        items.values.filter { $0.phase == .deadLettered }.count
    }

    func snapshot() -> [AppActorPaymentQueueItem] {
        Array(items.values)
    }

    private var rateLimitCooldown: Date?

    func getRateLimitCooldown() -> Date? {
        rateLimitCooldown
    }

    func setRateLimitCooldown(_ date: Date?) {
        rateLimitCooldown = date
    }

    // MARK: - Posted Ledger

    private var postedKeys: Set<String> = []

    func isPosted(key: String) -> Bool {
        postedKeys.contains(key)
    }

    func markPosted(key: String) {
        postedKeys.insert(key)
    }

    func purgeExpiredLedgerEntries(olderThan retention: TimeInterval) {
        // No-op in tests
    }

    func consumePurgedDeadLetters() -> [AppActorPurgedDeadLetterSummary] {
        let records = purgedDeadLetters
        purgedDeadLetters.removeAll()
        return records
    }

    func markPostedAndUpdate(key: String, item: AppActorPaymentQueueItem) {
        postedKeys.insert(key)
        items[key] = item
    }

    func purgeExpiredDeadLetters() -> Int {
        let cutoff = Date().addingTimeInterval(-30 * 24 * 60 * 60)
        var purgedCount = 0
        for (key, item) in items where item.phase == .deadLettered && item.firstSeenAt < cutoff {
            items.removeValue(forKey: key)
            purgedCount += 1
        }
        return purgedCount
    }

    // Test helper
    func allItems() -> [AppActorPaymentQueueItem] {
        Array(items.values)
    }

    func enqueuePurgedDeadLetter(_ record: AppActorPurgedDeadLetterSummary) {
        purgedDeadLetters.append(record)
    }
}

/// Thread-safe accumulator for receipt pipeline events.
/// Moved from PaymentProcessorTests to shared location.
final class PipelineEventAccumulator: @unchecked Sendable {
    private let queue = DispatchQueue(label: "test.events.lock")
    private var _events: [AppActorReceiptPipelineEventDetail] = []
    var events: [AppActorReceiptPipelineEventDetail] { queue.sync { _events } }
    func append(_ detail: AppActorReceiptPipelineEventDetail) { queue.sync { _events.append(detail) } }
}
