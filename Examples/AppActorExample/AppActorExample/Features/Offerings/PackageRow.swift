import SwiftUI
import AppActor

struct PackageRow: View {
    let package: AppActorPackage
    var onPurchase: ((AppActorPackage) -> Void)?

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(package.productName ?? package.productId)
                        .font(.system(size: 14, weight: .bold))
                    TypeBadge(type: package.packageType.rawValue)
                    if let tokenAmount = package.tokenAmount {
                        tokenBadge(tokenAmount)
                    }
                }

                Text(package.productId)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.tertiary)

                if let description = package.productDescription, !description.isEmpty {
                    Text(description)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            Spacer()

            Button {
                onPurchase?(package)
            } label: {
                VStack(spacing: 4) {
                    Text(package.localizedPriceString)
                        .font(.system(size: 14, weight: .bold))
                    Text("Buy")
                        .font(.system(size: 10, weight: .bold))
                        .opacity(0.84)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(PRTheme.headerGradient)
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(PRTheme.rowBackground)
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(0.75), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func tokenBadge(_ amount: Int) -> some View {
        Text("\(amount.formatted(.number.grouping(.automatic))) TOKENS")
            .font(.system(size: 10, weight: .bold))
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(PRTheme.warning.opacity(0.18))
            .foregroundStyle(PRTheme.warning)
            .clipShape(Capsule())
    }
}
