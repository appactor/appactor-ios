import SwiftUI

struct PRCard<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(PRTheme.cardPadding)
            .background(
                RoundedRectangle(cornerRadius: PRTheme.cardRadius, style: .continuous)
                    .fill(PRTheme.cardBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: PRTheme.cardRadius, style: .continuous)
                    .stroke(PRTheme.cardBorder, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: PRTheme.cardRadius, style: .continuous))
            .shadow(color: PRTheme.cardShadow, radius: 18, x: 0, y: 8)
    }
}

struct ExampleScreen<Content: View>: View {
    let title: String
    let subtitle: String
    let icon: String
    let tint: Color
    let badgeText: String?
    let badgeColor: Color
    let content: Content

    init(
        title: String,
        subtitle: String,
        icon: String,
        tint: Color = PRTheme.accent,
        badgeText: String? = nil,
        badgeColor: Color = PRTheme.success,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.tint = tint
        self.badgeText = badgeText
        self.badgeColor = badgeColor
        self.content = content()
    }

    var body: some View {
        ZStack {
            PRTheme.screenGradient.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 16) {
                    heroCard
                    content
                }
                .padding(.horizontal, PRTheme.screenPadding)
                .padding(.top, 12)
                .padding(.bottom, 28)
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var heroCard: some View {
        ZStack(alignment: .topTrailing) {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(PRTheme.heroGradient)
                .overlay(
                    LinearGradient(
                        colors: [Color.white.opacity(0.14), Color.clear],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                )

            Circle()
                .fill(Color.white.opacity(0.08))
                .frame(width: 130, height: 130)
                .offset(x: 30, y: -34)

            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(Color.white.opacity(0.14))
                            .frame(width: 54, height: 54)
                        Image(systemName: icon)
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(.white)
                    }

                    VStack(alignment: .leading, spacing: 5) {
                        Text(title)
                            .font(.system(size: 24, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                        Text(subtitle)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.white.opacity(0.84))
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 0)
                }

                if let badgeText, !badgeText.isEmpty {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(badgeColor)
                            .frame(width: 8, height: 8)
                        Text(badgeText)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.white.opacity(0.12))
                    .clipShape(Capsule())
                }
            }
            .padding(22)
        }
        .shadow(color: PRTheme.ink.opacity(0.14), radius: 22, x: 0, y: 12)
    }
}
