import Foundation

/// Log severity level for the AppActor SDK.
///
/// Levels are ordered from most severe (`.error`) to most verbose (`.debug`).
/// Setting a level enables that level and all levels above it.
///
/// ```swift
/// AppActor.logLevel = .verbose  // error + warn + info + verbose
/// ```
public enum AppActorLogLevel: Int, Sendable, Comparable {
    /// Only errors.
    case error = 0
    /// Errors + warnings.
    case warn = 1
    /// Errors + warnings + lifecycle info. **Default.**
    case info = 2
    /// Errors + warnings + info + function calls, API queries.
    case verbose = 3
    /// Everything.
    case debug = 4

    /// Default log level.
    public static let `default` = AppActorLogLevel.info

    public static func < (lhs: AppActorLogLevel, rhs: AppActorLogLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// Human-readable name used in formatted log output.
    var name: String {
        switch self {
        case .error:   return "ERROR"
        case .warn:    return "WARN"
        case .info:    return "INFO"
        case .verbose: return "VERBOSE"
        case .debug:   return "DEBUG"
        }
    }

    /// Emoji prefix for formatted log output.
    /// Only error/warn get a visual marker; info and below stay clean.
    var symbol: String {
        switch self {
        case .error:   return "❌ "
        case .warn:    return "⚠️ "
        case .info:    return ""
        case .verbose: return ""
        case .debug:   return ""
        }
    }
}

// MARK: - Codable (String-based)

extension AppActorLogLevel: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        self.init(stringLiteral: raw)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(stringLiteral)
    }
}

// MARK: - String Literal Init

extension AppActorLogLevel: ExpressibleByStringLiteral {
    /// Initializes a log level from a case-insensitive string.
    ///
    /// Useful for parsing log levels from remote config or environment:
    /// ```swift
    /// let level: AppActorLogLevel = "debug"  // → .debug
    /// ```
    /// Unrecognized strings default to `.info`.
    public init(stringLiteral value: String) {
        switch value.lowercased() {
        case "error":   self = .error
        case "warn":    self = .warn
        case "info":    self = .info
        case "verbose": self = .verbose
        case "debug":   self = .debug
        default:        self = .info
        }
    }

    /// String representation for serialization (lowercase).
    public var stringLiteral: String { name.lowercased() }
}
