import SwiftUI

struct SplashScreenView: View {
    @State private var isAnimating = false

    var body: some View {
        ZStack {
            QuickVPNTheme.backgroundGradient
                .ignoresSafeArea()

            VStack(spacing: 28) {
                ZStack {
                    RoundedRectangle(cornerRadius: 34, style: .continuous)
                        .fill(QuickVPNTheme.card.opacity(0.88))
                        .frame(width: 132, height: 132)
                        .overlay {
                            RoundedRectangle(cornerRadius: 34, style: .continuous)
                                .stroke(QuickVPNTheme.accent.opacity(0.38), lineWidth: 1)
                        }
                        .scaleEffect(isAnimating ? 1.04 : 0.98)

                    Image(systemName: "shield.lefthalf.filled")
                        .font(.system(size: 58, weight: .bold))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [QuickVPNTheme.accent, QuickVPNTheme.blue],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                }
                .shadow(color: QuickVPNTheme.accent.opacity(isAnimating ? 0.32 : 0.16), radius: 28, x: 0, y: 16)

                VStack(spacing: 8) {
                    Text("QuickVPN")
                        .font(.system(size: 36, weight: .heavy))
                        .foregroundStyle(QuickVPNTheme.primaryText)

                    Text("Secure tunnel")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(QuickVPNTheme.secondaryText)
                }

                HStack(spacing: 8) {
                    ForEach(0..<3, id: \.self) { index in
                        Capsule()
                            .fill(index == 1 ? QuickVPNTheme.accent : QuickVPNTheme.blue.opacity(0.65))
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
