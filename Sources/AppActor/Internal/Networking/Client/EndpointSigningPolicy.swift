import Foundation

/// Determines whether an endpoint requires a nonce for response signing.
///
/// Nonce-required endpoints get per-request replay protection.
/// Nonce-free endpoints get salt-based signing, enabling CDN caching.
enum EndpointSigningPolicy {
    case nonceRequired    // identify, login, logout, customer, receipt, restore, experiments
    case nonceFree        // offerings, remote-config

    /// Returns the policy for a given request path.
    static func forPath(_ path: String) -> EndpointSigningPolicy {
        if path.hasPrefix("/v1/payment/offerings") || path.hasPrefix("/v1/remote-config") {
            return .nonceFree
        }
        return .nonceRequired
    }

    var needsNonce: Bool { self == .nonceRequired }
}
