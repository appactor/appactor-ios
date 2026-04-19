import Foundation
import AppActor

/// Encodable wrapper for `AppActorASADiagnostics`.
struct PluginASADiagnostics: Encodable, Sendable {
    let attributionCompleted: Bool
    let pendingPurchaseEventCount: Int
    let debugMode: Bool
    let autoTrackPurchases: Bool
    let trackInSandbox: Bool

    init(from diagnostics: AppActorASADiagnostics) {
        self.attributionCompleted = diagnostics.attributionCompleted
        self.pendingPurchaseEventCount = diagnostics.pendingPurchaseEventCount
        self.debugMode = diagnostics.debugMode
        self.autoTrackPurchases = diagnostics.autoTrackPurchases
        self.trackInSandbox = diagnostics.trackInSandbox
    }
}
