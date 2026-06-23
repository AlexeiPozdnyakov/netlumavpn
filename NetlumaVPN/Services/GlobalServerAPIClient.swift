import CryptoKit
import Foundation
import Security
import UIKit

enum GlobalServerAPIError: LocalizedError, Equatable {
    case invalidBaseURL
    case invalidResponse
    case unauthorized
    case requestFailed(Int)
    case noServersAvailable
    case invalidIssuedProfile
    case certificatePinMismatch

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL:
            L10n.string("The NetlumaVPN server URL is not valid.")
        case .invalidResponse:
            L10n.string("The NetlumaVPN server response was not valid.")
        case .unauthorized:
            L10n.string("The NetlumaVPN server rejected this app build.")
        case .requestFailed:
            L10n.string("The NetlumaVPN server request failed.")
        case .noServersAvailable:
            L10n.string("No global servers are available right now.")
        case .invalidIssuedProfile:
            L10n.string("The NetlumaVPN server returned an invalid VPN profile.")
        case .certificatePinMismatch:
            L10n.string("The NetlumaVPN server identity could not be verified.")
        }
    }
}

protocol NetlumaVPNHTTPClient {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

protocol GlobalServerDeviceIdentifying {
    func deviceID() throws -> String
}

extension GlobalServerDeviceIdentityStore: GlobalServerDeviceIdentifying {}

struct GlobalServerAPIConfiguration: Equatable {
    var baseURL: URL
    var mobileClientKey: String
    var pinnedCertificateSHA256Base64: String?

    init(baseURL: URL, mobileClientKey: String, pinnedCertificateSHA256Base64: String? = nil) {
        self.baseURL = baseURL
        self.mobileClientKey = mobileClientKey
        self.pinnedCertificateSHA256Base64 = pinnedCertificateSHA256Base64
    }

    init(baseURL: URL, mobileClientKey: String, pinnedCertificateSHA256Base64: String) {
        self.init(
            baseURL: baseURL,
            mobileClientKey: mobileClientKey,
            pinnedCertificateSHA256Base64: Optional(pinnedCertificateSHA256Base64)
        )
    }

    static var production: GlobalServerAPIConfiguration {
        guard let baseURL = URL(string: AppConstants.Backend.mobileAPIBaseURL) else {
            preconditionFailure("Invalid backend URL")
        }
        let pin = AppConstants.Backend.mobileTLSCertificateSHA256Base64
        return GlobalServerAPIConfiguration(
            baseURL: baseURL,
            mobileClientKey: AppConstants.Backend.mobileClientKey,
            pinnedCertificateSHA256Base64: pin.isEmpty ? nil : pin
        )
    }
}

final class PinnedCertificateHTTPClient: NSObject, NetlumaVPNHTTPClient, URLSessionDelegate, URLSessionTaskDelegate {
    private let allowedPins: Set<String>
    private var pinningEnabled: Bool { !allowedPins.isEmpty }
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 20
        configuration.waitsForConnectivity = false
        configuration.connectionProxyDictionary = [:]
        return URLSession(
            configuration: configuration,
            delegate: self,
            delegateQueue: nil
        )
    }()

