import SwiftUI
import AppIntents

@main
struct AppActorExampleApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            Group {
                if appState.isConfigured || appState.errorMessage != nil {
                    MainTabView()
                } else {
                    SplashView()
                }
            }
            .environmentObject(appState)
            .task { appState.configureIfNeeded() }
            .preferredColorScheme(.light)
        }
    }
}
