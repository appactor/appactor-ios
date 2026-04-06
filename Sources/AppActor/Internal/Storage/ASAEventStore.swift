import Foundation

// MARK: - Stored Event

/// A purchase event persisted on disk, awaiting server delivery.
struct AppActorASAStoredEvent: Codable, Sendable {
    /// Stable local identifier (UUID) for safe removal by ID.
    let id: String
    let request: AppActorASAPurchaseEventRequest
    var retryCount: Int
    let createdAt: Date
}

// MARK: - Protocol

/// Persistence layer for ASA purchase events awaiting server delivery.
///
/// Much simpler than `PaymentQueueStoreProtocol` — no phases, no ledger.
/// Items are enqueued, flushed (single attempt per flush cycle), and removed on success.
protocol AppActorASAEventStoreProtocol: AnyObject, Sendable {
    /// Adds a purchase event to the queue.
    func enqueue(_ event: AppActorASAStoredEvent)

    /// Returns all pending events (oldest first).
    func pending() -> [AppActorASAStoredEvent]

    /// Removes a single event by its stable `id`.
    func remove(id: String)

    /// Updates an existing event (e.g. increment retryCount).
    func update(_ event: AppActorASAStoredEvent)

    /// Removes all events.
    func clear()

    /// Number of pending events.
    func count() -> Int
}

// MARK: - File-Based Implementation

/// File-backed ASA event store with atomic JSON writes.
///
/// Uses `Library/Application Support/appactor/asa_events.json`.
/// Maintains an in-memory cache; all mutations write through to disk atomically.
///
/// Thread-safe via `NSLock`. Marked `@unchecked Sendable` because Swift cannot
/// verify lock-based safety at compile time, but all mutable state is protected.
final class AppActorASAFileEventStore: AppActorASAEventStoreProtocol, @unchecked Sendable {

    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let lock = NSLock()

    /// In-memory cache. Loaded lazily from disk on first access.
    private var events: [AppActorASAStoredEvent]?

    /// Events buffered in memory when disk is unreadable.
    /// Merged into the main list on next successful disk read, preventing event loss.
    private var stagedEvents: [AppActorASAStoredEvent] = []

    /// Events older than 7 days are purged on first load.
    static let retentionDays: TimeInterval = 7 * 24 * 60 * 60

    /// Maximum number of events to keep (prevents unbounded growth).
    static let maxEvents: Int = 200

    /// Creates an event store.
    /// - Parameter directory: Override for testing. Defaults to `Library/Application Support/appactor/`.
    init(directory: URL? = nil) {
        let dir = directory ?? Self.defaultDirectory
        self.fileURL = dir.appendingPathComponent("asa_events.json")

        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .secondsSince1970
        self.encoder = enc

        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .secondsSince1970
        self.decoder = dec
    }

    // MARK: - ASAEventStoreProtocol

    func enqueue(_ event: AppActorASAStoredEvent) {
        lock.lock(); defer { lock.unlock() }
        var list = loadFromDisk_locked()

        // [N3] Disk unreadable — stage event in memory instead of dropping it.
        // Staged events are merged on next successful disk read.
        guard events != nil else {
            stagedEvents.append(event)
            // Enforce cap even while staged to prevent unbounded memory growth
            if stagedEvents.count > Self.maxEvents {
                let drop = stagedEvents.count - Self.maxEvents
                stagedEvents.removeFirst(drop)
            }
            Log.attribution.warn("Disk unreadable, event staged in memory (\(stagedEvents.count) staged)")
            return
        }

        // Cap enforcement: drop oldest if at limit
        if list.count >= Self.maxEvents {
            let dropCount = list.count - Self.maxEvents + 1
            list.removeFirst(dropCount)
            Log.attribution.warn("Event queue at capacity (\(Self.maxEvents)), dropped \(dropCount) oldest event(s)")
        }

        list.append(event)
        events = list
        writeToDisk(list)
    }

    func pending() -> [AppActorASAStoredEvent] {
        lock.lock(); defer { lock.unlock() }
        var list = loadFromDisk_locked()
        if !stagedEvents.isEmpty { list.append(contentsOf: stagedEvents) }
        return list
    }

    func remove(id: String) {
        lock.lock(); defer { lock.unlock() }
        var list = loadFromDisk_locked()
        if events != nil {
            list.removeAll { $0.id == id }
            events = list
            writeToDisk(list)
        }
        // Also remove from staged events (event may have been staged during disk failure)
        stagedEvents.removeAll { $0.id == id }
    }

