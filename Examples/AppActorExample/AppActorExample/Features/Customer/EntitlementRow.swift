import SwiftUI
import AppActor

struct EntitlementRow: View {
    let entitlement: AppActorEntitlementInfo
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header row (always visible)
            Button { withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() } } label: {
                HStack(spacing: 10) {
                    Image(systemName: entitlement.isActive ? "checkmark.seal.fill" : "xmark.seal")
                        .font(.system(size: 14))
                        .foregroundStyle(entitlement.isActive ? PRTheme.success : PRTheme.error)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(entitlement.id)
                            .font(.system(size: 14, weight: .medium))
                        if let productId = entitlement.productID {
                            Text(productId)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.tertiary)
                        }
                    }

                    Spacer()

                    Text(entitlement.isActive ? "Active" : "Expired")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(entitlement.isActive ? PRTheme.success : PRTheme.error)

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
                        if let starts = entitlement.startsAt {
                            detailRow("Starts", value: Self.formatDate(starts))
                        }
                        if let expires = entitlement.expirationDate {
                            detailRow("Expires", value: Self.formatDate(expires))
                        }
                        if let renewed = entitlement.renewedAt {
                            detailRow("Renewed", value: Self.formatDate(renewed))
                        }
                        if let gracePeriod = entitlement.gracePeriodExpiresAt {
                            detailRow("Grace Period", value: Self.formatDate(gracePeriod), color: PRTheme.warning)
                        }
                        if let billing = entitlement.billingIssueDetectedAt {
                            detailRow("Billing Issue", value: Self.formatDate(billing), color: PRTheme.error)
                        }
                        if let unsub = entitlement.unsubscribeDetectedAt {
                            detailRow("Unsubscribed", value: Self.formatDate(unsub), color: PRTheme.warning)
                        }
                        if let reason = entitlement.cancellationReason {
                            detailRow("Cancellation", value: reason.rawValue, color: PRTheme.error)
                        }
                        if let offerType = entitlement.activePromotionalOfferType {
                            detailRow("Promo Type", value: offerType)
                        }
                        if let offerId = entitlement.activePromotionalOfferId {
                            detailRow("Promo ID", value: offerId)
                        }
                        if let store = entitlement.store {
                            detailRow("Store", value: store.rawValue)
                        }
                        if let sandbox = entitlement.isSandbox {
                            detailRow("Sandbox", value: sandbox ? "Yes" : "No")
                        }
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
