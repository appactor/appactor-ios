import SwiftUI

struct DiagnosticsScreen: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var vm = DiagnosticsViewModel()

    var body: some View {
        ExampleScreen(
            title: "Diagnostics",
            subtitle: "Console logları ve SDK snapshot durumunu aynı akışta incele.",
            icon: "stethoscope",
            tint: PRTheme.warning,
            badgeText: appState.isConfigured ? "Live diagnostics" : "SDK not ready",
            badgeColor: appState.isConfigured ? PRTheme.success : PRTheme.warning
        ) {
            ConsoleView()
            SDKStateView(vm: vm)
        }
        .onAppear {
            vm.appState = appState
            vm.refreshSDKState()
        }
    }
}
