import SwiftUI

struct HomeConnectView: View {
    let status: VPNConnectionStatus
    let connectionStartedAt: Date?
    let selectedConnectionDisplayName: String?
    let selectedProfile: VPNProfile?
    let profiles: [VPNProfile]
    let selectedProfileID: UUID?
    let globalServers: [GlobalVPNServer]
    let isLoadingGlobalServers: Bool
    let globalServersErrorMessage: String?
    let activeGlobalServerID: String?
    let selectedGlobalServerID: String?
    let onToggleConnection: () -> Void
    let onSelectProfile: (VPNProfile) -> Void
    let onEditProfile: (VPNProfile) -> Void
    let onDeleteProfile: (VPNProfile) -> Void
    let onAddProfile: () -> Void
    let onImportProfile: () -> Void
    let onScanQRCode: () -> Void
    let onReloadGlobalServers: () -> Void
    let onSelectGlobalServer: (GlobalVPNServer) -> Void
    let onOpenPremium: () -> Void

    @State private var openProfileRowID: UUID?

    private var sortedProfiles: [VPNProfile] {
        profiles.filter { !$0.isNetlumaVPNManaged }.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                header
                sessionCard
                profilesAndServers
            }
            .padding(.horizontal, 24)
            .padding(.top, 8)
            .padding(.bottom, 20)
        }
        .scrollIndicators(.hidden)
        .background(NetlumaVPNTheme.backgroundGradient)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .navigationBar)
    }

    private var header: some View {
        HStack {
            editProfileButton

            Spacer()

            addProfileMenu
        }
        .frame(height: 52)
    }

    @ViewBuilder
    private var editProfileButton: some View {
        if let selectedProfile, selectedGlobalServerID == nil, !selectedProfile.isNetlumaVPNManaged {
            Button {
                onEditProfile(selectedProfile)
            } label: {
                Text("Edit")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(NetlumaVPNTheme.primaryText)
                    .padding(.horizontal, 16)
                    .frame(height: 33)
                    .background(NetlumaVPNTheme.card, in: Capsule())
            }
            .buttonStyle(.plain)
        }
    }

    private var addProfileMenu: some View {
        Menu {
            Button {
                onAddProfile()
            } label: {
                Label("Add Manually", systemImage: "plus")
            }

            Button {
                onImportProfile()
            } label: {
                Label("Import URL", systemImage: "link")
            }

            Button {
                onScanQRCode()
            } label: {
                Label("Scan QR Code", systemImage: "qrcode.viewfinder")
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(NetlumaVPNTheme.primaryText)
                .frame(width: 36, height: 36)
                .background(NetlumaVPNTheme.card, in: Circle())
        }
        .accessibilityLabel(L10n.string("Add Profile"))
    }

    private var sessionCard: some View {
        VStack(spacing: 8) {
            connectionStatusHeader

            ConnectionDurationText(
                startedAt: connectionStartedAt,
                isActive: status.isHomeSessionActive
            )

            Button(action: onToggleConnection) {
                ZStack {
                    Circle()
                        .fill(status.homePowerFill)
                        .frame(width: 76, height: 76)
                        .shadow(
                            color: status.homePowerShadow,
                            radius: status.isHomeSessionActive ? 30 : 0,
                            x: 0,
                            y: 10
                        )

                    Image(systemName: "power")
                        .font(.system(size: 34, weight: .medium))
                        .foregroundStyle(NetlumaVPNTheme.primaryText)
                }
                .frame(height: 92)
                .animation(.easeInOut(duration: 0.22), value: status)
            }
            .buttonStyle(.plain)
            .disabled(status == .disconnecting)
            .accessibilityLabel(status.homePowerAccessibilityLabel)

            NavigationLink {
                SessionInfoView()
            } label: {
                HStack(spacing: 6) {
                    Text("Session details")
                        .font(.system(size: 12, weight: .semibold))
                    Image(systemName: "info.circle")
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(status.homeSessionDetailsForeground)
                .padding(.horizontal, 14)
                .frame(height: 31)
                .background(status.homeSessionDetailsFill, in: Capsule())
                .overlay {
                    Capsule()
                        .stroke(status.homeSessionDetailsStroke, lineWidth: 1)
                }
            }
            .buttonStyle(.plain)
            .padding(.bottom, 13)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 240)
        .background(NetlumaVPNTheme.surface, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
    }

    private var connectionStatusHeader: some View {
        VStack(spacing: 4) {
            HStack(spacing: 6) {
                Circle()
                    .fill(status.homeStatusDotColor)
                    .frame(width: 8, height: 8)
                    .shadow(color: status.homeStatusDotColor.opacity(status.isHomeSessionActive ? 0.35 : 0), radius: 10)

                Text(status.title)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(status.homeStatusTextColor)
            }

            Text(selectedConnectionDisplayName ?? L10n.string("No profile selected"))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(status.homeLocationTextColor)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .padding(.top, 18)
    }

    private var profilesAndServers: some View {
        VStack(spacing: 10) {
            if !sortedProfiles.isEmpty {
                localProfilesSection
            }
            globalServersSection
        }
    }

    private var localProfilesSection: some View {
        VStack(spacing: 0) {
            SectionHeader(
                title: "LOCAL PROFILES",
                trailing: L10n.format("ACTIVE: %d", sortedProfiles.count)
            )
            .frame(height: 33)

            ForEach(Array(sortedProfiles.prefix(2).enumerated()), id: \.element.id) { index, profile in
                SwipeableProfileConnectRow(
                    profile: profile,
                    isSelected: profile.id == selectedProfileID,
                    isOpen: openProfileRowID == profile.id,
                    onOpen: {
                        openProfileRowID = profile.id
                    },
                    onClose: {
                        if openProfileRowID == profile.id {
                            openProfileRowID = nil
                        }
                    },
                    onSelect: {
                        openProfileRowID = nil
                        onSelectProfile(profile)
                    },
                    onEdit: {
                        openProfileRowID = nil
                        onEditProfile(profile)
                    },
                    onDelete: {
                        openProfileRowID = nil
                        onDeleteProfile(profile)
                    }
                )

                if index < min(sortedProfiles.count, 2) - 1 {
                    DividerLine()
                }
            }
        }
        .background(NetlumaVPNTheme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(NetlumaVPNTheme.borderSubtle, lineWidth: 1)
        }
    }

    private var globalServersSection: some View {
        VStack(spacing: 0) {
            GlobalServersHeader(
                isLoading: isLoadingGlobalServers,
                hasError: globalServersErrorMessage != nil
            )
            .frame(height: 48)

            if globalServers.isEmpty {
                GlobalServerStatusRow(
                    isLoading: isLoadingGlobalServers,
                    errorMessage: globalServersErrorMessage,
                    onRetry: onReloadGlobalServers
                )
            } else {
                ForEach(Array(globalServers.enumerated()), id: \.element.id) { index, server in
                    Button {
                        onSelectGlobalServer(server)
                    } label: {
                        GlobalServerRow(
                            server: server,
                            state: rowState(for: server)
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(!server.isAvailable || activeGlobalServerID != nil)
                    .accessibilityHint(server.isAvailable ? L10n.string("Selects this global server") : L10n.string("Server unavailable"))

                    if index < globalServers.count - 1 {
                        DividerLine()
                    }
                }
            }
        }
        .padding(.vertical, 8)
        .background(NetlumaVPNTheme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(NetlumaVPNTheme.borderSubtle, lineWidth: 1)
        }
    }

    private func rowState(for server: GlobalVPNServer) -> GlobalServerRowState {
        if activeGlobalServerID == server.id {
            return .connecting
        }
        if !server.isAvailable {
            return .unavailable
        }
        if selectedGlobalServerID == server.id {
            return status.isHomeSessionActive ? .connected : .selected
        }
        return .idle
    }
}

struct ProfileSwipeState: Equatable {
    static let actionWidth: CGFloat = 132
    static let openThreshold: CGFloat = 44
    static let horizontalDominanceRatio: CGFloat = 1.2

    static func offset(baseOffset: CGFloat, dragTranslation: CGFloat) -> CGFloat {
        min(0, max(-actionWidth, baseOffset + dragTranslation))
    }

    static func revealsActions(rowOffset: CGFloat) -> Bool {
        rowOffset < -1
    }

    static func horizontalTranslation(from translation: CGSize) -> CGFloat? {
        guard abs(translation.width) > abs(translation.height) * horizontalDominanceRatio else {
            return nil
        }
        return translation.width
    }

    static func shouldOpen(
        isOpen: Bool,
        translation: CGFloat,
        predictedEndTranslation: CGFloat
    ) -> Bool {
        if isOpen, translation > openThreshold {
            return false
        }

        if !isOpen, translation < -openThreshold {
            return true
        }

        let baseOffset = isOpen ? -actionWidth : 0
        let projectedOffset = offset(
            baseOffset: baseOffset,
            dragTranslation: predictedEndTranslation
        )
        return projectedOffset < -actionWidth / 2
    }
}

private struct SectionHeader<Trailing: View>: View {
    let title: String
    let trailing: Trailing

    init(title: String, trailing: String) where Trailing == Text {
        self.title = title
        self.trailing = Text(trailing)
    }

    init(title: String, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.trailing = trailing()
    }

    var body: some View {
        HStack {
            Text(L10n.string(title))
                .font(.system(size: 10, weight: .heavy))
                .foregroundStyle(NetlumaVPNTheme.primaryText)

            Spacer()

            trailing
                .font(.system(size: 9, weight: .heavy))
                .foregroundStyle(NetlumaVPNTheme.secondaryText)
        }
        .padding(.horizontal, 14)
    }
}

private struct GlobalServersHeader: View {
    let isLoading: Bool
    let hasError: Bool

    var body: some View {
        HStack {
            Text("GLOBAL SERVERS")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(NetlumaVPNTheme.primaryText)

            Spacer()

            if isLoading {
                ProgressView()
                    .tint(NetlumaVPNTheme.accent)
                    .controlSize(.small)
            } else {
                GlobalServerBadge(
                    title: hasError ? L10n.string("FAILED") : "PRO",
                    systemImage: hasError ? "exclamationmark.triangle.fill" : "crown.fill",
                    tint: hasError ? NetlumaVPNTheme.warning : NetlumaVPNTheme.accent
                )
            }
        }
        .padding(.horizontal, 18)
    }
}

private struct SwipeableProfileConnectRow: View {
    let profile: VPNProfile
    let isSelected: Bool
    let isOpen: Bool
    let onOpen: () -> Void
    let onClose: () -> Void
    let onSelect: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    @GestureState private var dragTranslation: CGFloat = 0

    private var rowOffset: CGFloat {
        ProfileSwipeState.offset(
            baseOffset: isOpen ? -ProfileSwipeState.actionWidth : 0,
            dragTranslation: dragTranslation
        )
    }

    private var revealsActions: Bool {
        ProfileSwipeState.revealsActions(rowOffset: rowOffset)
    }

    private var actionOffset: CGFloat {
        ProfileSwipeState.actionWidth + rowOffset
    }

    private var contentOffset: CGFloat {
        rowOffset * 0.18
    }

    var body: some View {
        ZStack(alignment: .trailing) {
            ProfileConnectRow(
                profile: profile,
                isSelected: isSelected,
                isOpen: isOpen,
                onSelect: {
                    if isOpen {
                        onClose()
                    } else {
                        onSelect()
                    }
                }
            )
            .background(NetlumaVPNTheme.card)
            .offset(x: contentOffset)

            swipeActions
                .offset(x: actionOffset)
                .opacity(revealsActions ? 1 : 0)
                .allowsHitTesting(isOpen)
                .accessibilityHidden(!isOpen)
        }
        .frame(height: 45)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .clipped()
        .simultaneousGesture(dragGesture)
        .animation(.spring(response: 0.26, dampingFraction: 0.86), value: isOpen)
        .accessibilityAction(named: Text("Edit")) {
            onEdit()
        }
        .accessibilityAction(named: Text("Delete")) {
            onDelete()
        }
    }

    private var swipeActions: some View {
        HStack(spacing: 0) {
            Button {
                onClose()
                onEdit()
            } label: {
                VStack(spacing: 2) {
                    Image(systemName: "pencil")
                        .font(.system(size: 12, weight: .bold))
                    Text("Edit")
                        .font(.system(size: 9, weight: .bold))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .foregroundStyle(NetlumaVPNTheme.primaryText)
                .background(NetlumaVPNTheme.blue)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("profile-swipe-edit")

            Button(role: .destructive) {
                onClose()
                onDelete()
            } label: {
                VStack(spacing: 2) {
                    Image(systemName: "trash")
                        .font(.system(size: 12, weight: .bold))
                    Text("Delete")
                        .font(.system(size: 9, weight: .bold))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .foregroundStyle(NetlumaVPNTheme.primaryText)
                .background(NetlumaVPNTheme.danger)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("profile-swipe-delete")
        }
        .frame(width: ProfileSwipeState.actionWidth, height: 45)
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 12, coordinateSpace: .local)
            .updating($dragTranslation) { value, state, _ in
                guard let horizontalTranslation = ProfileSwipeState.horizontalTranslation(from: value.translation) else {
                    return
                }
                state = horizontalTranslation
            }
            .onEnded { value in
                guard let horizontalTranslation = ProfileSwipeState.horizontalTranslation(from: value.translation) else {
                    return
                }
                let shouldOpen = ProfileSwipeState.shouldOpen(
                    isOpen: isOpen,
                    translation: horizontalTranslation,
                    predictedEndTranslation: value.predictedEndTranslation.width
                )
                shouldOpen ? onOpen() : onClose()
            }
    }
}

private struct ProfileConnectRow: View {
    let profile: VPNProfile
    let isSelected: Bool
    let isOpen: Bool
    let onSelect: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(isSelected ? NetlumaVPNTheme.accent : NetlumaVPNTheme.blue)
                .frame(width: 7, height: 7)

            VStack(alignment: .leading, spacing: 3) {
                Text(profile.displayName.uppercased())
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(NetlumaVPNTheme.primaryText)
                    .lineLimit(1)

                Text(profile.connectionSummary.uppercased())
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(NetlumaVPNTheme.secondaryText)
                    .lineLimit(1)
            }

            Spacer()

            Image(systemName: isSelected ? "checkmark.circle.fill" : "info.circle")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(isSelected ? NetlumaVPNTheme.accent : NetlumaVPNTheme.blue)
                .frame(width: 28, height: 28)
                .opacity(isOpen ? 0 : 1)
        }
        .padding(.horizontal, 14)
        .frame(height: 45)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
    }
}

enum GlobalServerRowState: Equatable {
    case idle
    case selected
    case connecting
    case connected
    case unavailable

    var trailingTitle: String {
        switch self {
        case .idle:
            L10n.string("SELECT")
        case .selected:
            L10n.string("SELECTED")
        case .connecting:
            "..."
        case .connected:
            L10n.string("ON")
        case .unavailable:
            L10n.string("OFF")
        }
    }

    var tint: Color {
        switch self {
        case .connected, .selected:
            NetlumaVPNTheme.accent
        case .connecting:
            NetlumaVPNTheme.warning
        case .unavailable:
            NetlumaVPNTheme.mutedText
        case .idle:
            NetlumaVPNTheme.blue
        }
    }

    var isSelected: Bool {
        self == .selected || self == .connected
    }
}

private struct GlobalServerStatusRow: View {
    let isLoading: Bool
    let errorMessage: String?
    let onRetry: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            if isLoading {
                ProgressView()
                    .tint(NetlumaVPNTheme.blue)
                    .frame(width: 28, height: 28)
            } else {
                Image(systemName: "wifi.exclamationmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(NetlumaVPNTheme.warning)
                    .frame(width: 28, height: 28)
            }

            Text(statusTitle)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(NetlumaVPNTheme.secondaryText)

            Spacer()

            if !isLoading, errorMessage != nil {
                Button(action: onRetry) {
                    Text("RETRY")
                        .font(.system(size: 8, weight: .heavy))
                        .foregroundStyle(NetlumaVPNTheme.primaryText)
                        .padding(.horizontal, 8)
                        .frame(height: 18)
                        .background(NetlumaVPNTheme.surface, in: Capsule())
                        .overlay {
                            Capsule()
                                .stroke(NetlumaVPNTheme.warning.opacity(0.5), lineWidth: 1)
                        }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 46)
    }

    private var statusTitle: String {
        if isLoading {
            return L10n.string("LOADING SERVERS")
        }
        return errorMessage ?? L10n.string("NO SERVERS ONLINE")
    }
}

private struct GlobalServerRow: View {
    let server: GlobalVPNServer
    let state: GlobalServerRowState

    var body: some View {
        HStack(spacing: 14) {
            if state.isSelected {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(NetlumaVPNTheme.accent)
                    .frame(width: 4, height: 32)
            }

            GlobalServerFlag(server: server)

            VStack(alignment: .leading, spacing: 3) {
                Text(server.title)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(NetlumaVPNTheme.primaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)

                Text(server.homeSubtitle)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(NetlumaVPNTheme.secondaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }

            Spacer(minLength: 8)

            if state == .connecting {
                ProgressView()
                    .tint(NetlumaVPNTheme.warning)
                    .frame(width: 44, height: 28)
            } else {
                GlobalServerBadge(
                    title: state == .unavailable ? L10n.string("OFF") : "PRO",
                    systemImage: nil,
                    tint: state == .unavailable ? NetlumaVPNTheme.mutedText : NetlumaVPNTheme.accent
                )

                if state.isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(NetlumaVPNTheme.accent)
                        .frame(width: 18, height: 18)
                }
            }
        }
        .padding(.horizontal, 14)
        .frame(height: state.isSelected ? 74 : 68)
        .frame(maxWidth: .infinity)
        .background(state.isSelected ? NetlumaVPNTheme.accent.opacity(0.2) : .clear, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .contentShape(Rectangle())
        .opacity(state == .unavailable ? 0.55 : 1)
    }
}

private struct GlobalServerFlag: View {
    let server: GlobalVPNServer

    var body: some View {
        let flag = server.countryFlag
        Group {
            if let flag {
                Text(flag)
                    .font(.system(size: 28))
            } else {
                Text(server.countryCode)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(NetlumaVPNTheme.primaryText)
            }
        }
        .frame(width: 44, height: 44)
        .background(
            flag == nil ? server.countryColor : NetlumaVPNTheme.surface,
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(NetlumaVPNTheme.primaryText.opacity(0.18), lineWidth: 1)
        }
        .accessibilityLabel(Text(server.country.nilIfBlank ?? server.countryCode))
    }
}

private struct GlobalServerBadge: View {
    let title: String
    let systemImage: String?
    let tint: Color

    var body: some View {
        HStack(spacing: 6) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .bold))
            }

            Text(title)
                .font(.system(size: 11, weight: .bold))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 9)
        .frame(height: 24)
        .background(tint.opacity(0.2), in: Capsule())
    }
}

private struct DividerLine: View {
    var body: some View {
        Rectangle()
            .fill(NetlumaVPNTheme.borderSubtle)
            .frame(height: 1)
            .padding(.leading, 14)
    }
}

private struct ConnectionDurationText: View {
    let startedAt: Date?
    let isActive: Bool

    var body: some View {
        if isActive, let startedAt {
            TimelineView(.periodic(from: startedAt, by: 1)) { timeline in
                durationText(Self.formattedDuration(from: startedAt, to: timeline.date))
            }
        } else {
            durationText("00:00:00")
        }
    }

    private func durationText(_ value: String) -> some View {
        Text(value)
            .font(.system(size: 34, weight: .semibold, design: .monospaced))
            .monospacedDigit()
            .foregroundStyle(isActive ? NetlumaVPNTheme.primaryText : NetlumaVPNTheme.secondaryText)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
    }

    private static func formattedDuration(from startedAt: Date, to date: Date) -> String {
        let totalSeconds = max(0, Int(date.timeIntervalSince(startedAt)))
        let hours = totalSeconds / 3600
        let minutes = totalSeconds % 3600 / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
    }
}

private extension VPNProfile {
    var connectionSummary: String {
        if protocolType == .wireguard {
            return "\(protocolType.title) / UDP"
        }
        return "\(protocolType.title) / \(networkType.shortTitle) \(security.title)"
    }
}

private extension VPNNetworkType {
    var shortTitle: String {
        switch self {
        case .tcp:
            "TCP"
        case .ws:
            "WS"
        case .grpc:
            "gRPC"
        case .httpupgrade:
            "HTTPU"
        }
    }
}

private extension GlobalVPNServer {
    var homeSubtitle: String {
        let location = city.nilIfBlank ?? region.nilIfBlank ?? locationSummary.nilIfBlank ?? L10n.string("Online")
        return "\(location) · \(protocolName)"
    }

    var countryCode: String {
        switch country.lowercased() {
        case "united states", "usa", "us":
            "US"
        case "germany", "deutschland":
            "DE"
        case "netherlands", "the netherlands":
            "NL"
        case "france":
            "FR"
        case "united kingdom", "uk", "great britain":
            "UK"
        case "japan":
            "JP"
        case "singapore":
            "SG"
        default:
            country
                .split(separator: " ")
                .compactMap { $0.first }
                .prefix(2)
                .map { String($0).uppercased() }
                .joined()
                .nilIfBlank ?? "VPN"
        }
    }

    var countryColor: Color {
        switch countryCode {
        case "US":
            Color(hex: "#1E3A8A")
        case "DE":
            Color(hex: "#374151")
        case "NL":
            Color(hex: "#1D4ED8")
        case "JP":
            Color(hex: "#7F1D1D")
        case "SG":
            Color(hex: "#991B1B")
        default:
            NetlumaVPNTheme.blue.opacity(0.35)
        }
    }

    /// Emoji flag for the server's country, e.g. "Germany" -> 🇩🇪.
    /// Returns `nil` when the country cannot be mapped to an ISO region so the
    /// row can fall back to the country-code badge.
    var countryFlag: String? {
        guard let code = isoCountryCode else { return nil }
        let scalars = code.unicodeScalars.compactMap { UnicodeScalar(127_397 + $0.value) }
        guard scalars.count == 2 else { return nil }
        return String(String.UnicodeScalarView(scalars))
    }

    /// ISO 3166-1 alpha-2 code derived from the backend `country` string.
    var isoCountryCode: String? {
        let normalized = country
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard normalized.isEmpty == false else { return nil }

        // Common aliases / shorthands the backend may send.
        let aliases: [String: String] = [
            "usa": "US", "us": "US", "united states": "US",
            "united states of america": "US", "america": "US",
            "uk": "GB", "u.k.": "GB", "england": "GB",
            "great britain": "GB", "united kingdom": "GB",
            "deutschland": "DE",
            "holland": "NL", "the netherlands": "NL",
            "russia": "RU", "russian federation": "RU",
            "korea": "KR", "south korea": "KR",
            "uae": "AE", "united arab emirates": "AE",
            "czechia": "CZ", "czech republic": "CZ",
            "turkey": "TR", "türkiye": "TR",
            "hong kong": "HK", "vietnam": "VN",
        ]
        if let code = aliases[normalized] {
            return code
        }

        // Backend already sent a 2-letter ISO code.
        if normalized.count == 2, Self.isoRegionCodes.contains(normalized.uppercased()) {
            return normalized.uppercased()
        }

        // Reverse lookup by English region name (covers most countries).
        return Self.englishRegionNameToCode[normalized]
    }

    private static let isoRegionCodes: Set<String> = Set(
        Locale.Region.isoRegions
            .map(\.identifier)
            .filter { $0.count == 2 }
    )

    private static let englishRegionNameToCode: [String: String] = {
        let english = Locale(identifier: "en_US")
        var map: [String: String] = [:]
        for region in Locale.Region.isoRegions where region.identifier.count == 2 {
            if let name = english.localizedString(forRegionCode: region.identifier)?.lowercased() {
                map[name] = region.identifier
            }
        }
        return map
    }()
}

extension VPNConnectionStatus {
    var isHomeSessionActive: Bool {
        switch self {
        case .connected, .connecting, .disconnecting:
            true
        case .disconnected, .failed:
            false
        }
    }

    var homePowerAccessibilityLabel: String {
        isHomeSessionActive ? L10n.string("Disconnect") : L10n.string("Connect")
    }

    var homePowerFill: Color {
        switch self {
        case .connected:
            NetlumaVPNTheme.accent
        case .connecting:
            NetlumaVPNTheme.warning
        case .disconnecting:
            NetlumaVPNTheme.accent.opacity(0.78)
        case .failed:
            NetlumaVPNTheme.danger
        case .disconnected:
            NetlumaVPNTheme.inactiveControl
        }
    }

    var homePowerShadow: Color {
        switch self {
        case .connected:
            NetlumaVPNTheme.accent.opacity(0.4)
        case .connecting:
            NetlumaVPNTheme.warning.opacity(0.35)
        case .disconnecting:
            NetlumaVPNTheme.accent.opacity(0.3)
        case .failed, .disconnected:
            .clear
        }
    }

    var homeStatusDotColor: Color {
        switch self {
        case .connected:
            NetlumaVPNTheme.accent
        case .connecting, .disconnecting:
            NetlumaVPNTheme.warning
        case .failed:
            NetlumaVPNTheme.danger
        case .disconnected:
            NetlumaVPNTheme.mutedText
        }
    }

    var homeStatusTextColor: Color {
        isHomeSessionActive ? NetlumaVPNTheme.primaryText : NetlumaVPNTheme.secondaryText
    }

    var homeLocationTextColor: Color {
        isHomeSessionActive ? NetlumaVPNTheme.secondaryText : NetlumaVPNTheme.mutedText
    }

    var homeSessionDetailsForeground: Color {
        isHomeSessionActive ? NetlumaVPNTheme.primaryText : NetlumaVPNTheme.secondaryText
    }

    var homeSessionDetailsFill: Color {
        isHomeSessionActive ? Color(hex: "#0F172A") : Color(hex: "#101827")
    }

    var homeSessionDetailsStroke: Color {
        isHomeSessionActive ? NetlumaVPNTheme.border : NetlumaVPNTheme.borderSubtle
    }
}

#Preview("Home Inactive") {
    NavigationStack {
        HomeConnectView(
            status: .disconnected,
            connectionStartedAt: nil,
            selectedConnectionDisplayName: PreviewHomeData.profiles.first?.displayName,
            selectedProfile: PreviewHomeData.profiles.first,
            profiles: PreviewHomeData.profiles,
            selectedProfileID: PreviewHomeData.profiles.first?.id,
            globalServers: PreviewHomeData.globalServers,
            isLoadingGlobalServers: false,
            globalServersErrorMessage: nil,
            activeGlobalServerID: nil,
            selectedGlobalServerID: nil,
            onToggleConnection: {},
            onSelectProfile: { _ in },
            onEditProfile: { _ in },
            onDeleteProfile: { _ in },
            onAddProfile: {},
            onImportProfile: {},
            onScanQRCode: {},
            onReloadGlobalServers: {},
            onSelectGlobalServer: { _ in },
            onOpenPremium: {}
        )
    }
    .preferredColorScheme(.dark)
}

#Preview("Home Active") {
    NavigationStack {
        HomeConnectView(
            status: .connected,
            connectionStartedAt: Date().addingTimeInterval(-72),
            selectedConnectionDisplayName: PreviewHomeData.globalServers.first?.profileRemarks,
            selectedProfile: PreviewHomeData.profiles.first,
            profiles: PreviewHomeData.profiles,
            selectedProfileID: PreviewHomeData.profiles.first?.id,
            globalServers: PreviewHomeData.globalServers,
            isLoadingGlobalServers: false,
            globalServersErrorMessage: nil,
            activeGlobalServerID: nil,
            selectedGlobalServerID: "netlumavpn-mvp-eu-1",
            onToggleConnection: {},
            onSelectProfile: { _ in },
            onEditProfile: { _ in },
            onDeleteProfile: { _ in },
            onAddProfile: {},
            onImportProfile: {},
            onScanQRCode: {},
            onReloadGlobalServers: {},
            onSelectGlobalServer: { _ in },
            onOpenPremium: {}
        )
    }
    .preferredColorScheme(.dark)
}

private enum PreviewHomeData {
    static let profiles = [
        VPNProfile(
            id: UUID(uuidString: "8A2F9586-928D-486F-8E30-50B1E107AFD4")!,
            protocolType: .vless,
            host: "xtls.example.com",
            port: 443,
            security: .tls,
            networkType: .tcp,
            remarks: "XTLS"
        ),
        VPNProfile(
            id: UUID(uuidString: "C3AE5A11-4C42-47A9-88AE-B8C23A6E6B32")!,
            protocolType: .vless,
            host: "steal.example.com",
            port: 443,
            security: .reality,
            networkType: .tcp,
            remarks: "STEAL"
        )
    ]

    static let globalServers = [
        GlobalVPNServer(
            id: "netlumavpn-mvp-eu-1",
            name: "NetlumaVPN Global",
            country: "Germany",
            city: "Nuremberg",
            region: "Europe",
            protocolName: "VLESS Reality",
            isAvailable: true
        )
    ]
}
