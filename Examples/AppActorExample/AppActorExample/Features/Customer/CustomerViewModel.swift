import Foundation
import AppActor

@MainActor
final class CustomerViewModel: ObservableObject {

    @Published var customer: AppActorCustomerInfo?

    weak var appState: AppState?

    init(appState: AppState? = nil) {
        self.appState = appState
    }

    func fetchCustomer() {
        guard let appState, appState.ensureConfigured() else { return }
        appState.isLoading = true
        Task {
            do {
                customer = try await AppActor.shared.getCustomerInfo()
                appState.logStore.log("getCustomerInfo() fetched")
                appState.refreshState()
            } catch {
                appState.showError(error)
            }
            appState.isLoading = false
        }
    }
}
