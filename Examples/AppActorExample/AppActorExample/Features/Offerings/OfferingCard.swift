import SwiftUI
import AppActor

struct OfferingCard: View {
    let offering: AppActorOffering
    var onPurchase: ((AppActorPackage) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(offering.displayName)
                        .font(.system(size: 16, weight: .bold))

                    Text(offering.lookupKey ?? offering.id)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }

                if offering.isCurrent {
                    Text("CURRENT")
                        .font(.system(size: 10, weight: .bold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(PRTheme.success.opacity(0.12))
                        .foregroundStyle(PRTheme.success)
                        .clipShape(Capsule())
                }

                Spacer()
            }

            if offering.packages.isEmpty {
                Text("No packages")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            } else {
                ForEach(offering.packages, id: \.id) { package in
                    PackageRow(package: package, onPurchase: onPurchase)
                }
            }
        }
        .padding(14)
        .background(PRTheme.rowBackground)
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.white.opacity(0.78), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}
