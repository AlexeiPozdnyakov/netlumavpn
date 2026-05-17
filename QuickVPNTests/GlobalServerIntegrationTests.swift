import Foundation
import Testing
@testable import QuickVPN

struct GlobalServerIntegrationTests {
    @Test func fetchServersAddsMobileHeadersAndDecodesAvailableServers() async throws {
        let httpClient = MockQuickVPNHTTPClient(
            statusCode: 200,
            body: """
            {
              "ok": true,
              "servers": [
                {
                  "id": "quickvpn-mvp-eu-1",
                  "name": "QuickVPN Global",
                  "country": "Germany",
                  "city": "Nuremberg",
                  "region": "Europe",
                  "protocol": "VLESS Reality",
                  "is_available": true
                },
                {
                  "id": "offline",
                  "name": "Offline",
                  "country": "US",
                  "city": "New York",
                  "region": "North America",
                  "protocol": "VLESS Reality",
                  "is_available": false
                }
              ]
            }
            """
        )
        let client = GlobalServerAPIClient(
            configuration: Self.testConfiguration,
            httpClient: httpClient,
            deviceIdentityStore: FixedDeviceIdentityStore(deviceID: "device-12345678901234567890")
        )

        let servers = try await client.fetchServers()

        #expect(servers.map { $0.id } == ["quickvpn-mvp-eu-1"])
        let requests = await httpClient.recordedRequests()
        let request = try #require(requests.first)
        #expect(request.url?.absoluteString == "https://quickvpn.test:8443/api/v1/mobile/servers")
        #expect(request.timeoutInterval == 12)
        #expect(request.value(forHTTPHeaderField: "X-QuickVPN-Client-Key") == "mobile-key")
        #expect(request.value(forHTTPHeaderField: "X-QuickVPN-Device-ID") == nil)
        #expect(request.value(forHTTPHeaderField: "X-QuickVPN-API-Key") == nil)
    }

    @Test func issueProfileAddsDeviceHeaderAndReturnsConfigURL() async throws {
        let httpClient = MockQuickVPNHTTPClient(
            statusCode: 200,
            body: """
            {
              "ok": true,
              "profile_id": "profile-1",
              "server_id": "quickvpn-mvp-eu-1",
              "protocol": "vless",
              "config_url": "vless://11111111-1111-1111-1111-111111111111@example.com:443/?security=reality&pbk=public-key&fp=chrome&type=tcp&sni=www.microsoft.com&sid=short-id&spx=%2F&flow=xtls-rprx-vision#Test"
            }
            """
        )
        let client = GlobalServerAPIClient(
            configuration: Self.testConfiguration,
            httpClient: httpClient,
            deviceIdentityStore: FixedDeviceIdentityStore(deviceID: "device-12345678901234567890")
        )

        let issue = try await client.issueProfile(for: Self.server)

        #expect(issue.profileID == "profile-1")
        #expect(issue.configURL.hasPrefix("vless://"))
        let requests = await httpClient.recordedRequests()
        let request = try #require(requests.first)
        #expect(request.url?.absoluteString == "https://quickvpn.test:8443/api/v1/mobile/servers/quickvpn-mvp-eu-1/profile")
        #expect(request.timeoutInterval == 35)
        #expect(request.value(forHTTPHeaderField: "X-QuickVPN-Client-Key") == "mobile-key")
        #expect(request.value(forHTTPHeaderField: "X-QuickVPN-Device-ID") == "device-12345678901234567890")
        #expect(request.value(forHTTPHeaderField: "X-QuickVPN-API-Key") == nil)
    }

