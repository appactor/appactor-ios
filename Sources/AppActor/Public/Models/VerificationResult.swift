import Foundation

/// The result of verifying a server response's cryptographic signature.
///
/// Exposed on cache entries and optionally on server-sourced models
/// so the app can react to verification status.
public enum AppActorVerificationResult: String, Sendable, Codable, Equatable {
    /// Verification was not performed (signing disabled or endpoint doesn't support it).
    case notRequested
    /// Response signature was successfully verified by the server.
    case verified
    /// Entitlements were verified on-device via StoreKit 2 (offline / server unreachable).
    case verifiedOnDevice
    /// Response signature verification failed — possible tampering.
    case failed

    /// Whether the result represents a trusted verification (server or device).
    public var isVerified: Bool {
        self == .verified || self == .verifiedOnDevice
    }

    /// Maps a `signatureVerified` bool to the appropriate result.
    /// `true` → `.verified`, `false` → `.notRequested` (transitional unsigned, NOT a failure).
    static func from(signatureVerified: Bool) -> AppActorVerificationResult {
        signatureVerified ? .verified : .notRequested
    }
}
