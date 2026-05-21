import Foundation
import AppActor

@MainActor
final class ASAViewModel: ObservableObject {

    @Published var asaState: ASAStateSnapshot?
    @Published var firstInstallOnDevice: Bool = true
    @Published var firstInstallOnAccount: Bool = true

    weak var appState: AppState?

    struct ASAStateSnapshot {
        let isEnabled: Bool
        let attributionCompleted: Bool
        let pendingPurchaseEventCount: Int
        let debugMode: Bool
        let autoTrackPurchases: Bool
        let trackInSandbox: Bool
        let timestamp: Date

        var formattedTime: String {
            Self.formatter.string(from: timestamp)
        }

        private static let formatter: DateFormatter = {
            let f = DateFormatter()
            f.dateFormat = "HH:mm:ss"
            return f
        }()
    }

    func refresh() {
        refreshKeychainState()
        refreshASAState()
    }

    func refreshASAState() {
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
                appState?.logStore.log("[ASA] State snapshot refreshed")
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
                appState?.logStore.log("[ASA] Not configured")
            }
        }
    }

    func refreshKeychainState() {
        firstInstallOnDevice = AppActor.asaFirstInstallOnDevice
        firstInstallOnAccount = AppActor.asaFirstInstallOnAccount
    }
}
