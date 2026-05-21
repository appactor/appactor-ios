import Foundation
import os

// MARK: - OSLogType Mapping

extension AppActorLogLevel {
    var osLogType: OSLogType {
        switch self {
        case .error:   return .fault
        case .warn:    return .error
        case .info:    return .default
        case .verbose: return .info
        case .debug:   return .debug
        }
    }
}

// MARK: - os.log Integration

extension AppActorLogger {

    /// Per-category OSLog cache protected by a lock to prevent
    /// data races when multiple threads log concurrently during startup.
    private static let loggersLock = NSLock()
    nonisolated(unsafe) private static var loggers = [AppActorLogCategory: OSLog]()

    /// Writes a record to the system os.log subsystem.
    static func osLogWrite(_ record: AppActorLogRecord) {
        // Resolve the OSLog instance under lock, then release before os_log
        // to minimize lock contention.
        let osLog: OSLog

        loggersLock.lock()
        if let cached = loggers[record.category] {
            osLog = cached
        } else {
            let newLog = OSLog(subsystem: record.category.subsystem, category: record.category.name)
            loggers[record.category] = newLog
            osLog = newLog
        }
        loggersLock.unlock()

        os_log(
            record.level.osLogType,
            log: osLog,
            "[AppActor] %{public}@%{public}@",
            record.level.symbol,
            record.message
        )
    }
}
