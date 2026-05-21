import Foundation

// MARK: - Diagnostics Snapshot

/// A point-in-time snapshot of ASA (Apple Search Ads) state.
///
/// Returned by ``AppActor/asaDiagnostics()`` for debug/support screens.
///
/// ```swift
/// if let diag = await AppActor.shared.asaDiagnostics() {
///     print("Attribution: \(diag.attributionCompleted)")
///     print("Pending events: \(diag.pendingPurchaseEventCount)")
/// }
/// ```
public struct AppActorASADiagnostics: Sendable {
    /// Whether ASA attribution has been completed (or permanently failed) for this install.
    public let attributionCompleted: Bool

    /// Number of purchase events waiting to be flushed to the server.
    public let pendingPurchaseEventCount: Int

    /// Whether ASA debug mode is enabled.
    public let debugMode: Bool

    /// Whether auto-tracking of purchases is enabled.
    public let autoTrackPurchases: Bool

    /// Whether sandbox/StoreKit Testing transactions are tracked.
    public let trackInSandbox: Bool
}
