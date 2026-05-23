import Foundation
import Observation
import WidgetKit

protocol OnboardingCompletionStoring {
    var hasCompletedOnboarding: Bool { get set }
}

struct UserDefaultsOnboardingCompletionStore: OnboardingCompletionStoring {
    private let defaults: UserDefaults
    private let key: String

    init(
        defaults: UserDefaults = .standard,
        key: String = "hasCompletedOnboarding.v1"
    ) {
        self.defaults = defaults
        self.key = key
    }

    var hasCompletedOnboarding: Bool {
        get {
            defaults.bool(forKey: key)
        }
        nonmutating set {
            defaults.set(newValue, forKey: key)
        }
    }
}

@MainActor
@Observable
final class AppModel {
    var profiles: [VPNProfile] = []
    var selectedProfileID: UUID?
    var status: VPNConnectionStatus = .disconnected
    var connectionStartedAt: Date?
    var networkPreferences: NetworkPreferences
    var hasCompletedOnboarding: Bool
    var errorMessage: String?
    var globalServers: [GlobalVPNServer] = []
    var isLoadingGlobalServers = false
    var activeGlobalServerID: String?
    var selectedGlobalServerID: String?
    var globalServersErrorMessage: String?

    @ObservationIgnored private let profileStorage: ProfileStorage
    @ObservationIgnored private let networkPreferencesStorage: NetworkPreferencesStorage
    @ObservationIgnored private let vpnManager: any VPNManaging
    @ObservationIgnored private let sessionStateStorage: SessionStateStorage
    @ObservationIgnored private let displayStateStorage: ConnectionDisplayStateStorage
    @ObservationIgnored private let widgetActionStorage: WidgetActionStorage
    @ObservationIgnored private let globalServerService: any GlobalServerServicing
    @ObservationIgnored private var onboardingStore: OnboardingCompletionStoring
    @ObservationIgnored private let parser = VPNConfigurationParser()
    @ObservationIgnored private var statusObserver: NSObjectProtocol?

    init(
        profileStorage: ProfileStorage = ProfileStorage(),
        networkPreferencesStorage: NetworkPreferencesStorage = NetworkPreferencesStorage(),
        vpnManager: (any VPNManaging)? = nil,
        sessionStateStorage: SessionStateStorage = SessionStateStorage(),
        displayStateStorage: ConnectionDisplayStateStorage = ConnectionDisplayStateStorage(),
        widgetActionStorage: WidgetActionStorage = WidgetActionStorage(),
        globalServerService: any GlobalServerServicing = GlobalServerService(),
        onboardingStore: OnboardingCompletionStoring = UserDefaultsOnboardingCompletionStore()
    ) {
        self.profileStorage = profileStorage
        self.networkPreferencesStorage = networkPreferencesStorage
        self.networkPreferences = networkPreferencesStorage.load()
        self.vpnManager = vpnManager ?? VPNManager(networkPreferencesStorage: networkPreferencesStorage)
        self.sessionStateStorage = sessionStateStorage
        self.displayStateStorage = displayStateStorage
        self.widgetActionStorage = widgetActionStorage
        self.globalServerService = globalServerService
        self.onboardingStore = onboardingStore
        self.hasCompletedOnboarding = onboardingStore.hasCompletedOnboarding
        reloadProfiles()
        AppLogger.info("App model initialized with \(profiles.count) profile(s)", category: .app)
        statusObserver = self.vpnManager.observeConnectionState { [weak self] connectionState in
            self?.apply(connectionState: connectionState)
        }
    }

    deinit {
        if let statusObserver {
            NotificationCenter.default.removeObserver(statusObserver)
        }
    }

    var selectedProfile: VPNProfile? {
        profiles.first { $0.id == selectedProfileID } ?? profiles.first
    }

    var selectedDNSResolver: DNSResolver {
        networkPreferences.selectedDNSResolver
    }

    var selectedConnectionDisplayName: String? {
        if let selectedGlobalServerID,
           let server = globalServers.first(where: { $0.id == selectedGlobalServerID }) {
            return server.profileRemarks
        }

        return selectedProfile?.displayName
    }

    func completeOnboarding() {
        onboardingStore.hasCompletedOnboarding = true
        hasCompletedOnboarding = true
        AppLogger.info("Onboarding completed", category: .app)
    }

    func refreshStatus() async {
        apply(connectionState: await vpnManager.currentConnectionState())
    }

