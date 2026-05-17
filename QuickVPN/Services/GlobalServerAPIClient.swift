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
            "The QuickVPN server URL is not valid."
        case .invalidResponse:
            "The QuickVPN server response was not valid."
        case .unauthorized:
            "The QuickVPN server rejected this app build."
        case .requestFailed:
            "The QuickVPN server request failed."
        case .noServersAvailable:
            "No global servers are available right now."
        case .invalidIssuedProfile:
            "The QuickVPN server returned an invalid VPN profile."
        case .certificatePinMismatch:
            "The QuickVPN server identity could not be verified."
        }
    }
}

protocol QuickVPNHTTPClient {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

protocol GlobalServerDeviceIdentifying {
    func deviceID() throws -> String
}

extension GlobalServerDeviceIdentityStore: GlobalServerDeviceIdentifying {}

struct GlobalServerAPIConfiguration: Equatable {
    var baseURL: URL
    var mobileClientKey: String
    var pinnedCertificateSHA256Base64: String

    static var production: GlobalServerAPIConfiguration {
        guard let baseURL = URL(string: AppConstants.Backend.mobileAPIBaseURL) else {
            preconditionFailure("Invalid backend URL")
        }
        return GlobalServerAPIConfiguration(
            baseURL: baseURL,
            mobileClientKey: AppConstants.Backend.mobileClientKey,
            pinnedCertificateSHA256Base64: AppConstants.Backend.mobileTLSCertificateSHA256Base64
        )
    }
}

final class PinnedCertificateHTTPClient: NSObject, QuickVPNHTTPClient, URLSessionDelegate {
    private let allowedPins: Set<String>
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 45
        configuration.waitsForConnectivity = false
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
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw GlobalServerAPIError.invalidResponse
        }
        return (data, httpResponse)
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let serverTrust = challenge.protectionSpace.serverTrust else {
            return (.performDefaultHandling, nil)
        }

        let certificates = SecTrustCopyCertificateChain(serverTrust) as? [SecCertificate] ?? []
        let hasPinnedCertificate = certificates.contains { certificate in
            let certificateData = SecCertificateCopyData(certificate) as Data
            let digest = SHA256.hash(data: certificateData)
            return allowedPins.contains(Data(digest).base64EncodedString())
        }

        guard hasPinnedCertificate else {
            AppLogger.warning("Global server TLS pin mismatch", category: .app)
            return (.cancelAuthenticationChallenge, nil)
        }

        return (.useCredential, URLCredential(trust: serverTrust))
    }
}

struct GlobalServerAPIClient {
    private let configuration: GlobalServerAPIConfiguration
    private let httpClient: QuickVPNHTTPClient
    private let deviceIdentityStore: GlobalServerDeviceIdentifying

    init(
        configuration: GlobalServerAPIConfiguration = .production,
        httpClient: QuickVPNHTTPClient? = nil,
        deviceIdentityStore: GlobalServerDeviceIdentifying = GlobalServerDeviceIdentityStore()
    ) {
        self.configuration = configuration
        self.httpClient = httpClient ?? PinnedCertificateHTTPClient(
            allowedPins: [configuration.pinnedCertificateSHA256Base64]
        )
        self.deviceIdentityStore = deviceIdentityStore
    }

    func fetchServers() async throws -> [GlobalVPNServer] {
        var request = URLRequest(url: endpoint("/api/v1/mobile/servers"))
        request.httpMethod = "GET"
        request.timeoutInterval = 12
        applyMobileHeaders(to: &request)

        let (data, response) = try await httpClient.data(for: request)
        try validate(response)
        let payload = try JSONDecoder().decode(ServerListResponse.self, from: data)
        guard payload.ok else {
            throw GlobalServerAPIError.invalidResponse
        }
        return payload.servers.filter(\.isAvailable)
    }

    func issueProfile(for server: GlobalVPNServer) async throws -> GlobalServerProfileIssue {
        let url = endpoint("/api/v1/mobile/servers/\(server.id)/profile")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 35
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyMobileHeaders(to: &request)
        request.setValue(try deviceIdentityStore.deviceID(), forHTTPHeaderField: "X-QuickVPN-Device-ID")
        request.httpBody = try JSONEncoder().encode(ProfileIssueRequest(deviceName: UIDevice.current.model))

        let (data, response) = try await httpClient.data(for: request)
        try validate(response)
        let payload = try JSONDecoder().decode(ProfileIssueResponse.self, from: data)
        guard payload.ok, let issue = payload.issue else {
            throw GlobalServerAPIError.invalidIssuedProfile
        }
        return issue
    }

    private func applyMobileHeaders(to request: inout URLRequest) {
        request.setValue(configuration.mobileClientKey, forHTTPHeaderField: "X-QuickVPN-Client-Key")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
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
    let configURL: String?

    enum CodingKeys: String, CodingKey {
        case ok
        case profileID = "profile_id"
        case serverID = "server_id"
        case protocolType = "protocol"
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
            configURL: configURL
        )
    }
}
