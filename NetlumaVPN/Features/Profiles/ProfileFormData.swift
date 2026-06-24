import Foundation

enum ProfileFormError: LocalizedError {
    case missingName
    case missingHost
    case invalidPort
    case missingUserID
    case missingPassword
    case missingRealityPublicKey
    case missingWireGuardPrivateKey
    case missingWireGuardPeerPublicKey
    case missingWireGuardAddress
    case invalidWireGuardKeepAlive
    case invalidWireGuardMTU
    case invalidWireGuardReserved

    var errorDescription: String? {
        switch self {
        case .missingName:
            L10n.string("Enter a profile name.")
        case .missingHost:
            L10n.string("Enter a server host.")
        case .invalidPort:
            L10n.string("Enter a valid port from 1 to 65535.")
        case .missingUserID:
            L10n.string("Enter the user ID.")
        case .missingPassword:
            L10n.string("Enter the password.")
        case .missingRealityPublicKey:
            L10n.string("Enter the Reality public key.")
        case .missingWireGuardPrivateKey:
            L10n.string("Enter the WireGuard private key.")
        case .missingWireGuardPeerPublicKey:
            L10n.string("Enter the WireGuard peer public key.")
        case .missingWireGuardAddress:
            L10n.string("Enter at least one WireGuard interface address.")
        case .invalidWireGuardKeepAlive:
            L10n.string("Enter a valid WireGuard keepalive value.")
        case .invalidWireGuardMTU:
            L10n.string("Enter a valid WireGuard MTU from 576 to 9000.")
        case .invalidWireGuardReserved:
            L10n.string("Enter WireGuard reserved bytes as comma-separated values from 0 to 255.")
        }
    }
}

struct ProfileFormData {
    var protocolType: VPNProtocolType = .vless
    var remarks = ""
    var host = ""
    var port = "443"
    var userId = ""
    var password = ""
    var security: VPNTransportSecurity = .tls
    var networkType: VPNNetworkType = .tcp
    var sni = ""
    var transportHost = ""
    var path = ""
    var flow = ""
    var tlsFingerprint = "chrome"
    var tlsALPN = ""
    var realityPublicKey = ""
    var realityFingerprint = "chrome"
    var realityShortID = ""
    var realitySpiderX = "/"
    var wireGuardPrivateKey = ""
    var wireGuardPeerPublicKey = ""
    var wireGuardPreSharedKey = ""
    var wireGuardAddresses = ""
    var wireGuardAllowedIPs = "0.0.0.0/0, ::/0"
    var wireGuardPersistentKeepAlive = ""
    var wireGuardMTU = "1420"
    var wireGuardReserved = ""

    init() {}

    init(profile: VPNProfile?, secret: VPNProfileSecret?) {
        guard let profile else {
            return
        }

        protocolType = profile.protocolType
        remarks = profile.remarks
        host = profile.host
        port = String(profile.port)
        userId = secret?.userId ?? ""
        password = secret?.password ?? ""
        security = profile.security
        networkType = profile.networkType
        sni = profile.sni ?? ""
        transportHost = profile.transportHost ?? ""
        path = profile.path ?? ""
        flow = profile.flow ?? ""
        tlsFingerprint = profile.tlsFingerprint ?? profile.realityFingerprint ?? "chrome"
        tlsALPN = profile.tlsALPN?.joined(separator: ", ") ?? ""
        realityPublicKey = profile.realityPublicKey ?? ""
        realityFingerprint = profile.realityFingerprint ?? "chrome"
        realityShortID = profile.realityShortID ?? ""
        realitySpiderX = profile.realitySpiderX ?? "/"
        wireGuardPrivateKey = secret?.wireGuardPrivateKey ?? ""
        wireGuardPeerPublicKey = profile.wireGuardPeerPublicKey ?? ""
        wireGuardPreSharedKey = secret?.wireGuardPreSharedKey ?? ""
        wireGuardAddresses = profile.wireGuardLocalAddresses?.joined(separator: ", ") ?? ""
        wireGuardAllowedIPs = profile.wireGuardAllowedIPs?.joined(separator: ", ") ?? "0.0.0.0/0, ::/0"
        wireGuardPersistentKeepAlive = profile.wireGuardPersistentKeepAlive.map(String.init) ?? ""
        wireGuardMTU = profile.wireGuardMTU.map(String.init) ?? "1420"
        wireGuardReserved = profile.wireGuardReserved?.map(String.init).joined(separator: ", ") ?? ""
    }

