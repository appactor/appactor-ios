import SwiftUI
import AppActor

struct SDKStateView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var vm: DiagnosticsViewModel

    var body: some View {
        VStack(spacing: PRTheme.spacing) {
            sdkStateCard
            asaQuickCard
        }
    }

    // MARK: - SDK State Card

    private var sdkStateCard: some View {
        PRCard {
            VStack(alignment: .leading, spacing: PRTheme.spacing) {
                HStack {
                    SectionHeader(
                        "SDK State",
                        icon: "cpu",
                        color: PRTheme.info,
                        subtitle: "Anlık runtime snapshot"
                    )
                    Spacer()
                    Button(action: vm.refreshSDKState) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(PRTheme.accent)
                    }
                }

                InfoRow(
                    label: "Configured",
                    value: appState.isConfigured ? "Yes" : "No",
                    valueColor: appState.isConfigured ? PRTheme.success : PRTheme.error
                )
                InfoRow(
                    label: "User ID",
                    value: appState.currentAppUserId,
                    monospaced: true
                )
                InfoRow(
                    label: "Anonymous",
                    value: appState.isAnonymous ? "Yes" : "No",
                    valueColor: appState.isAnonymous ? PRTheme.warning : PRTheme.success
                )

                if let snapshot = vm.sdkState {
                    Text("Last refresh: \(snapshot.formattedTime)")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    // MARK: - ASA Quick Card

    private var asaQuickCard: some View {
        PRCard {
            VStack(alignment: .leading, spacing: PRTheme.spacing) {
                HStack {
                    SectionHeader(
                        "ASA Attribution",
                        icon: "megaphone.fill",
                        color: PRTheme.accent,
                        subtitle: "ASA screen için kısa özet"
                    )
                    Spacer()
                    Button(action: vm.refreshASAState) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(PRTheme.accent)
                    }
                }

                if let asa = vm.asaState {
                    InfoRow(
                        label: "Enabled",
                        value: asa.isEnabled ? "Yes" : "No",
                        valueColor: asa.isEnabled ? PRTheme.success : PRTheme.error
                    )
                    if asa.isEnabled {
                        InfoRow(
                            label: "Attribution",
                            value: asa.attributionCompleted ? "Completed" : "Pending",
                            valueColor: asa.attributionCompleted ? PRTheme.success : PRTheme.warning
                        )
                        InfoRow(
                            label: "Pending Events",
                            value: "\(asa.pendingPurchaseEventCount)",
                            valueColor: asa.pendingPurchaseEventCount > 0 ? PRTheme.warning : PRTheme.success
                        )
                    }
                    Text("See ASA tab for full details")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                } else {
                    Text("Tap refresh to load ASA state")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
