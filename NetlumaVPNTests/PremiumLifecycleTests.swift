import Foundation
import Testing
@testable import NetlumaVPN

/// Covers the subscription *lifecycle* wiring in `AppModel` while temporary free-access
/// mode is enabled: launch/foreground checks grant access without StoreKit, the
/// transaction observer is skipped, and mid-session revocation is suppressed. The
/// StoreKit `Product`/`Transaction` plumbing itself lives in
/// `StoreKitPremiumSubscriptionService` and is exercised only through the injected
/// `ControllablePremiumService` fake here.
struct PremiumLifecycleTests {
    private static let managedServerID = "netlumavpn-mvp-eu-1"

    // MARK: - Pure gate logic

    @Test func freeAccessDoesNotRevokeLiveManagedSessions() {
        let local = VPNProfile(
            protocolType: .vless,
            host: "local.example.com",
            port: 443,
            security: .tls,
            networkType: .tcp,
            remarks: "Local"
        )

        // Temporary free access keeps live global sessions up even without a subscription.
        #expect(PremiumAccessGate.shouldRevokeActiveSession(
            status: .connected,
            selectedGlobalServerID: Self.managedServerID,
            selectedProfile: nil,
            hasActiveSubscription: false
        ) == false)
        #expect(PremiumAccessGate.shouldRevokeActiveSession(
            status: .connecting,
            selectedGlobalServerID: Self.managedServerID,
            selectedProfile: nil,
            hasActiveSubscription: false
        ) == false)

        // A valid subscription, a user-imported profile, or an inactive session must not.
        #expect(PremiumAccessGate.shouldRevokeActiveSession(
            status: .connected,
            selectedGlobalServerID: Self.managedServerID,
            selectedProfile: nil,
            hasActiveSubscription: true
        ) == false)
        #expect(PremiumAccessGate.shouldRevokeActiveSession(
            status: .connected,
            selectedGlobalServerID: nil,
            selectedProfile: local,
            hasActiveSubscription: false
        ) == false)
        for status in [VPNConnectionStatus.disconnected, .disconnecting, .failed] {
            #expect(PremiumAccessGate.shouldRevokeActiveSession(
                status: status,
                selectedGlobalServerID: Self.managedServerID,
                selectedProfile: nil,
                hasActiveSubscription: false
            ) == false)
        }
    }

    // MARK: - Launch / foreground entitlement check

    @MainActor
    @Test func bootstrapMarksFreeAccessActiveAndHidesBannerWithoutStoreKitObserver() async {
        let premium = ControllablePremiumService(active: false)
        let model = Self.makeModel(premium: premium)

        await model.bootstrapPremium()

        #expect(model.hasActivePremiumSubscription)
        #expect(model.hasLoadedPremiumEntitlements)
        #expect(model.shouldShowPremiumBanner == false)
        #expect(premium.observeCallCount == 0)
    }

    @MainActor
    @Test func bootstrapHidesBannerForNonSubscriberWhileFreeAccessIsEnabled() async {
        let premium = ControllablePremiumService(active: false)
        let model = Self.makeModel(premium: premium)

        await model.bootstrapPremium()

        #expect(model.hasActivePremiumSubscription)
        #expect(model.hasLoadedPremiumEntitlements)
        #expect(model.shouldShowPremiumBanner == false)
    }

    @MainActor
    @Test func bootstrapSkipsTransactionObserverWhileFreeAccessIsEnabled() async {
        let premium = ControllablePremiumService(active: true)
        let model = Self.makeModel(premium: premium)

        await model.bootstrapPremium()
        await model.bootstrapPremium()

        #expect(premium.observeCallCount == 0)
    }

    // MARK: - Free access entitlement refresh

    @MainActor
    @Test func foregroundRefreshKeepsManagedSessionWhenSubscriptionLapsesDuringFreeAccess() async {
        let premium = ControllablePremiumService(active: true)
        let vpn = RecordingVPNManager()
        let model = Self.makeModel(premium: premium, vpn: vpn)
        model.hasActivePremiumSubscription = true
        model.hasLoadedPremiumEntitlements = true
        model.selectedGlobalServerID = Self.managedServerID
        model.status = .connected

        premium.active = false
        await model.refreshPremiumEntitlements()

        #expect(model.hasActivePremiumSubscription)
        #expect(model.shouldShowPremiumBanner == false)
        #expect(vpn.disconnectCallCount == 0)
        #expect(model.status == .connected)
    }

    @MainActor
    @Test func foregroundRefreshKeepsManagedSessionForActiveSubscriber() async {
        let premium = ControllablePremiumService(active: true)
        let vpn = RecordingVPNManager()
        let model = Self.makeModel(premium: premium, vpn: vpn)
        model.hasActivePremiumSubscription = true
        model.hasLoadedPremiumEntitlements = true
        model.selectedGlobalServerID = Self.managedServerID
        model.status = .connected

        await model.refreshPremiumEntitlements()

        #expect(model.hasActivePremiumSubscription)
        #expect(vpn.disconnectCallCount == 0)
        #expect(model.status == .connected)
    }

    @MainActor
    @Test func transactionObserverRevocationIsIgnoredWhileFreeAccessIsEnabled() async {
        let premium = ControllablePremiumService(active: true)
        let vpn = RecordingVPNManager()
        let model = Self.makeModel(premium: premium, vpn: vpn)

        await model.bootstrapPremium()
        model.selectedGlobalServerID = Self.managedServerID
        model.status = .connected

        await premium.emit(isActive: false)

        #expect(model.hasActivePremiumSubscription)
        #expect(vpn.disconnectCallCount == 0)
        #expect(model.status == .connected)
        #expect(model.shouldShowPremiumBanner == false)
    }

    @MainActor
    @Test func restoreWithoutSubscriptionSucceedsWhileFreeAccessIsEnabled() async {
        let premium = ControllablePremiumService(active: false)
        let model = Self.makeModel(premium: premium)

        let restored = await model.restorePremiumPurchases()

        #expect(restored)
        #expect(model.hasActivePremiumSubscription)
        #expect(model.hasLoadedPremiumEntitlements)
        #expect(model.shouldShowPremiumBanner == false)
    }

    // MARK: - Builder

    @MainActor
    private static func makeModel(
        premium: any PremiumSubscriptionServicing,
        vpn: (any VPNManaging)? = nil
    ) -> AppModel {
        let suiteName = "NetlumaVPNTests-\(UUID().uuidString)"
        let appGroupStorage = AppGroupStorage(suiteName: suiteName)
        return AppModel(
            profileStorage: ProfileStorage(
                appGroupStorage: appGroupStorage,
                keychainStorage: InMemorySecureValueStorage()
            ),
            networkPreferencesStorage: NetworkPreferencesStorage(appGroupStorage: appGroupStorage),
            vpnManager: vpn,
            sessionStateStorage: SessionStateStorage(appGroupStorage: appGroupStorage),
            displayStateStorage: ConnectionDisplayStateStorage(appGroupStorage: appGroupStorage),
            globalServerService: EmptyGlobalServerService(),
            premiumService: premium,
            onboardingStore: InMemoryOnboardingStore()
        )
    }
}

