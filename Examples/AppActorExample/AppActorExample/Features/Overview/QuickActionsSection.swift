import SwiftUI
import AppActor

struct QuickActionsSection: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        PRCard {
            VStack(alignment: .leading, spacing: PRTheme.spacing) {
                SectionHeader(
                    "Quick Actions",
                    icon: "bolt.fill",
                    color: PRTheme.warning,
                    subtitle: "Test sırasında en sık kullanılan recovery adımları"
                )

                ActionTile(
                    title: "Restore",
                    icon: "arrow.clockwise.circle.fill",
                    color: PRTheme.success,
                    subtitle: "Restore purchases ve state refresh",
                    action: restorePurchases
                )
            }
        }
    }

    private func restorePurchases() {
        guard appState.ensureConfigured() else { return }
        appState.isLoading = true
        Task {
            do {
                try await AppActor.shared.restorePurchases()
                appState.logStore.log("restorePurchases() succeeded")
                appState.refreshState()
            } catch {
                appState.showError(error)
            }
            appState.isLoading = false
        }
    }

}
