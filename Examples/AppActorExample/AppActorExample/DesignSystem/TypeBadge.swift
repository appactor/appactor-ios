import SwiftUI

struct TypeBadge: View {
    let type: String

    var body: some View {
        Text(type.uppercased())
            .font(.system(size: 9, weight: .bold))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(color.opacity(0.12))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }

    private var color: Color {
        switch type {
        case "annual": return PRTheme.success
        case "monthly": return PRTheme.info
        case "weekly": return PRTheme.warning
        case "lifetime": return PRTheme.accent
        default: return .secondary
        }
    }
}
