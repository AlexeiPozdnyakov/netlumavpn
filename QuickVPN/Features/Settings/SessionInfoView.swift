import SwiftUI

struct SessionInfoView: View {
    @State private var sessionInfo = SessionInfo.empty
    @State private var isLoading = true
    @State private var speedTestState: SpeedTestState = .idle

    private let service: SessionInfoService
    private let diagnostics: ConnectionDiagnostics

    init(
        service: SessionInfoService = .live,
        diagnostics: ConnectionDiagnostics = ConnectionDiagnostics()
    ) {
        self.service = service
        self.diagnostics = diagnostics
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                QuickVPNCard {
                    VStack(spacing: 0) {
                        ForEach(infoRows) { row in
                            SessionInfoRow(title: row.title, value: row.value)
                            if row.id != infoRows.last?.id {
                                Rectangle()
                                    .fill(QuickVPNTheme.borderSubtle)
                                    .frame(height: 1)
                            }
                        }
                    }
                    .redacted(reason: isLoading ? .placeholder : [])
                }

                Text("Your IP address is a unique identifier associated with your online activity, similar to a return address on a letter.")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(QuickVPNTheme.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Button {
                    runSpeedTest()
                } label: {
                    HStack(spacing: 8) {
                        if speedTestState == .running {
                            ProgressView()
                                .tint(QuickVPNTheme.blue)
                                .controlSize(.small)
                        } else {
                            Image(systemName: speedTestState.iconName)
                        }
                        Text(speedTestState.title)
                    }
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(QuickVPNTheme.blue)
                    .frame(maxWidth: .infinity)
                    .frame(height: 54)
                    .background(QuickVPNTheme.card, in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(speedTestState == .running)
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 18)
        }
        .background(QuickVPNTheme.backgroundGradient)
        .navigationTitle("Session")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(QuickVPNTheme.backgroundGradient, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .task {
            await load()
        }
    }

    private var infoRows: [SessionInfoDisplayRow] {
        [
            SessionInfoDisplayRow(title: "IPv4", value: sessionInfo.ipv4),
            SessionInfoDisplayRow(title: "IPv6", value: sessionInfo.ipv6),
            SessionInfoDisplayRow(title: "ASN", value: sessionInfo.asn),
            SessionInfoDisplayRow(title: "AS Organization", value: sessionInfo.organization),
            SessionInfoDisplayRow(title: "Country", value: sessionInfo.countryCode),
            SessionInfoDisplayRow(title: "City", value: sessionInfo.city),
            SessionInfoDisplayRow(title: "Region", value: sessionInfo.region),
            SessionInfoDisplayRow(title: "Latitude", value: sessionInfo.latitude.map { String(format: "%.5f", $0) }),
            SessionInfoDisplayRow(title: "Longitude", value: sessionInfo.longitude.map { String(format: "%.5f", $0) })
        ]
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }

        do {
            sessionInfo = try await service.fetch()
        } catch {
            sessionInfo = .empty
        }
    }

    private func runSpeedTest() {
        speedTestState = .running
        Task {
            let isReachable = await diagnostics.checkInternetReachability(timeout: 6)
            speedTestState = isReachable ? .reachable : .unreachable
        }
    }
}

private struct SessionInfoDisplayRow: Identifiable {
    let title: String
    let value: String?

    var id: String { title }
}

private struct SessionInfoRow: View {
    let title: String
    let value: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(title)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(QuickVPNTheme.primaryText)
            Spacer()
            Text(value?.nilIfBlank ?? "-")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(QuickVPNTheme.secondaryText)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 45)
    }
}

private enum SpeedTestState {
    case idle
    case running
    case reachable
    case unreachable

    var title: String {
        switch self {
        case .idle:
            "Speed Test"
        case .running:
            "Testing"
        case .reachable:
            "Internet Reachable"
        case .unreachable:
            "No Response"
        }
    }

    var iconName: String {
        switch self {
        case .idle:
            "speedometer"
        case .running:
            "speedometer"
        case .reachable:
            "checkmark.circle"
        case .unreachable:
            "exclamationmark.triangle"
        }
    }
}
