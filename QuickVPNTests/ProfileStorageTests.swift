import Foundation
import Testing
@testable import QuickVPN

struct ProfileStorageTests {
    @Test func onboardingCompletionStorePersistsFlag() {
        let suiteName = "QuickVPNTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        var storage = UserDefaultsOnboardingCompletionStore(
            defaults: defaults,
            key: "hasCompletedOnboarding.test"
        )

        #expect(storage.hasCompletedOnboarding == false)

        storage.hasCompletedOnboarding = true

        let reloadedStorage = UserDefaultsOnboardingCompletionStore(
            defaults: defaults,
            key: "hasCompletedOnboarding.test"
        )
        #expect(reloadedStorage.hasCompletedOnboarding)
    }

    @Test func deletingSelectedProfileRemovesProfileSecretAndMovesSelection() throws {
        let suiteName = "QuickVPNTests-\(UUID().uuidString)"
        let appGroupStorage = AppGroupStorage(suiteName: suiteName)
        let keychainStorage = InMemorySecureValueStorage()
        let storage = ProfileStorage(
            appGroupStorage: appGroupStorage,
            keychainStorage: keychainStorage
        )
        let firstProfile = VPNProfile(
            protocolType: .vless,
            host: "first.example.com",
            port: 443,
            security: .tls,
            networkType: .tcp,
            remarks: "First"
        )
        let secondProfile = VPNProfile(
            protocolType: .vless,
            host: "second.example.com",
            port: 443,
            security: .tls,
            networkType: .tcp,
            remarks: "Second"
        )
        defer {
            try? storage.deleteProfile(firstProfile)
            try? storage.deleteProfile(secondProfile)
            appGroupStorage.removeObject(forKey: AppConstants.AppGroupKeys.profiles)
            appGroupStorage.removeObject(forKey: AppConstants.AppGroupKeys.selectedProfileID)
        }

        try storage.saveProfile(
            firstProfile,
            secret: VPNProfileSecret(userId: "11111111-1111-1111-1111-111111111111")
        )
        try storage.saveProfile(
            secondProfile,
            secret: VPNProfileSecret(userId: "22222222-2222-2222-2222-222222222222")
        )
        storage.setSelectedProfileID(firstProfile.id)

        try storage.deleteProfile(firstProfile)

        let remainingProfiles = storage.loadProfiles()
        #expect(remainingProfiles.map(\.id) == [secondProfile.id])
        #expect(storage.selectedProfileID() == secondProfile.id)
        #expect(try storage.secret(for: firstProfile) == nil)
        #expect(try storage.secret(for: secondProfile)?.userId == "22222222-2222-2222-2222-222222222222")
    }

    @Test func managedProfileMetadataPersistsWithoutExposingSecretInProfileList() throws {
        let suiteName = "QuickVPNTests-\(UUID().uuidString)"
        let appGroupStorage = AppGroupStorage(suiteName: suiteName)
        let keychainStorage = InMemorySecureValueStorage()
        let storage = ProfileStorage(
            appGroupStorage: appGroupStorage,
            keychainStorage: keychainStorage
        )
        let profile = VPNProfile(
            protocolType: .vless,
            host: "192.0.2.10",
            port: 443,
            security: .reality,
            networkType: .tcp,
            origin: .quickVPNGlobal,
            managedServerID: "quickvpn-mvp-eu-1",
            remarks: "QuickVPN Global"
        )
        defer {
            try? storage.deleteProfile(profile)
            appGroupStorage.removeObject(forKey: AppConstants.AppGroupKeys.profiles)
        }

        try storage.saveProfile(
            profile,
            secret: VPNProfileSecret(userId: "33333333-3333-3333-3333-333333333333")
        )

        let loadedProfile = try #require(storage.loadProfiles().first)
        #expect(loadedProfile.isQuickVPNManaged)
        #expect(loadedProfile.managedServerID == "quickvpn-mvp-eu-1")
        #expect(try storage.secret(for: loadedProfile)?.userId == "33333333-3333-3333-3333-333333333333")
    }

    @Test func sessionStateStoragePersistsAndClearsConnectionStart() {
        let suiteName = "QuickVPNTests-\(UUID().uuidString)"
        let appGroupStorage = AppGroupStorage(suiteName: suiteName)
        let storage = SessionStateStorage(appGroupStorage: appGroupStorage)
        let startedAt = Date(timeIntervalSince1970: 1_776_000_123.5)
        defer {
            appGroupStorage.removeObject(forKey: AppConstants.AppGroupKeys.connectionSessionState)
        }

        storage.markConnectionStarted(at: startedAt)

        #expect(abs(storage.connectionStartedAt()?.timeIntervalSince(startedAt) ?? 1) < 0.001)

        storage.clearConnectionStartedAt()

        #expect(storage.connectionStartedAt() == nil)
    }

    @Test func connectionDisplayStateStoragePersistsRecentState() {
        let suiteName = "QuickVPNTests-\(UUID().uuidString)"
        let appGroupStorage = AppGroupStorage(suiteName: suiteName)
        let storage = ConnectionDisplayStateStorage(appGroupStorage: appGroupStorage, maxStateAge: 30)
        let now = Date(timeIntervalSince1970: 1_776_000_000)
        let startedAt = now.addingTimeInterval(-4)
        defer {
            appGroupStorage.removeObject(forKey: AppConstants.AppGroupKeys.connectionDisplayState)
        }

        storage.save(status: .connecting, connectionStartedAt: startedAt, now: now)

        let state = storage.state(now: now.addingTimeInterval(12))
        #expect(state?.status == .connecting)
        #expect(state?.connectionStartedAt == startedAt)
    }

    @Test func connectionDisplayStateStorageDropsExpiredState() {
        let suiteName = "QuickVPNTests-\(UUID().uuidString)"
        let appGroupStorage = AppGroupStorage(suiteName: suiteName)
        let storage = ConnectionDisplayStateStorage(appGroupStorage: appGroupStorage, maxStateAge: 30)
        let now = Date(timeIntervalSince1970: 1_776_000_000)
        defer {
            appGroupStorage.removeObject(forKey: AppConstants.AppGroupKeys.connectionDisplayState)
        }

        storage.save(status: .connecting, now: now)

        #expect(storage.state(now: now.addingTimeInterval(31)) == nil)
    }

    @Test func widgetActionStorageConsumesRecentToggleOnce() {
        let suiteName = "QuickVPNTests-\(UUID().uuidString)"
        let appGroupStorage = AppGroupStorage(suiteName: suiteName)
        let storage = WidgetActionStorage(appGroupStorage: appGroupStorage, maxActionAge: 30)
        let now = Date(timeIntervalSince1970: 1_776_000_000)
        defer {
            appGroupStorage.removeObject(forKey: AppConstants.AppGroupKeys.pendingWidgetAction)
        }

        storage.requestToggleConnection(now: now)

        #expect(storage.consumePendingToggle(now: now.addingTimeInterval(12)))
        #expect(storage.consumePendingToggle(now: now.addingTimeInterval(13)) == false)
    }

    @Test func widgetActionStorageDropsExpiredToggle() {
        let suiteName = "QuickVPNTests-\(UUID().uuidString)"
        let appGroupStorage = AppGroupStorage(suiteName: suiteName)
        let storage = WidgetActionStorage(appGroupStorage: appGroupStorage, maxActionAge: 30)
        let now = Date(timeIntervalSince1970: 1_776_000_000)
        defer {
            appGroupStorage.removeObject(forKey: AppConstants.AppGroupKeys.pendingWidgetAction)
        }

        storage.requestToggleConnection(now: now)

        #expect(storage.consumePendingToggle(now: now.addingTimeInterval(31)) == false)
    }

}
