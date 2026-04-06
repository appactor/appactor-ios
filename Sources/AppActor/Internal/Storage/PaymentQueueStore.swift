import Foundation

// MARK: - Protocol

/// Persistence layer for payment queue items awaiting server validation.
///
/// **Not an actor** — owned exclusively by `PaymentProcessor` and called
/// synchronously within its isolation context.
protocol AppActorPaymentQueueStoreProtocol: AnyObject, Sendable {
    /// Inserts or updates an item by `key`. Merges sources, updates jws,
    /// preserves retry metadata on existing items.
    func upsert(_ item: AppActorPaymentQueueItem)

    /// Claims items ready for POSTing:
    /// - `.needsPost` items whose `nextRetryAt <= now`
    /// - Stale `.posting` items (claimedAt > 2 min ago)
    ///
    /// `.needsFinish` items are handled separately by the drain loop.
    /// Sets `phase = .posting` and `claimedAt = now`, persists, then returns.
    func claimReady(limit: Int, now: Date) -> [AppActorPaymentQueueItem]

    /// Updates an existing item in the store.
    func update(_ item: AppActorPaymentQueueItem)

    /// Removes an item by its key.
    func remove(key: String)

    /// Removes all items.
    func clear()

    /// Number of items in `.needsPost` or `.posting` phase.
    func pendingCount() -> Int

    /// Number of items in `.deadLettered` phase.
    func deadLetteredCount() -> Int

    /// Returns all items for diagnostic purposes.
    func snapshot() -> [AppActorPaymentQueueItem]

    /// Returns the persisted rate-limit cooldown timestamp, or `nil` if none/expired.
    func getRateLimitCooldown() -> Date?

    /// Persists (or clears) the rate-limit cooldown timestamp.
    func setRateLimitCooldown(_ date: Date?)

    // MARK: - Posted Ledger (Duplicate POST Prevention)

    /// Returns `true` if the given key was already successfully posted.
    func isPosted(key: String) -> Bool

    /// Marks a key as successfully posted with the current timestamp.
    func markPosted(key: String)

    /// Removes ledger entries older than the given retention interval.
    func purgeExpiredLedgerEntries(olderThan retention: TimeInterval)

    /// Returns and clears dead-letter items purged during disk hydration.
    func consumePurgedDeadLetters() -> [AppActorPurgedDeadLetterSummary]

    /// Removes dead-lettered items older than 30 days. Returns the count of purged items.
    func purgeExpiredDeadLetters() -> Int

    /// Atomically marks a key as posted AND updates the item in a single disk write.
    /// Eliminates the crash window between separate `markPosted` and `update` calls.
    func markPostedAndUpdate(key: String, item: AppActorPaymentQueueItem)
}

// MARK: - File-Based Implementation

/// File-backed payment queue store with atomic JSON writes.
///
/// Uses `Library/Application Support/appactor/payment_queue.json`.
/// Maintains an in-memory cache; all mutations write through to disk atomically.
/// Dead-lettered items older than 30 days are purged on first load.
///
/// Marked `@unchecked Sendable` because it is owned exclusively by the
/// `PaymentProcessor` actor and never accessed concurrently.
final class AppActorAtomicJSONQueueStore: AppActorPaymentQueueStoreProtocol, @unchecked Sendable {

    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    /// In-memory cache. Loaded lazily from disk on first access.
    private var items: [String: AppActorPaymentQueueItem]?

    /// In-memory cache for persisted rate-limit cooldown.
    private var cachedCooldown: Date?
    /// Whether `cachedCooldown` has been loaded from disk.
    private var cooldownLoaded: Bool = false

    /// Dead-lettered items older than this are purged on first load.
    static let deadLetterRetentionDays: TimeInterval = 30 * 24 * 60 * 60

    /// Dead-letter items purged during the last disk load, consumed by the pipeline.
    private var purgedDeadLetters: [AppActorPurgedDeadLetterSummary] = []

    /// Stale claim threshold: claims older than this are considered abandoned.
    static let staleClaimThreshold: TimeInterval = 2 * 60

    /// Creates a queue store.
    /// - Parameter directory: Override for testing. Defaults to `Library/Application Support/appactor/`.
    init(directory: URL? = nil) {
        let dir = directory ?? Self.defaultDirectory
        self.fileURL = dir.appendingPathComponent("payment_queue.json")

        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .secondsSince1970
        self.encoder = enc

        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .secondsSince1970
        self.decoder = dec
    }

    /// In-memory cache for the posted ledger. Keys → postedAt timestamps.
    private var postedLedger: [String: TimeInterval]?

    /// Posted ledger entries older than this are purged on first load.
    static let ledgerRetentionDays: TimeInterval = 90 * 24 * 60 * 60

