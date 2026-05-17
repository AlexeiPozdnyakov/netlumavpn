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
        profiles.filter { !$0.isQuickVPNManaged }.sorted {
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
        .background(QuickVPNTheme.backgroundGradient)
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
        if let selectedProfile, selectedGlobalServerID == nil, !selectedProfile.isQuickVPNManaged {
            Button {
                onEditProfile(selectedProfile)
            } label: {
                Text("Edit")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(QuickVPNTheme.primaryText)
                    .padding(.horizontal, 16)
                    .frame(height: 33)
                    .background(QuickVPNTheme.card, in: Capsule())
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
                .foregroundStyle(QuickVPNTheme.primaryText)
                .frame(width: 36, height: 36)
                .background(QuickVPNTheme.card, in: Circle())
        }
        .accessibilityLabel("Add Profile")
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
                        .foregroundStyle(QuickVPNTheme.primaryText)
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
        .background(QuickVPNTheme.surface, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
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

            Text(selectedConnectionDisplayName ?? "No profile selected")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(status.homeLocationTextColor)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .padding(.top, 18)
    }

    private var profilesAndServers: some View {
        VStack(spacing: 10) {
            localProfilesSection
            globalServersSection
        }
    }

    private var localProfilesSection: some View {
        VStack(spacing: 0) {
            SectionHeader(
                title: "LOCAL PROFILES",
                trailing: "\(sortedProfiles.count) ACTIVE"
            )
            .frame(height: 33)

            if sortedProfiles.isEmpty {
                EmptyProfileRow(onAddProfile: onAddProfile)
            } else {
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
        }
        .background(QuickVPNTheme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(QuickVPNTheme.borderSubtle, lineWidth: 1)
        }
    }

    private var globalServersSection: some View {
        VStack(spacing: 0) {
            SectionHeader(
                title: "GLOBAL SERVERS",
                trailing: globalServersTrailingTitle
            )
            .frame(height: 39)

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
                    .accessibilityHint(server.isAvailable ? "Selects this global server" : "Server unavailable")

                    if index < globalServers.count - 1 {
                        DividerLine()
                    }
                }
            }
        }
        .background(QuickVPNTheme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(QuickVPNTheme.borderSubtle, lineWidth: 1)
        }
    }

    private var globalServersTrailingTitle: String {
        if isLoadingGlobalServers {
            return "LOADING"
        }
        if globalServersErrorMessage != nil {
            return "FAILED"
        }
        return "\(globalServers.count) ONLINE"
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
            Text(title)
                .font(.system(size: 10, weight: .heavy))
                .foregroundStyle(QuickVPNTheme.primaryText)

            Spacer()

            trailing
                .font(.system(size: 9, weight: .heavy))
                .foregroundStyle(QuickVPNTheme.secondaryText)
        }
        .padding(.horizontal, 14)
    }
}

private struct EmptyProfileRow: View {
    let onAddProfile: () -> Void

