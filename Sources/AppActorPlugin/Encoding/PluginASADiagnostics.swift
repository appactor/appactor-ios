import Foundation
import AppActor

/// Encodable wrapper for `AppActorASADiagnostics`.
struct PluginASADiagnostics: Encodable, Sendable {
    struct PendingUserIdChange: Encodable, Sendable {
        let oldUserId: String
        let newUserId: String

        init(from change: AppActorASADiagnostics.PendingUserIdChange) {
            self.oldUserId = change.oldUserId
            self.newUserId = change.newUserId
        }
    }

    let attributionCompleted: Bool
    let pendingPurchaseEventCount: Int
    let hasPendingUserIdChange: Bool
    let pendingUserIdChange: PendingUserIdChange?
    let debugMode: Bool
    let autoTrackPurchases: Bool
    let trackInSandbox: Bool

    init(from diagnostics: AppActorASADiagnostics) {
        self.attributionCompleted = diagnostics.attributionCompleted
        self.pendingPurchaseEventCount = diagnostics.pendingPurchaseEventCount
        self.hasPendingUserIdChange = diagnostics.hasPendingUserIdChange
        self.pendingUserIdChange = diagnostics.pendingUserIdChange.map { PendingUserIdChange(from: $0) }
        self.debugMode = diagnostics.debugMode
        self.autoTrackPurchases = diagnostics.autoTrackPurchases
        self.trackInSandbox = diagnostics.trackInSandbox
    }
}
