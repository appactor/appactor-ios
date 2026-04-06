import SwiftUI

enum PRTheme {
    // Brand colors
    static let accent = Color(hex: "0F766E")
    static let accentLight = Color(hex: "5EEAD4")
    static let success = Color(hex: "15803D")
    static let warning = Color(hex: "D97706")
    static let error = Color(hex: "DC2626")
    static let info = Color(hex: "0369A1")
    static let ink = Color(hex: "0F172A")
    static let mist = Color(hex: "E2E8F0")
    static let sand = Color(hex: "FFF7ED")

    // Semantic
    static let cardBackground = Color.white.opacity(0.92)
    static let cardBorder = Color.white.opacity(0.55)
    static let cardShadow = Color.black.opacity(0.08)
    static let screenBackground = Color(hex: "F6FBFB")
    static let rowBackground = Color.white.opacity(0.72)

    // Gradients
    static let headerGradient = LinearGradient(
        colors: [Color(hex: "0F766E"), Color(hex: "14B8A6"), Color(hex: "67E8F9")],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
    static let screenGradient = LinearGradient(
        colors: [
            Color(hex: "ECFEFF"),
            Color(hex: "F8FAFC"),
            Color(hex: "FFF7ED")
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
    static let heroGradient = LinearGradient(
        colors: [
            Color(hex: "083344"),
            Color(hex: "0F766E"),
            Color(hex: "14B8A6")
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    // Layout
    static let cardRadius: CGFloat = 22
    static let cardPadding: CGFloat = 18
    static let spacing: CGFloat = 14
    static let screenPadding: CGFloat = 18
}

// MARK: - Color Hex Init

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r, g, b: UInt64
        switch hex.count {
        case 6:
            (r, g, b) = ((int >> 16) & 0xFF, (int >> 8) & 0xFF, int & 0xFF)
        default:
            (r, g, b) = (0, 0, 0)
        }
        self.init(.sRGB, red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255)
    }
}
