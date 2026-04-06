import SwiftUI
import AppActor

struct SubscriptionRow: View {
    let subscription: AppActorSubscriptionInfo
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header row (always visible)
            Button { withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() } } label: {
                HStack(spacing: 10) {
                    Image(systemName: subscription.isActive
                        ? "arrow.triangle.2.circlepath.circle.fill"
                        : "arrow.triangle.2.circlepath.circle")
                        .font(.system(size: 14))
                        .foregroundStyle(subscription.isActive ? PRTheme.success : PRTheme.error)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(subscription.productIdentifier)
                            .font(.system(size: 14, weight: .medium))
                        if let period = subscription.periodType {
                            Text(period.rawValue)
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                        }
                    }

                    Spacer()

                    VStack(alignment: .trailing, spacing: 2) {
                        Text(subscription.isActive ? "Active" : "Expired")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(subscription.isActive ? PRTheme.success : PRTheme.error)
                        if let store = subscription.store {
                            Text(store.rawValue)
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                        }
                    }

                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            // Detail rows (expanded)
            if isExpanded {
                VStack(spacing: 0) {
                    Divider().padding(.horizontal, 12)

                    VStack(alignment: .leading, spacing: 6) {
                        if let purchased = subscription.purchased {
                            detailRow("Purchased", value: Self.formatDate(purchased))
                        }
                        if let expires = subscription.expires {
                            detailRow("Expires", value: Self.formatDate(expires))
                        }
                        if let renewed = subscription.renewed {
                            detailRow("Renewed", value: Self.formatDate(renewed))
                        }
                        if let gracePeriod = subscription.gracePeriodExpires {
                            detailRow("Grace Period", value: Self.formatDate(gracePeriod), color: PRTheme.warning)
                        }
                        if let unsub = subscription.unsubscribeDetected {
                            detailRow("Unsubscribed", value: Self.formatDate(unsub), color: PRTheme.warning)
                        }
                        if let reason = subscription.cancellationReason {
                            detailRow("Cancellation", value: reason.rawValue, color: PRTheme.error)
                        }
                        if let originalTxn = subscription.originalTransactionId {
                            detailRow("Original Txn", value: originalTxn)
                        }
                        if let latestTxn = subscription.latestTransactionId {
                            detailRow("Latest Txn", value: latestTxn)
                        }
                        if let offerType = subscription.activePromotionalOfferType {
                            detailRow("Promo Type", value: offerType)
                        }
                        if let offerId = subscription.activePromotionalOfferId {
                            detailRow("Promo ID", value: offerId)
                        }
                        if let sandbox = subscription.isSandbox {
                            detailRow("Sandbox", value: sandbox ? "Yes" : "No")
                        }
                        detailRow("Auto-Renew", value: subscription.willRenew ? "On" : "Off",
                                  color: subscription.willRenew ? PRTheme.success : PRTheme.warning)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
            }
        }
        .background(Color(.tertiarySystemFill))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func detailRow(_ label: String, value: String, color: Color = .secondary) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(color)
                .lineLimit(1)
        }
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
}
