import Foundation

struct GlobalVPNServer: Identifiable, Codable, Equatable, Hashable {
    let id: String
    let name: String
    let country: String
    let city: String
    let region: String
    let protocolName: String
    let isAvailable: Bool
    let preferredIPMode: TunnelIPMode

    init(
        id: String,
        name: String,
        country: String,
        city: String,
        region: String,
        protocolName: String,
        isAvailable: Bool,
        preferredIPMode: TunnelIPMode = .ipv4Only
    ) {
        self.id = id
        self.name = name
        self.country = country
        self.city = city
        self.region = region
        self.protocolName = protocolName
        self.isAvailable = isAvailable
        self.preferredIPMode = preferredIPMode
    }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case country
        case city
        case region
        case protocolName = "protocol"
        case isAvailable = "is_available"
        case preferredIPMode = "ip_mode"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        country = try container.decode(String.self, forKey: .country)
        city = try container.decode(String.self, forKey: .city)
        region = try container.decode(String.self, forKey: .region)
        protocolName = try container.decode(String.self, forKey: .protocolName)
        isAvailable = try container.decode(Bool.self, forKey: .isAvailable)
        preferredIPMode = try container.decodeIfPresent(TunnelIPMode.self, forKey: .preferredIPMode) ?? .ipv4Only
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(country, forKey: .country)
        try container.encode(city, forKey: .city)
        try container.encode(region, forKey: .region)
        try container.encode(protocolName, forKey: .protocolName)
        try container.encode(isAvailable, forKey: .isAvailable)
        try container.encode(preferredIPMode, forKey: .preferredIPMode)
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
        "\(title) - \(protocolName) - \(locationSummary.nilIfBlank ?? region)"
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
