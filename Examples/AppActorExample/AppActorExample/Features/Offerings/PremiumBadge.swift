import SwiftUI

struct PremiumBadge: View {
    let isPremium: Bool

    var body: some View {
        PRCard {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(color.opacity(0.12))
                        .frame(width: 50, height: 50)
                    Image(systemName: isPremium ? "crown.fill" : "xmark.circle")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(color)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("Premium Status")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.secondary)
                    Text(isPremium ? "Active" : "Inactive")
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .foregroundStyle(color)
                }

                Spacer()

                StatusBadge(text: isPremium ? "Unlocked" : "Locked", color: color)
            }
        }
    }

    private var color: Color {
        isPremium ? PRTheme.success : PRTheme.error
    }
}
