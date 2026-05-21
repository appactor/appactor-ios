import Foundation

/// A named logging category for the AppActor SDK.
///
/// Each category maps to a separate `os.Logger` instance, enabling
/// fine-grained filtering in Console.app.
struct AppActorLogCategory: Sendable, Hashable, Codable {
    /// The os.log subsystem (e.g. `"com.appactor"`).
    let subsystem: String
    /// The SDK version string.
    let version: String
    /// The category name (e.g. `"Network"`, `"Identity"`).
    let name: String

    init(subsystem: String = "com.appactor", version: String = AppActorSDK.version, name: String) {
        self.subsystem = subsystem
        self.version = version
        self.name = name
    }
}

extension AppActorLogCategory: CustomStringConvertible {
    /// Clean prefix — version and category live in the `AppActorLogRecord` metadata,
    /// not repeated in every formatted line.
    var description: String { "[AppActor]" }
}

// MARK: - Convenience Logging Methods

extension AppActorLogCategory {

    func error(
        _ message: @autoclosure () -> String,
        file: String = #fileID,
        function: String = #function,
        line: UInt = #line
    ) {
        log(.error, message(), file: file, function: function, line: line)
    }

    func warn(
        _ message: @autoclosure () -> String,
        file: String = #fileID,
        function: String = #function,
        line: UInt = #line
    ) {
        log(.warn, message(), file: file, function: function, line: line)
    }

    func info(
        _ message: @autoclosure () -> String,
        file: String = #fileID,
        function: String = #function,
        line: UInt = #line
    ) {
        log(.info, message(), file: file, function: function, line: line)
    }

    func verbose(
        _ message: @autoclosure () -> String,
        file: String = #fileID,
        function: String = #function,
        line: UInt = #line
    ) {
        log(.verbose, message(), file: file, function: function, line: line)
    }

    func debug(
        _ message: @autoclosure () -> String,
        file: String = #fileID,
        function: String = #function,
        line: UInt = #line
    ) {
        log(.debug, message(), file: file, function: function, line: line)
    }

    // MARK: - Private

    private func log(
        _ level: AppActorLogLevel,
        _ message: String,
        file: String,
        function: String,
        line: UInt
    ) {
        guard AppActorLogger.isLevel(level) else { return }

        // Extract just the filename from #fileID (e.g. "AppActor/PaymentClient.swift" → "PaymentClient.swift")
        let fileName: String
        if let lastSlash = file.lastIndex(of: "/") {
            fileName = String(file[file.index(after: lastSlash)...])
        } else {
            fileName = file
        }

        let record = AppActorLogRecord(
            date: Date(),
            level: level,
            message: message,
            category: self,
            source: AppActorLogSource(
                fileName: fileName,
                functionName: function,
                lineNumber: line
            )
        )
        AppActorLogger.write(record: record)
    }
}
