import SwiftUI
import WidgetKit

struct NetlumaVPNWidgetEntry: TimelineEntry {
    let date: Date
    let state: NetlumaVPNWidgetState
}

struct NetlumaVPNWidgetState: Equatable {
    var status: VPNConnectionStatus
    var selectedProfile: VPNProfile?
    var sessionInfo: NetlumaVPNWidgetSessionInfo?
    var latencyMS: Int?

    var canToggle: Bool {
        status != .disconnecting && (selectedProfile != nil || status.isWidgetSessionActive)
    }

    var statusTitle: String {
        switch status {
        case .connected:
            L10n.string("Connected")
        case .connecting:
            L10n.string("Connecting")
        case .disconnecting:
            L10n.string("Disconnecting")
        case .failed:
            L10n.string("Failed")
        case .disconnected:
            L10n.string("Disconnected")
        }
    }

    var statusRowTitle: String {
        switch status {
        case .connected:
            L10n.string("VPN Connected")
        case .connecting:
            L10n.string("VPN Connecting")
        case .disconnecting:
            L10n.string("VPN Disconnecting")
        case .failed:
            L10n.string("VPN Failed")
        case .disconnected:
            L10n.string("VPN Disconnected")
        }
    }

    var title: String {
        switch status {
        case .connected:
            L10n.string("Protected connection")
        case .connecting:
            L10n.string("Connecting...")
        case .disconnecting:
            L10n.string("Disconnecting...")
        case .failed:
            L10n.string("Connection failed")
        case .disconnected:
            selectedProfile == nil ? L10n.string("No profile selected") : L10n.string("Ready to connect")
        }
    }

    var actionTitle: String {
        switch status {
        case .connected, .connecting:
            L10n.string("Tap to turn off")
        case .disconnecting:
            L10n.string("Turning off")
        case .failed:
            selectedProfile == nil ? L10n.string("Add profile") : L10n.string("Try again")
        case .disconnected:
            selectedProfile == nil ? L10n.string("Add profile") : L10n.string("Tap to turn on")
        }
    }

    var smallLocationTitle: String {
        if status == .connected, let location = sessionInfo?.shortLocation {
            return location
        }

        if let selectedProfile {
            return selectedProfile.displayName
        }

        return L10n.string("No profile")
    }

    var locationTitle: String {
        if status == .connected {
            if let countryName = sessionInfo?.countryName?.nilIfBlank {
                return countryName
            }

            if let countryCode = sessionInfo?.countryCode?.nilIfBlank {
                return countryCode
            }
        }

        if let selectedProfile {
            return selectedProfile.displayName
        }

        return L10n.string("No profile")
    }

    var locationSubtitle: String {
        if status == .connected {
            if let location = sessionInfo?.cityRegion {
                return location
            }

            if let ipAddress = sessionInfo?.ipAddress?.nilIfBlank {
                return ipAddress
            }
        }

        if let selectedProfile {
            return selectedProfile.widgetConnectionSummary
        }

        return L10n.string("Open NetlumaVPN to add one")
    }

    var ipText: String {
        guard status == .connected else {
            return L10n.string("No IP")
        }
        return sessionInfo?.ipAddress?.nilIfBlank ?? L10n.string("No IP")
    }

    var latencyText: String {
        guard let latencyMS else {
            return L10n.string("No ping")
        }
        return "\(latencyMS) ms"
    }

    static let placeholder = NetlumaVPNWidgetState(
        status: .disconnected,
        selectedProfile: nil,
        sessionInfo: nil,
        latencyMS: nil
    )

    static let previewConnected = NetlumaVPNWidgetState(
        status: .connected,
        selectedProfile: VPNProfile(
            protocolType: .vless,
            host: "vpn.example.com",
            port: 443,
            security: .tls,
            networkType: .tcp,
            remarks: "Fast VPN"
        ),
        sessionInfo: NetlumaVPNWidgetSessionInfo(
            ipAddress: "10.8.0.42",
            countryCode: "JP",
            countryName: "Japan",
            city: "Tokyo",
            region: nil
        ),
        latencyMS: 38
    )
}

