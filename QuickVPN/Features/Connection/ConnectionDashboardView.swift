import SwiftUI

struct ConnectionDashboardView: View {
    let status: VPNConnectionStatus
    let selectedProfile: VPNProfile?
    let onToggleConnection: () -> Void

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .center, spacing: 12) {
                    Image(systemName: statusIcon)
                        .font(.title2)
                        .foregroundStyle(statusColor)
                        .frame(width: 34, height: 34)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(status.title)
                            .font(.title3.weight(.semibold))
                        Text(selectedProfile?.displayEndpoint ?? "No server selected")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()
                }

                Button(action: onToggleConnection) {
                    Label(buttonTitle, systemImage: buttonIcon)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(selectedProfile == nil || status == .disconnecting)
            }
            .padding(.vertical, 8)
        }
    }

    private var buttonTitle: String {
        switch status {
        case .connected, .connecting:
            "Disconnect"
        case .disconnected, .disconnecting, .failed:
            "Connect"
        }
    }

    private var buttonIcon: String {
        switch status {
        case .connected, .connecting:
            "stop.fill"
        case .disconnected, .disconnecting, .failed:
            "play.fill"
        }
    }

    private var statusIcon: String {
        switch status {
        case .connected:
            "checkmark.shield.fill"
        case .connecting, .disconnecting:
            "clock.badge"
        case .disconnected:
            "shield"
        case .failed:
            "exclamationmark.triangle.fill"
        }
    }

    private var statusColor: Color {
        switch status {
        case .connected:
            .green
        case .connecting, .disconnecting:
            .orange
        case .disconnected:
            .secondary
        case .failed:
            .red
        }
    }
}

#Preview {
    List {
        ConnectionDashboardView(
            status: .connected,
            selectedProfile: VPNProfile(
                protocolType: .vless,
                host: "vpn.example.com",
                port: 443,
                security: .tls,
                networkType: .tcp,
                remarks: "Example"
            ),
            onToggleConnection: {}
        )
    }
}
