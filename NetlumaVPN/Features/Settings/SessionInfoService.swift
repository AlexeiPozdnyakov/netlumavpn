import Foundation

struct SessionInfo: Equatable {
    var ipv4: String?
    var ipv6: String?
    var asn: String?
    var organization: String?
    var countryCode: String?
    var city: String?
    var region: String?
    var latitude: Double?
    var longitude: Double?

    static let empty = SessionInfo()
}

struct IPAPISessionResponse: Decodable, Equatable {
    var ip: String?
    var asn: String?
    var org: String?
    var countryCode: String?
    var city: String?
    var region: String?
    var latitude: Double?
    var longitude: Double?

    enum CodingKeys: String, CodingKey {
        case ip
        case asn
        case org
        case countryCode = "country_code"
        case city
        case region
        case latitude
        case longitude
    }
}

struct SessionInfoService {
    var fetch: () async throws -> SessionInfo

    static let live = SessionInfoService {
        var request = URLRequest(url: URL(string: "https://ipapi.co/json/")!)
        request.timeoutInterval = 8

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 8
        let session = URLSession(configuration: configuration)
        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200..<400).contains(httpResponse.statusCode) else {
            return .empty
        }

        let decoded = try JSONDecoder().decode(IPAPISessionResponse.self, from: data)
        return SessionInfo(response: decoded)
    }
}

extension SessionInfo {
    init(response: IPAPISessionResponse) {
        let ip = response.ip?.nilIfBlank
        ipv4 = ip?.contains(":") == false ? ip : nil
        ipv6 = ip?.contains(":") == true ? ip : nil
        asn = response.asn?.nilIfBlank
        organization = response.org?.nilIfBlank
        countryCode = response.countryCode?.nilIfBlank
        city = response.city?.nilIfBlank
        region = response.region?.nilIfBlank
        latitude = response.latitude
        longitude = response.longitude
    }
}
