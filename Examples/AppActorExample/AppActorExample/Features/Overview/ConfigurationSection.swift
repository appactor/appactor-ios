import SwiftUI

struct ConfigurationSection: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var vm: OverviewViewModel

    var body: some View {
        PRCard {
            VStack(alignment: .leading, spacing: PRTheme.spacing) {
                HStack {
                    SectionHeader(
                        "Configuration",
                        icon: "gearshape.fill",
                        subtitle: "SDK reset ve bootstrap durumunu kontrol et"
                    )
                    Spacer()
                    StatusBadge(
                        text: appState.isConfigured ? "Configured" : "Connecting...",
                        color: appState.isConfigured ? PRTheme.success : PRTheme.warning
                    )
                }

                Button(action: vm.resetSDK) {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 13))
                        Text("Reset SDK")
                            .font(.system(size: 14, weight: .medium))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .background(PRTheme.error.opacity(0.1))
                    .foregroundStyle(PRTheme.error)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
    }
}
