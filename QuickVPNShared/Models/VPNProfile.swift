import Foundation

enum VPNProtocolType: String, CaseIterable, Codable, Identifiable {
    case vless
    case vmess
    case trojan
    case wireguard

    var id: String { rawValue }

    var title: String {
        switch self {
        case .vless:
            "VLESS"
        case .vmess:
            "VMess"
        case .trojan:
            "Trojan"
        case .wireguard:
            "WireGuard"
        }
    }
}

enum VPNTransportSecurity: String, CaseIterable, Codable, Identifiable {
    case none
    case tls
    case reality

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none:
            "None"
        case .tls:
            "TLS"
        case .reality:
            "Reality"
        }
    }
}

enum VPNNetworkType: String, CaseIterable, Codable, Identifiable {
    case tcp
    case ws
    case grpc
    case httpupgrade

    var id: String { rawValue }

    var title: String {
        switch self {
        case .tcp:
            "TCP"
        case .ws:
            "WebSocket"
        case .grpc:
            "gRPC"
        case .httpupgrade:
            "HTTP Upgrade"
        }
    }
}

enum VPNProfileOrigin: String, Codable {
    case quickVPNGlobal
}

struct VPNProfile: Identifiable, Codable, Equatable, Hashable {
    var id: UUID
    var protocolType: VPNProtocolType
    var host: String
    var port: Int
    var security: VPNTransportSecurity
    var networkType: VPNNetworkType
    var sni: String?
    var transportHost: String?
    var path: String?
    var flow: String?
    var tlsFingerprint: String?
    var tlsALPN: [String]?
    var realityPublicKey: String?
    var realityFingerprint: String?
    var realityShortID: String?
    var realitySpiderX: String?
    var wireGuardPeerPublicKey: String?
    var wireGuardLocalAddresses: [String]?
    var wireGuardAllowedIPs: [String]?
    var wireGuardPersistentKeepAlive: Int?
    var wireGuardMTU: Int?
    var wireGuardReserved: [Int]?
    var origin: VPNProfileOrigin?
    var managedServerID: String?
    var remarks: String
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        protocolType: VPNProtocolType,
        host: String,
        port: Int,
        security: VPNTransportSecurity,
        networkType: VPNNetworkType,
        sni: String? = nil,
        transportHost: String? = nil,
        path: String? = nil,
        flow: String? = nil,
        tlsFingerprint: String? = nil,
        tlsALPN: [String]? = nil,
        realityPublicKey: String? = nil,
        realityFingerprint: String? = nil,
        realityShortID: String? = nil,
        realitySpiderX: String? = nil,
        wireGuardPeerPublicKey: String? = nil,
        wireGuardLocalAddresses: [String]? = nil,
        wireGuardAllowedIPs: [String]? = nil,
        wireGuardPersistentKeepAlive: Int? = nil,
        wireGuardMTU: Int? = nil,
        wireGuardReserved: [Int]? = nil,
        origin: VPNProfileOrigin? = nil,
        managedServerID: String? = nil,
        remarks: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.protocolType = protocolType
        self.host = host
        self.port = port
        self.security = security
        self.networkType = networkType
        self.sni = sni?.nilIfBlank
        self.transportHost = transportHost?.nilIfBlank
        self.path = path?.nilIfBlank
        self.flow = flow?.nilIfBlank
        self.tlsFingerprint = tlsFingerprint?.nilIfBlank
        let normalizedALPN = tlsALPN?.compactMap(\.nilIfBlank)
        self.tlsALPN = normalizedALPN?.isEmpty == false ? normalizedALPN : nil
        self.realityPublicKey = realityPublicKey?.nilIfBlank
        self.realityFingerprint = realityFingerprint?.nilIfBlank
        self.realityShortID = realityShortID?.nilIfBlank
        self.realitySpiderX = realitySpiderX?.nilIfBlank
        self.wireGuardPeerPublicKey = wireGuardPeerPublicKey?.nilIfBlank
        let normalizedWireGuardAddresses = wireGuardLocalAddresses?.compactMap(\.nilIfBlank)
        self.wireGuardLocalAddresses = normalizedWireGuardAddresses?.isEmpty == false ? normalizedWireGuardAddresses : nil
        let normalizedAllowedIPs = wireGuardAllowedIPs?.compactMap(\.nilIfBlank)
        self.wireGuardAllowedIPs = normalizedAllowedIPs?.isEmpty == false ? normalizedAllowedIPs : nil
        self.wireGuardPersistentKeepAlive = wireGuardPersistentKeepAlive
        self.wireGuardMTU = wireGuardMTU
        self.wireGuardReserved = wireGuardReserved?.isEmpty == false ? wireGuardReserved : nil
        self.origin = origin
        self.managedServerID = managedServerID?.nilIfBlank
        self.remarks = remarks.nilIfBlank ?? "\(protocolType.title) \(host)"
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var displayName: String {
        remarks.nilIfBlank ?? host
    }

    var displayEndpoint: String {
        "\(host):\(port)"
    }

    var keychainAccount: String {
        "vpn-profile-\(id.uuidString)"
    }

    var isQuickVPNManaged: Bool {
        origin == .quickVPNGlobal
    }
}

struct VPNProfileSecret: Codable, Equatable {
    var userId: String?
    var password: String?
    var wireGuardPrivateKey: String?
    var wireGuardPreSharedKey: String?

    init(
        userId: String? = nil,
        password: String? = nil,
        wireGuardPrivateKey: String? = nil,
        wireGuardPreSharedKey: String? = nil
    ) {
        self.userId = userId?.nilIfBlank
        self.password = password?.nilIfBlank
        self.wireGuardPrivateKey = wireGuardPrivateKey?.nilIfBlank
        self.wireGuardPreSharedKey = wireGuardPreSharedKey?.nilIfBlank
    }
}

struct ResolvedVPNProfile: Codable, Equatable {
    var profile: VPNProfile
    var secret: VPNProfileSecret
}

struct TunnelStartPayload: Codable, Equatable {
    var resolvedProfile: ResolvedVPNProfile
}

extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