    @Test func globalServerServiceParsesIssuedProfileAsManagedProfile() async throws {
        let httpClient = MockQuickVPNHTTPClient(
            statusCode: 200,
            body: """
            {
              "ok": true,
              "profile_id": "profile-1",
              "server_id": "quickvpn-mvp-eu-1",
              "protocol": "vless",
              "config_url": "vless://11111111-1111-1111-1111-111111111111@192.0.2.10:443/?security=reality&encryption=none&pbk=REPLACE_WITH_LOCAL_VALUE&fp=chrome&type=tcp&sni=www.microsoft.com&sid=REPLACE_WITH_LOCAL_VALUE&spx=%2F&flow=xtls-rprx-vision#Mobile"
            }
            """
        )
        let apiClient = GlobalServerAPIClient(
            configuration: Self.testConfiguration,
            httpClient: httpClient,
            deviceIdentityStore: FixedDeviceIdentityStore(deviceID: "device-12345678901234567890")
        )
        let service = GlobalServerService(apiClient: apiClient)

        let (profile, secret) = try await service.provisionProfile(for: Self.server)

        #expect(profile.isQuickVPNManaged)
        #expect(profile.managedServerID == "quickvpn-mvp-eu-1")
        #expect(profile.remarks == "QuickVPN Global - Nuremberg, Germany")
        #expect(profile.host == "192.0.2.10")
        #expect(profile.security == VPNTransportSecurity.reality)
        #expect(secret.userId == "11111111-1111-1111-1111-111111111111")
    }

    @Test func deviceIdentityStorePersistsGeneratedDeviceID() throws {
        let account = "global-device-\(UUID().uuidString)"
        let keychainStorage = InMemorySecureValueStorage()
        let firstStore = GlobalServerDeviceIdentityStore(
            keychainStorage: keychainStorage,
            account: account,
            idGenerator: { "device-12345678901234567890" }
        )
        let secondStore = GlobalServerDeviceIdentityStore(
            keychainStorage: keychainStorage,
            account: account,
            idGenerator: { "different-device" }
        )

        let firstID = try firstStore.deviceID()
        let secondID = try secondStore.deviceID()

        #expect(firstID == "device-12345678901234567890")
        #expect(secondID == firstID)
    }

    @Test @MainActor func selectingGlobalServerDoesNotProvisionProfileUntilPowerButton() async {
        let service = MockGlobalServerService(servers: [Self.server])
        let model = Self.makeAppModel(globalServerService: service)
        model.globalServers = [Self.server]

        model.selectGlobalServer(Self.server)

        #expect(model.selectedGlobalServerID == Self.server.id)
        #expect(model.selectedProfileID == nil)
        let provisionCallCount = await service.provisionCallCount
        #expect(provisionCallCount == 0)
    }

    @Test @MainActor func loadGlobalServersCachesSuccessfulListUntilForcedReload() async {
        let service = MockGlobalServerService(servers: [Self.server])
        let model = Self.makeAppModel(globalServerService: service)

        await model.loadGlobalServers()
        await model.loadGlobalServers()

        #expect(model.globalServers == [Self.server])
        let cachedFetchCallCount = await service.fetchCallCount
        #expect(cachedFetchCallCount == 1)

        await model.loadGlobalServers(force: true)

        let forcedFetchCallCount = await service.fetchCallCount
        #expect(forcedFetchCallCount == 2)
    }

    @Test func productionMobileAPIFetchesServersWhenNetworkTestsEnabled() async throws {
        guard Self.networkTestsEnabled else {
            return
        }

        let servers = try await GlobalServerAPIClient().fetchServers()

        #expect(servers.contains { $0.id == "quickvpn-mvp-eu-1" })
    }

    @Test func productionMobileAPIIssuesParseableProfileWhenNetworkTestsEnabled() async throws {
        guard Self.networkTestsEnabled else {
            return
        }

        let client = GlobalServerAPIClient(
            deviceIdentityStore: FixedDeviceIdentityStore(deviceID: "quickvpn-ios-network-test-device")
        )
        let server = try #require(try await client.fetchServers().first { $0.id == "quickvpn-mvp-eu-1" })

        let issue = try await client.issueProfile(for: server)
        let (profile, secret) = try VPNConfigurationParser().parse(issue.configURL)

        #expect(issue.serverID == server.id)
        #expect(issue.configURL.hasPrefix("vless://"))
        #expect(profile.host == "192.0.2.10")
        #expect(profile.security == VPNTransportSecurity.reality)
        #expect(secret.userId?.nilIfBlank != nil)
    }

