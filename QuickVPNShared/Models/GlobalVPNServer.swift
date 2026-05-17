import Foundation

struct GlobalVPNServer: Identifiable, Codable, Equatable, Hashable {
    let id: String
    let name: String
    let country: String
    let city: String
    let region: String
    let protocolName: String
    let isAvailable: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case country
        case city
        case region
        case protocolName = "protocol"
        case isAvailable = "is_available"
    }

    var title: String {
        name.nilIfBlank ?? country
    }

    var locationSummary: String {
        [city.nilIfBlank, country.nilIfBlank]
            .compactMap { $0 }
            .joined(separator: ", ")
    }

    var profileRemarks: String {
        "\(title) - \(locationSummary.nilIfBlank ?? region)"
    }
}

struct GlobalServerProfileIssue: Codable, Equatable {
    let profileID: String
    let serverID: String
    let protocolType: String
    let configURL: String

    enum CodingKeys: String, CodingKey {
        case profileID = "profile_id"
        case serverID = "server_id"
        case protocolType = "protocol"
        case configURL = "config_url"
    }
}