struct NetlumaVPNWidgetSessionInfo: Equatable {
    var ipAddress: String?
    var countryCode: String?
    var countryName: String?
    var city: String?
    var region: String?

    var shortLocation: String? {
        let parts = [countryName, city]
            .compactMap { $0?.nilIfBlank }
        guard parts.isEmpty == false else {
            return nil
        }
        return parts.joined(separator: " / ")
    }

    var cityRegion: String? {
        let parts = [city, region]
            .compactMap { $0?.nilIfBlank }
        guard parts.isEmpty == false else {
            return nil
        }
        return parts.joined(separator: " / ")
    }

    var flagEmoji: String? {
        guard let countryCode = countryCode?.nilIfBlank?.uppercased(),
              countryCode.count == 2 else {
            return nil
        }

        let scalars = countryCode.unicodeScalars.compactMap { scalar in
            UnicodeScalar(127397 + scalar.value)
        }
        guard scalars.count == 2 else {
            return nil
        }
        return String(String.UnicodeScalarView(scalars))
    }
}

private struct NetlumaVPNWidgetSessionResponse: Decodable {
    var ip: String?
    var countryCode: String?
    var countryName: String?
    var city: String?
    var region: String?

    enum CodingKeys: String, CodingKey {
        case ip
        case countryCode = "country_code"
        case countryName = "country_name"
        case city
        case region
    }
}

private struct NetlumaVPNWidgetSessionInfoService {
    func fetch(timeout: TimeInterval = 1) async throws -> NetlumaVPNWidgetSessionInfo {
        var request = URLRequest(url: URL(string: "https://ipapi.co/json/")!)
        request.timeoutInterval = timeout

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: configuration)
        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200..<400).contains(httpResponse.statusCode) else {
            return NetlumaVPNWidgetSessionInfo()
        }

        let decoded = try JSONDecoder().decode(NetlumaVPNWidgetSessionResponse.self, from: data)
        return NetlumaVPNWidgetSessionInfo(
            ipAddress: decoded.ip,
            countryCode: decoded.countryCode,
            countryName: decoded.countryName,
            city: decoded.city,
            region: decoded.region
        )
    }
}

private struct NetlumaVPNWidgetStateLoader {
    private let profileStorage = ProfileStorage()
    private let vpnController = WidgetVPNController()
    private let diagnostics = ConnectionDiagnostics()
    private let sessionInfoService = NetlumaVPNWidgetSessionInfoService()
    private let networkDetailTimeout: TimeInterval = 1

    func load(fetchNetworkDetails: Bool) async -> NetlumaVPNWidgetState {
        let profiles = profileStorage.loadProfiles()
        let selectedProfile = selectedProfile(from: profiles)
        let status = await vpnController.currentStatus()

        async let sessionInfo = loadSessionInfo(
            enabled: fetchNetworkDetails && status == .connected
        )
        async let latencyMS = loadLatency(
            for: selectedProfile,
            enabled: fetchNetworkDetails && status == .connected && selectedProfile != nil
        )

        return await NetlumaVPNWidgetState(
            status: status,
            selectedProfile: selectedProfile,
            sessionInfo: sessionInfo,
            latencyMS: latencyMS
        )
    }

    private func selectedProfile(from profiles: [VPNProfile]) -> VPNProfile? {
        if let selectedProfileID = profileStorage.selectedProfileID(),
           let profile = profiles.first(where: { $0.id == selectedProfileID }) {
            return profile
        }

        return profiles.first
    }

    private func loadSessionInfo(enabled: Bool) async -> NetlumaVPNWidgetSessionInfo? {
        guard enabled else {
            return nil
        }
        return try? await sessionInfoService.fetch(timeout: networkDetailTimeout)
    }

