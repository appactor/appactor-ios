import Foundation

/// JSON envelope: `{"success": <T>}` or `{"error": {...}}`.
///
/// Uses a private Codable enum internally for type-safe single-pass encoding.
/// Custom requests can build responses with ``encoding(_:)``, ``successVoid``,
/// or by returning `.error(AppActorPluginError(...))`.
public enum AppActorPluginResult: Sendable {

    case success(Data)
    case error(AppActorPluginError)

    // MARK: - JSON Output

    var jsonData: Data {
        switch self {
        case .success(let data):
            return Envelope.wrapSuccess(payload: data)
        case .error(let error):
            return Envelope.wrapError(error)
        }
    }

    var jsonString: String {
        String(data: jsonData, encoding: .utf8) ?? "{}"
    }

    // MARK: - Convenience Factories

    /// Encodes an `Encodable` value into a success envelope.
    public static func encoding<T: Encodable>(_ value: T) -> AppActorPluginResult {
        do {
            let data = try AppActorPluginCoder.encoder.encode(value)
            return .success(data)
        } catch {
            return .error(AppActorPluginError(
                code: AppActorPluginError.encodingFailed,
                message: "Failed to encode response",
                detail: error.localizedDescription
            ))
        }
    }

    /// Void success: `{"success": true}`.
    public static let successVoid = AppActorPluginResult.success(Data("true".utf8))

    /// Cached null payload for optional returns.
    static let nullData = Data("null".utf8)
}

// MARK: - Private Envelope

/// Envelope construction for JSON responses.
private enum Envelope {

    private struct ErrorEnvelope: Encodable {
        let error: AppActorPluginError
    }

    /// Wraps pre-encoded JSON data in `{"success": <raw>}`.
    static func wrapSuccess(payload: Data) -> Data {
        let payloadStr = String(data: payload, encoding: .utf8) ?? "{}"
        return Data(("{\"success\":" + payloadStr + "}").utf8)
    }

    /// Wraps an error in `{"error": {...}}` using Codable.
    static func wrapError(_ pluginError: AppActorPluginError) -> Data {
        do {
            return try AppActorPluginCoder.encoder.encode(ErrorEnvelope(error: pluginError))
        } catch {
            let escaped = pluginError.message.replacingOccurrences(of: "\"", with: "\\\"")
            return Data("{\"error\":{\"code\":\(pluginError.code),\"message\":\"\(escaped)\",\"detail\":\"\"}}".utf8)
        }
    }
}