    func handlePendingWidgetAction() async {
        guard widgetActionStorage.consumePendingToggle() else {
            return
        }

        AppLogger.info("Handling VPN toggle requested from widget", category: .app)
        await refreshStatus()
        await toggleConnection()
    }

    func selectProfile(_ profile: VPNProfile) {
        selectedProfileID = profile.id
        selectedGlobalServerID = profile.isQuickVPNManaged ? profile.managedServerID : nil
        profileStorage.setSelectedProfileID(profile.id)
        reloadWidgets()
    }

    func saveProfile(_ profile: VPNProfile, secret: VPNProfileSecret) throws {
        try profileStorage.saveProfile(profile, secret: secret)
        reloadProfiles()
        selectProfile(profile)
        AppLogger.info("Profile selected after save \(AppLogger.safeProfileLabel(profile))", category: .app)
    }

    func importProfile(from value: String) throws {
        AppLogger.info("Import requested", category: .importConfig)
        let (profile, secret) = try parser.parse(value)
        try saveProfile(profile, secret: secret)
        AppLogger.info("Import completed for \(AppLogger.safeProfileLabel(profile))", category: .importConfig)
    }

    func loadGlobalServers(force: Bool = false) async {
        guard !isLoadingGlobalServers else {
            return
        }
        guard force || globalServers.isEmpty || globalServersErrorMessage != nil else {
            return
        }

        isLoadingGlobalServers = true
        globalServersErrorMessage = nil
        defer {
            isLoadingGlobalServers = false
        }

        do {
            globalServers = try await globalServerService.fetchServers()
            AppLogger.info("Loaded \(globalServers.count) global server(s)", category: .app)
        } catch {
            AppLogger.error(error, message: "Load global servers failed", category: .app)
            if globalServers.isEmpty {
                globalServersErrorMessage = Self.globalServerLoadMessage(for: error)
            }
        }
    }

    func selectGlobalServer(_ server: GlobalVPNServer) {
        guard server.isAvailable else {
            return
        }

        applyPreferredIPMode(for: server)
        selectedGlobalServerID = server.id
        if let existingProfile = profiles.first(where: { $0.isQuickVPNManaged && $0.managedServerID == server.id }) {
            selectedProfileID = existingProfile.id
            profileStorage.setSelectedProfileID(existingProfile.id)
        } else {
            selectedProfileID = nil
            profileStorage.setSelectedProfileID(nil)
        }
        reloadWidgets()
    }

    private func connectSelectedGlobalServer(_ server: GlobalVPNServer) async {
        guard server.isAvailable else {
            return
        }
        if activeGlobalServerID == server.id {
            return
        }

        activeGlobalServerID = server.id
        defer {
            activeGlobalServerID = nil
        }

        if status.isHomeSessionActive {
            await disconnect()
        }

        do {
            applyPreferredIPMode(for: server)
            var (profile, secret) = try await globalServerService.provisionProfile(for: server)
            if let existingProfile = profiles.first(where: { $0.isQuickVPNManaged && $0.managedServerID == server.id }) {
                profile.id = existingProfile.id
                profile.createdAt = existingProfile.createdAt
            }
            try saveProfile(profile, secret: secret)
            await connect()
        } catch {
            AppLogger.error(error, message: "Global server connect failed", category: .app)
            errorMessage = Self.globalServerLoadMessage(for: error)
        }
    }

