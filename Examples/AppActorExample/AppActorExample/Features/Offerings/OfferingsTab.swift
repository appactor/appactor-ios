import SwiftUI
import AppActor

struct OfferingsScreen: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var vm = OfferingsViewModel()

    var body: some View {
        ExampleScreen(
            title: "Offerings",
            subtitle: "Catalog verisini çek, premium durumunu gör ve package bazında satın alma dene.",
            icon: "tag.fill",
            tint: PRTheme.accent,
            badgeText: vm.offerings == nil ? "Catalog not loaded" : "Catalog loaded",
            badgeColor: vm.offerings == nil ? PRTheme.warning : PRTheme.success
        ) {
            PRCard {
                VStack(alignment: .leading, spacing: PRTheme.spacing) {
                    SectionHeader(
                        "Data & Actions",
                        icon: "square.grid.2x2.fill",
                        color: PRTheme.success,
                        subtitle: "Önce offerings çek, sonra premium kontrol et"
                    )

                    LazyVGrid(
                        columns: [
                            GridItem(.flexible(), spacing: 10),
                            GridItem(.flexible(), spacing: 10),
                        ],
                        spacing: 10
                    ) {
                        ActionTile(
                            title: "Load Offerings",
                            icon: "tag.fill",
                            color: PRTheme.accent,
                            subtitle: "Server catalog + StoreKit ürünleri",
                            action: vm.fetchOfferings
                        )
                        ActionTile(
                            title: "Check Premium",
                            icon: "crown.fill",
                            color: PRTheme.warning,
                            subtitle: "Aktif entitlement durumunu doğrula",
                            action: vm.checkPremium
                        )
                    }
                }
            }

            if let premium = vm.isPremiumStatus {
                PremiumBadge(isPremium: premium)
            }

            if let offerings = vm.offerings {
                offeringsCard(offerings)
            }
        }
        .onAppear { vm.appState = appState }
    }

    @ViewBuilder
    private func offeringsCard(_ offerings: AppActorOfferings) -> some View {
        PRCard {
            VStack(alignment: .leading, spacing: PRTheme.spacing) {
                SectionHeader(
                    "Offerings",
                    icon: "tag.fill",
                    color: PRTheme.accent,
                    subtitle: "Package kartlarında token miktarı da gösteriliyor"
                )

                if offerings.all.isEmpty {
                    EmptyStateView("No offerings available")
                } else {
                    let sorted = offerings.all.values.sorted { $0.id < $1.id }
                    ForEach(sorted, id: \.id) { offering in
                        OfferingCard(offering: offering, onPurchase: vm.purchasePackage)
                    }
                }
            }
        }
    }
}
