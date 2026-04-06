import SwiftUI

struct StatusDot: View {
    let color: Color
    let pulse: Bool

    init(_ color: Color, pulse: Bool = false) {
        self.color = color
        self.pulse = pulse
    }

    @State private var isPulsing = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .overlay {
                if pulse {
                    Circle()
                        .stroke(color.opacity(0.4), lineWidth: 2)
                        .scaleEffect(isPulsing ? 2.5 : 1)
                        .opacity(isPulsing ? 0 : 1)
                        .animation(
                            .easeOut(duration: 1.5).repeatForever(autoreverses: false),
                            value: isPulsing
                        )
                }
            }
            .onAppear { isPulsing = true }
    }
}
