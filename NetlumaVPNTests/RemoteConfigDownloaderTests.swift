import Foundation
import Testing
@testable import NetlumaVPN

// MARK: - Link classification

struct RemoteConfigLinkDetectionTests {
    @Test func detectsHTTPSJSONLinkAsRemote() {
        let url = RemoteConfigDownloader.remoteConfigURL(
            from: "https://netlumavpn.example/ho0aWfb3s3S2KtqYOIqUkHwrOSdXOA/qv_b897df807f3e0ec9-VLESS-CLIENT.json"
        )
        #expect(url?.host == "netlumavpn.example")
    }

    @Test func detectsHTTPLinkAsRemote() {
        #expect(RemoteConfigDownloader.remoteConfigURL(from: "http://example.com/profile.json") != nil)
    }

    @Test func trimsWhitespaceBeforeDetecting() {
        #expect(RemoteConfigDownloader.remoteConfigURL(from: "  https://example.com/c.json\n") != nil)
    }

    @Test func treatsVLESSURLAsDirect() {
        #expect(RemoteConfigDownloader.remoteConfigURL(from: "vless://uuid@host.example.com:443?security=tls#x") == nil)
    }

    @Test func treatsTrojanURLAsDirect() {
        #expect(RemoteConfigDownloader.remoteConfigURL(from: "trojan://pass@host.example.com:443#x") == nil)
    }

    @Test func treatsWireGuardSchemesAsDirect() {
        #expect(RemoteConfigDownloader.remoteConfigURL(from: "wireguard://host.example.com") == nil)
        #expect(RemoteConfigDownloader.remoteConfigURL(from: "wg://host.example.com") == nil)
    }

    @Test func treatsInlineJSONAsDirect() {
        #expect(RemoteConfigDownloader.remoteConfigURL(from: "{\"outbounds\": []}") == nil)
    }

    @Test func treatsBlankAsDirect() {
        #expect(RemoteConfigDownloader.remoteConfigURL(from: "   ") == nil)
    }

    @Test func treatsSchemelessHostAsDirect() {
        #expect(RemoteConfigDownloader.remoteConfigURL(from: "example.com/c.json") == nil)
    }
}

// MARK: - Download behaviour (URLProtocol stub)

@Suite(.serialized)
struct RemoteConfigDownloadTests {
    @Test func downloadsBodyOnSuccess() async throws {
        let payload = "{\"outbounds\": []}"
        StubURLProtocol.handler = { request in
            (Self.response(for: request, status: 200), Data(payload.utf8))
        }
        let downloader = RemoteConfigDownloader(session: Self.stubSession())

        let body = try await downloader.download(from: URL(string: "https://example.com/c.json")!)

        #expect(body == payload)
    }

    @Test func throwsRequestFailedOnNon2xx() async {
        StubURLProtocol.handler = { request in
            (Self.response(for: request, status: 404), Data("not found".utf8))
        }
        let downloader = RemoteConfigDownloader(session: Self.stubSession())

        await #expect(throws: RemoteConfigDownloadError.requestFailed(404)) {
            try await downloader.download(from: URL(string: "https://example.com/missing.json")!)
        }
    }

    @Test func throwsEmptyResponseOnEmptyBody() async {
        StubURLProtocol.handler = { request in
            (Self.response(for: request, status: 200), Data())
        }
        let downloader = RemoteConfigDownloader(session: Self.stubSession())

        await #expect(throws: RemoteConfigDownloadError.emptyResponse) {
            try await downloader.download(from: URL(string: "https://example.com/empty.json")!)
        }
    }

    @Test func throwsPayloadTooLargeOnOversizedBody() async {
        let oversized = Data(repeating: UInt8(ascii: "a"), count: RemoteConfigDownloader.maxPayloadBytes + 1)
        StubURLProtocol.handler = { request in
            (Self.response(for: request, status: 200), oversized)
        }
        let downloader = RemoteConfigDownloader(session: Self.stubSession())

        await #expect(throws: RemoteConfigDownloadError.payloadTooLarge) {
            try await downloader.download(from: URL(string: "https://example.com/big.json")!)
        }
    }

    @Test func throwsUnsupportedSchemeWithoutHittingNetwork() async {
        StubURLProtocol.handler = { _ in
            Issue.record("Network should not be used for an unsupported scheme")
            return (HTTPURLResponse(), Data())
        }
        let downloader = RemoteConfigDownloader(session: Self.stubSession())

        await #expect(throws: RemoteConfigDownloadError.unsupportedScheme) {
            try await downloader.download(from: URL(string: "ftp://example.com/c.json")!)
        }
    }

    private static func stubSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private static func response(for request: URLRequest, status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
    }
}

// MARK: - AppModel import orchestration

struct RemoteConfigImportTests {
    private static let singBoxVLESSJSON = """
    {
      "outbounds": [
        { "tag": "direct", "type": "direct" },
        {
          "tag": "proxy",
          "type": "vless",
          "server": "vpn.netlumavpn.example",
          "server_port": 443,
          "uuid": "22222222-2222-2222-2222-222222222222",
          "tls": { "enabled": true, "server_name": "vpn.netlumavpn.example" },
          "transport": { "type": "ws", "path": "/abc" }
        }
      ]
    }
    """