    /// Maximum number of ledger entries to keep.
    static let maxLedgerEntries: Int = 5000

    /// On-disk envelope: items + metadata. Backward-compatible with legacy `[PaymentQueueItem]` format.
    private struct PersistedState: Codable {
        var items: [AppActorPaymentQueueItem]
        var rateLimitCooldownUntil: Date?
        /// Keys that were successfully posted, mapped to postedAt (secondsSince1970).
        var postedKeys: [String: TimeInterval]?
    }

    // MARK: - PaymentQueueStoreProtocol

    func upsert(_ item: AppActorPaymentQueueItem) {
        var map = loadFromDisk()

        if var existing = map[item.key] {
            existing.mergeFrom(item)
            map[item.key] = existing
        } else {
            map[item.key] = item
        }

        items = map
        writeToDisk(map)
    }

    func claimReady(limit: Int, now: Date) -> [AppActorPaymentQueueItem] {
        var map = loadFromDisk()
        let staleThreshold = now.addingTimeInterval(-Self.staleClaimThreshold)

        var claimed: [AppActorPaymentQueueItem] = []

        for (key, item) in map {
            guard claimed.count < limit else { break }

            let shouldClaim: Bool
            switch item.phase {
            case .needsPost:
                shouldClaim = item.nextRetryAt <= now
            case .posting:
                // Stale claim — previous processor crashed or timed out
                shouldClaim = item.claimedAt.map { $0 < staleThreshold } ?? true
            case .needsFinish:
                // Handled separately by drain loop Step 1, not claimed for POSTing
                shouldClaim = false
            case .deadLettered:
                shouldClaim = false
            }

            if shouldClaim {
                var updated = item
                updated.phase = .posting
                updated.claimedAt = now
                map[key] = updated
                claimed.append(updated)
            }
        }

        if !claimed.isEmpty {
            items = map
            writeToDisk(map)
        }

        return claimed
    }

    func update(_ item: AppActorPaymentQueueItem) {
        var map = loadFromDisk()
        map[item.key] = item
        items = map
        writeToDisk(map)
    }

    func remove(key: String) {
        var map = loadFromDisk()
        map.removeValue(forKey: key)
        items = map
        writeToDisk(map)
    }

    func clear() {
        items = [:]
        cachedCooldown = nil
        cooldownLoaded = true
        postedLedger = [:]
        purgedDeadLetters = []
        writeToDisk([:])
    }

    func pendingCount() -> Int {
        let map = loadFromDisk()
        return map.values.filter { $0.phase == .needsPost || $0.phase == .posting }.count
    }

    func deadLetteredCount() -> Int {
        let map = loadFromDisk()
        return map.values.filter { $0.phase == .deadLettered }.count
    }

    func snapshot() -> [AppActorPaymentQueueItem] {
        Array(loadFromDisk().values)
    }

    func getRateLimitCooldown() -> Date? {
        if cooldownLoaded { return cachedCooldown }
        // Force load from disk to populate cachedCooldown
        _ = loadFromDisk()
        return cachedCooldown
    }

    func setRateLimitCooldown(_ date: Date?) {
        cachedCooldown = date
        cooldownLoaded = true
        let map = loadFromDisk()
        writeToDisk(map)
    }

    // MARK: - Posted Ledger

    func isPosted(key: String) -> Bool {
        let ledger = loadLedger()
        return ledger[key] != nil
    }

    func markPosted(key: String) {
        var ledger = loadLedger()
        ledger[key] = Date().timeIntervalSince1970
        enforceLedgerCap(&ledger)
        postedLedger = ledger
        let map = loadFromDisk()
        writeToDisk(map)
    }

    func markPostedAndUpdate(key: String, item: AppActorPaymentQueueItem) {
        // Atomically mark posted + update item phase in a single disk write.
        // This eliminates the crash window between separate markPosted and update calls.
        var ledger = loadLedger()
        ledger[key] = Date().timeIntervalSince1970
        enforceLedgerCap(&ledger)
        postedLedger = ledger

        var map = loadFromDisk()
        map[key] = item
        items = map
        writeToDisk(map)
    }

    private func enforceLedgerCap(_ ledger: inout [String: TimeInterval]) {
        if ledger.count > Self.maxLedgerEntries {
            let cutoff = Date().timeIntervalSince1970 - Self.ledgerRetentionDays
            ledger = ledger.filter { $0.value > cutoff }
            if ledger.count > Self.maxLedgerEntries {
                let sorted = ledger.sorted { $0.value > $1.value }
                ledger = Dictionary(uniqueKeysWithValues: sorted.prefix(Self.maxLedgerEntries).map { ($0.key, $0.value) })
            }
        }
    }

