import SwiftUI

struct DNSSettingsView: View {
    let selectedResolverID: DNSResolver.ID
    let onSelect: (DNSResolver) -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                NetlumaVPNCard {
                    VStack(spacing: 0) {
                        ForEach(DNSResolver.catalog) { resolver in
                            Button {
                                onSelect(resolver)
                            } label: {
                                DNSResolverRow(
                                    resolver: resolver,
                                    isSelected: resolver.id == selectedResolverID
                                )
                            }
                            .buttonStyle(.plain)

                            if resolver.id != DNSResolver.catalog.last?.id {
                                Rectangle()
                                    .fill(NetlumaVPNTheme.borderSubtle)
                                    .frame(height: 1)
                                    .padding(.leading, 16)
                            }
                        }
                    }
                }

                Text("In order for the DNS settings to take effect, it is necessary to disconnect and reconnect to the VPN.")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(NetlumaVPNTheme.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 14)
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 18)
        }
        .background(NetlumaVPNTheme.backgroundGradient)
        .navigationTitle("DNS")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(NetlumaVPNTheme.backgroundGradient, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
    }
}

private struct DNSResolverRow: View {
    let resolver: DNSResolver
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .strokeBorder(isSelected ? NetlumaVPNTheme.blue : NetlumaVPNTheme.mutedText, lineWidth: 1.5)
                .background {
                    if isSelected {
                        Circle().fill(NetlumaVPNTheme.blue)
                    }
                }
                .frame(width: 16, height: 16)

            Text(resolver.title)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(NetlumaVPNTheme.primaryText)
                .lineLimit(1)

            Spacer()

            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(NetlumaVPNTheme.mutedText)
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
        .contentShape(Rectangle())
    }
}
