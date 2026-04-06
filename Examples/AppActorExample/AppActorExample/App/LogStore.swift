import Foundation

@MainActor
final class LogStore: ObservableObject {

    enum Level: String {
        case debug = "DEBUG"
        case info  = "INFO"
        case warning = "WARN"
        case error   = "ERROR"
    }

    struct Entry: Identifiable {
        let id = UUID()
        let timestamp: Date
        let level: Level
        let message: String

        var formattedTime: String {
            Self.formatter.string(from: timestamp)
        }

        var plainText: String {
            "\(formattedTime) [\(level.rawValue)] \(message)"
        }

        private static let formatter: DateFormatter = {
            let f = DateFormatter()
            f.dateFormat = "HH:mm:ss.SSS"
            return f
        }()
    }

    @Published private(set) var entries: [Entry] = []

    private let maxEntries = 500

    func log(_ message: String, level: Level = .info) {
        let entry = Entry(timestamp: Date(), level: level, message: message)
        entries.append(entry)
        if entries.count > maxEntries { entries.removeFirst() }
    }

    func clear() {
        entries.removeAll()
    }

    /// Returns all entries formatted as a single copyable string with a header.
    func formattedForCopy() -> String {
        let header = """
        === AppActor SDK Debug Log ===
        Date   : \(Self.headerFormatter.string(from: Date()))
        Entries: \(entries.count)
        ==============================
        """
        let body = entries.map(\.plainText).joined(separator: "\n")
        return header + "\n" + body + "\n=============================="
    }

    private static let headerFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()
}
