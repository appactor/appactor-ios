import SwiftUI

struct EmptyStateView: View {
    let icon: String
    let message: String

    init(_ message: String, icon: String = "tray") {
        self.message = message
        self.icon = icon
    }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(PRTheme.mist)
                    .frame(width: 34, height: 34)
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(PRTheme.info)
            }

            Text(message)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(PRTheme.rowBackground)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
