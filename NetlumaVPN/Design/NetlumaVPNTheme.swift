import SwiftUI

enum NetlumaVPNTheme {
    static let background = Color(hex: "#0B0F1A")
    static let backgroundGradient = LinearGradient(
        colors: [
            Color(hex: "#0B0F1A"),
            Color(hex: "#102A30")
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
    static let surface = Color(hex: "#151B2B")
    static let card = Color(hex: "#1C2336")
    static let cardHover = Color(hex: "#222B42")
    static let inactiveControl = Color(hex: "#313645")
    static let border = Color(hex: "#2A3349")
    static let borderSubtle = Color(hex: "#1F2638")
    static let accent = Color(hex: "#34D399")
    static let accentSoft = Color(hex: "#10B981")
    static let accentGlow = Color(hex: "#34D399").opacity(0.2)
    static let blue = Color(hex: "#60A5FA")
    static let purple = Color(hex: "#A78BFA")
    static let warning = Color(hex: "#FBBF24")
    static let danger = Color(hex: "#F87171")
    static let primaryText = Color.white
    static let secondaryText = Color(hex: "#94A3B8")
    static let mutedText = Color(hex: "#64748B")
    static let onAccent = Color(hex: "#0B0F1A")
}

extension Color {
    init(hex: String) {
        let cleaned = hex
            .trimmingCharacters(in: CharacterSet.alphanumerics.inverted)

        var value: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&value)

        let alpha: UInt64
        let red: UInt64
        let green: UInt64
        let blue: UInt64

        switch cleaned.count {
        case 3:
            alpha = 255
            red = (value >> 8) * 17
            green = (value >> 4 & 0xF) * 17
            blue = (value & 0xF) * 17
        case 6:
            alpha = 255
            red = value >> 16
            green = value >> 8 & 0xFF
            blue = value & 0xFF
        case 8:
            alpha = value & 0xFF
            red = value >> 24
            green = value >> 16 & 0xFF
            blue = value >> 8 & 0xFF
        default:
            alpha = 255
            red = 255
            green = 255
            blue = 255
        }

        self.init(
            .sRGB,
            red: Double(red) / 255,
            green: Double(green) / 255,
            blue: Double(blue) / 255,
            opacity: Double(alpha) / 255
        )
    }
}

struct CapsuleIconButtonStyle: ButtonStyle {
    var tint: Color = NetlumaVPNTheme.card

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(NetlumaVPNTheme.primaryText)
            .padding(.horizontal, 14)
            .frame(height: 36)
            .background(tint.opacity(configuration.isPressed ? 0.75 : 1), in: Capsule())
    }
}

struct NetlumaVPNCard<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .background(NetlumaVPNTheme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(NetlumaVPNTheme.borderSubtle, lineWidth: 1)
            }
    }
}