    private func loadLatency(for profile: VPNProfile?, enabled: Bool) async -> Int? {
        guard enabled, let profile else {
            return nil
        }

        return await diagnostics.measureTCPConnectLatency(
            host: profile.host,
            port: profile.port,
            timeout: networkDetailTimeout
        )
    }
}

struct NetlumaVPNWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> NetlumaVPNWidgetEntry {
        NetlumaVPNWidgetEntry(date: Date(), state: .placeholder)
    }

    func getSnapshot(
        in context: Context,
        completion: @escaping (NetlumaVPNWidgetEntry) -> Void
    ) {
        if context.isPreview {
            completion(NetlumaVPNWidgetEntry(date: Date(), state: .previewConnected))
            return
        }

        Task {
            completion(
                await NetlumaVPNWidgetEntry(
                    date: Date(),
                    state: NetlumaVPNWidgetStateLoader().load(fetchNetworkDetails: false)
                )
            )
        }
    }

    func getTimeline(
        in context: Context,
        completion: @escaping (Timeline<NetlumaVPNWidgetEntry>) -> Void
    ) {
        Task {
            let entry = await NetlumaVPNWidgetEntry(
                date: Date(),
                state: NetlumaVPNWidgetStateLoader().load(fetchNetworkDetails: true)
            )
            let refreshInterval: TimeInterval = entry.state.status.isWidgetTransitioning
                ? 2
                : (entry.state.status == .connected ? 180 : 900)
            completion(
                Timeline(
                    entries: [entry],
                    policy: .after(Date().addingTimeInterval(refreshInterval))
                )
            )
        }
    }
}

struct NetlumaVPNWidgetView: View {
    @Environment(\.widgetFamily) private var family

    let entry: NetlumaVPNWidgetEntry

    var body: some View {
        Group {
            switch family {
            case .systemMedium:
                NetlumaVPNMediumWidgetView(state: entry.state)
            default:
                NetlumaVPNSmallWidgetView(state: entry.state)
            }
        }
        .containerBackground(for: .widget) {
            NetlumaVPNWidgetBackground(status: entry.state.status)
        }
    }
}

private struct NetlumaVPNSmallWidgetView: View {
    let state: NetlumaVPNWidgetState

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                HStack(spacing: 6) {
                    WidgetIconBox(
                        iconName: "shield.checkered",
                        iconColor: WidgetTheme.accent,
                        fill: WidgetTheme.accentGlow,
                        size: 24,
                        iconSize: 14,
                        cornerRadius: 12
                    )

                    Text("NetlumaVPN")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(WidgetTheme.primaryText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }

                Spacer(minLength: 0)

                StatusDot(status: state.status, size: 8)
            }

            Spacer(minLength: 0)

            PowerIntentButton(state: state, diameter: 70, iconSize: 34)

            Spacer(minLength: 0)

            VStack(spacing: 2) {
                Text(state.statusTitle)
                    .font(.system(size: 14, weight: .heavy))
                    .foregroundStyle(WidgetTheme.primaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)

                Text(state.smallLocationTitle)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(WidgetTheme.secondaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity)
        }
        .padding(14)
    }
}

private struct NetlumaVPNMediumWidgetView: View {
    let state: NetlumaVPNWidgetState

