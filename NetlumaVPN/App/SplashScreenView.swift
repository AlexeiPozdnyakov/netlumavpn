import SwiftUI

struct SplashScreenView: View {
    @State private var isAnimating = false

    var body: some View {
        ZStack {
            NetlumaVPNTheme.backgroundGradient
                .ignoresSafeArea()

            VStack(spacing: 28) {
                ZStack {
                    RoundedRectangle(cornerRadius: 34, style: .continuous)
                        .fill(NetlumaVPNTheme.card.opacity(0.88))
                        .frame(width: 132, height: 132)
                        .overlay {
                            RoundedRectangle(cornerRadius: 34, style: .continuous)
                                .stroke(NetlumaVPNTheme.accent.opacity(0.38), lineWidth: 1)
                        }
                        .scaleEffect(isAnimating ? 1.04 : 0.98)

                    Image(systemName: "shield.lefthalf.filled")
                        .font(.system(size: 58, weight: .bold))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [NetlumaVPNTheme.accent, NetlumaVPNTheme.blue],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                }
                .shadow(color: NetlumaVPNTheme.accent.opacity(isAnimating ? 0.32 : 0.16), radius: 28, x: 0, y: 16)

                VStack(spacing: 8) {
                    Text("NetlumaVPN")
                        .font(.system(size: 36, weight: .heavy))
                        .foregroundStyle(NetlumaVPNTheme.primaryText)

                    Text("Secure tunnel")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(NetlumaVPNTheme.secondaryText)
                }

                HStack(spacing: 8) {
                    ForEach(0..<3, id: \.self) { index in
                        Capsule()
                            .fill(index == 1 ? NetlumaVPNTheme.accent : NetlumaVPNTheme.blue.opacity(0.65))
                            .frame(width: isAnimating && index == 1 ? 24 : 8, height: 8)
                            .animation(
                                .easeInOut(duration: 0.75)
                                .repeatForever(autoreverses: true)
                                .delay(Double(index) * 0.12),
                                value: isAnimating
                            )
                    }
                }
                .padding(.top, 4)
            }
            .padding(.bottom, 24)
        }
        .onAppear {
            isAnimating = true
        }
    }
}

#Preview {
    SplashScreenView()
}
