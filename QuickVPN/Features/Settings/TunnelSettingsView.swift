import SwiftUI

struct TunnelSettingsView: View {
    @Binding var preferences: TunnelPreferences

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                QuickVPNCard {
                    ToggleRow(title: "Persist Tunnel", isOn: persistTunnelBinding)
                }

                Text("Keep the tunnel connected while switching profiles.")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(QuickVPNTheme.secondaryText)
                    .padding(.horizontal, 4)

                MenuPickerRow(
                    title: "IP Settings",
                    value: preferences.ipMode.title,
                    icon: "network"
                ) {
                    ForEach(TunnelIPMode.allCases) { mode in
                        Button {
                            preferences.ipMode = mode
                        } label: {
                            Label(mode.title, systemImage: preferences.ipMode == mode ? "checkmark" : "")
                        }
                    }
                }

                Text("Some apps may not function with IPv6-only settings.")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(QuickVPNTheme.secondaryText)
                    .padding(.horizontal, 4)

                MenuPickerRow(
                    title: "On Demand",
                    value: preferences.onDemandMode.title,
                    icon: "bolt.horizontal"
                ) {
                    ForEach(TunnelOnDemandMode.allCases) { mode in
                        Button {
                            preferences.onDemandMode = mode
                        } label: {
                            Label(mode.title, systemImage: preferences.onDemandMode == mode ? "checkmark" : "")
                        }
                    }
                }

                Text(onDemandHelpText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(QuickVPNTheme.secondaryText)
                    .padding(.horizontal, 4)

                QuickVPNCard {
                    ToggleRow(title: "Include All Networks", isOn: includeAllNetworksBinding)
                }

                Text("Route most network traffic through the tunnel, except for traffic related to designated system services.")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(QuickVPNTheme.secondaryText)
                    .padding(.horizontal, 4)
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 18)
        }
        .background(QuickVPNTheme.backgroundGradient)
        .navigationTitle("Tunnel")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(QuickVPNTheme.backgroundGradient, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
    }

    private var persistTunnelBinding: Binding<Bool> {
        Binding(
            get: { preferences.persistTunnel },
            set: { newValue in
                preferences.persistTunnel = newValue
                if newValue == false {
                    preferences.onDemandMode = .disabled
                }
            }
        )
    }

    private var includeAllNetworksBinding: Binding<Bool> {
        Binding(
            get: { preferences.includeAllNetworks },
            set: { preferences.includeAllNetworks = $0 }
        )
    }

    private var onDemandHelpText: String {
        if preferences.persistTunnel {
            "Connect On Demand can reconnect automatically when the tunnel drops."
        } else {
            "Enable Persist Tunnel before using On Demand."
        }
    }
}

private struct ToggleRow: View {
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            Text(title)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(QuickVPNTheme.primaryText)
        }
        .toggleStyle(SwitchToggleStyle(tint: QuickVPNTheme.accent))
        .padding(.horizontal, 16)
        .frame(height: 60)
    }
}

private struct MenuPickerRow<Content: View>: View {
    let title: String
    let value: String
    let icon: String
    let content: Content

    init(
        title: String,
        value: String,
        icon: String,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.value = value
        self.icon = icon
        self.content = content()
    }

    var body: some View {
        QuickVPNCard {
            Menu {
                content
            } label: {
                HStack(spacing: 12) {
                    Text(title)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(QuickVPNTheme.primaryText)

                    Spacer()

                    Text(value)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(QuickVPNTheme.primaryText)

                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(QuickVPNTheme.secondaryText)
                }
                .padding(.horizontal, 16)
                .frame(height: 60)
            }
            .buttonStyle(.plain)
        }
    }
}
