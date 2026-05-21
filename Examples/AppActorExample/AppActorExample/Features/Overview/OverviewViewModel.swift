import Foundation

@MainActor
final class OverviewViewModel: ObservableObject {

    @Published var newAppUserId: String = ""

    weak var appState: AppState?

    init(appState: AppState? = nil) {
        self.appState = appState
    }

    func login() {
        appState?.login(userId: newAppUserId)
        if appState?.errorMessage == nil {
            newAppUserId = ""
        }
    }

    func logout() {
        appState?.logout()
    }

    func resetSDK() {
        appState?.resetSDK()
    }
}