    private static func globalServerLoadMessage(for error: Error) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut:
                return "SERVER TIMEOUT"
            case .notConnectedToInternet, .networkConnectionLost:
                return "NO INTERNET"
            case .cannotFindHost, .cannotConnectToHost:
                return "SERVER OFFLINE"
            case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate:
                return "TLS CHECK FAILED"
            default:
                break
            }
        }

        return "SERVER LOAD FAILED"
    }

    func deleteProfile(_ profile: VPNProfile) {
        do {
            try profileStorage.deleteProfile(profile)
            reloadProfiles()
            reloadWidgets()
        } catch {
            AppLogger.error(error, message: "Delete profile failed", category: .app)
            errorMessage = error.localizedDescription
        }
    }

    func secret(for profile: VPNProfile) -> VPNProfileSecret? {
        do {
            return try profileStorage.secret(for: profile)
        } catch {
            AppLogger.error(error, message: "Load profile secret failed", category: .storage)
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func updateTunnelPreferences(_ preferences: TunnelPreferences) {
        networkPreferences.tunnel = preferences
        saveNetworkPreferences()
        reloadWidgets()
    }

    func selectDNSResolver(_ resolver: DNSResolver) {
        networkPreferences.selectedDNSResolverID = resolver.id
        saveNetworkPreferences()
        reloadWidgets()
    }

    func toggleConnection() async {
        switch status {
        case .connected, .connecting:
            await disconnect()
        case .disconnected, .disconnecting, .failed:
            if let selectedGlobalServerID,
               let server = globalServers.first(where: { $0.id == selectedGlobalServerID }) {
                await connectSelectedGlobalServer(server)
            } else {
                await connect()
            }
        }
    }

    private func connect() async {
        guard let profile = selectedProfile else {
            AppLogger.warning("Connect requested without selected profile", category: .app)
            errorMessage = "Add or select a VPN profile first."
            return
        }

        do {
            apply(status: .connecting, connectionStartedAt: Date())
            apply(connectionState: try await vpnManager.connect(profile: profile))
        } catch {
            apply(status: .failed)
            AppLogger.error(error, message: "Connect failed", category: .app)
            errorMessage = error.localizedDescription
        }
    }

    private func disconnect() async {
        do {
            apply(status: .disconnecting)
            apply(connectionState: try await vpnManager.disconnect())
        } catch {
            apply(status: .failed)
            AppLogger.error(error, message: "Disconnect failed", category: .app)
            errorMessage = error.localizedDescription
        }
    }

    private func apply(connectionState: VPNConnectionState) {
        apply(status: connectionState.status, connectionStartedAt: connectionState.connectedDate)
    }

    private func apply(status newStatus: VPNConnectionStatus, connectionStartedAt reportedStartedAt: Date? = nil) {
        let shouldReloadWidgets = status != newStatus
        status = newStatus

        switch newStatus {
        case .connecting, .connected:
            let startedAt = reportedStartedAt
                ?? connectionStartedAt
                ?? sessionStateStorage.connectionStartedAt()
                ?? Date()
            connectionStartedAt = startedAt
            sessionStateStorage.markConnectionStarted(at: startedAt)
            displayStateStorage.save(status: newStatus, connectionStartedAt: startedAt)
        case .disconnecting:
            connectionStartedAt = reportedStartedAt
                ?? connectionStartedAt
                ?? sessionStateStorage.connectionStartedAt()
            displayStateStorage.save(status: newStatus, connectionStartedAt: connectionStartedAt)
        case .disconnected, .failed:
            connectionStartedAt = nil
            sessionStateStorage.clearConnectionStartedAt()
            displayStateStorage.save(status: newStatus)
        }

        if shouldReloadWidgets {
            reloadWidgets()
        }
    }

    private func saveNetworkPreferences() {
        networkPreferencesStorage.save(networkPreferences)
    }

    private func applyPreferredIPMode(for server: GlobalVPNServer) {
        guard networkPreferences.tunnel.ipMode != server.preferredIPMode else {
            return
        }
        networkPreferences.tunnel.ipMode = server.preferredIPMode
        saveNetworkPreferences()
    }

    private func reloadWidgets() {
        WidgetCenter.shared.reloadAllTimelines()
    }

    private func reloadProfiles() {
        profiles = profileStorage.loadProfiles()
        let storedProfileID = profileStorage.selectedProfileID()

        if let storedProfileID,
           profiles.contains(where: { $0.id == storedProfileID }) {
            selectedProfileID = storedProfileID
        } else if let currentProfileID = selectedProfileID,
                  profiles.contains(where: { $0.id == currentProfileID }) {
            selectedProfileID = currentProfileID
        } else if let selectedGlobalServerID,
                  let managedProfile = profiles.first(where: { $0.isQuickVPNManaged && $0.managedServerID == selectedGlobalServerID }) {
            selectedProfileID = managedProfile.id
        } else if selectedGlobalServerID != nil {
            selectedProfileID = nil
            profileStorage.setSelectedProfileID(nil)
        } else {
            selectedProfileID = profiles.first?.id
            profileStorage.setSelectedProfileID(selectedProfileID)
        }

        if let selectedProfile = profiles.first(where: { $0.id == selectedProfileID }) {
            selectedGlobalServerID = selectedProfile.isQuickVPNManaged ? selectedProfile.managedServerID : nil
        }
    }
}