    init(allowedPins: Set<String>) {
        self.allowedPins = allowedPins
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let host = request.url?.host ?? "unknown"
        AppLogger.info("Global server request start host=\(host) path=\(request.url?.path ?? "")", category: .app)
        let started = Date()
        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw GlobalServerAPIError.invalidResponse
            }
            let elapsed = Int(Date().timeIntervalSince(started) * 1000)
            AppLogger.info("Global server response status=\(httpResponse.statusCode) elapsed=\(elapsed)ms", category: .app)
            return (data, httpResponse)
        } catch {
            let elapsed = Int(Date().timeIntervalSince(started) * 1000)
            if let urlError = error as? URLError {
                AppLogger.warning("Global server request failed code=\(urlError.code.rawValue) elapsed=\(elapsed)ms", category: .app)
            } else {
                AppLogger.warning("Global server request failed elapsed=\(elapsed)ms", category: .app)
            }
            throw error
        }
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard pinningEnabled,
              challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let serverTrust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        let certificates = SecTrustCopyCertificateChain(serverTrust) as? [SecCertificate] ?? []
        guard let leafCertificate = certificates.first else {
            AppLogger.warning("Global server TLS challenge missing leaf certificate", category: .app)
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        let leafData = SecCertificateCopyData(leafCertificate) as Data
        let leafDigest = Data(SHA256.hash(data: leafData)).base64EncodedString()
        guard allowedPins.contains(leafDigest) else {
            AppLogger.warning("Global server TLS pin mismatch got=\(leafDigest)", category: .app)
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        SecTrustSetAnchorCertificates(serverTrust, [leafCertificate] as CFArray)
        SecTrustSetAnchorCertificatesOnly(serverTrust, true)

        var cfError: CFError?
        if SecTrustEvaluateWithError(serverTrust, &cfError) {
            completionHandler(.useCredential, URLCredential(trust: serverTrust))
        } else {
            let description = (cfError as Error?)?.localizedDescription ?? "unknown"
            AppLogger.warning("Global server TLS trust evaluation failed: \(description)", category: .app)
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        guard let last = metrics.transactionMetrics.last else {
            return
        }
        let dns = Self.duration(from: last.domainLookupStartDate, to: last.domainLookupEndDate)
        let tcp = Self.duration(from: last.connectStartDate, to: last.connectEndDate)
        let tls = Self.duration(from: last.secureConnectionStartDate, to: last.secureConnectionEndDate)
        let request = Self.duration(from: last.requestStartDate, to: last.requestEndDate)
        let response = Self.duration(from: last.responseStartDate, to: last.responseEndDate)
        AppLogger.info("Global server timing dns=\(dns) tcp=\(tcp) tls=\(tls) req=\(request) resp=\(response) protocol=\(last.networkProtocolName ?? "?")", category: .app)
    }

    private static func duration(from start: Date?, to end: Date?) -> String {
        guard let start, let end else {
            return "-"
        }
        return "\(Int(end.timeIntervalSince(start) * 1000))ms"
    }
}

struct GlobalServerAPIClient {
    private let configuration: GlobalServerAPIConfiguration
    private let httpClient: NetlumaVPNHTTPClient
    private let deviceIdentityStore: GlobalServerDeviceIdentifying

    init(
        configuration: GlobalServerAPIConfiguration = .production,
        httpClient: NetlumaVPNHTTPClient? = nil,
        deviceIdentityStore: GlobalServerDeviceIdentifying = GlobalServerDeviceIdentityStore()
    ) {
        self.configuration = configuration
        let pins = configuration.pinnedCertificateSHA256Base64.map { Set([$0]) } ?? []
        self.httpClient = httpClient ?? PinnedCertificateHTTPClient(allowedPins: pins)
        self.deviceIdentityStore = deviceIdentityStore
    }

    func fetchServers() async throws -> [GlobalVPNServer] {
        var request = URLRequest(url: endpoint("/api/v1/mobile/servers"))
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        applyMobileHeaders(to: &request)

        let (data, response) = try await performWithRetry(request)
        try validate(response)
        let payload = try JSONDecoder().decode(ServerListResponse.self, from: data)
        guard payload.ok else {
            throw GlobalServerAPIError.invalidResponse
        }
        return payload.servers.filter(\.isAvailable)
    }

    private func performWithRetry(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            return try await httpClient.data(for: request)
        } catch let error as URLError where Self.isRetryable(error) {
            AppLogger.warning("Global server request retrying after \(error.code.rawValue)", category: .app)
            try? await Task.sleep(nanoseconds: 500_000_000)
            return try await httpClient.data(for: request)
        }
    }

    private static func isRetryable(_ error: URLError) -> Bool {
        switch error.code {
        case .timedOut, .networkConnectionLost, .dnsLookupFailed:
            true
        default:
            false
        }
    }

    func issueProfile(for server: GlobalVPNServer) async throws -> GlobalServerProfileIssue {
        let url = endpoint("/api/v1/mobile/servers/\(server.id)/profile")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 35
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyMobileHeaders(to: &request)
        try applyDeviceHeaders(to: &request)
        let deviceName = await UIDevice.current.model
        request.httpBody = try JSONEncoder().encode(ProfileIssueRequest(deviceName: deviceName))

        let (data, response) = try await httpClient.data(for: request)
        try validate(response)
        let payload = try JSONDecoder().decode(ProfileIssueResponse.self, from: data)
        guard payload.ok, let issue = payload.issue else {
            throw GlobalServerAPIError.invalidIssuedProfile
        }
        return issue
    }

    func downloadConfig(for issue: GlobalServerProfileIssue) async throws -> String {
        guard let url = URL(string: issue.configURL) else {
            throw GlobalServerAPIError.invalidIssuedProfile
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 25
        applyMobileHeaders(to: &request)
        try applyDeviceHeaders(to: &request)

        let (data, response) = try await httpClient.data(for: request)
        try validate(response)
        guard let value = String(data: data, encoding: .utf8)?.nilIfBlank else {
            throw GlobalServerAPIError.invalidIssuedProfile
        }
        return value
    }

    private func applyMobileHeaders(to request: inout URLRequest) {
        request.setValue(configuration.mobileClientKey, forHTTPHeaderField: "X-NetlumaVPN-Client-Key")
        request.setValue(configuration.mobileClientKey, forHTTPHeaderField: "X-QuickVPN-Client-Key")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
    }

    private func applyDeviceHeaders(to request: inout URLRequest) throws {
        let deviceID = try deviceIdentityStore.deviceID()
        request.setValue(deviceID, forHTTPHeaderField: "X-NetlumaVPN-Device-ID")
        request.setValue(deviceID, forHTTPHeaderField: "X-QuickVPN-Device-ID")
    }

    private func endpoint(_ path: String) -> URL {
        URL(string: path, relativeTo: configuration.baseURL)!.absoluteURL
    }

    private func validate(_ response: HTTPURLResponse) throws {
        switch response.statusCode {
        case 200..<300:
            return
        case 401, 403:
            throw GlobalServerAPIError.unauthorized
        default:
            throw GlobalServerAPIError.requestFailed(response.statusCode)
        }
    }
}

private struct ServerListResponse: Codable {
    let ok: Bool
    let servers: [GlobalVPNServer]
}

private struct ProfileIssueRequest: Codable {
    let deviceName: String

    enum CodingKeys: String, CodingKey {
        case deviceName = "device_name"
    }
}

private struct ProfileIssueResponse: Codable {
    let ok: Bool
    let profileID: String?
    let serverID: String?
    let protocolType: String?
    let configFormat: String?
    let configURL: String?

    enum CodingKeys: String, CodingKey {
        case ok
        case profileID = "profile_id"
        case serverID = "server_id"
        case protocolType = "protocol"
        case configFormat = "config_format"
        case configURL = "config_url"
    }

    var issue: GlobalServerProfileIssue? {
        guard let profileID, let serverID, let protocolType, let configURL else {
            return nil
        }
        return GlobalServerProfileIssue(
            profileID: profileID,
            serverID: serverID,
            protocolType: protocolType,
            configFormat: configFormat ?? "uri",
            configURL: configURL
        )
    }
}
