import Foundation
import Testing
@testable import NetlumaVPN

struct GlobalServerIntegrationTests {
    @Test func fetchServersAddsMobileHeadersAndDecodesAvailableServers() async throws {
        let httpClient = MockNetlumaVPNHTTPClient(
            statusCode: 200,
            body: """
            {
              "ok": true,
              "servers": [
                {
                  "id": "netlumavpn-mvp-eu-1",
                  "name": "NetlumaVPN Global",
                  "country": "Germany",
                  "city": "Nuremberg",
                  "region": "Europe",
                  "protocol": "VLESS Reality",
                  "is_available": true,
                  "ip_mode": "ipv4_only"
                },
                {
                  "id": "netlumavpn-mvp-eu-1-trojan",
                  "name": "NetlumaVPN Global",
                  "country": "Germany",
                  "city": "Nuremberg",
                  "region": "Europe",
                  "protocol": "Trojan TLS",
                  "is_available": true,
                  "ip_mode": "ipv4_only"
                },
                {
                  "id": "netlumavpn-mvp-eu-1-wireguard",
                  "name": "NetlumaVPN Global",
                  "country": "Germany",
                  "city": "Nuremberg",
                  "region": "Europe",
                  "protocol": "WireGuard",
                  "is_available": true,
                  "ip_mode": "ipv4_only"
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

        #expect(servers.map { $0.id } == [
            "netlumavpn-mvp-eu-1",
            "netlumavpn-mvp-eu-1-trojan",
            "netlumavpn-mvp-eu-1-wireguard"
        ])
        #expect(servers.map { $0.protocolName } == ["VLESS Reality", "Trojan TLS", "WireGuard"])
        #expect(servers.first?.preferredIPMode == .ipv4Only)
        let requests = await httpClient.recordedRequests()
        let request = try #require(requests.first)
        #expect(request.url?.absoluteString == "https://netlumavpn.test:8443/api/v1/mobile/servers")
        #expect(request.timeoutInterval == 20)
        #expect(request.value(forHTTPHeaderField: "X-NetlumaVPN-Client-Key") == "mobile-key")
        #expect(request.value(forHTTPHeaderField: "X-QuickVPN-Client-Key") == "mobile-key")
        #expect(request.value(forHTTPHeaderField: "X-NetlumaVPN-Device-ID") == nil)
        #expect(request.value(forHTTPHeaderField: "X-QuickVPN-Device-ID") == nil)
        #expect(request.value(forHTTPHeaderField: "X-NetlumaVPN-API-Key") == nil)
        #expect(request.value(forHTTPHeaderField: "X-QuickVPN-API-Key") == nil)
    }

    @Test func fetchServersRetriesOnceAfterTransientTimeout() async throws {
        let httpClient = MockNetlumaVPNHTTPClient(
            statusCode: 200,
            body: """
            {"ok": true, "servers": [{"id":"netlumavpn-mvp-eu-1","name":"NetlumaVPN Global","country":"Germany","city":"Nuremberg","region":"Europe","protocol":"VLESS Reality","is_available":true}]}
            """,
            transientErrors: [URLError(.timedOut)]
        )
        let client = GlobalServerAPIClient(
            configuration: Self.testConfiguration,
            httpClient: httpClient,
            deviceIdentityStore: FixedDeviceIdentityStore(deviceID: "device-12345678901234567890")
        )

        let servers = try await client.fetchServers()

        #expect(servers.map { $0.id } == ["netlumavpn-mvp-eu-1"])
        let attempts = await httpClient.recordedRequests().count
        #expect(attempts == 2)
    }

    @Test func fetchServersDoesNotRetryNonTransientErrors() async {
        let httpClient = MockNetlumaVPNHTTPClient(
            statusCode: 200,
            body: "",
            transientErrors: [URLError(.userAuthenticationRequired)]
        )
        let client = GlobalServerAPIClient(
            configuration: Self.testConfiguration,
            httpClient: httpClient,
            deviceIdentityStore: FixedDeviceIdentityStore(deviceID: "device-12345678901234567890")
        )

        await #expect(throws: URLError.self) {
            _ = try await client.fetchServers()
        }
        let attempts = await httpClient.recordedRequests().count
        #expect(attempts == 1)
    }

    @Test func fetchServersReportsFinalTransportFailureAsNetworkNonFatal() async throws {
        let httpClient = MockNetlumaVPNHTTPClient(
            statusCode: 200,
            body: "",
            transientErrors: [URLError(.timedOut), URLError(.cannotFindHost)]
        )
        let reporter = MockNetworkErrorReporter()
        let client = GlobalServerAPIClient(
            configuration: Self.testConfiguration,
            httpClient: httpClient,
            deviceIdentityStore: FixedDeviceIdentityStore(deviceID: "device-12345678901234567890"),
            networkErrorReporter: reporter
        )

        await #expect(throws: URLError.self) {
            _ = try await client.fetchServers()
        }

        let reports = await reporter.recordedReports()
        let report = try #require(reports.first)
        #expect(reports.count == 1)
        #expect((report.error as? URLError)?.code == .cannotFindHost)
        #expect(report.context.method == "GET")
        #expect(report.context.host == "netlumavpn.test")
        #expect(report.context.path == "/api/v1/mobile/servers")
        #expect(report.context.statusCode == nil)
        #expect(report.context.attemptCount == 2)
    }

    @Test func fetchServersReportsHTTPFailureAsNetworkNonFatal() async throws {
        let httpClient = MockNetlumaVPNHTTPClient(
            statusCode: 503,
            body: #"{"ok": false}"#
        )
        let reporter = MockNetworkErrorReporter()
        let client = GlobalServerAPIClient(
            configuration: Self.testConfiguration,
            httpClient: httpClient,
            deviceIdentityStore: FixedDeviceIdentityStore(deviceID: "device-12345678901234567890"),
            networkErrorReporter: reporter
        )

        await #expect(throws: GlobalServerAPIError.self) {
            _ = try await client.fetchServers()
        }

        let reports = await reporter.recordedReports()
        let report = try #require(reports.first)
        #expect(reports.count == 1)
        #expect(report.context.statusCode == 503)
        #expect(report.context.attemptCount == 1)
    }

    @Test func fetchServersDoesNotReportTransientFailureWhenRetrySucceeds() async throws {
        let httpClient = MockNetlumaVPNHTTPClient(
            statusCode: 200,
            body: """
            {"ok": true, "servers": [{"id":"netlumavpn-mvp-eu-1","name":"NetlumaVPN Global","country":"Germany","city":"Nuremberg","region":"Europe","protocol":"VLESS Reality","is_available":true}]}
            """,
            transientErrors: [URLError(.timedOut)]
        )
        let reporter = MockNetworkErrorReporter()
        let client = GlobalServerAPIClient(
            configuration: Self.testConfiguration,
            httpClient: httpClient,
            deviceIdentityStore: FixedDeviceIdentityStore(deviceID: "device-12345678901234567890"),
            networkErrorReporter: reporter
        )

        _ = try await client.fetchServers()

        let reports = await reporter.recordedReports()
        #expect(reports.isEmpty)
    }

    @Test func issueProfileAddsDeviceHeaderAndReturnsConfigURL() async throws {
        let httpClient = MockNetlumaVPNHTTPClient(
            responses: [
                MockNetlumaVPNHTTPResponse(
                    statusCode: 200,
                    body: """
            {
              "ok": true,
              "profile_id": "profile-1",
              "server_id": "netlumavpn-mvp-eu-1",
              "protocol": "vless",
              "config_format": "uri",
              "config_url": "vless://11111111-1111-1111-1111-111111111111@example.com:443/?security=reality&pbk=public-key&fp=chrome&type=tcp&sni=www.microsoft.com&sid=short-id&spx=%2F#Test"
            }
            """
                )
            ]
        )
        let client = GlobalServerAPIClient(
            configuration: Self.testConfiguration,
            httpClient: httpClient,
            deviceIdentityStore: FixedDeviceIdentityStore(deviceID: "device-12345678901234567890")
        )

        let issue = try await client.issueProfile(for: Self.server)

        #expect(issue.profileID == "profile-1")
        #expect(issue.configURL.hasPrefix("vless://"))
        #expect(issue.configFormat == "uri")
        let requests = await httpClient.recordedRequests()
        let request = try #require(requests.first)
        #expect(request.url?.absoluteString == "https://netlumavpn.test:8443/api/v1/mobile/servers/netlumavpn-mvp-eu-1/profile")
        #expect(request.timeoutInterval == 35)
        #expect(request.value(forHTTPHeaderField: "X-NetlumaVPN-Client-Key") == "mobile-key")
        #expect(request.value(forHTTPHeaderField: "X-QuickVPN-Client-Key") == "mobile-key")
        #expect(request.value(forHTTPHeaderField: "X-NetlumaVPN-Device-ID") == "device-12345678901234567890")
        #expect(request.value(forHTTPHeaderField: "X-QuickVPN-Device-ID") == "device-12345678901234567890")
        #expect(request.value(forHTTPHeaderField: "X-NetlumaVPN-API-Key") == nil)
        #expect(request.value(forHTTPHeaderField: "X-QuickVPN-API-Key") == nil)
    }

    @Test func globalServerServiceParsesIssuedProfileAsManagedProfile() async throws {
        let httpClient = MockNetlumaVPNHTTPClient(
            responses: [
                MockNetlumaVPNHTTPResponse(
                    statusCode: 200,
                    body: """
            {
              "ok": true,
              "profile_id": "profile-1",
              "server_id": "netlumavpn-mvp-eu-1",
              "protocol": "vless",
              "config_format": "uri",
              "config_url": "vless://11111111-1111-1111-1111-111111111111@192.0.2.10:443/?security=reality&encryption=none&pbk=REPLACE_WITH_LOCAL_VALUE&fp=chrome&type=tcp&sni=www.microsoft.com&sid=REPLACE_WITH_LOCAL_VALUE&spx=%2F#Mobile"
            }
            """
                )
            ]
        )
        let apiClient = GlobalServerAPIClient(
            configuration: Self.testConfiguration,
            httpClient: httpClient,
            deviceIdentityStore: FixedDeviceIdentityStore(deviceID: "device-12345678901234567890")
        )
        let service = GlobalServerService(apiClient: apiClient)

        let (profile, secret) = try await service.provisionProfile(for: Self.server)

        #expect(profile.isNetlumaVPNManaged)
        #expect(profile.managedServerID == "netlumavpn-mvp-eu-1")
        #expect(profile.remarks == "NetlumaVPN Global - VLESS Reality - Nuremberg, Germany")
        #expect(profile.host == "192.0.2.10")
        #expect(profile.security == VPNTransportSecurity.reality)
        #expect(secret.userId == "11111111-1111-1111-1111-111111111111")
    }

    @Test func globalServerServiceDownloadsAndParsesSingBoxJSONProfile() async throws {
        let httpClient = MockNetlumaVPNHTTPClient(
            responses: [
                MockNetlumaVPNHTTPResponse(
                    statusCode: 200,
                    body: """
                    {
                      "ok": true,
                      "profile_id": "profile-1",
                      "server_id": "netlumavpn-singbox-vless",
                      "protocol": "vless",
                      "config_format": "sing-box-json",
                      "config_url": "https://vpn.netlumavpn.example/api/v1/mobile/profiles/profile-1/config"
                    }
                    """
                ),
                MockNetlumaVPNHTTPResponse(
                    statusCode: 200,
                    body: """
                    {
                      "outbounds": [
                        {
                          "tag": "proxy",
                          "type": "vless",
                          "server": "vpn.netlumavpn.example",
                          "server_port": 443,
                          "uuid": "22222222-2222-2222-2222-222222222222",
                          "tls": {
                            "enabled": true,
                            "server_name": "vpn.netlumavpn.example",
                            "utls": {"enabled": true, "fingerprint": "chrome"}
                          },
                          "transport": {
                            "type": "ws",
                            "path": "/example-websocket-path",
                            "headers": {"Host": "vpn.netlumavpn.example"}
                          }
                        }
                      ]
                    }
                    """
                )
            ]
        )
        let apiClient = GlobalServerAPIClient(
            configuration: Self.testConfiguration,
            httpClient: httpClient,
            deviceIdentityStore: FixedDeviceIdentityStore(deviceID: "device-12345678901234567890")
        )
        let server = GlobalVPNServer(
            id: "netlumavpn-singbox-vless",
            name: "NetlumaVPN VLESS",
            country: "Germany",
            city: "Nuremberg",
            region: "Europe",
            protocolName: "VLESS JSON",
            configFormat: "sing-box-json",
            isAvailable: true
        )
        let service = GlobalServerService(apiClient: apiClient)

        let (profile, secret) = try await service.provisionProfile(for: server)

        #expect(profile.isNetlumaVPNManaged)
        #expect(profile.managedServerID == "netlumavpn-singbox-vless")
        #expect(profile.protocolType == .vless)
        #expect(profile.host == "vpn.netlumavpn.example")
        #expect(profile.security == .tls)
        #expect(profile.networkType == .ws)
        #expect(profile.path == "/example-websocket-path")
        #expect(secret.userId == "22222222-2222-2222-2222-222222222222")
        let requests = await httpClient.recordedRequests()
        #expect(requests.map { $0.url?.absoluteString } == [
            "https://netlumavpn.test:8443/api/v1/mobile/servers/netlumavpn-singbox-vless/profile",
            "https://vpn.netlumavpn.example/api/v1/mobile/profiles/profile-1/config"
        ])
        #expect(requests.last?.value(forHTTPHeaderField: "X-NetlumaVPN-Device-ID") == "device-12345678901234567890")
        #expect(requests.last?.value(forHTTPHeaderField: "X-QuickVPN-Device-ID") == "device-12345678901234567890")
        #expect(requests.last?.value(forHTTPHeaderField: "X-NetlumaVPN-Client-Key") == "mobile-key")
        #expect(requests.last?.value(forHTTPHeaderField: "X-QuickVPN-Client-Key") == "mobile-key")
    }

    @Test func globalServerServiceParsesTrojanAndWireGuardIssuedProfiles() async throws {
        let trojanServer = GlobalVPNServer(
            id: "netlumavpn-mvp-eu-1-trojan",
            name: "NetlumaVPN Global",
            country: "Germany",
            city: "Nuremberg",
            region: "Europe",
            protocolName: "Trojan TLS",
            isAvailable: true
        )
        let trojanClient = GlobalServerAPIClient(
            configuration: Self.testConfiguration,
            httpClient: MockNetlumaVPNHTTPClient(
                statusCode: 200,
                body: """
                {
                  "ok": true,
                  "profile_id": "profile-trojan",
                  "server_id": "netlumavpn-mvp-eu-1-trojan",
                  "protocol": "trojan",
                  "config_url": "trojan://test-password@trojan.netlumavpn.example:443/?security=tls&type=tcp&sni=trojan.netlumavpn.example&fp=chrome#Trojan"
                }
                """
            ),
            deviceIdentityStore: FixedDeviceIdentityStore(deviceID: "device-12345678901234567890")
        )
        let trojanService = GlobalServerService(apiClient: trojanClient)

        let (trojanProfile, trojanSecret) = try await trojanService.provisionProfile(for: trojanServer)

        #expect(trojanProfile.protocolType == .trojan)
        #expect(trojanProfile.managedServerID == "netlumavpn-mvp-eu-1-trojan")
        #expect(trojanProfile.remarks == "NetlumaVPN Global - Trojan TLS - Nuremberg, Germany")
        #expect(trojanSecret.password == "test-password")

        let wireGuardServer = GlobalVPNServer(
            id: "netlumavpn-mvp-eu-1-wireguard",
            name: "NetlumaVPN Global",
            country: "Germany",
            city: "Nuremberg",
            region: "Europe",
            protocolName: "WireGuard",
            isAvailable: true
        )
        let wireGuardClient = GlobalServerAPIClient(
            configuration: Self.testConfiguration,
            httpClient: MockNetlumaVPNHTTPClient(
                statusCode: 200,
                body: """
                {
                  "ok": true,
                  "profile_id": "profile-wireguard",
                  "server_id": "netlumavpn-mvp-eu-1-wireguard",
                  "protocol": "wireguard",
                  "config_url": "wireguard://192.0.2.10:51820/?privatekey=client-private&publickey=server-public&presharedkey=client-psk&address=10.8.0.2%2F32&allowedips=0.0.0.0%2F0&persistentkeepalive=25&mtu=1280#WireGuard"
                }
                """
            ),
            deviceIdentityStore: FixedDeviceIdentityStore(deviceID: "device-12345678901234567890")
        )
        let wireGuardService = GlobalServerService(apiClient: wireGuardClient)

        let (wireGuardProfile, wireGuardSecret) = try await wireGuardService.provisionProfile(for: wireGuardServer)

        #expect(wireGuardProfile.protocolType == .wireguard)
        #expect(wireGuardProfile.managedServerID == "netlumavpn-mvp-eu-1-wireguard")
        #expect(wireGuardProfile.remarks == "NetlumaVPN Global - WireGuard - Nuremberg, Germany")
        #expect(wireGuardProfile.wireGuardLocalAddresses == ["10.8.0.2/32"])
        #expect(wireGuardSecret.wireGuardPrivateKey == "client-private")
        #expect(wireGuardSecret.wireGuardPreSharedKey == "client-psk")
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

        let selectionResult = await model.selectGlobalServer(Self.server)

        #expect(selectionResult == .proceeded)
        #expect(model.selectedGlobalServerID == Self.server.id)
        #expect(model.selectedProfileID == nil)
        let provisionCallCount = await service.provisionCallCount
        #expect(provisionCallCount == 0)
    }

    @Test @MainActor func selectingGlobalServerWithoutPremiumRequiresSubscription() async {
        let service = MockGlobalServerService(servers: [Self.server])
        let model = Self.makeAppModel(
            globalServerService: service,
            hasActivePremiumSubscription: false
        )
        model.globalServers = [Self.server]

        let selectionResult = await model.selectGlobalServer(Self.server)

        #expect(selectionResult == .requiresPremium)
        #expect(model.selectedGlobalServerID == nil)
        #expect(model.selectedProfileID == nil)
        let provisionCallCount = await service.provisionCallCount
        #expect(provisionCallCount == 0)
    }

    @Test @MainActor func selectingDifferentLocalProfileDisconnectsActiveVPN() async throws {
        let suiteName = "NetlumaVPNTests-\(UUID().uuidString)"
        let appGroupStorage = AppGroupStorage(suiteName: suiteName)
        let profileStorage = ProfileStorage(
            appGroupStorage: appGroupStorage,
            keychainStorage: InMemorySecureValueStorage()
        )
        defer {
            appGroupStorage.removeObject(forKey: AppConstants.AppGroupKeys.profiles)
            appGroupStorage.removeObject(forKey: AppConstants.AppGroupKeys.selectedProfileID)
        }

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
        try profileStorage.saveProfile(
            firstProfile,
            secret: VPNProfileSecret(userId: "11111111-1111-1111-1111-111111111111")
        )
        try profileStorage.saveProfile(
            secondProfile,
            secret: VPNProfileSecret(userId: "22222222-2222-2222-2222-222222222222")
        )
        profileStorage.setSelectedProfileID(firstProfile.id)

        let vpnManager = MockVPNManager()
        let model = Self.makeAppModel(
            globalServerService: MockGlobalServerService(servers: []),
            profileStorage: profileStorage,
            vpnManager: vpnManager
        )
        model.status = .connected

        await model.selectProfile(secondProfile)

        #expect(model.selectedProfileID == secondProfile.id)
        #expect(model.selectedGlobalServerID == nil)
        #expect(vpnManager.disconnectCallCount == 1)
        #expect(model.status == .disconnected)
    }

    @Test @MainActor func selectingGlobalServerDisconnectsActiveVPNWithoutProvisioningProfile() async {
        let service = MockGlobalServerService(servers: [Self.server])
        let vpnManager = MockVPNManager()
        let model = Self.makeAppModel(
            globalServerService: service,
            vpnManager: vpnManager
        )
        model.globalServers = [Self.server]
        model.status = .connected

        let selectionResult = await model.selectGlobalServer(Self.server)

        #expect(selectionResult == .proceeded)
        #expect(model.selectedGlobalServerID == Self.server.id)
        #expect(vpnManager.disconnectCallCount == 1)
        #expect(model.status == .disconnected)
        let provisionCallCount = await service.provisionCallCount
        #expect(provisionCallCount == 0)
    }

    @Test @MainActor func globalServerConnectRefreshesExistingManagedProfileBeforeStartingVPN() async throws {
        let suiteName = "NetlumaVPNTests-\(UUID().uuidString)"
        let appGroupStorage = AppGroupStorage(suiteName: suiteName)
        let profileStorage = ProfileStorage(
            appGroupStorage: appGroupStorage,
            keychainStorage: InMemorySecureValueStorage()
        )
        let networkPreferencesStorage = NetworkPreferencesStorage(appGroupStorage: appGroupStorage)
        defer {
            appGroupStorage.removeObject(forKey: AppConstants.AppGroupKeys.profiles)
            appGroupStorage.removeObject(forKey: AppConstants.AppGroupKeys.selectedProfileID)
            appGroupStorage.removeObject(forKey: AppConstants.AppGroupKeys.networkPreferences)
        }

        let staleProfile = VPNProfile(
            protocolType: .vless,
            host: "192.0.2.10",
            port: 443,
            security: .reality,
            networkType: .tcp,
            origin: .netlumaVPNGlobal,
            managedServerID: "netlumavpn-mvp-eu-1",
            remarks: "Old NetlumaVPN Global"
        )
        try profileStorage.saveProfile(
            staleProfile,
            secret: VPNProfileSecret(userId: "11111111-1111-1111-1111-111111111111")
        )
        networkPreferencesStorage.save(
            NetworkPreferences(tunnel: TunnelPreferences(ipMode: .ipv4AndIPv6))
        )

        let refreshedProfile = VPNProfile(
            protocolType: .vless,
            host: "192.0.2.10",
            port: 443,
            security: .reality,
            networkType: .tcp,
            sni: "www.microsoft.com",
            realityPublicKey: "REPLACE_WITH_LOCAL_VALUE",
            realityFingerprint: "chrome",
            realityShortID: "REPLACE_WITH_LOCAL_VALUE",
            realitySpiderX: "/",
            origin: .netlumaVPNGlobal,
            managedServerID: "netlumavpn-mvp-eu-1",
            remarks: "NetlumaVPN Global"
        )
        let service = MockGlobalServerService(
            servers: [Self.server],
            issuedProfile: (
                refreshedProfile,
                VPNProfileSecret(userId: "22222222-2222-2222-2222-222222222222")
            )
        )
        let vpnManager = MockVPNManager()
        let model = Self.makeAppModel(
            globalServerService: service,
            profileStorage: profileStorage,
            networkPreferencesStorage: networkPreferencesStorage,
            vpnManager: vpnManager
        )
        model.globalServers = [Self.server]
        let selectionResult = await model.selectGlobalServer(Self.server)

        let connectionResult = await model.toggleConnection()

        #expect(selectionResult == .proceeded)
        #expect(connectionResult == .proceeded)
        let provisionCallCount = await service.provisionCallCount
        #expect(provisionCallCount == 1)
        let connectedProfile = try #require(vpnManager.connectedProfiles.first)
        #expect(connectedProfile.id == staleProfile.id)
        #expect(connectedProfile.sni == "www.microsoft.com")
        #expect(connectedProfile.realityPublicKey == "REPLACE_WITH_LOCAL_VALUE")
        #expect(networkPreferencesStorage.load().tunnel.ipMode == .ipv4Only)

        let storedProfile = try #require(profileStorage.loadProfiles().first { $0.id == staleProfile.id })
        let storedSecret = try #require(try profileStorage.secret(for: storedProfile))
        #expect(storedSecret.userId == "22222222-2222-2222-2222-222222222222")
    }

    @Test @MainActor func connectingSelectedGlobalServerWithoutPremiumRequiresSubscription() async {
        let service = MockGlobalServerService(servers: [Self.server])
        let vpnManager = MockVPNManager()
        let model = Self.makeAppModel(
            globalServerService: service,
            vpnManager: vpnManager,
            hasActivePremiumSubscription: false
        )
        model.globalServers = [Self.server]
        model.selectedGlobalServerID = Self.server.id

        let connectionResult = await model.toggleConnection()

        #expect(connectionResult == .requiresPremium)
        let provisionCallCount = await service.provisionCallCount
        #expect(provisionCallCount == 0)
        #expect(vpnManager.connectedProfiles.isEmpty)
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

        #expect(servers.contains { $0.id == "netlumavpn-singbox-vless" })
        #expect(servers.contains { $0.id == "netlumavpn-singbox-trojan" })
    }

    @Test func productionMobileAPIIssuesParseableProfileWhenNetworkTestsEnabled() async throws {
        guard Self.networkTestsEnabled else {
            return
        }

        let client = GlobalServerAPIClient(
            deviceIdentityStore: FixedDeviceIdentityStore(deviceID: "netlumavpn-ios-network-test-device")
        )
        let server = try #require(try await client.fetchServers().first { $0.id == "netlumavpn-singbox-vless" })

        let issue = try await client.issueProfile(for: server)
        let rawConfig = issue.requiresConfigDownload ? try await client.downloadConfig(for: issue) : issue.configURL
        let (profile, secret) = try VPNConfigurationParser().parse(rawConfig)

        #expect(issue.serverID == server.id)
        #expect(issue.configFormat == "sing-box-json")
        #expect(profile.host == "vpn.netlumavpn.example")
        #expect(profile.security == VPNTransportSecurity.tls)
        #expect(profile.networkType == VPNNetworkType.ws)
        #expect(secret.userId?.nilIfBlank != nil)
    }

    private static let testConfiguration = GlobalServerAPIConfiguration(
        baseURL: URL(string: "https://netlumavpn.test:8443")!,
        mobileClientKey: "mobile-key",
        pinnedCertificateSHA256Base64: "pin"
    )

    private static let server = GlobalVPNServer(
        id: "netlumavpn-mvp-eu-1",
        name: "NetlumaVPN Global",
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
    private static func makeAppModel(
        globalServerService: any GlobalServerServicing,
        profileStorage providedProfileStorage: ProfileStorage? = nil,
        networkPreferencesStorage providedNetworkPreferencesStorage: NetworkPreferencesStorage? = nil,
        vpnManager: (any VPNManaging)? = nil,
        hasActivePremiumSubscription: Bool = true
    ) -> AppModel {
        let suiteName = "NetlumaVPNTests-\(UUID().uuidString)"
        let appGroupStorage = AppGroupStorage(suiteName: suiteName)
        let profileStorage = providedProfileStorage ?? ProfileStorage(
            appGroupStorage: appGroupStorage,
            keychainStorage: InMemorySecureValueStorage()
        )
        let networkPreferencesStorage = providedNetworkPreferencesStorage
            ?? NetworkPreferencesStorage(appGroupStorage: appGroupStorage)
        let model = AppModel(
            profileStorage: profileStorage,
            networkPreferencesStorage: networkPreferencesStorage,
            vpnManager: vpnManager,
            sessionStateStorage: SessionStateStorage(appGroupStorage: appGroupStorage),
            displayStateStorage: ConnectionDisplayStateStorage(appGroupStorage: appGroupStorage),
            globalServerService: globalServerService,
            premiumService: MockPremiumSubscriptionService(isActive: hasActivePremiumSubscription),
            onboardingStore: InMemoryOnboardingStore()
        )
        model.hasActivePremiumSubscription = hasActivePremiumSubscription
        model.hasLoadedPremiumEntitlements = true
        return model
    }
}

@MainActor
private final class MockVPNManager: VPNManaging {
    private let observer = NSObject()
    private(set) var connectedProfiles: [VPNProfile] = []
    private(set) var disconnectCallCount = 0

    func observeConnectionState(_ handler: @escaping @MainActor (VPNConnectionState) -> Void) -> NSObjectProtocol {
        observer
    }

    func currentConnectionState() async -> VPNConnectionState {
        VPNConnectionState(status: .disconnected)
    }

    func connect(profile: VPNProfile) async throws -> VPNConnectionState {
        connectedProfiles.append(profile)
        return VPNConnectionState(status: .connected, connectedDate: Date())
    }

    func disconnect() async throws -> VPNConnectionState {
        disconnectCallCount += 1
        return VPNConnectionState(status: .disconnected)
    }
}

@MainActor
private final class MockPremiumSubscriptionService: PremiumSubscriptionServicing {
    private var isActive: Bool

    init(isActive: Bool) {
        self.isActive = isActive
    }

    func loadProducts() async throws -> [PremiumSubscriptionPlan] {
        []
    }

    func hasActiveSubscription() async -> Bool {
        isActive
    }

    func purchase(productID: String) async throws -> PremiumPurchaseOutcome {
        isActive = true
        return .purchased
    }

    func restorePurchases() async throws -> Bool {
        isActive
    }

    func observeTransactionUpdates(_ handler: @escaping @MainActor (Bool) async -> Void) -> Task<Void, Never> {
        Task {}
    }
}

private actor MockNetlumaVPNHTTPClient: NetlumaVPNHTTPClient {
    private var responses: [MockNetlumaVPNHTTPResponse]
    private var pendingErrors: [Error]
    private var requests: [URLRequest] = []

    init(statusCode: Int, body: String, transientErrors: [Error] = []) {
        self.responses = [MockNetlumaVPNHTTPResponse(statusCode: statusCode, body: body)]
        self.pendingErrors = transientErrors
    }

    init(responses: [MockNetlumaVPNHTTPResponse], transientErrors: [Error] = []) {
        self.responses = responses
        self.pendingErrors = transientErrors
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)

        if !pendingErrors.isEmpty {
            throw pendingErrors.removeFirst()
        }

        let responsePayload = responses.count > 1
            ? responses.removeFirst()
            : responses.first ?? MockNetlumaVPNHTTPResponse(statusCode: 500, body: "{}")
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: responsePayload.statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
        return (Data(responsePayload.body.utf8), response)
    }

    func recordedRequests() -> [URLRequest] {
        requests
    }
}

private struct MockNetlumaVPNHTTPResponse {
    let statusCode: Int
    let body: String
}

private actor MockNetworkErrorReporter: NetworkErrorReporting {
    private var reports: [(error: Error, context: NetworkErrorContext)] = []

    func recordNetworkError(_ error: Error, context: NetworkErrorContext) async {
        reports.append((error, context))
    }

    func recordedReports() -> [(error: Error, context: NetworkErrorContext)] {
        reports
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
                origin: .netlumaVPNGlobal,
                managedServerID: "netlumavpn-mvp-eu-1",
                remarks: "NetlumaVPN Global"
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
