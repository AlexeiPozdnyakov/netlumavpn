import Foundation

enum TunnelIPMode: String, CaseIterable, Codable, Identifiable {
    case ipv4AndIPv6
    case ipv4Only

    var id: String { rawValue }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        switch value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_") {
        case "ipv4_and_ipv6", "ipv4andipv6", "dual_stack", "dualstack":
            self = .ipv4AndIPv6
        case "ipv4_only", "ipv4only", "ipv4":
            self = .ipv4Only
        default:
            self = .ipv4Only
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    var title: String {
        switch self {
        case .ipv4AndIPv6:
            L10n.string("IPv4 & IPv6")
        case .ipv4Only:
            L10n.string("IPv4 Only")
        }
    }
}

enum TunnelOnDemandMode: String, CaseIterable, Codable, Identifiable {
    case disabled
    case always

    var id: String { rawValue }

    var title: String {
        switch self {
        case .disabled:
            L10n.string("Disable")
        case .always:
            L10n.string("Always")
        }
    }

    var isEnabled: Bool {
        self == .always
    }
}

struct TunnelPreferences: Codable, Equatable {
    var persistTunnel: Bool
    var ipMode: TunnelIPMode
    var onDemandMode: TunnelOnDemandMode
    var includeAllNetworks: Bool

    init(
        persistTunnel: Bool = false,
        ipMode: TunnelIPMode = .ipv4Only,
        onDemandMode: TunnelOnDemandMode = .disabled,
        includeAllNetworks: Bool = false
    ) {
        self.persistTunnel = persistTunnel
        self.ipMode = ipMode
        self.onDemandMode = onDemandMode
        self.includeAllNetworks = includeAllNetworks
    }

    var isOnDemandEnabled: Bool {
        persistTunnel && onDemandMode.isEnabled
    }
}

enum DNSResolverKind: String, Codable, Equatable {
    case standard
    case doh
    case dot

    var title: String {
        switch self {
        case .standard:
            "DoU"
        case .doh:
            "DoH"
        case .dot:
            "DoT"
        }
    }
}

struct DNSResolver: Codable, Equatable, Identifiable {
    var id: String
    var kind: DNSResolverKind
    var serverAddress: String
    var serverName: String?
    var serverURL: URL?

    var title: String {
        "\(kind.title): \(serverAddress)"
    }

    var servers: [String] {
        [serverAddress]
    }
}

extension DNSResolver {
    static let catalog: [DNSResolver] = [
        DNSResolver(
            id: "doh-google-ipv4",
            kind: .doh,
            serverAddress: "8.8.8.8",
            serverName: "dns.google",
            serverURL: URL(string: "https://dns.google/dns-query")
        ),
        DNSResolver(
            id: "doh-google-ipv6",
            kind: .doh,
            serverAddress: "2001:4860:4860::8888",
            serverName: "dns.google",
            serverURL: URL(string: "https://dns.google/dns-query")
        ),
        DNSResolver(
            id: "dot-google-ipv4",
            kind: .dot,
            serverAddress: "8.8.8.8",
            serverName: "dns.google"
        ),
        DNSResolver(
            id: "dot-google-ipv6",
            kind: .dot,
            serverAddress: "2001:4860:4860::8888",
            serverName: "dns.google"
        ),
        DNSResolver(id: "dou-google-ipv4", kind: .standard, serverAddress: "8.8.8.8"),
        DNSResolver(id: "dou-google-ipv6", kind: .standard, serverAddress: "2001:4860:4860::8888"),
        DNSResolver(
            id: "doh-cloudflare-ipv4",
            kind: .doh,
            serverAddress: "1.1.1.1",
            serverName: "cloudflare-dns.com",
            serverURL: URL(string: "https://cloudflare-dns.com/dns-query")
        ),
        DNSResolver(
            id: "doh-cloudflare-ipv6",
            kind: .doh,
            serverAddress: "2606:4700:4700::1111",
            serverName: "cloudflare-dns.com",
            serverURL: URL(string: "https://cloudflare-dns.com/dns-query")
        ),
        DNSResolver(
            id: "dot-cloudflare-ipv4",
            kind: .dot,
            serverAddress: "1.1.1.1",
            serverName: "cloudflare-dns.com"
        ),
        DNSResolver(
            id: "dot-cloudflare-ipv6",
            kind: .dot,
            serverAddress: "2606:4700:4700::1111",
            serverName: "cloudflare-dns.com"
        ),
        DNSResolver(id: "dou-cloudflare-ipv4", kind: .standard, serverAddress: "1.1.1.1")
    ]

    static let defaultResolver = catalog[0]

    static func resolver(for id: String) -> DNSResolver {
        catalog.first { $0.id == id } ?? defaultResolver
    }
}

struct NetworkPreferences: Codable, Equatable {
    var tunnel: TunnelPreferences
    var selectedDNSResolverID: DNSResolver.ID

    init(
        tunnel: TunnelPreferences = TunnelPreferences(),
        selectedDNSResolverID: DNSResolver.ID = DNSResolver.defaultResolver.id
    ) {
        self.tunnel = tunnel
        self.selectedDNSResolverID = selectedDNSResolverID
    }

    var selectedDNSResolver: DNSResolver {
        DNSResolver.resolver(for: selectedDNSResolverID)
    }
}
