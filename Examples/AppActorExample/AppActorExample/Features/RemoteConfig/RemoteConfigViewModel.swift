import Foundation
import AppActor

@MainActor
final class RemoteConfigViewModel: ObservableObject {

    @Published var configs: AppActorRemoteConfigs?
    @Published var lastLoadDate: Date?

    weak var appState: AppState?

    init(appState: AppState? = nil) {
        self.appState = appState
    }

    func loadConfigs() {
        guard let appState, appState.ensureConfigured() else { return }
        appState.isLoading = true
        Task {
            do {
                configs = try await AppActor.shared.getRemoteConfigs()
                lastLoadDate = Date()
                appState.logStore.log("getRemoteConfigs() fetched \(configs?.items.count ?? 0) items")
                appState.refreshState()
            } catch {
                appState.showError(error)
            }
            appState.isLoading = false
        }
    }
}
