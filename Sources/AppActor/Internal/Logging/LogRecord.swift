import Foundation

/// A structured log entry emitted by the AppActor SDK.
struct AppActorLogRecord: Sendable, Codable {
    /// Timestamp of the log event.
    let date: Date
    /// Severity level.
    let level: AppActorLogLevel
    /// The log message.
    let message: String
    /// The category that emitted this record.
    let category: AppActorLogCategory
    /// Source location where the log was emitted.
    let source: AppActorLogSource
}

extension AppActorLogRecord: CustomStringConvertible {
    /// Compact description: `"[AppActor] → POST /v1/payment/identify"` or `"[AppActor] ❌ Decode failed"`
    var description: String {
        "[AppActor] \(level.symbol)\(message)"
    }
}

extension AppActorLogRecord: CustomDebugStringConvertible {
    /// Verbose description including source location:
    /// `"[AppActor] → POST /v1/payment/identify — PaymentClient.swift#142"`
    var debugDescription: String {
        "[AppActor] \(level.symbol)\(message) — \(source)"
    }
}