// MARK: - Fakes

@MainActor
private final class ControllablePremiumService: PremiumSubscriptionServicing {
    var active: Bool
    private(set) var observeCallCount = 0
    private var handler: (@MainActor (Bool) async -> Void)?

    init(active: Bool) {
        self.active = active
    }

    func loadProducts() async throws -> [PremiumSubscriptionPlan] {
        []
    }

    func hasActiveSubscription() async -> Bool {
        active
    }

    func purchase(productID: String) async throws -> PremiumPurchaseOutcome {
        active = true
        return .purchased
    }

    func restorePurchases() async throws -> Bool {
        active
    }

    func observeTransactionUpdates(_ handler: @escaping @MainActor (Bool) async -> Void) -> Task<Void, Never> {
        observeCallCount += 1
        self.handler = handler
        return Task {}
    }

    /// Simulates a StoreKit `Transaction.updates` delivery (renewal / expiry / revocation).
    func emit(isActive: Bool) async {
        active = isActive
        await handler?(isActive)
    }
}

@MainActor
private final class RecordingVPNManager: VPNManaging {
    private let observer = NSObject()
    private(set) var disconnectCallCount = 0

    func observeConnectionState(_ handler: @escaping @MainActor (VPNConnectionState) -> Void) -> NSObjectProtocol {
        observer
    }

    func currentConnectionState() async -> VPNConnectionState {
        VPNConnectionState(status: .disconnected)
    }

    func connect(profile: VPNProfile) async throws -> VPNConnectionState {
        VPNConnectionState(status: .connected, connectedDate: Date())
    }

    func disconnect() async throws -> VPNConnectionState {
        disconnectCallCount += 1
        return VPNConnectionState(status: .disconnected)
    }
}

private struct EmptyGlobalServerService: GlobalServerServicing {
    func fetchServers() async throws -> [GlobalVPNServer] {
        []
    }

    func provisionProfile(for server: GlobalVPNServer) async throws -> (VPNProfile, VPNProfileSecret) {
        throw CancellationError()
    }
}

private struct InMemoryOnboardingStore: OnboardingCompletionStoring {
    var hasCompletedOnboarding = true
}
