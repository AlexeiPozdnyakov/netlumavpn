import Foundation

enum RemoteConfigDownloadError: LocalizedError, Equatable {
    case unsupportedScheme
    case requestFailed(Int)
    case emptyResponse
    case payloadTooLarge
    case invalidEncoding

    var errorDescription: String? {
        switch self {
        case .unsupportedScheme:
            L10n.string("Only http and https links can be downloaded.")
        case .requestFailed:
            L10n.string("The configuration link could not be downloaded.")
        case .emptyResponse:
            L10n.string("The downloaded configuration file was empty.")
        case .payloadTooLarge:
            L10n.string("The configuration file is too large to import.")
        case .invalidEncoding:
            L10n.string("The configuration file could not be read as text.")
        }
    }
}

protocol RemoteConfigDownloading {
    /// Downloads the body of `url` and returns it as a UTF-8 string so it can be
    /// handed to `VPNConfigurationParser`. The body is expected to be a VPN config
    /// (sing-box JSON, or a single vless:// / trojan:// / WireGuard config).
    func download(from url: URL) async throws -> String
}

/// Fetches a VPN configuration file from an arbitrary http(s) link.
///
/// This is intentionally separate from `GlobalServerAPIClient`: it talks to a
/// user-supplied host (not the NetlumaVPN backend), so it does **not** attach the
/// `X-NetlumaVPN-*` auth headers or the backend certificate pin. Standard system
/// TLS trust applies for `https` links.
struct RemoteConfigDownloader: RemoteConfigDownloading {
    /// Upper bound on the file we will read. Real profiles are a few KB; this guards
    /// against a link that points at something huge.
    static let maxPayloadBytes = 512 * 1024

    private let session: URLSession

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 15
            configuration.timeoutIntervalForResource = 20
            configuration.waitsForConnectivity = false
            configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            self.session = URLSession(configuration: configuration)
        }
    }

    func download(from url: URL) async throws -> String {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw RemoteConfigDownloadError.unsupportedScheme
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue("\(AppConstants.appName)-iOS", forHTTPHeaderField: "User-Agent")

        // Never log the full URL/path — it can carry a per-device secret token.
        AppLogger.info("Downloading remote configuration host=\(url.host ?? "unknown")", category: .importConfig)

        let (data, response) = try await session.data(for: request)

        if let httpResponse = response as? HTTPURLResponse,
           !(200..<300).contains(httpResponse.statusCode) {
            AppLogger.warning("Remote configuration download failed status=\(httpResponse.statusCode)", category: .importConfig)
            throw RemoteConfigDownloadError.requestFailed(httpResponse.statusCode)
        }

        guard data.count <= Self.maxPayloadBytes else {
            throw RemoteConfigDownloadError.payloadTooLarge
        }
        guard !data.isEmpty else {
            throw RemoteConfigDownloadError.emptyResponse
        }
        guard let body = String(data: data, encoding: .utf8)?.nilIfBlank else {
            throw RemoteConfigDownloadError.invalidEncoding
        }

        AppLogger.info("Downloaded remote configuration bytes=\(data.count)", category: .importConfig)
        return body
    }

    /// Returns the URL to download when `raw` is an http(s) link to a config file,
    /// or `nil` when `raw` is something the parser handles directly — a
    /// vless:// / vmess:// / trojan:// / WireGuard link, or inline JSON.
    static func remoteConfigURL(from raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host?.nilIfBlank != nil else {
            return nil
        }
        return url
    }
}