    func update(_ event: AppActorASAStoredEvent) {
        lock.lock(); defer { lock.unlock() }
        var list = loadFromDisk_locked()
        if events != nil {
            if let index = list.firstIndex(where: { $0.id == event.id }) {
                list[index] = event
            }
            events = list
            writeToDisk(list)
        }
        // Also update in staged events
        if let index = stagedEvents.firstIndex(where: { $0.id == event.id }) {
            stagedEvents[index] = event
        }
    }

    func clear() {
        lock.lock(); defer { lock.unlock() }
        events = []
        stagedEvents.removeAll()
        writeToDisk([])
    }

    func count() -> Int {
        lock.lock(); defer { lock.unlock() }
        return loadFromDisk_locked().count + stagedEvents.count
    }

    // MARK: - Disk I/O

    /// Must be called under `lock`. Does NOT acquire lock itself.
    private func loadFromDisk_locked() -> [AppActorASAStoredEvent] {
        if let cached = events { return cached }

        // [N3] Distinguish "file doesn't exist" (→ cache empty) from "read failed" (→ don't cache, retry next access)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            events = []
            mergeStagedEvents()
            return events!
        }

        // Read with single retry for transient I/O errors
        guard let data = readFileData() else {
            Log.attribution.warn("Failed to read asa_events.json after retry, will retry on next access")
            return []  // Don't cache — allows retry on next call
        }

        // [L2] Fail soft: on decode failure, log, delete corrupt file, and treat as empty
        guard let decoded = try? decoder.decode([AppActorASAStoredEvent].self, from: data) else {
            Log.attribution.warn("Failed to decode asa_events.json, deleting corrupt file and treating as empty")
            try? FileManager.default.removeItem(at: fileURL)
            events = []
            mergeStagedEvents()
            return events!
        }

        // Purge events older than retention period
        let cutoff = Date().addingTimeInterval(-Self.retentionDays)
        let list = decoded.filter { $0.createdAt > cutoff }

        if list.count < decoded.count {
            let purged = decoded.count - list.count
            Log.attribution.info("Purged \(purged) expired event(s) older than 7 days")
            writeToDisk(list)
        }

        events = list
        mergeStagedEvents()
        return events!
    }

    /// Reads file data with a single immediate retry for transient I/O errors.
    private func readFileData() -> Data? {
        if let data = try? Data(contentsOf: fileURL) { return data }
        return try? Data(contentsOf: fileURL)
    }

    /// Merges any staged events into the main list and persists.
    /// Called after a successful disk read to recover events from previous failures.
    /// Enforces maxEvents cap and retention on merged result.
    private func mergeStagedEvents() {
        guard !stagedEvents.isEmpty, events != nil else { return }
        let count = stagedEvents.count

        // Filter expired staged events before merging
        let cutoff = Date().addingTimeInterval(-Self.retentionDays)
        let validStaged = stagedEvents.filter { $0.createdAt > cutoff }
        stagedEvents.removeAll()

        events!.append(contentsOf: validStaged)

        // Enforce cap: drop oldest if over limit
        if events!.count > Self.maxEvents {
            let dropCount = events!.count - Self.maxEvents
            events!.removeFirst(dropCount)
        }

        writeToDisk(events!)
        Log.attribution.info("Merged \(count) staged event(s) from previous disk read failure(s)")
    }

    // [L3] Log disk write failures instead of silently ignoring
    private func writeToDisk(_ list: [AppActorASAStoredEvent]) {
        guard let data = try? encoder.encode(list) else {
            Log.attribution.warn("Failed to encode event store, data not persisted")
            return
        }
        let dir = fileURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            Log.attribution.warn("Failed to create event store directory: \(error.localizedDescription)")
        }
        do {
            try data.write(to: fileURL, options: .atomic)
        } catch {
            Log.attribution.warn("Failed to write event store to disk: \(error.localizedDescription)")
        }
    }

    // MARK: - Default Path

    private static var defaultDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        return appSupport.appendingPathComponent("appactor", isDirectory: true)
    }

    /// Removes the persisted events file from the default directory.
    ///
    /// Thread-safe: performs only a filesystem delete. Use from `reset()`.
    static func deletePersistedFile() {
        let fileURL = defaultDirectory.appendingPathComponent("asa_events.json")
        try? FileManager.default.removeItem(at: fileURL)
    }
}
