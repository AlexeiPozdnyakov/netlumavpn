import SwiftUI

struct ServersView: View {
    let profiles: [VPNProfile]
    let selectedProfileID: UUID?
    let onSelect: (VPNProfile) -> Void
    let onAddProfile: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Locations")
                            .font(.system(size: 24, weight: .bold))
                            .foregroundStyle(QuickVPNTheme.primaryText)
                        Text("\(profiles.count) local \(profiles.count == 1 ? "server" : "servers")")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(QuickVPNTheme.secondaryText)
                    }

                    Spacer()

                    Button(action: onAddProfile) {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(QuickVPNTheme.primaryText)
                            .frame(width: 40, height: 40)
                            .background(QuickVPNTheme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }

                QuickVPNCard {
                    VStack(spacing: 0) {
                        if profiles.isEmpty {
                            VStack(spacing: 12) {
                                Image(systemName: "bolt.shield")
                                    .font(.system(size: 26, weight: .bold))
                                    .foregroundStyle(QuickVPNTheme.accent)
                                Text("Add a local server profile")
                                    .font(.headline)
                                    .foregroundStyle(QuickVPNTheme.primaryText)
                                Button("Add Profile", action: onAddProfile)
                                    .buttonStyle(CapsuleIconButtonStyle(tint: QuickVPNTheme.accent))
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 36)
                        } else {
                            ForEach(profiles) { profile in
                                Button {
                                    onSelect(profile)
                                } label: {
                                    ServerProfileRow(
                                        profile: profile,
                                        isSelected: profile.id == selectedProfileID
                                    )
                                }
                                .buttonStyle(.plain)

                                if profile.id != profiles.last?.id {
                                    Rectangle()
                                        .fill(QuickVPNTheme.borderSubtle)
                                        .frame(height: 1)
                                        .padding(.leading, 64)
                                }
                            }
                        }
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

private struct ServerProfileRow: View {
    let profile: VPNProfile
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: isSelected ? "checkmark.shield.fill" : "server.rack")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(isSelected ? QuickVPNTheme.accent : QuickVPNTheme.blue)
                .frame(width: 38, height: 38)
                .background((isSelected ? QuickVPNTheme.accent : QuickVPNTheme.blue).opacity(0.16), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(profile.displayName)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(QuickVPNTheme.primaryText)
                Text(profile.displayEndpoint)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(QuickVPNTheme.secondaryText)
            }

            Spacer()

            Text(profile.protocolType.title)
                .font(.system(size: 10, weight: .heavy))
                .foregroundStyle(isSelected ? QuickVPNTheme.onAccent : QuickVPNTheme.secondaryText)
                .padding(.horizontal, 8)
                .frame(height: 22)
                .background(isSelected ? QuickVPNTheme.accent : QuickVPNTheme.surface, in: Capsule())
        }
        .padding(.horizontal, 14)
        .frame(height: 62)
    }
}
