import SwiftUI

struct MainTabView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        TabView {
            PaymentTab()
                .tabItem {
                    Label("Payments", systemImage: "creditcard.fill")
                }

            NavigationView {
                ASAScreen()
            }
            .navigationViewStyle(.stack)
            .tabItem {
                Label("Attribution", systemImage: "megaphone.fill")
            }

            NavigationView {
                RemoteConfigScreen()
            }
            .navigationViewStyle(.stack)
            .tabItem {
                Label("Configs", systemImage: "slider.horizontal.3")
            }

            NavigationView {
                ExperimentsScreen()
            }
            .navigationViewStyle(.stack)
            .tabItem {
                Label("Experiments", systemImage: "flask.fill")
            }
        }
        .tint(PRTheme.accent)
        .background(PRTheme.screenBackground)
        .alert("Error", isPresented: .init(
            get: { appState.errorMessage != nil },
            set: { if !$0 { appState.errorMessage = nil } }
        )) {
            Button("OK") { appState.errorMessage = nil }
        } message: {
            Text(appState.errorMessage ?? "")
        }
        .overlay {
            if appState.isLoading {
                LoadingOverlay()
            }
        }
        .animation(.spring(response: 0.3), value: appState.isLoading)
    }
}
