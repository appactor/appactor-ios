import Foundation

// MARK: - Remote Config API Response DTOs

/// A single resolved remote config item from the server.
/// Decoded from `GET /v1/remote-config` response items.
struct AppActorRemoteConfigItemDTO: Codable, Sendable {
    let key: String
    let value: AppActorConfigValue
    let valueType: String
}

// MARK: - Conditional Fetch Result

/// Result type for conditional GET on remote config endpoint.
enum AppActorRemoteConfigFetchResult: Sendable {
    /// Fresh data from the server (HTTP 200).
    case fresh([AppActorRemoteConfigItemDTO], eTag: String?, requestId: String?, signatureVerified: Bool)
    /// Server returned 304 — cached data is still valid.
    case notModified(eTag: String?, requestId: String?)
}

// MARK: - Public Models

/// The resolved remote configuration for the current app context.
public struct AppActorRemoteConfigs: Sendable {
    /// All resolved config items.
    public let items: [AppActorRemoteConfigItem]

    /// Quick lookup by key. Returns the value for the first matching key, or `nil`.
    public subscript(key: String) -> AppActorConfigValue? {
        items.first { $0.key == key }?.value
    }
}

/// A single resolved remote config item.
public struct AppActorRemoteConfigItem: Sendable {
    public let key: String
    public let value: AppActorConfigValue
    public let valueType: AppActorConfigValueType
}

/// The type of a remote config value, matching the server's `value_type` enum.
public enum AppActorConfigValueType: String, Codable, Sendable {
    case boolean
    case number
    case string
    case json
}

// MARK: - Config Value (Type-safe JSON)

/// A type-safe representation of any JSON value used in remote config.
///
/// Provides typed accessors (``boolValue``, ``stringValue``, ``doubleValue``, ``intValue``)
/// for safe extraction of the underlying value.
public enum AppActorConfigValue: Sendable, Equatable {
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([AppActorConfigValue])
    case dictionary([String: AppActorConfigValue])
    case null
}

// MARK: - Codable

extension AppActorConfigValue: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let b = try? container.decode(Bool.self) {
            self = .bool(b)
        } else if let i = try? container.decode(Int.self) {
            self = .int(i)
        } else if let d = try? container.decode(Double.self) {
            self = .double(d)
        } else if let s = try? container.decode(String.self) {
            self = .string(s)
        } else if let arr = try? container.decode([AppActorConfigValue].self) {
            self = .array(arr)
        } else if let obj = try? container.decode([String: AppActorConfigValue].self) {
            self = .dictionary(obj)
        } else {
            throw DecodingError.typeMismatch(
                AppActorConfigValue.self,
                .init(codingPath: decoder.codingPath, debugDescription: "Unsupported JSON value type")
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .bool(let v): try container.encode(v)
        case .int(let v): try container.encode(v)
        case .double(let v): try container.encode(v)
        case .string(let v): try container.encode(v)
        case .array(let v): try container.encode(v)
        case .dictionary(let v): try container.encode(v)
        case .null: try container.encodeNil()
        }
    }
}

// MARK: - Typed Accessors

extension AppActorConfigValue {
    /// Returns the value as a `Bool`, or `nil` if the type doesn't match.
    public var boolValue: Bool? {
        if case .bool(let v) = self { return v }
        return nil
    }

    /// Returns the value as a `String`, or `nil` if the type doesn't match.
    public var stringValue: String? {
        if case .string(let v) = self { return v }
        return nil
    }

    /// Returns the value as a `Double`, or `nil` if the type doesn't match.
    /// Accepts both `.double` and `.int` (with implicit widening).
    public var doubleValue: Double? {
        switch self {
        case .double(let v): return v
        case .int(let v): return Double(v)
        default: return nil
        }
    }

    /// Returns the value as an `Int`, or `nil` if the type doesn't match.
    /// Accepts `.int` and whole `.double` values (e.g. `3.0` → `3`).
    public var intValue: Int? {
        switch self {
        case .int(let v): return v
        case .double(let v) where v == v.rounded(): return Int(v)
        default: return nil
        }
    }

    /// Access a key inside a `.dictionary` value.
    ///
    /// ```swift
    /// let title = payload["title"]?.stringValue ?? "Welcome"
    /// ```
    public subscript(key: String) -> AppActorConfigValue? {
        if case .dictionary(let dict) = self { return dict[key] }
        return nil
    }
}
