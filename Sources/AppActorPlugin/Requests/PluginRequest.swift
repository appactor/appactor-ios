import Foundation

/// Protocol for all cross-platform request handlers.
///
/// Each struct conforming to this protocol represents a single JSON-RPC method.
/// The `method` string is the key used by Flutter/RN to invoke the native call.
/// Custom requests should return ``AppActorPluginResult/encoding(_:)``,
/// ``AppActorPluginResult/successVoid``, or `.error(AppActorPluginError(...))`.
public protocol AppActorPluginRequest: Decodable, Sendable {
    /// JSON-RPC method name (e.g. "get_customer_info").
    static var method: String { get }

    /// Executes the request against the AppActor SDK.
    @MainActor
    func execute() async throws -> AppActorPluginResult
}
