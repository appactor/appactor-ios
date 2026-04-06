import Foundation
import os

/// Central logging engine for the AppActor SDK.
///
/// Routes log records to os.log (per-category), an optional custom handler,
/// and a synchronous test sink.
///
/// ```swift
/// // Set the global log level
/// AppActor.logLevel = .verbose
/// ```
enum AppActorLogger {

    // MARK: - Level

    /// The current log level. Only records at this level or above are emitted.
    /// Thread-safe for fast reads without `await`.
    nonisolated(unsafe) static var level: AppActorLogLevel = .default

    // MARK: - Handler

    /// Custom log handler type. Called alongside os.log, not instead of it.
    typealias Handler = @Sendable (AppActorLogRecord) -> Void

    /// Lock protecting `_handler` from concurrent read/write races.
    private static let handlerLock = NSLock()
    nonisolated(unsafe) private static var _handler: Handler?

    /// Thread-safe accessor for the custom handler.
    static var handler: Handler? {
        handlerLock.lock()
        defer { handlerLock.unlock() }
        return _handler
    }

    // MARK: - Test Hook

    /// Synchronous test hook for capturing logs in unit tests.
    /// Same `(level, message)` signature as the old `logSink` for minimal test migration.
    static var testSink: ((_ level: String, _ message: String) -> Void)?

    // MARK: - Level Check

    /// Returns `true` if the given level is enabled under the current log level.
    nonisolated static func isLevel(_ level: AppActorLogLevel) -> Bool {
        self.level >= level
    }

    // MARK: - Write Pipeline

    /// Writes a record through the pipeline: testSink (sync) → os.log → handler (detached).
    static func write(record: AppActorLogRecord) {
        // Synchronous test hook (for test capture without async)
        testSink?(record.level.name.lowercased(), record.message)

        // os.log integration (direct, same thread for reliability)
        osLogWrite(record)

        // Custom handler — dispatched to a detached task so a slow handler
        // (e.g. disk I/O, network) never blocks the calling thread.
        if let handler {
            Task.detached(priority: .utility) {
                handler(record)
            }
        }
    }

    // MARK: - Stamp

    /// Random alphanumeric stamp for request correlation.
    private static let stampChars = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")

    static var stamp: String {
        var result = ""
        result.reserveCapacity(6)
        for _ in 0..<6 {
            result.append(stampChars[Int(arc4random_uniform(62))])
        }
        return result
    }

    /// Hierarchical stamp for nested operations: `"parent/child"`.
    static func stamp(parent: String) -> String {
        "\(parent)/\(stamp)"
    }

    // MARK: - Internal API Helpers

    /// Sets the custom log handler (thread-safe).
    static func setHandler(_ handler: Handler?) {
        handlerLock.lock()
        _handler = handler
        handlerLock.unlock()
    }
}

// MARK: - Public API on AppActor

public extension AppActor {

    /// The current SDK log level. Default: `.info`.
    ///
    /// ```swift
    /// AppActor.logLevel = .debug  // Enable all logging
    /// ```
    nonisolated static var logLevel: AppActorLogLevel {
        get { AppActorLogger.level }
        set { AppActorLogger.level = newValue }
    }

    /// Sets a custom log handler that receives SDK log records alongside os.log.
    ///
    /// The handler is dispatched on a background task so it never blocks the SDK.
    /// Pass `nil` to remove the handler.
    nonisolated static func setLogHandler(
        _ handler: (@Sendable (_ level: String, _ message: String, _ category: String, _ date: Date) -> Void)?
    ) {
        if let handler {
            AppActorLogger.setHandler { record in
                handler(
                    record.level.name.lowercased(),
                    record.message,
                    record.category.name,
                    record.date
                )
            }
        } else {
            AppActorLogger.setHandler(nil)
        }
    }
}

// MARK: - Internal Type Aliases

/// Convenience namespace for internal log types.
enum AppActorLog {
    typealias Level = AppActorLogLevel
    typealias Record = AppActorLogRecord
    typealias Handler = AppActorLogger.Handler
}