    private static let testConfiguration = GlobalServerAPIConfiguration(
        baseURL: URL(string: "https://quickvpn.test:8443")!,
        mobileClientKey: "mobile-key",
        pinnedCertificateSHA256Base64: "pin"
    )

    private static let server = GlobalVPNServer(
        id: "quickvpn-mvp-eu-1",
        name: "QuickVPN Global",
        country: "Germany",
        city: "Nuremberg",
        region: "Europe",
        protocolName: "VLESS Reality",
        isAvailable: true
    )

    private static var networkTestsEnabled: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["RUN_NETWORK_TESTS"] == "1"
        || environment["TEST_RUNNER_RUN_NETWORK_TESTS"] == "1"
    }

    @MainActor
    private static func makeAppModel(globalServerService: any GlobalServerServicing) -> AppModel {
        let suiteName = "QuickVPNTests-\(UUID().uuidString)"
        let appGroupStorage = AppGroupStorage(suiteName: suiteName)
        return AppModel(
            profileStorage: ProfileStorage(
                appGroupStorage: appGroupStorage,
                keychainStorage: InMemorySecureValueStorage()
            ),
            networkPreferencesStorage: NetworkPreferencesStorage(appGroupStorage: appGroupStorage),
            sessionStateStorage: SessionStateStorage(appGroupStorage: appGroupStorage),
            displayStateStorage: ConnectionDisplayStateStorage(appGroupStorage: appGroupStorage),
            widgetActionStorage: WidgetActionStorage(appGroupStorage: appGroupStorage),
            globalServerService: globalServerService,
            onboardingStore: InMemoryOnboardingStore()
        )
    }
}

private actor MockQuickVPNHTTPClient: QuickVPNHTTPClient {
    private let statusCode: Int
    private let body: String
    private var requests: [URLRequest] = []

    init(statusCode: Int, body: String) {
        self.statusCode = statusCode
        self.body = body
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)

        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
        return (Data(body.utf8), response)
    }

    func recordedRequests() -> [URLRequest] {
        requests
    }
}

private struct FixedDeviceIdentityStore: GlobalServerDeviceIdentifying {
    let id: String

    init(deviceID: String) {
        self.id = deviceID
    }

    func deviceID() throws -> String {
        id
    }
}

private actor MockGlobalServerService: GlobalServerServicing {
    private let servers: [GlobalVPNServer]
    private var issuedProfile: (VPNProfile, VPNProfileSecret)
    private(set) var fetchCallCount = 0
    private(set) var provisionCallCount = 0

    init(
        servers: [GlobalVPNServer],
        issuedProfile: (VPNProfile, VPNProfileSecret) = (
            VPNProfile(
                protocolType: .vless,
                host: "192.0.2.10",
                port: 443,
                security: .reality,
                networkType: .tcp,
                origin: .quickVPNGlobal,
                managedServerID: "quickvpn-mvp-eu-1",
                remarks: "QuickVPN Global"
            ),
            VPNProfileSecret(userId: "11111111-1111-1111-1111-111111111111")
        )
    ) {
        self.servers = servers
        self.issuedProfile = issuedProfile
    }

    func fetchServers() async throws -> [GlobalVPNServer] {
        fetchCallCount += 1
        return servers
    }

    func provisionProfile(for server: GlobalVPNServer) async throws -> (VPNProfile, VPNProfileSecret) {
        provisionCallCount += 1
        return issuedProfile
    }
}

private struct InMemoryOnboardingStore: OnboardingCompletionStoring {
    var hasCompletedOnboarding = true
}
