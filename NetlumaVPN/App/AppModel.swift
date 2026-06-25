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
    var premiumPlans: [PremiumSubscriptionPlan] = []
    var isLoadingPremiumProducts = false
    var isPurchasingPremium = false
    var hasActivePremiumSubscription = false
    var hasLoadedPremiumEntitlements = false
    var premiumProductsErrorMessage: String?

    @ObservationIgnored private let profileStorage: ProfileStorage
    @ObservationIgnored private let networkPreferencesStorage: NetworkPreferencesStorage
    @ObservationIgnored private let vpnManager: any VPNManaging
    @ObservationIgnored private let sessionStateStorage: SessionStateStorage
    @ObservationIgnored private let displayStateStorage: ConnectionDisplayStateStorage
    @ObservationIgnored private let globalServerService: any GlobalServerServicing
    @ObservationIgnored private let premiumService: any PremiumSubscriptionServicing
    @ObservationIgnored private var onboardingStore: OnboardingCompletionStoring
    @ObservationIgnored private let parser = VPNConfigurationParser()
    @ObservationIgnored private let configDownloader: any RemoteConfigDownloading
    @ObservationIgnored private var statusObserver: NSObjectProtocol?
    @ObservationIgnored private var premiumTransactionUpdatesTask: Task<Void, Never>?

    init(
        profileStorage: ProfileStorage = ProfileStorage(),
        networkPreferencesStorage: NetworkPreferencesStorage = NetworkPreferencesStorage(),
        vpnManager: (any VPNManaging)? = nil,
        sessionStateStorage: SessionStateStorage = SessionStateStorage(),
        displayStateStorage: ConnectionDisplayStateStorage = ConnectionDisplayStateStorage(),
        globalServerService: any GlobalServerServicing = GlobalServerService(),
        premiumService: (any PremiumSubscriptionServicing)? = nil,
        onboardingStore: OnboardingCompletionStoring = UserDefaultsOnboardingCompletionStore(),
        configDownloader: any RemoteConfigDownloading = RemoteConfigDownloader()
    ) {
        self.profileStorage = profileStorage
        self.networkPreferencesStorage = networkPreferencesStorage
        self.networkPreferences = networkPreferencesStorage.load()
        self.vpnManager = vpnManager ?? VPNManager(networkPreferencesStorage: networkPreferencesStorage)
        self.sessionStateStorage = sessionStateStorage
        self.displayStateStorage = displayStateStorage
        self.globalServerService = globalServerService
        self.premiumService = premiumService ?? StoreKitPremiumSubscriptionService()
        self.onboardingStore = onboardingStore
        self.configDownloader = configDownloader
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
        premiumTransactionUpdatesTask?.cancel()
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

    var shouldShowPremiumBanner: Bool {
        hasLoadedPremiumEntitlements && !hasActivePremiumSubscription
    }

    var premiumBannerPriceText: String {
        if let weeklyPlan = premiumPlans.first(where: { $0.kind == .weekly }) {
            return L10n.format("from %@", weeklyPlan.displayPrice)
        }

        if let firstPlan = premiumPlans.first {
            return L10n.format("from %@", firstPlan.displayPrice)
        }

        return isLoadingPremiumProducts ? L10n.string("Loading prices") : L10n.string("Plans")
    }

    func loadPremiumProducts(force: Bool = false) async {
        guard !isLoadingPremiumProducts else {
            return
        }
        guard force || premiumPlans.isEmpty || premiumProductsErrorMessage != nil else {
            return
        }

        isLoadingPremiumProducts = true
        premiumProductsErrorMessage = nil
        defer {
            isLoadingPremiumProducts = false
        }

        do {
            premiumPlans = try await premiumService.loadProducts()
            AppLogger.info("Loaded \(premiumPlans.count) premium product(s)", category: .app)
        } catch {
            AppLogger.error(error, message: "Load premium products failed", category: .app)
            premiumProductsErrorMessage = error.localizedDescription
        }
    }

    /// Begins premium monitoring for the app session: starts the StoreKit
    /// `Transaction.updates` observer and performs an authoritative entitlement check so an
    /// active subscription is pulled in (and the upsell banner suppressed) from launch, while
    /// a lapsed subscription immediately revokes access. Idempotent — safe to call repeatedly.
    func bootstrapPremium() async {
        startPremiumTransactionObserver()
        await refreshPremiumEntitlements()
    }

    func refreshPremiumEntitlements() async {
        hasActivePremiumSubscription = await premiumService.hasActiveSubscription()
        hasLoadedPremiumEntitlements = true
        await enforcePremiumAccessIfNeeded()
    }

    func purchasePremium(productID: String) async -> Bool {
        startPremiumTransactionObserver()
        guard !isPurchasingPremium else {
            return false
        }

        isPurchasingPremium = true
        defer {
            isPurchasingPremium = false
        }

        do {
            switch try await premiumService.purchase(productID: productID) {
            case .purchased:
                await refreshPremiumEntitlements()
                if hasActivePremiumSubscription {
                    return true
                }
                errorMessage = L10n.string("Purchase completed, but no active subscription was found yet.")
                return false
            case .cancelled:
                return false
            case .pending:
                errorMessage = L10n.string("Purchase is pending approval.")
                return false
            }
        } catch {
            AppLogger.error(error, message: "Premium purchase failed", category: .app)
            errorMessage = error.localizedDescription
            return false
        }
    }

    func restorePremiumPurchases() async -> Bool {
        startPremiumTransactionObserver()
        guard !isPurchasingPremium else {
            return false
        }

        isPurchasingPremium = true
        defer {
            isPurchasingPremium = false
        }

        do {
            hasActivePremiumSubscription = try await premiumService.restorePurchases()
            hasLoadedPremiumEntitlements = true
            if hasActivePremiumSubscription {
                return true
            }
            errorMessage = L10n.string("No active subscription was found.")
            return false
        } catch {
            AppLogger.error(error, message: "Premium restore failed", category: .app)
            errorMessage = error.localizedDescription
            return false
        }
    }

    func completeOnboarding() {
        onboardingStore.hasCompletedOnboarding = true
        hasCompletedOnboarding = true
        AppLogger.info("Onboarding completed", category: .app)
    }

    func refreshStatus() async {
        apply(connectionState: await vpnManager.currentConnectionState())
    }

    func selectProfile(_ profile: VPNProfile) async {
        let shouldDisconnect = shouldDisconnectForProfileSelection(profile)
        selectProfileImmediately(profile)
        if shouldDisconnect {
            await disconnect()
        }
    }

    private func selectProfileImmediately(_ profile: VPNProfile) {
        selectedProfileID = profile.id
        selectedGlobalServerID = profile.isNetlumaVPNManaged ? profile.managedServerID : nil
        profileStorage.setSelectedProfileID(profile.id)
        reloadWidgets()
    }

    func saveProfile(_ profile: VPNProfile, secret: VPNProfileSecret) throws {
        try profileStorage.saveProfile(profile, secret: secret)
        reloadProfiles()
        selectProfileImmediately(profile)
        AppLogger.info("Profile selected after save \(AppLogger.safeProfileLabel(profile))", category: .app)
    }

    /// Imports a profile from a pasted/scanned value.
    ///
    /// When the value is an http(s) link (e.g. a `*-VLESS-CLIENT.json` file), the
    /// file is downloaded first and its body is parsed. Any other value — a
    /// vless:// / vmess:// / trojan:// / WireGuard link, or inline JSON — is parsed
    /// directly, exactly as before.
    func importProfile(from value: String) async throws {
        AppLogger.info("Import requested", category: .importConfig)
        let rawConfig: String
        if let remoteURL = RemoteConfigDownloader.remoteConfigURL(from: value) {
            rawConfig = try await configDownloader.download(from: remoteURL)
        } else {
            rawConfig = value
        }
        let (profile, secret) = try parser.parse(rawConfig)
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

    func selectGlobalServer(_ server: GlobalVPNServer) async -> PremiumGatedActionResult {
        await refreshPremiumEntitlements()
        guard !PremiumAccessGate.requiresPremium(
            selectedGlobalServerID: server.id,
            selectedProfile: nil,
            hasActiveSubscription: hasActivePremiumSubscription
        ) else {
            return .requiresPremium
        }

        let shouldDisconnect = shouldDisconnectForGlobalServerSelection(server)
        selectGlobalServerImmediately(server)
        if shouldDisconnect {
            await disconnect()
        }
        return .proceeded
    }

    private func selectGlobalServerImmediately(_ server: GlobalVPNServer) {
        guard server.isAvailable else {
            return
        }

        applyPreferredIPMode(for: server)
        selectedGlobalServerID = server.id
        if let existingProfile = profiles.first(where: { $0.isNetlumaVPNManaged && $0.managedServerID == server.id }) {
            selectedProfileID = existingProfile.id
            profileStorage.setSelectedProfileID(existingProfile.id)
        } else {
            selectedProfileID = nil
            profileStorage.setSelectedProfileID(nil)
        }
        reloadWidgets()
    }

    private func shouldDisconnectForProfileSelection(_ profile: VPNProfile) -> Bool {
        guard status.shouldDisconnectBeforeSelectionChange else {
            return false
        }

        let nextGlobalServerID = profile.isNetlumaVPNManaged ? profile.managedServerID : nil
        return selectedProfileID != profile.id || selectedGlobalServerID != nextGlobalServerID
    }

    private func shouldDisconnectForGlobalServerSelection(_ server: GlobalVPNServer) -> Bool {
        guard server.isAvailable, status.shouldDisconnectBeforeSelectionChange else {
            return false
        }

        return selectedGlobalServerID != server.id
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
            if let existingProfile = profiles.first(where: { $0.isNetlumaVPNManaged && $0.managedServerID == server.id }) {
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
                return L10n.string("SERVER TIMEOUT")
            case .notConnectedToInternet, .networkConnectionLost:
                return L10n.string("NO INTERNET")
            case .cannotFindHost, .cannotConnectToHost:
                return L10n.string("SERVER OFFLINE")
            case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate:
                return L10n.string("TLS CHECK FAILED")
            default:
                break
            }
        }

        return L10n.string("SERVER LOAD FAILED")
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

    func toggleConnection() async -> PremiumGatedActionResult {
        switch status {
        case .connected, .connecting:
            await disconnect()
        case .disconnected, .disconnecting, .failed:
            if PremiumAccessGate.requiresPremium(
                selectedGlobalServerID: selectedGlobalServerID,
                selectedProfile: selectedProfile,
                hasActiveSubscription: false
            ) {
                await refreshPremiumEntitlements()
            }

            guard !PremiumAccessGate.requiresPremium(
                selectedGlobalServerID: selectedGlobalServerID,
                selectedProfile: selectedProfile,
                hasActiveSubscription: hasActivePremiumSubscription
            ) else {
                return .requiresPremium
            }

            if let selectedGlobalServerID,
               let server = globalServers.first(where: { $0.id == selectedGlobalServerID }) {
                await connectSelectedGlobalServer(server)
            } else {
                await connect()
            }
        }
        return .proceeded
    }

    private func connect() async {
        guard let profile = selectedProfile else {
            AppLogger.warning("Connect requested without selected profile", category: .app)
            errorMessage = L10n.string("Add or select a VPN profile first.")
            return
        }

        guard !PremiumAccessGate.requiresPremium(
            selectedGlobalServerID: nil,
            selectedProfile: profile,
            hasActiveSubscription: hasActivePremiumSubscription
        ) else {
            AppLogger.warning("Blocked managed profile connection without active subscription", category: .app)
            errorMessage = L10n.string("Netluma Global requires an active Premium subscription.")
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

    private func startPremiumTransactionObserver() {
        guard premiumTransactionUpdatesTask == nil else {
            return
        }

        premiumTransactionUpdatesTask = premiumService.observeTransactionUpdates { [weak self] isActive in
            guard let self else {
                return
            }
            self.hasActivePremiumSubscription = isActive
            self.hasLoadedPremiumEntitlements = true
            await self.enforcePremiumAccessIfNeeded()
        }
    }

    /// Tears down a live Netluma Global / managed tunnel the moment the user stops holding an
    /// active subscription, so a lapsed / refunded / revoked subscription loses access
    /// mid-session rather than only being blocked at the next connect attempt.
    private func enforcePremiumAccessIfNeeded() async {
        guard PremiumAccessGate.shouldRevokeActiveSession(
            status: status,
            selectedGlobalServerID: selectedGlobalServerID,
            selectedProfile: selectedProfile,
            hasActiveSubscription: hasActivePremiumSubscription
        ) else {
            return
        }

        AppLogger.info("Premium access ended during an active managed session — disconnecting", category: .app)
        errorMessage = L10n.string("Your Premium subscription has ended. Netluma Global requires an active subscription.")
        await disconnect()
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
                  let managedProfile = profiles.first(where: { $0.isNetlumaVPNManaged && $0.managedServerID == selectedGlobalServerID }) {
            selectedProfileID = managedProfile.id
        } else if selectedGlobalServerID != nil {
            selectedProfileID = nil
            profileStorage.setSelectedProfileID(nil)
        } else {
            selectedProfileID = profiles.first?.id
            profileStorage.setSelectedProfileID(selectedProfileID)
        }

        if let selectedProfile = profiles.first(where: { $0.id == selectedProfileID }) {
            selectedGlobalServerID = selectedProfile.isNetlumaVPNManaged ? selectedProfile.managedServerID : nil
        }
    }
}

private extension VPNConnectionStatus {
    var shouldDisconnectBeforeSelectionChange: Bool {
        switch self {
        case .connected, .connecting:
            true
        case .disconnected, .disconnecting, .failed:
            false
        }
    }
}
