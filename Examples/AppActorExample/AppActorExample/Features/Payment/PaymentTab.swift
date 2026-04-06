import SwiftUI

struct PaymentTab: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        NavigationView {
            ExampleScreen(
                title: "AppActor Example",
                subtitle: "SDK akışlarını tek yerden dene: kurulum, offerings, customer, restore ve diagnostics.",
                icon: "sparkles.rectangle.stack.fill",
                tint: PRTheme.accent,
                badgeText: appState.isConfigured ? "SDK ready" : "Configuring SDK",
                badgeColor: appState.isConfigured ? PRTheme.success : PRTheme.warning
            ) {
                summaryCard
                menuCard
            }
        }
        .navigationViewStyle(.stack)
    }

    private var summaryCard: some View {
        PRCard {
            VStack(alignment: .leading, spacing: PRTheme.spacing) {
                SectionHeader(
                    "Session Snapshot",
                    icon: "waveform.path.ecg.rectangle",
                    color: PRTheme.info,
                    subtitle: "Hızlı durum bilgisi"
                )

                HStack(spacing: 12) {
                    summaryMetric(
                        title: "SDK",
                        value: appState.isConfigured ? "Ready" : "Booting",
                        color: appState.isConfigured ? PRTheme.success : PRTheme.warning
                    )
                    summaryMetric(
                        title: "Identity",
                        value: appState.isAnonymous ? "Anon" : "Known",
                        color: appState.isAnonymous ? PRTheme.warning : PRTheme.info
                    )
                    summaryMetric(
                        title: "User ID",
                        value: appState.currentAppUserId == "-" ? "Waiting" : "Set",
                        color: appState.currentAppUserId == "-" ? .secondary : PRTheme.accent
                    )
                }
            }
        }
    }

    private var menuCard: some View {
        PRCard {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(
                    "Payment Tools",
                    icon: "square.grid.2x2.fill",
                    color: PRTheme.accent,
                    subtitle: "Sık kullanılan ekranlar"
                )

                NavigationLink {
                    OverviewScreen()
                } label: {
                    PaymentMenuItem(
                        title: "Overview",
                        subtitle: "Configuration, identity ve restore akışı",
                        icon: "house.fill",
                        color: PRTheme.accent
                    )
                }

                NavigationLink {
                    OfferingsScreen()
                } label: {
                    PaymentMenuItem(
                        title: "Offerings",
                        subtitle: "Ürünleri gör, token miktarını kontrol et, satın al",
                        icon: "tag.fill",
                        color: PRTheme.success
                    )
                }

                NavigationLink {
                    CustomerScreen()
                } label: {
                    PaymentMenuItem(
                        title: "Customer",
                        subtitle: "Entitlements, subscriptions ve token bakiyesi",
                        icon: "person.fill",
                        color: PRTheme.info
                    )
                }

                NavigationLink {
                    DiagnosticsScreen()
                } label: {
                    PaymentMenuItem(
                        title: "Diagnostics",
                        subtitle: "Console, SDK state ve receipt queue",
                        icon: "stethoscope",
                        color: PRTheme.warning
                    )
                }
            }
        }
    }

    private func summaryMetric(title: String, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 17, weight: .bold, design: .rounded))
                .foregroundStyle(PRTheme.ink)
            Capsule()
                .fill(color)
                .frame(width: 34, height: 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(PRTheme.rowBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

// MARK: - Menu Item

private struct PaymentMenuItem: View {
    let title: String
    let subtitle: String
    let icon: String
    let color: Color

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(color.opacity(0.12))
                    .frame(width: 48, height: 48)
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(color)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(PRTheme.ink)
                Text(subtitle)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            ZStack {
                Circle()
                    .fill(color.opacity(0.12))
                    .frame(width: 28, height: 28)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(color)
            }
        }
        .padding(16)
        .background(PRTheme.rowBackground)
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.white.opacity(0.7), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}