    func purgeExpiredLedgerEntries(olderThan retention: TimeInterval) {
        var ledger = loadLedger()
        let cutoff = Date().timeIntervalSince1970 - retention

        // Remove entries older than retention
        ledger = ledger.filter { $0.value > cutoff }

        // If still over max, keep only the newest entries
        if ledger.count > Self.maxLedgerEntries {
            let sorted = ledger.sorted { $0.value > $1.value }
            ledger = Dictionary(uniqueKeysWithValues: sorted.prefix(Self.maxLedgerEntries).map { ($0.key, $0.value) })
        }

        postedLedger = ledger
        let map = loadFromDisk()
        writeToDisk(map)
    }

    func consumePurgedDeadLetters() -> [AppActorPurgedDeadLetterSummary] {
        _ = loadFromDisk()
        let purged = purgedDeadLetters
        purgedDeadLetters.removeAll()
        return purged
    }

    func purgeExpiredDeadLetters() -> Int {
        var map = loadFromDisk()
        let cutoff = Date().addingTimeInterval(-Self.deadLetterRetentionDays)
        var purgedCount = 0
        for (key, item) in map where item.phase == .deadLettered && item.firstSeenAt < cutoff {
            map.removeValue(forKey: key)
            purgedCount += 1
        }
        if purgedCount > 0 {
            items = map
            writeToDisk(map)
        }
        return purgedCount
    }

    private func loadLedger() -> [String: TimeInterval] {
        if let cached = postedLedger { return cached }
        // Force disk load to populate postedLedger
        _ = loadFromDisk()
        return postedLedger ?? [:]
    }

    // MARK: - Disk I/O

    private func loadFromDisk() -> [String: AppActorPaymentQueueItem] {
        if let cached = items { return cached }

        guard FileManager.default.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL) else {
            items = [:]
            if !cooldownLoaded {
                cachedCooldown = nil
                cooldownLoaded = true
            }
            return [:]
        }

        // Try new PersistedState format first, fall back to legacy [PaymentQueueItem]
        let list: [AppActorPaymentQueueItem]
        if let state = try? decoder.decode(PersistedState.self, from: data) {
            list = state.items
            if !cooldownLoaded {
                cachedCooldown = state.rateLimitCooldownUntil
                cooldownLoaded = true
            }
            if postedLedger == nil {
                postedLedger = state.postedKeys ?? [:]
            }
        } else if let legacyList = try? decoder.decode([AppActorPaymentQueueItem].self, from: data) {
            list = legacyList
            if !cooldownLoaded {
                cachedCooldown = nil
                cooldownLoaded = true
            }
            if postedLedger == nil {
                postedLedger = [:]
            }
        } else {
            items = [:]
            if !cooldownLoaded {
                cachedCooldown = nil
                cooldownLoaded = true
            }
            if postedLedger == nil {
                postedLedger = [:]
            }
            return [:]
        }

        // Build map keyed by item.key
        var map: [String: AppActorPaymentQueueItem] = [:]
        for item in list {
            map[item.key] = item
        }

        // Purge dead-lettered items older than 30 days
        let cutoff = Date().addingTimeInterval(-Self.deadLetterRetentionDays)
        var purgedCount = 0
        map = map.filter { _, item in
            guard item.phase == .deadLettered && item.firstSeenAt < cutoff else { return true }
            purgedDeadLetters.append(AppActorPurgedDeadLetterSummary(
                transactionId: item.transactionId,
                productId: item.productId,
                attemptCount: item.attemptCount,
                lastError: item.lastError
            ))
            purgedCount += 1
            return false
        }
        if purgedCount > 0 {
            Log.storage.info("Purged \(purgedCount) dead-lettered payment queue item(s) older than 30 days")
            writeToDisk(map)
        }

        items = map
        return map
    }

    /// Writes the current items + cooldown state to disk atomically.
    /// Always reads `cachedCooldown` for the cooldown value.
    private func writeToDisk(_ map: [String: AppActorPaymentQueueItem]) {
        let state = PersistedState(
            items: Array(map.values),
            rateLimitCooldownUntil: cachedCooldown,
            postedKeys: postedLedger
        )
        guard let data = try? encoder.encode(state) else { return }
        let dir = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Apply file protection to the directory (createDirectory only sets attributes on creation, not on existing dirs).
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: dir.path
        )
        try? data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    // MARK: - Default Path

    private static var defaultDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        return appSupport.appendingPathComponent("appactor", isDirectory: true)
    }

    /// Removes the persisted queue file from the default directory.
    ///
    /// Thread-safe: performs only a filesystem delete without touching any store
    /// instance state. Use this from `reset()` to avoid data races with
    /// a running `PaymentProcessor` that owns a live store instance.
    static func deletePersistedFile() {
        let fileURL = defaultDirectory.appendingPathComponent("payment_queue.json")
        try? FileManager.default.removeItem(at: fileURL)
    }
}
