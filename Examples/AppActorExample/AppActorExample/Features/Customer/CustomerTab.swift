import SwiftUI
import AppActor

struct CustomerScreen: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var vm = CustomerViewModel()

    var body: some View {
        ExampleScreen(
            title: "Customer",
            subtitle: "Customer info, entitlementlar, subscriptions ve token bakiyesini tek ekranda incele.",
            icon: "person.text.rectangle",
            tint: PRTheme.info,
            badgeText: vm.customer == nil ? "Customer not loaded" : "Customer loaded",
            badgeColor: vm.customer == nil ? PRTheme.warning : PRTheme.success
        ) {
            PRCard {
                VStack(alignment: .leading, spacing: PRTheme.spacing) {
                    SectionHeader(
                        "Customer Fetch",
                        icon: "person.text.rectangle",
                        color: PRTheme.info,
                        subtitle: "Server veya cache kaynaklı en güncel customer snapshot"
                    )

                    ActionTile(
                        title: "Fetch Customer",
                        icon: "person.text.rectangle",
                        color: PRTheme.info,
                        subtitle: "Entitlements, subscriptions ve tokens",
                        action: vm.fetchCustomer
                    )
                }
            }

            if let customer = vm.customer {
                customerCard(customer)
            }
        }
        .onAppear { vm.appState = appState }
    }

    @ViewBuilder
    private func customerCard(_ customer: AppActorCustomerInfo) -> some View {
        PRCard {
            VStack(alignment: .leading, spacing: PRTheme.spacing) {
                SectionHeader(
                    "Customer Info",
                    icon: "person.text.rectangle",
                    color: PRTheme.info,
                    subtitle: "App user kimliği, premium durumu ve purchase geçmişi"
                )

                InfoRow(label: "User", value: customer.appUserId ?? "—", monospaced: true)

                InfoRow(
                    label: "Premium",
                    value: customer.hasActiveEntitlement("premium") ? "Active" : "Inactive",
                    valueColor: customer.hasActiveEntitlement("premium") ? PRTheme.success : PRTheme.error
                )

                if let firstSeen = customer.firstSeenDate {
                    InfoRow(label: "First Seen", value: Self.formatDate(firstSeen))
                }
                if let lastSeen = customer.lastSeenDate {
                    InfoRow(label: "Last Seen", value: Self.formatDate(lastSeen))
                }

                if let tokenBalance = customer.tokenBalance {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("TOKENS")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.secondary)

                        InfoRow(label: "Total", value: Self.formatNumber(tokenBalance.total))
                        InfoRow(label: "Renewable", value: Self.formatNumber(tokenBalance.renewable))
                        InfoRow(label: "Non-Renewable", value: Self.formatNumber(tokenBalance.nonRenewable))
                    }
                } else {
                    InfoRow(label: "Tokens", value: "Disabled")
                }

                // Entitlements
                if !customer.entitlements.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("ENTITLEMENTS")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.secondary)

                        ForEach(customer.entitlements.values.sorted(by: { $0.id < $1.id })) { entitlement in
                            EntitlementRow(entitlement: entitlement)
                        }
                    }
                } else {
                    InfoRow(label: "Entitlements", value: "None")
                }

                // Subscriptions
                if !customer.subscriptions.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("SUBSCRIPTIONS")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.secondary)

                        ForEach(customer.subscriptions.values.sorted(by: { $0.productIdentifier < $1.productIdentifier }), id: \.productIdentifier) { sub in
                            SubscriptionRow(subscription: sub)
                        }
                    }
                } else {
                    InfoRow(label: "Subscriptions", value: "None")
                }

                // Non-Subscriptions (one-time purchases)
                let allNonSubs = customer.nonSubscriptions.values.flatMap { $0 }
                if !allNonSubs.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("NON-SUBSCRIPTIONS")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.secondary)

                        ForEach(Array(allNonSubs.sorted(by: { $0.productIdentifier < $1.productIdentifier }).enumerated()), id: \.offset) { _, item in
                            nonSubscriptionRow(item)
                        }
                    }
                }
            }
        }
    }

    private func nonSubscriptionRow(_ item: AppActorNonSubscription) -> some View {
        HStack(spacing: 10) {
            Image(systemName: item.isRefund == true ? "arrow.uturn.left.circle.fill" : "bag.fill")
                .font(.system(size: 14))
                .foregroundStyle(item.isRefund == true ? PRTheme.error : PRTheme.info)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.productIdentifier)
                    .font(.system(size: 14, weight: .medium))
                if let date = item.purchased {
                    Text(Self.formatDate(date))
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()

            if item.isConsumable == true {
                Text("Consumable")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(PRTheme.info)
            }
            if item.isRefund == true {
                Text("Refunded")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(PRTheme.error)
            }
            if let store = item.store {
                Text(store.rawValue)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            if item.isSandbox == true {
                Text("Sandbox")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(PRTheme.warning)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(PRTheme.rowBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    private static func formatDate(_ date: Date) -> String {
        dateFormatter.string(from: date)
    }

    private static func formatNumber(_ value: Int) -> String {
        value.formatted(.number.grouping(.automatic))
    }
}
