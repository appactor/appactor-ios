import Foundation

/// Wire format for the server-driven screen bridge. **Frozen**: the
/// counterpart is `appactor-screens/.../spec/bridge.ts` and Android speaks the
/// same one, so renaming a field here is a protocol bump, not a refactor.
///
/// Two asymmetries are load bearing. Native→web goes out **base64** because
/// interpolating raw JSON into `evaluateJavaScript` breaks on quotes and
/// newlines. Batches are an **array** of those, decoded per element on both
/// sides, so one unrecognised message cannot take the `purchaseResult` beside
/// it down with it.
enum AppActorScreenProtocol {

    /// On every envelope, both directions. A mismatch is a drop, never a
    /// best-effort read: guessing a field's meaning in a version you do not
    /// know is how silent corruption starts.
    static let version = 1

    static let nativeEntrypoint = "__appactor"
    static let webChannel = "appactorScreens"

    /// Native's own watchdog, separate from the runtime's `slow_first_paint`:
    /// it covers the case where the runtime never runs at all and nothing
    /// web-side is left to report it.
    static let readyWatchdog: TimeInterval = 2.0

    /// Bounds what a compromised or wedged page can send.
    static let maxInboundMessageBytes = 256 * 1024
}

// MARK: - web → native

enum AppActorScreenOutboundType: String, CaseIterable {
    case ready
    case purchase
    case restore
    case close
    case navigate
    case openUrl
    case event
    case error
}

/// A decoded message from the runtime.
struct AppActorScreenOutbound {
    let type: AppActorScreenOutboundType
    /// Required on `purchase` and `restore` (day-1 rule #14): without it a
    /// result cannot be tied back to the request that asked for it.
    let requestId: String?
    let payload: [String: Any]

    func string(_ key: String) -> String? {
        payload[key] as? String
    }
}

/// Why a message was dropped. Specific on purpose: these are the only symptoms
/// available when the bridge misbehaves in the field.
enum AppActorScreenDecodeFailure: Error, Equatable {
    case notAString
    case tooLarge(bytes: Int)
    case malformedJSON
    case notAnObject
    case protocolMismatch(received: Int?)
    case unknownType(String)
    case missingPayload

    var reason: String {
        switch self {
        case .notAString: return "message body was not a string"
        case .tooLarge(let bytes): return "message was \(bytes) bytes, over the \(AppActorScreenProtocol.maxInboundMessageBytes) limit"
        case .malformedJSON: return "message was not valid JSON"
        case .notAnObject: return "message was not a JSON object"
        case .protocolMismatch(let received):
            let got = received.map(String.init) ?? "nothing"
            return "protocol_version mismatch: native speaks \(AppActorScreenProtocol.version), received \(got)"
        case .unknownType(let type): return "unknown message type \"\(type)\""
        case .missingPayload: return "message had no payload object"
        }
    }
}

extension AppActorScreenOutbound {

    /// Parses one `postMessage` body. Never throws and never traps: the page is
    /// the least trustworthy input the SDK has.
    static func decode(_ body: Any) -> Result<AppActorScreenOutbound, AppActorScreenDecodeFailure> {
        guard let json = body as? String else { return .failure(.notAString) }

        // UTF-8 bytes, not characters: the limit bounds memory, and one emoji
        // is four bytes. Transcoding once avoids walking the string twice.
        let data = Data(json.utf8)
        guard data.count <= AppActorScreenProtocol.maxInboundMessageBytes else {
            return .failure(.tooLarge(bytes: data.count))
        }

        guard let parsed = try? JSONSerialization.jsonObject(with: data)
        else { return .failure(.malformedJSON) }

        guard let envelope = parsed as? [String: Any] else { return .failure(.notAnObject) }

        // Exact, not `as? Int`. `1` and `1.0` are the same version and must
        // both pass; anything that merely *truncates* to a known version must
        // not. `intValue` alone reads 1.5 as 1, and `true` bridges to an
        // NSNumber that reads as 1.
        let number = envelope["protocol_version"] as? NSNumber
        let isBoolean = number.map { CFGetTypeID($0) == CFBooleanGetTypeID() } ?? false
        guard let number, !isBoolean, number.doubleValue == Double(AppActorScreenProtocol.version) else {
            return .failure(.protocolMismatch(received: isBoolean ? nil : number?.intValue))
        }

        guard let rawType = envelope["type"] as? String else { return .failure(.unknownType("")) }
        guard let type = AppActorScreenOutboundType(rawValue: rawType) else {
            return .failure(.unknownType(rawType))
        }

        guard let payload = envelope["payload"] as? [String: Any] else { return .failure(.missingPayload) }

        return .success(
            AppActorScreenOutbound(
                type: type,
                requestId: envelope["requestId"] as? String,
                payload: payload
            )
        )
    }
}

// MARK: - native → web

enum AppActorScreenInboundType: String {
    case initialise = "init"
    case packages
    case purchaseResult
    case restoreResult
    case dismiss
}

struct AppActorScreenInbound {
    let type: AppActorScreenInboundType
    let requestId: String?
    let payload: [String: Any]

    init(_ type: AppActorScreenInboundType, requestId: String? = nil, payload: [String: Any] = [:]) {
        self.type = type
        self.requestId = requestId
        self.payload = payload
    }

    /// `nil` when the payload is not JSON-encodable (a `Date`, a `NaN`), so a
    /// mapping bug is not a crash in the host app.
    func base64() -> String? {
        var envelope: [String: Any] = [
            "protocol_version": AppActorScreenProtocol.version,
            "type": type.rawValue,
            "payload": payload,
        ]
        if let requestId { envelope["requestId"] = requestId }

        // No `.sortedKeys`: nothing reads key order, and the `init` envelope
        // wraps the whole document -- sorting it costs first paint.
        guard JSONSerialization.isValidJSONObject(envelope),
              let data = try? JSONSerialization.data(withJSONObject: envelope)
        else { return nil }

        return data.base64EncodedString()
    }
}

enum AppActorScreenInboundBatch {

    /// Builds the `evaluateJavaScript` source for a batch. Always an array,
    /// even for one message, so the per-element decode guarantee does not
    /// depend on how many happened to be in flight. Unencodable messages are
    /// skipped; `nil` means nothing survived.
    static func javaScript(for messages: [AppActorScreenInbound]) -> String? {
        let encoded = messages.compactMap { $0.base64() }
        guard !encoded.isEmpty else { return nil }
        // Safe unescaped: base64 is A-Za-z0-9+/= -- no quote, backslash or
        // line terminator.
        let list = encoded.map { "\"\($0)\"" }.joined(separator: ",")
        return "\(AppActorScreenProtocol.nativeEntrypoint).receive([\(list)])"
    }
}
