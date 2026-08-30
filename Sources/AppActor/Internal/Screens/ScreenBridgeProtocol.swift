import Foundation

/// Wire format for the server-driven screen bridge.
///
/// This is the Swift half of a **frozen** contract. Its counterpart lives in
/// `appactor-screens/packages/schema/src/spec/bridge.ts`, and the Android SDK
/// speaks the same one. Renaming anything here is a protocol bump, not a
/// refactor: documents already published name these fields.
///
/// The transport is deliberately asymmetric, and both directions are load
/// bearing:
///
/// - **web → native** arrives as a single JSON string through
///   `WKScriptMessageHandler`. One message per call, so a malformed message
///   can only lose itself.
/// - **native → web** goes out as base64 through `__appactor.receive(...)`.
///   Base64 because interpolating raw JSON into `evaluateJavaScript` breaks on
///   quotes, newlines and astral-plane characters — a paywall with a `"` in a
///   price string is not an edge case. Base64 output is `A-Za-z0-9+/=` only, so
///   the result is safe to place inside a JS string literal with no escaping.
///
/// A batch is sent as a JSON **array** of base64 strings, and the runtime
/// decodes each element inside its own `try`/`catch`. That is the entire point:
/// one unrecognised message in a batch must not take the `purchaseResult`
/// sitting next to it down with it.
enum AppActorScreenProtocol {

    /// Carried on every envelope, in **both** directions. A mismatch is a drop,
    /// never a best-effort interpretation — guessing what a field means in a
    /// version you do not know is how silent corruption starts.
    static let version = 1

    /// The global the runtime installs for native to call into.
    static let nativeEntrypoint = "__appactor"

    /// `WKScriptMessageHandler` name the runtime posts to.
    static let webChannel = "appactorScreens"

    /// The runtime raises `slow_first_paint` on its own after this long. Native
    /// keeps a separate watchdog for the case the runtime never runs at all —
    /// a parse failure, a dead channel — where nothing web-side is left to fire.
    static let readyWatchdog: TimeInterval = 2.0

    /// Upper bound on a single message from the web side. The runtime already
    /// bounds what it sends; this bounds what a compromised or wedged page
    /// could send.
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
    /// Required on `purchase` and `restore` (day-1 rule #14). Without it a
    /// result cannot be tied to the request that asked for it, and the runtime
    /// answers a mismatched result with `unmatched_purchase_result`.
    let requestId: String?
    let payload: [String: Any]

    func string(_ key: String) -> String? {
        payload[key] as? String
    }
}

/// Why a message was dropped. Kept specific because these are the only
/// symptoms available when the bridge misbehaves in the field — "dropped a
/// message" in a log is not something anyone can act on.
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

    /// Parses one `postMessage` body.
    ///
    /// Never throws and never traps: this runs on whatever the page chose to
    /// send, and the page is the least trustworthy input the SDK has.
    static func decode(_ body: Any) -> Result<AppActorScreenOutbound, AppActorScreenDecodeFailure> {
        guard let json = body as? String else { return .failure(.notAString) }

        // Count UTF-8 bytes, not characters: the limit exists to bound memory,
        // and one emoji is four bytes.
        let byteCount = json.utf8.count
        guard byteCount <= AppActorScreenProtocol.maxInboundMessageBytes else {
            return .failure(.tooLarge(bytes: byteCount))
        }

        guard let data = json.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data)
        else { return .failure(.malformedJSON) }

        guard let envelope = parsed as? [String: Any] else { return .failure(.notAnObject) }

        // `as? Int` on an NSNumber holding a double would succeed for 1.0, so
        // read it as a number first and compare exactly.
        let received = (envelope["protocol_version"] as? NSNumber)?.intValue
        guard received == AppActorScreenProtocol.version else {
            return .failure(.protocolMismatch(received: received))
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

    /// `nil` when the payload is not JSON-encodable — a `Date`, a `NaN`
    /// slipped in somewhere. Returning `nil` rather than trapping keeps a
    /// mapping bug from being a crash in the host app. (`Decimal` is fine: it
    /// bridges to `NSNumber`.)
    func base64() -> String? {
        var envelope: [String: Any] = [
            "protocol_version": AppActorScreenProtocol.version,
            "type": type.rawValue,
            "payload": payload,
        ]
        if let requestId { envelope["requestId"] = requestId }

        guard JSONSerialization.isValidJSONObject(envelope),
              let data = try? JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])
        else { return nil }

        return data.base64EncodedString()
    }
}

enum AppActorScreenInboundBatch {

    /// Builds the `evaluateJavaScript` source for a batch.
    ///
    /// Always an array, even for one message, so the runtime takes its
    /// per-element decode path every time — the guarantee that a bad message
    /// cannot take a good one with it should not depend on how many happened to
    /// be in flight.
    ///
    /// Messages that fail to encode are skipped rather than aborting the batch;
    /// `nil` comes back only when nothing survived, so the caller can log that
    /// it sent nothing instead of silently evaluating `receive([])`.
    static func javaScript(for messages: [AppActorScreenInbound]) -> String? {
        let encoded = messages.compactMap { $0.base64() }
        guard !encoded.isEmpty else { return nil }
        // Safe to interpolate unquoted-escaped: base64 alphabet is A-Za-z0-9+/=
        // and contains neither a quote, a backslash, nor a line terminator.
        let list = encoded.map { "\"\($0)\"" }.joined(separator: ",")
        return "\(AppActorScreenProtocol.nativeEntrypoint).receive([\(list)])"
    }
}
