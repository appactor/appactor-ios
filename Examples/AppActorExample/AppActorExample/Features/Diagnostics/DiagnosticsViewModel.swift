import Foundation
import AppActor

@MainActor
final class DiagnosticsViewModel: ObservableObject {

    @Published var sdkState: SDKStateSnapshot?
    @Published var asaState: ASAStateSnapshot?
    weak var appState: AppState?

    init(appState: AppState? = nil) {
        self.appState = appState
    }

    // MARK: - Snapshots

    struct SDKStateSnapshot {
        let isConfigured: Bool
        let currentAppUserId: String
        let isAnonymous: Bool
        let timestamp: Date

        var formattedTime: String { Self.fmt.string(from: timestamp) }
        private static let fmt: DateFormatter = {
            let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"; return f
        }()
    }

    struct ASAStateSnapshot {
        let isEnabled: Bool
        let attributionCompleted: Bool
        let pendingPurchaseEventCount: Int
        let debugMode: Bool
        let autoTrackPurchases: Bool
        let trackInSandbox: Bool
        let timestamp: Date

        var formattedTime: String { Self.fmt.string(from: timestamp) }
        private static let fmt: DateFormatter = {
            let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"; return f
        }()
    }

    // MARK: - Refresh Actions

    func refreshSDKState() {
        guard let appState else { return }
        sdkState = SDKStateSnapshot(
            isConfigured: appState.isConfigured,
            currentAppUserId: appState.currentAppUserId,
            isAnonymous: appState.isAnonymous,
            timestamp: Date()
        )
        appState.logStore.log("🔄 SDK state snapshot taken")
    }

    func refreshASAState() {
        guard let appState else { return }
        Task {
            if let diag = await AppActor.shared.asaDiagnostics() {
                asaState = ASAStateSnapshot(
                    isEnabled: true,
                    attributionCompleted: diag.attributionCompleted,
                    pendingPurchaseEventCount: diag.pendingPurchaseEventCount,
                    debugMode: diag.debugMode,
                    autoTrackPurchases: diag.autoTrackPurchases,
                    trackInSandbox: diag.trackInSandbox,
                    timestamp: Date()
                )
                appState.logStore.log("🔄 ASA state snapshot taken")
            } else {
                asaState = ASAStateSnapshot(
                    isEnabled: false,
                    attributionCompleted: false,
                    pendingPurchaseEventCount: 0,
                    debugMode: false,
                    autoTrackPurchases: false,
                    trackInSandbox: false,
                    timestamp: Date()
                )
                appState.logStore.log("ASA not configured")
            }
        }
    }

}
