import SwiftUI

struct OverviewScreen: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var vm = OverviewViewModel()

    var body: some View {
        ExampleScreen(
            title: "Overview",
            subtitle: "SDK kurulumu, kullanıcı kimliği ve restore akışını tek ekranda yönet.",
            icon: "house.fill",
            tint: PRTheme.accent,
            badgeText: appState.isConfigured ? "Configured" : "Waiting for setup",
            badgeColor: appState.isConfigured ? PRTheme.success : PRTheme.warning
        ) {
            ConfigurationSection(vm: vm)
            IdentitySection(vm: vm)
            QuickActionsSection()
        }
        .onAppear { vm.appState = appState }
    }
}