    @Test @MainActor func importsProfileFromRemoteJSONLink() async throws {
        let downloader = StubRemoteConfigDownloader(result: .success(Self.singBoxVLESSJSON))
        let (model, appGroupStorage) = Self.makeModel(downloader: downloader)
        defer { Self.cleanUp(appGroupStorage) }
        let link = "https://netlumavpn.example/ho0aWfb3s3S2KtqYOIqUkHwrOSdXOA/qv_b897df807f3e0ec9-VLESS-CLIENT.json"

        try await model.importProfile(from: link)

        #expect(downloader.requestedURLs.map(\.absoluteString) == [link])
        #expect(model.profiles.count == 1)
        #expect(model.profiles.first?.protocolType == .vless)
        #expect(model.profiles.first?.host == "vpn.netlumavpn.example")
        #expect(model.selectedProfileID == model.profiles.first?.id)
    }

    @Test @MainActor func importsDirectVLESSURLWithoutDownloading() async throws {
        let downloader = StubRemoteConfigDownloader(result: .failure(RemoteConfigDownloadError.emptyResponse))
        let (model, appGroupStorage) = Self.makeModel(downloader: downloader)
        defer { Self.cleanUp(appGroupStorage) }
        let url = "vless://11111111-1111-1111-1111-111111111111@vpn.example.com:443?security=tls&type=ws&sni=vpn.example.com&path=%2Fsocket#Office"

        try await model.importProfile(from: url)

        #expect(downloader.requestedURLs.isEmpty)
        #expect(model.profiles.count == 1)
        #expect(model.profiles.first?.protocolType == .vless)
        #expect(model.profiles.first?.host == "vpn.example.com")
    }

    @Test @MainActor func surfacesDownloadFailureAndSavesNothing() async {
        let downloader = StubRemoteConfigDownloader(result: .failure(RemoteConfigDownloadError.requestFailed(500)))
        let (model, appGroupStorage) = Self.makeModel(downloader: downloader)
        defer { Self.cleanUp(appGroupStorage) }

        await #expect(throws: RemoteConfigDownloadError.requestFailed(500)) {
            try await model.importProfile(from: "https://example.com/profile.json")
        }
        #expect(model.profiles.isEmpty)
    }

    @MainActor
    private static func makeModel(downloader: any RemoteConfigDownloading) -> (AppModel, AppGroupStorage) {
        let suiteName = "NetlumaVPNTests-\(UUID().uuidString)"
        let appGroupStorage = AppGroupStorage(suiteName: suiteName)
        let profileStorage = ProfileStorage(
            appGroupStorage: appGroupStorage,
            keychainStorage: InMemorySecureValueStorage()
        )
        let model = AppModel(
            profileStorage: profileStorage,
            networkPreferencesStorage: NetworkPreferencesStorage(appGroupStorage: appGroupStorage),
            vpnManager: StubVPNManager(),
            sessionStateStorage: SessionStateStorage(appGroupStorage: appGroupStorage),
            displayStateStorage: ConnectionDisplayStateStorage(appGroupStorage: appGroupStorage),
            globalServerService: StubGlobalServerService(),
            premiumService: StubPremiumSubscriptionService(),
            onboardingStore: StubOnboardingStore(),
            configDownloader: downloader
        )
        return (model, appGroupStorage)
    }

    private static func cleanUp(_ appGroupStorage: AppGroupStorage) {
        appGroupStorage.removeObject(forKey: AppConstants.AppGroupKeys.profiles)
        appGroupStorage.removeObject(forKey: AppConstants.AppGroupKeys.selectedProfileID)
    }
}

// MARK: - Test doubles

private final class StubRemoteConfigDownloader: RemoteConfigDownloading {
    private(set) var requestedURLs: [URL] = []
    private let result: Result<String, Error>

    init(result: Result<String, Error>) {
        self.result = result
    }

    func download(from url: URL) async throws -> String {
        requestedURLs.append(url)
        return try result.get()
    }
}

final class StubURLProtocol: URLProtocol {
    static var handler: ((URLRequest) -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        let (response, data) = handler(request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private struct StubOnboardingStore: OnboardingCompletionStoring {
    var hasCompletedOnboarding = true
}

private struct StubGlobalServerService: GlobalServerServicing {
    func fetchServers() async throws -> [GlobalVPNServer] { [] }
    func provisionProfile(for server: GlobalVPNServer) async throws -> (VPNProfile, VPNProfileSecret) {
        throw GlobalServerAPIError.noServersAvailable
    }
}

private final class StubPremiumSubscriptionService: PremiumSubscriptionServicing {
    func loadProducts() async throws -> [PremiumSubscriptionPlan] { [] }
    func hasActiveSubscription() async -> Bool { true }
    func purchase(productID: String) async throws -> PremiumPurchaseOutcome { .purchased }
    func restorePurchases() async throws -> Bool { true }
    func observeTransactionUpdates(_ handler: @escaping @MainActor (Bool) -> Void) -> Task<Void, Never> {
        Task {}
    }
}

@MainActor
private final class StubVPNManager: VPNManaging {
    private let observer = NSObject()

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
        VPNConnectionState(status: .disconnected)
    }
}
