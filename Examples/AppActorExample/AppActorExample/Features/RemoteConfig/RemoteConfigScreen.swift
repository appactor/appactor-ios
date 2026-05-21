import SwiftUI
import AppActor

struct RemoteConfigScreen: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var vm = RemoteConfigViewModel()

    var body: some View {
        ExampleScreen(
            title: "Remote Config",
            subtitle: "Server config verilerini çek, son yükleme zamanını gör ve değerleri hızlıca tara.",
            icon: "slider.horizontal.3",
            tint: PRTheme.accent,
            badgeText: vm.configs == nil ? "Configs not loaded" : "Configs loaded",
            badgeColor: vm.configs == nil ? PRTheme.warning : PRTheme.success
        ) {
            PRCard {
                VStack(alignment: .leading, spacing: PRTheme.spacing) {
                    SectionHeader(
                        "Actions",
                        icon: "square.grid.2x2.fill",
                        color: PRTheme.success,
                        subtitle: "Remote config endpoint'ini elle tetikle"
                    )

                    ActionTile(
                        title: "Load Configs",
                        icon: "arrow.down.circle.fill",
                        color: PRTheme.accent,
                        subtitle: "Fetch ve cache edilen config öğeleri",
                        action: vm.loadConfigs
                    )
                }
            }

            if let date = vm.lastLoadDate {
                PRCard {
                    VStack(alignment: .leading, spacing: 8) {
                        SectionHeader("Status", icon: "info.circle.fill", color: PRTheme.info)
                        InfoRow(
                            label: "Items",
                            value: "\(vm.configs?.items.count ?? 0)"
                        )
                        InfoRow(
                            label: "Last Load",
                            value: date.formatted(date: .omitted, time: .standard)
                        )
                    }
                }
            }

            if let configs = vm.configs {
                PRCard {
                    VStack(alignment: .leading, spacing: PRTheme.spacing) {
                        SectionHeader(
                            "Remote Configs (\(configs.items.count))",
                            icon: "slider.horizontal.3",
                            color: PRTheme.accent,
                            subtitle: "Anahtar, değer ve rule çıktıları"
                        )

                        if configs.items.isEmpty {
                            EmptyStateView("No remote configs available")
                        } else {
                            ForEach(configs.items, id: \.key) { item in
                                ConfigItemRow(item: item)
                            }
                        }
                    }
                }
            }
        }
        .onAppear { vm.appState = appState }
    }
}
