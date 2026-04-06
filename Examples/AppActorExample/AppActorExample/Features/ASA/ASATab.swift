import SwiftUI
import AppActor

struct ASAScreen: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var vm = ASAViewModel()

    var body: some View {
        ExampleScreen(
            title: "ASA Attribution",
            subtitle: "Apple Search Ads state, keychain flagleri ve pending sync durumunu izle.",
            icon: "megaphone.fill",
            tint: PRTheme.accent,
            badgeText: vm.asaState?.isEnabled == true ? "ASA enabled" : "ASA disabled",
            badgeColor: vm.asaState?.isEnabled == true ? PRTheme.success : PRTheme.warning
        ) {
            asaStatusCard
            keychainCard
            purchaseEventsCard
            userIdChangeCard
        }
        .onAppear {
            vm.appState = appState
            vm.refresh()
        }
    }

    // MARK: - ASA Status Card

    private var asaStatusCard: some View {
        PRCard {
            VStack(alignment: .leading, spacing: PRTheme.spacing) {
                HStack {
                    SectionHeader(
                        "Attribution Status",
                        icon: "megaphone.fill",
                        color: PRTheme.accent,
                        subtitle: "Current attribution pipeline snapshot"
                    )
                    Spacer()
                    Button(action: vm.refresh) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(PRTheme.accent)
                    }
                }

                if let asa = vm.asaState {
                    InfoRow(
                        label: "ASA Enabled",
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
                            label: "Auto-Track Purchases",
                            value: asa.autoTrackPurchases ? "On" : "Off",
                            valueColor: asa.autoTrackPurchases ? PRTheme.success : .secondary
                        )

                        InfoRow(
                            label: "Debug Mode",
                            value: asa.debugMode ? "On" : "Off",
                            valueColor: asa.debugMode ? PRTheme.info : .secondary
                        )
                    }

                    Text("Updated: \(asa.formattedTime)")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                } else {
                    HStack {
                        Spacer()
                        ProgressView()
                            .controlSize(.small)
                        Text("Loading...")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.vertical, 8)
                }
            }
        }
    }

    // MARK: - Keychain Card

    private var keychainCard: some View {
        PRCard {
            VStack(alignment: .leading, spacing: PRTheme.spacing) {
                SectionHeader(
                    "Keychain Flags",
                    icon: "key.fill",
                    color: PRTheme.warning,
                    subtitle: "Install ve account bazlı ASA marker'ları"
                )

                InfoRow(
                    label: "First Install (Device)",
                    value: vm.firstInstallOnDevice ? "Yes" : "No",
                    valueColor: vm.firstInstallOnDevice ? PRTheme.success : .secondary
                )

                InfoRow(
                    label: "First Install (Account)",
                    value: vm.firstInstallOnAccount ? "Yes" : "No",
                    valueColor: vm.firstInstallOnAccount ? PRTheme.success : .secondary
                )

                Text("Keychain persists across uninstall/reinstall.\niCloud flag syncs across devices on the same Apple account.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 2)
            }
        }
    }

    // MARK: - Purchase Events Card

    private var purchaseEventsCard: some View {
        PRCard {
            VStack(alignment: .leading, spacing: PRTheme.spacing) {
                SectionHeader(
                    "Purchase Events",
                    icon: "cart.fill",
                    color: PRTheme.success,
                    subtitle: "Pending post queue durumu"
                )

                if let asa = vm.asaState, asa.isEnabled {
                    InfoRow(
                        label: "Pending Events",
                        value: "\(asa.pendingPurchaseEventCount)",
                        valueColor: asa.pendingPurchaseEventCount > 0 ? PRTheme.warning : PRTheme.success
                    )

                    Text(asa.pendingPurchaseEventCount > 0
                         ? "Events will be flushed on next bootstrap or foreground."
                         : "All purchase events have been synced.")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                } else {
                    Text("ASA not configured")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - User ID Change Card

    private var userIdChangeCard: some View {
        PRCard {
            VStack(alignment: .leading, spacing: PRTheme.spacing) {
                SectionHeader(
                    "User ID Sync",
                    icon: "person.2.fill",
                    color: PRTheme.info,
                    subtitle: "ASA tarafına bekleyen user mapping değişiklikleri"
                )

                if let asa = vm.asaState, asa.isEnabled {
                    InfoRow(
                        label: "Pending Change",
                        value: asa.hasPendingUserIdChange ? "Yes" : "None",
                        valueColor: asa.hasPendingUserIdChange ? PRTheme.warning : PRTheme.success
                    )

                    if asa.hasPendingUserIdChange {
                        InfoRow(
                            label: "Old → New",
                            value: "\(asa.pendingOldUserId ?? "?") → \(asa.pendingNewUserId ?? "?")",
                            monospaced: true,
                            valueColor: PRTheme.warning
                        )
                    }

                    Text("User ID changes are synced before attribution on each bootstrap.")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                } else {
                    Text("ASA not configured")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
