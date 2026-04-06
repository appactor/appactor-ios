import SwiftUI

struct SplashView: View {
    @State private var dotCount = 0
    private let timer = Timer.publish(every: 0.4, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            PRTheme.headerGradient
                .ignoresSafeArea()

            VStack(spacing: 24) {
                Image(systemName: "bolt.shield.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(.white)

                Text("AppActor")
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)

                HStack(spacing: 4) {
                    Text("Initializing")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.8))
                    Text(String(repeating: ".", count: dotCount))
                        .font(.subheadline.monospaced())
                        .foregroundStyle(.white.opacity(0.8))
                        .frame(width: 20, alignment: .leading)
                }
            }
        }
        .onReceive(timer) { _ in
            dotCount = (dotCount % 3) + 1
        }
    }
}
