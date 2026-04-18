import Foundation

final class LockedLogCollector: @unchecked Sendable {
    typealias Entry = (level: String, message: String)

    private let lock = NSLock()
    private var entries: [Entry] = []

    func append(level: String, message: String) {
        lock.withLock {
            entries.append((level, message))
        }
    }

    func snapshot() -> [Entry] {
        lock.withLock {
            entries
        }
    }
}