    var body: some View {
        Button(action: onAddProfile) {
            HStack(spacing: 10) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(QuickVPNTheme.accent)

                VStack(alignment: .leading, spacing: 3) {
                    Text("ADD PROFILE")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(QuickVPNTheme.primaryText)
                    Text("Import URL / scan QR")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(QuickVPNTheme.secondaryText)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(QuickVPNTheme.blue)
            }
            .padding(.horizontal, 14)
            .frame(height: 45)
        }
        .buttonStyle(.plain)
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
            .background(QuickVPNTheme.card)
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
                .foregroundStyle(QuickVPNTheme.primaryText)
                .background(QuickVPNTheme.blue)
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
                .foregroundStyle(QuickVPNTheme.primaryText)
                .background(QuickVPNTheme.danger)
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
                .fill(isSelected ? QuickVPNTheme.accent : QuickVPNTheme.blue)
                .frame(width: 7, height: 7)

            VStack(alignment: .leading, spacing: 3) {
                Text(profile.displayName.uppercased())
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(QuickVPNTheme.primaryText)
                    .lineLimit(1)

                Text(profile.connectionSummary.uppercased())
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(QuickVPNTheme.secondaryText)
                    .lineLimit(1)
            }

            Spacer()

            Image(systemName: isSelected ? "checkmark.circle.fill" : "info.circle")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(isSelected ? QuickVPNTheme.accent : QuickVPNTheme.blue)
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
            "SELECT"
        case .selected:
            "SELECTED"
        case .connecting:
            "..."
        case .connected:
            "ON"
        case .unavailable:
            "OFF"
        }
    }

    var tint: Color {
        switch self {
        case .connected:
            QuickVPNTheme.accent
        case .connecting:
            QuickVPNTheme.warning
        case .unavailable:
            QuickVPNTheme.mutedText
        case .idle, .selected:
            QuickVPNTheme.blue
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
                    .tint(QuickVPNTheme.blue)
                    .frame(width: 28, height: 28)
            } else {
                Image(systemName: "wifi.exclamationmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(QuickVPNTheme.warning)
                    .frame(width: 28, height: 28)
            }

            Text(statusTitle)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(QuickVPNTheme.secondaryText)

            Spacer()

            if !isLoading, errorMessage != nil {
                Button(action: onRetry) {
                    Text("RETRY")
                        .font(.system(size: 8, weight: .heavy))
                        .foregroundStyle(QuickVPNTheme.primaryText)
                        .padding(.horizontal, 8)
                        .frame(height: 18)
                        .background(QuickVPNTheme.surface, in: Capsule())
                        .overlay {
                            Capsule()
                                .stroke(QuickVPNTheme.warning.opacity(0.5), lineWidth: 1)
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
            return "LOADING SERVERS"
        }
        return errorMessage ?? "NO SERVERS ONLINE"
    }
}

private struct GlobalServerRow: View {
    let server: GlobalVPNServer
    let state: GlobalServerRowState

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: state.isSelected ? "checkmark.shield.fill" : "globe.europe.africa.fill")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(state.tint)
                .frame(width: 28, height: 28)
                .background(state.tint.opacity(0.16), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(state.tint.opacity(0.35), lineWidth: 1)
                }

            VStack(alignment: .leading, spacing: 3) {
                Text(server.title.uppercased())
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(QuickVPNTheme.primaryText)
                    .lineLimit(1)

                Text("\(server.locationSummary) · \(server.protocolName)")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(QuickVPNTheme.secondaryText)
                    .lineLimit(1)
            }

            Spacer()

            if state == .connecting {
                ProgressView()
                    .tint(QuickVPNTheme.warning)
                    .frame(width: 36, height: 28)
            } else {
                Text(state.trailingTitle)
                    .font(.system(size: 8, weight: .heavy))
                    .foregroundStyle(state == .connected ? QuickVPNTheme.onAccent : QuickVPNTheme.primaryText)
                    .padding(.horizontal, 7)
                    .frame(height: 18)
                    .background(state == .connected ? QuickVPNTheme.accent : QuickVPNTheme.surface, in: Capsule())
                    .overlay {
                        Capsule()
                            .stroke(state.tint.opacity(0.35), lineWidth: 1)
                    }
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 46)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }
}

private struct DividerLine: View {
    var body: some View {
        Rectangle()
            .fill(QuickVPNTheme.borderSubtle)
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
            .foregroundStyle(isActive ? QuickVPNTheme.primaryText : QuickVPNTheme.secondaryText)
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
        isHomeSessionActive ? "Disconnect" : "Connect"
    }

    var homePowerFill: Color {
        switch self {
        case .connected:
            QuickVPNTheme.accent
        case .connecting:
            QuickVPNTheme.warning
        case .disconnecting:
            QuickVPNTheme.accent.opacity(0.78)
        case .failed:
            QuickVPNTheme.danger
        case .disconnected:
            QuickVPNTheme.inactiveControl
        }
    }

    var homePowerShadow: Color {
        switch self {
        case .connected:
            QuickVPNTheme.accent.opacity(0.4)
        case .connecting:
            QuickVPNTheme.warning.opacity(0.35)
        case .disconnecting:
            QuickVPNTheme.accent.opacity(0.3)
        case .failed, .disconnected:
            .clear
        }
    }

    var homeStatusDotColor: Color {
        switch self {
        case .connected:
            QuickVPNTheme.accent
        case .connecting, .disconnecting:
            QuickVPNTheme.warning
        case .failed:
            QuickVPNTheme.danger
        case .disconnected:
            QuickVPNTheme.mutedText
        }
    }

    var homeStatusTextColor: Color {
        isHomeSessionActive ? QuickVPNTheme.primaryText : QuickVPNTheme.secondaryText
    }

    var homeLocationTextColor: Color {
        isHomeSessionActive ? QuickVPNTheme.secondaryText : QuickVPNTheme.mutedText
    }

    var homeSessionDetailsForeground: Color {
        isHomeSessionActive ? QuickVPNTheme.primaryText : QuickVPNTheme.secondaryText
    }

    var homeSessionDetailsFill: Color {
        isHomeSessionActive ? Color(hex: "#0F172A") : Color(hex: "#101827")
    }

    var homeSessionDetailsStroke: Color {
        isHomeSessionActive ? QuickVPNTheme.border : QuickVPNTheme.borderSubtle
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
            selectedGlobalServerID: "quickvpn-mvp-eu-1",
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
            id: "quickvpn-mvp-eu-1",
            name: "QuickVPN Global",
            country: "Germany",
            city: "Nuremberg",
            region: "Europe",
            protocolName: "VLESS Reality",
            isAvailable: true
        )
    ]
}
