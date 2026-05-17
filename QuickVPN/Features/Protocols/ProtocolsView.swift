import SwiftUI

struct ProtocolsView: View {
    let selectedProfile: VPNProfile?

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Protocols")
                            .font(.system(size: 24, weight: .bold))
                            .foregroundStyle(QuickVPNTheme.primaryText)
                        Text("Choose how you connect")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(QuickVPNTheme.secondaryText)
                    }
                    Spacer()
                }

                QuickVPNCard {
                    HStack(spacing: 12) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(QuickVPNTheme.accent)
                            .frame(width: 38, height: 38)
                            .background(QuickVPNTheme.accent.opacity(0.16), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Auto Protocol")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(QuickVPNTheme.primaryText)
                            Text(selectedProfile?.protocolType.title ?? "Pick a profile to connect")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(QuickVPNTheme.secondaryText)
                        }

                        Spacer()

                        Image(systemName: selectedProfile == nil ? "circle" : "checkmark.circle.fill")
                            .foregroundStyle(selectedProfile == nil ? QuickVPNTheme.mutedText : QuickVPNTheme.accent)
                    }
                    .padding(14)
                }

                VStack(spacing: 10) {
                    ForEach(VPNProtocolType.allCases) { protocolType in
                        ProtocolCard(
                            protocolType: protocolType,
                            isSelected: selectedProfile?.protocolType == protocolType
                        )
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 18)
        }
        .background(QuickVPNTheme.backgroundGradient)
        .toolbar(.hidden, for: .navigationBar)
    }
}

private struct ProtocolCard: View {
    let protocolType: VPNProtocolType
    let isSelected: Bool

    var body: some View {
        QuickVPNCard {
            HStack(spacing: 12) {
                Image(systemName: iconName)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(color)
                    .frame(width: 44, height: 44)
                    .background(color.opacity(0.16), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                VStack(alignment: .leading, spacing: 4) {
                    Text(protocolType.title)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(QuickVPNTheme.primaryText)
                    Text(subtitle)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(QuickVPNTheme.secondaryText)
                }

                Spacer()

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(isSelected ? QuickVPNTheme.accent : QuickVPNTheme.mutedText)
            }
            .padding(14)
        }
    }

    private var iconName: String {
        switch protocolType {
        case .vless:
            "shield.lefthalf.filled"
        case .vmess:
            "bolt.shield"
        case .trojan:
            "key"
        case .wireguard:
            "dot.radiowaves.left.and.right"
        }
    }

    private var color: Color {
        switch protocolType {
        case .vless:
            QuickVPNTheme.accent
        case .vmess:
            QuickVPNTheme.purple
        case .trojan:
            QuickVPNTheme.blue
        case .wireguard:
            QuickVPNTheme.warning
        }
    }

    private var subtitle: String {
        switch protocolType {
        case .vless:
            "Modern encrypted proxy profile"
        case .vmess:
            "Legacy VMess compatible profile"
        case .trojan:
            "TLS-based secure tunnel"
        case .wireguard:
            "Fast UDP tunnel profile"
        }
    }
}
