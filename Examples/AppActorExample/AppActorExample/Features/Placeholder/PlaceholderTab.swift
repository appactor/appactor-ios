import SwiftUI

struct PlaceholderTab: View {
    let title: String
    let icon: String

    var body: some View {
        NavigationView {
            ZStack {
                PRTheme.screenBackground.ignoresSafeArea()

                VStack(spacing: 16) {
                    Image(systemName: icon)
                        .font(.system(size: 48, weight: .light))
                        .foregroundStyle(PRTheme.accentLight)

                    Text(title)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.primary)

                    Text("Coming Soon")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
        }
        .navigationViewStyle(.stack)
    }
}