    func makeProfile(existingProfile: VPNProfile?) throws -> (VPNProfile, VPNProfileSecret) {
        guard let remarks = remarks.nilIfBlank else {
            throw ProfileFormError.missingName
        }
        guard let host = host.nilIfBlank else {
            throw ProfileFormError.missingHost
        }
        guard let portValue = Int(port), (1...65535).contains(portValue) else {
            throw ProfileFormError.invalidPort
        }

        let secret: VPNProfileSecret
        switch protocolType {
        case .vless, .vmess:
            guard let userId = userId.nilIfBlank else {
                throw ProfileFormError.missingUserID
            }
            secret = VPNProfileSecret(userId: userId)
        case .trojan:
            guard let password = password.nilIfBlank else {
                throw ProfileFormError.missingPassword
            }
            secret = VPNProfileSecret(password: password)
        case .wireguard:
            guard let privateKey = wireGuardPrivateKey.nilIfBlank else {
                throw ProfileFormError.missingWireGuardPrivateKey
            }
            secret = VPNProfileSecret(
                wireGuardPrivateKey: privateKey,
                wireGuardPreSharedKey: wireGuardPreSharedKey
            )
        }

        if protocolType != .wireguard, security == .reality, realityPublicKey.nilIfBlank == nil {
            throw ProfileFormError.missingRealityPublicKey
        }

        let wireGuardAddresses = commaSeparatedValues(self.wireGuardAddresses)
        let wireGuardAllowedIPs = commaSeparatedValues(self.wireGuardAllowedIPs)
        let wireGuardPersistentKeepAlive = try optionalInt(
            wireGuardPersistentKeepAlive,
            range: 0...Int.max,
            error: .invalidWireGuardKeepAlive
        )
        let wireGuardMTU = try optionalInt(
            wireGuardMTU,
            range: 576...9000,
            error: .invalidWireGuardMTU
        )
        let wireGuardReserved = try reservedBytes(wireGuardReserved)

        if protocolType == .wireguard {
            guard wireGuardPeerPublicKey.nilIfBlank != nil else {
                throw ProfileFormError.missingWireGuardPeerPublicKey
            }
            guard wireGuardAddresses.isEmpty == false else {
                throw ProfileFormError.missingWireGuardAddress
            }
        }

        let profile = VPNProfile(
            id: existingProfile?.id ?? UUID(),
            protocolType: protocolType,
            host: host,
            port: portValue,
            security: protocolType == .wireguard ? .none : security,
            networkType: protocolType == .wireguard ? .tcp : networkType,
            sni: protocolType == .wireguard ? nil : sni,
            transportHost: protocolType == .wireguard ? nil : transportHost,
            path: protocolType == .wireguard ? nil : path,
            flow: protocolType == .wireguard ? nil : flow,
            tlsFingerprint: protocolType == .wireguard ? nil : tlsFingerprint,
            tlsALPN: protocolType == .wireguard ? nil : tlsALPN.split(separator: ",").compactMap { String($0).nilIfBlank },
            realityPublicKey: protocolType == .wireguard ? nil : realityPublicKey,
            realityFingerprint: protocolType == .wireguard ? nil : realityFingerprint,
            realityShortID: protocolType == .wireguard ? nil : realityShortID,
            realitySpiderX: protocolType == .wireguard ? nil : realitySpiderX,
            wireGuardPeerPublicKey: protocolType == .wireguard ? wireGuardPeerPublicKey : nil,
            wireGuardLocalAddresses: protocolType == .wireguard ? wireGuardAddresses : nil,
            wireGuardAllowedIPs: protocolType == .wireguard ? wireGuardAllowedIPs : nil,
            wireGuardPersistentKeepAlive: protocolType == .wireguard ? wireGuardPersistentKeepAlive : nil,
            wireGuardMTU: protocolType == .wireguard ? wireGuardMTU : nil,
            wireGuardReserved: protocolType == .wireguard ? wireGuardReserved : nil,
            // DNS has no editor field; preserve it from the imported profile so editing
            // a WireGuard profile doesn't strip its resolvers (see VPN_TUNNEL.md).
            wireGuardDNSServers: protocolType == .wireguard ? existingProfile?.wireGuardDNSServers : nil,
            remarks: remarks,
            createdAt: existingProfile?.createdAt ?? Date(),
            updatedAt: Date()
        )

        return (profile, secret)
    }

    mutating func applyDefaultsForSelectedProtocol() {
        guard protocolType == .wireguard else {
            return
        }

        security = .none
        networkType = .tcp
        if port == "443" {
            port = "51820"
        }
        if wireGuardAllowedIPs.nilIfBlank == nil {
            wireGuardAllowedIPs = "0.0.0.0/0, ::/0"
        }
        if wireGuardMTU.nilIfBlank == nil {
            wireGuardMTU = "1420"
        }
    }

    private func commaSeparatedValues(_ value: String) -> [String] {
        value
            .split(separator: ",")
            .compactMap { String($0).nilIfBlank }
    }

    private func optionalInt(
        _ value: String,
        range: ClosedRange<Int>,
        error: ProfileFormError
    ) throws -> Int? {
        guard let value = value.nilIfBlank else {
            return nil
        }
        guard let intValue = Int(value), range.contains(intValue) else {
            throw error
        }
        return intValue
    }

    private func reservedBytes(_ value: String) throws -> [Int]? {
        let values = commaSeparatedValues(value)
        guard values.isEmpty == false else {
            return nil
        }

        let bytes = values.compactMap(Int.init)
        guard bytes.count == values.count,
              bytes.allSatisfy({ (0...255).contains($0) }) else {
            throw ProfileFormError.invalidWireGuardReserved
        }
        return bytes
    }
}
