import Foundation
@testable import AppActor

/// In-memory implementation of `AppActorPaymentQueueStoreProtocol` for testing.
/// Moved from PaymentProcessorTests to shared location.
final class InMemoryPaymentQueueStore: AppActorPaymentQueueStoreProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: AppActorPaymentQueueItem] = [:]
    private var purgedDeadLetters: [AppActorPurgedDeadLetterSummary] = []

    @discardableResult
    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    func upsert(_ item: AppActorPaymentQueueItem) {
        withLock {
            if var existing = items[item.key] {
                existing.mergeFrom(item)
                items[item.key] = existing
            } else {
                items[item.key] = item
            }
        }
    }

    func claimReady(limit: Int, now: Date) -> [AppActorPaymentQueueItem] {
        withLock {
            let staleThreshold = now.addingTimeInterval(-120)
            var claimed: [AppActorPaymentQueueItem] = []

            for (key, item) in items {
                guard claimed.count < limit else { break }

                let shouldClaim: Bool
                switch item.phase {
                case .waitingForIdentity:
                    shouldClaim = false
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
    }

    func deferReadyUntilIdentity(confirmedAppUserIds: Set<String>, now: Date) -> [AppActorPaymentQueueItem] {
        withLock {
            var deferred: [AppActorPaymentQueueItem] = []

            for (key, item) in items where !confirmedAppUserIds.contains(item.appUserId) {
                switch item.phase {
                case .waitingForIdentity, .needsFinish, .deadLettered:
                    continue
                case .needsPost, .posting:
                    var updated = item
                    updated.phase = .waitingForIdentity
                    updated.claimedAt = nil
                    updated.lastSeenAt = now
                    items[key] = updated
                    deferred.append(updated)
                }
            }

            return deferred
        }
    }

    func releaseWaitingForIdentity(appUserId: String) -> [AppActorPaymentQueueItem] {
        withLock {
            var released: [AppActorPaymentQueueItem] = []

            for (key, item) in items where item.appUserId == appUserId && item.phase == .waitingForIdentity {
                var updated = item
                updated.phase = .needsPost
                updated.claimedAt = nil
                items[key] = updated
                released.append(updated)
            }

            return released
        }
    }

    func update(_ item: AppActorPaymentQueueItem) {
        withLock {
            items[item.key] = item
        }
    }

    func remove(key: String) {
        withLock {
            items.removeValue(forKey: key)
        }
    }

    func clear() {
        withLock {
            items = [:]
        }
    }

    func pendingCount() -> Int {
        withLock {
            items.values.filter {
                $0.phase == .waitingForIdentity || $0.phase == .needsPost || $0.phase == .posting
            }.count
        }
    }

    func deadLetteredCount() -> Int {
        withLock {
            items.values.filter { $0.phase == .deadLettered }.count
        }
    }

    func snapshot() -> [AppActorPaymentQueueItem] {
        withLock {
            Array(items.values)
        }
    }

    private var rateLimitCooldown: Date?

    func getRateLimitCooldown() -> Date? {
        withLock {
            rateLimitCooldown
        }
    }

    func setRateLimitCooldown(_ date: Date?) {
        withLock {
            rateLimitCooldown = date
        }
    }

    // MARK: - Posted Ledger

    private var postedKeys: Set<String> = []

    func isPosted(key: String) -> Bool {
        withLock {
            postedKeys.contains(key)
        }
    }

    func markPosted(key: String) {
        withLock {
            postedKeys.insert(key)
        }
    }

    func purgeExpiredLedgerEntries(olderThan retention: TimeInterval) {
        // No-op in tests
    }

    func consumePurgedDeadLetters() -> [AppActorPurgedDeadLetterSummary] {
        withLock {
            let records = purgedDeadLetters
            purgedDeadLetters.removeAll()
            return records
        }
    }

    func markPostedAndUpdate(key: String, item: AppActorPaymentQueueItem) {
        withLock {
            postedKeys.insert(key)
            items[key] = item
        }
    }

    func purgeExpiredDeadLetters() -> Int {
        withLock {
            let cutoff = Date().addingTimeInterval(-30 * 24 * 60 * 60)
            let keysToPurge = items.compactMap { key, item in
                item.phase == .deadLettered && item.firstSeenAt < cutoff ? key : nil
            }
            keysToPurge.forEach { key in
                items.removeValue(forKey: key)
            }
            return keysToPurge.count
        }
    }

    // Test helper
    func allItems() -> [AppActorPaymentQueueItem] {
        withLock {
            Array(items.values)
        }
    }

    func enqueuePurgedDeadLetter(_ record: AppActorPurgedDeadLetterSummary) {
        withLock {
            purgedDeadLetters.append(record)
        }
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