    var body: some View {
        HStack(spacing: 16) {
            VStack(spacing: 8) {
                PowerIntentButton(state: state, diameter: 84, iconSize: 38)

                Text(state.actionTitle)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(WidgetTheme.secondaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(width: 94)
            .frame(maxHeight: .infinity)

            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        StatusDot(status: state.status, size: 8)

                        Text(state.statusRowTitle)
                            .font(.system(size: 13, weight: .heavy))
                            .foregroundStyle(state.status.widgetAccentColor)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                    }

                    Text(state.title)
                        .font(.system(size: 21, weight: .heavy))
                        .foregroundStyle(WidgetTheme.primaryText)
                        .lineLimit(2)
                        .minimumScaleFactor(0.7)
                }

                HStack(spacing: 10) {
                    WidgetLocationIcon(state: state)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(state.locationTitle)
                            .font(.system(size: 14, weight: .heavy))
                            .foregroundStyle(WidgetTheme.primaryText)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)

                        Text(state.locationSubtitle)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(WidgetTheme.secondaryText)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                HStack(spacing: 8) {
                    WidgetPill(
                        iconName: "lock.fill",
                        iconColor: WidgetTheme.secondaryText,
                        text: state.ipText,
                        textColor: WidgetTheme.secondaryText
                    )

                    WidgetPill(
                        iconName: "waveform.path.ecg",
                        iconColor: state.status.widgetAccentColor,
                        text: state.latencyText,
                        textColor: WidgetTheme.primaryText
                    )
                    .fixedSize(horizontal: true, vertical: false)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
        .padding(16)
    }
}

private struct PowerIntentButton: View {
    let state: NetlumaVPNWidgetState
    let diameter: CGFloat
    let iconSize: CGFloat

    var body: some View {
        Group {
            if state.status.isWidgetSessionActive {
                Button(intent: DisconnectVPNConnectionIntent()) {
                    label
                }
            } else {
                Button(intent: ConnectVPNConnectionIntent()) {
                    label
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(state.canToggle == false)
        .accessibilityLabel(state.status.isWidgetSessionActive ? L10n.string("Disconnect VPN") : L10n.string("Connect VPN"))
    }

    private var label: some View {
        ZStack {
            Circle()
                .fill(state.status.widgetPowerFill)
                .frame(width: diameter, height: diameter)
                .shadow(
                    color: state.status.widgetPowerShadow,
                    radius: state.status.isWidgetSessionActive ? 24 : 0,
                    x: 0,
                    y: 10
                )

            Image(systemName: "power")
                .font(.system(size: iconSize, weight: .medium))
                .foregroundStyle(state.status.widgetPowerIconColor)
        }
        .frame(width: diameter, height: diameter)
        .opacity(state.status == .disconnecting || state.canToggle ? 1 : 0.65)
    }
}

private struct StatusDot: View {
    let status: VPNConnectionStatus
    let size: CGFloat

    var body: some View {
        Circle()
            .fill(status.widgetAccentColor)
            .frame(width: size, height: size)
            .shadow(color: status.widgetAccentColor.opacity(0.35), radius: 10)
    }
}

private struct WidgetIconBox: View {
    let iconName: String
    let iconColor: Color
    let fill: Color
    let size: CGFloat
    let iconSize: CGFloat
    let cornerRadius: CGFloat

    var body: some View {
        Image(systemName: iconName)
            .font(.system(size: iconSize, weight: .bold))
            .foregroundStyle(iconColor)
            .frame(width: size, height: size)
            .background(fill, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

private struct WidgetLocationIcon: View {
    let state: NetlumaVPNWidgetState

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(state.status == .connected ? WidgetTheme.locationFill : WidgetTheme.surface)

            if let flagEmoji = state.sessionInfo?.flagEmoji, state.status == .connected {
                Text(flagEmoji)
                    .font(.system(size: 19, weight: .bold))
            } else {
                Image(systemName: "server.rack")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(state.status.widgetAccentColor)
            }
        }
        .frame(width: 36, height: 36)
    }
}

private struct WidgetPill: View {
    let iconName: String
    let iconColor: Color
    let text: String
    let textColor: Color

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: iconName)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(iconColor)
                .frame(width: 13, height: 13)

            Text(text)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(textColor)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .frame(maxWidth: .infinity)
        .background(WidgetTheme.pillFill, in: Capsule())
    }
}

private struct NetlumaVPNWidgetBackground: View {
    let status: VPNConnectionStatus

    var body: some View {
        LinearGradient(
            colors: [
                Color(widgetHex: "#0B0F1A"),
                Color(widgetHex: "#102A30")
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

struct NetlumaVPNWidget: Widget {
    private let kind = "NetlumaVPNWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: NetlumaVPNWidgetProvider()) { entry in
            NetlumaVPNWidgetView(entry: entry)
        }
        .configurationDisplayName("NetlumaVPN")
        .description("Connect, disconnect, and check the current VPN state.")
        .supportedFamilies([.systemSmall, .systemMedium])
        .contentMarginsDisabled()
    }
}

@main
struct NetlumaVPNWidgetBundle: WidgetBundle {
    var body: some Widget {
        NetlumaVPNWidget()
    }
}

private enum WidgetTheme {
    static let surface = Color(widgetHex: "#151B2B")
    static let card = Color(widgetHex: "#1C2336")
    static let inactiveControl = Color(widgetHex: "#454B5E")
    static let accent = Color(widgetHex: "#34D399")
    static let accentGlow = Color(widgetHex: "#34D399").opacity(0.2)
    static let warning = Color(widgetHex: "#FBBF24")
    static let danger = Color(widgetHex: "#F87171")
    static let primaryText = Color.white
    static let secondaryText = Color(widgetHex: "#94A3B8")
    static let mutedText = Color(widgetHex: "#64748B")
    static let onAccent = Color(widgetHex: "#0B0F1A")
    static let locationFill = Color(widgetHex: "#1E3A8A")
    static let pillFill = Color.white.opacity(0.05)
}

private extension VPNConnectionStatus {
    var isWidgetTransitioning: Bool {
        switch self {
        case .connecting, .disconnecting:
            true
        case .connected, .disconnected, .failed:
            false
        }
    }

    var isWidgetSessionActive: Bool {
        switch self {
        case .connected, .connecting, .disconnecting:
            true
        case .disconnected, .failed:
            false
        }
    }

    var widgetAccentColor: Color {
        switch self {
        case .connected:
            WidgetTheme.accent
        case .connecting:
            WidgetTheme.warning
        case .disconnecting:
            WidgetTheme.accent.opacity(0.78)
        case .failed:
            WidgetTheme.danger
        case .disconnected:
            WidgetTheme.mutedText
        }
    }

    var widgetPowerFill: Color {
        switch self {
        case .connected:
            WidgetTheme.accent
        case .connecting, .disconnecting:
            WidgetTheme.warning
        case .failed:
            WidgetTheme.danger
        case .disconnected:
            WidgetTheme.inactiveControl
        }
    }

    var widgetPowerShadow: Color {
        switch self {
        case .connected:
            WidgetTheme.accent.opacity(0.6)
        case .connecting:
            WidgetTheme.warning.opacity(0.5)
        case .disconnecting:
            WidgetTheme.accent.opacity(0.35)
        case .failed, .disconnected:
            .clear
        }
    }

    var widgetPowerIconColor: Color {
        switch self {
        case .connected, .connecting, .disconnecting:
            WidgetTheme.onAccent
        case .failed, .disconnected:
            WidgetTheme.primaryText
        }
    }
}

private extension VPNProfile {
    var widgetConnectionSummary: String {
        if protocolType == .wireguard {
            return "\(displayEndpoint) / \(protocolType.title) UDP"
        }
        return "\(displayEndpoint) / \(protocolType.title) \(networkType.widgetShortTitle)"
    }
}

private extension VPNNetworkType {
    var widgetShortTitle: String {
        switch self {
        case .tcp:
            "TCP"
        case .ws:
            "WS"
        case .grpc:
            "gRPC"
        case .httpupgrade:
            "HTTP"
        }
    }
}

private extension Color {
    init(widgetHex: String) {
        let cleaned = widgetHex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)

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

#Preview(as: .systemSmall) {
    NetlumaVPNWidget()
} timeline: {
    NetlumaVPNWidgetEntry(date: Date(), state: .previewConnected)
}

#Preview(as: .systemMedium) {
    NetlumaVPNWidget()
} timeline: {
    NetlumaVPNWidgetEntry(date: Date(), state: .previewConnected)
}
