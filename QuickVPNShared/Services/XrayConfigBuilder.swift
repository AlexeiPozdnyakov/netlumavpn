import Foundation

enum XrayConfigBuilderError: LocalizedError {
    case missingCredential(VPNProtocolType)
    case missingRealityPublicKey
    case missingWireGuardPeerPublicKey
    case missingWireGuardAddress
    case invalidJSON

    var errorDescription: String? {
        switch self {
        case .missingCredential(let protocolType):
            "Required credential is missing for \(protocolType.title)."
        case .missingRealityPublicKey:
            "Reality public key is missing."
        case .missingWireGuardPeerPublicKey:
            "WireGuard peer public key is missing."
        case .missingWireGuardAddress:
            "WireGuard interface address is missing."
        case .invalidJSON:
            "Could not build Xray JSON configuration."
        }
    }
}

struct XrayConfigBuilder {
    func buildConfigData(for resolvedProfile: ResolvedVPNProfile) throws -> Data {
        let configuration: [String: Any] = [
            "log": [
                "loglevel": "warning"
            ],
            "inbounds": [
                [
                    "tag": "local-socks",
                    "protocol": "socks",
                    "listen": "127.0.0.1",
                    "port": 10808,
                    "settings": [
                        "udp": true,
                        "auth": "noauth"
                    ],
                    "sniffing": [
                        "enabled": false
                    ]
                ]
            ],
            "outbounds": [
                try outbound(for: resolvedProfile)
            ]
        ]

        guard JSONSerialization.isValidJSONObject(configuration) else {
            throw XrayConfigBuilderError.invalidJSON
        }

        return try JSONSerialization.data(
            withJSONObject: configuration,
            options: [.prettyPrinted, .sortedKeys]
        )
    }

    private func outbound(for resolvedProfile: ResolvedVPNProfile) throws -> [String: Any] {
        let profile = resolvedProfile.profile
        var outbound: [String: Any] = [
            "tag": "proxy",
            "protocol": profile.protocolType.rawValue
        ]

        switch profile.protocolType {
        case .vless:
            outbound["streamSettings"] = try streamSettings(for: profile)

            guard let userId = resolvedProfile.secret.userId?.nilIfBlank else {
                throw XrayConfigBuilderError.missingCredential(profile.protocolType)
            }
            var user: [String: Any] = [
                "id": userId,
                "encryption": "none"
            ]
            if let flow = profile.flow?.nilIfBlank {
                user["flow"] = flow
            }

            outbound["settings"] = [
                "vnext": [
                    [
                        "address": profile.host,
                        "port": profile.port,
                        "users": [
                            user
                        ]
                    ]
                ]
            ]
        case .vmess:
            outbound["streamSettings"] = try streamSettings(for: profile)

            guard let userId = resolvedProfile.secret.userId?.nilIfBlank else {
                throw XrayConfigBuilderError.missingCredential(profile.protocolType)
            }
            outbound["settings"] = [
                "vnext": [
                    [
                        "address": profile.host,
                        "port": profile.port,
                        "users": [
                            [
                                "id": userId,
                                "alterId": 0,
                                "security": "auto"
                            ]
                        ]
                    ]
                ]
            ]
        case .trojan:
            outbound["streamSettings"] = try streamSettings(for: profile)

            guard let password = resolvedProfile.secret.password?.nilIfBlank else {
                throw XrayConfigBuilderError.missingCredential(profile.protocolType)
            }
            outbound["settings"] = [
                "servers": [
                    [
                        "address": profile.host,
                        "port": profile.port,
                        "password": password
                    ]
                ]
            ]
        case .wireguard:
            guard let privateKey = resolvedProfile.secret.wireGuardPrivateKey?.nilIfBlank else {
                throw XrayConfigBuilderError.missingCredential(profile.protocolType)
            }
            guard let peerPublicKey = profile.wireGuardPeerPublicKey?.nilIfBlank else {
                throw XrayConfigBuilderError.missingWireGuardPeerPublicKey
            }
            guard let addresses = profile.wireGuardLocalAddresses?.compactMap(\.nilIfBlank),
                  addresses.isEmpty == false else {
                throw XrayConfigBuilderError.missingWireGuardAddress
            }

            var peer: [String: Any] = [
                "endpoint": wireGuardEndpoint(for: profile),
                "publicKey": peerPublicKey
            ]

            if let preSharedKey = resolvedProfile.secret.wireGuardPreSharedKey?.nilIfBlank {
                peer["preSharedKey"] = preSharedKey
            }
            if let keepAlive = profile.wireGuardPersistentKeepAlive {
                peer["keepAlive"] = keepAlive
            }
            if let allowedIPs = profile.wireGuardAllowedIPs?.compactMap(\.nilIfBlank),
               allowedIPs.isEmpty == false {
                peer["allowedIPs"] = allowedIPs
            }

            var settings: [String: Any] = [
                "secretKey": privateKey,
                "address": addresses,
                "peers": [
                    peer
                ],
                "noKernelTun": true,
                "domainStrategy": "ForceIP"
            ]

            if let mtu = profile.wireGuardMTU {
                settings["mtu"] = mtu
            }
            if let reserved = profile.wireGuardReserved, reserved.isEmpty == false {
                settings["reserved"] = reserved
            }

            outbound["settings"] = settings
        }

        return outbound
    }

    private func streamSettings(for profile: VPNProfile) throws -> [String: Any] {
        var settings: [String: Any] = [
            "network": profile.networkType.rawValue,
            "security": profile.security.rawValue
        ]

        if profile.security == .tls {
            var tlsSettings: [String: Any] = [
                "serverName": profile.sni?.nilIfBlank ?? profile.host
            ]
            if let fingerprint = (profile.tlsFingerprint ?? profile.realityFingerprint)?.nilIfBlank {
                tlsSettings["fingerprint"] = fingerprint
            }
            if let alpn = profile.tlsALPN?.compactMap(\.nilIfBlank), alpn.isEmpty == false {
                tlsSettings["alpn"] = alpn
            }
            settings["tlsSettings"] = tlsSettings
        }

        if profile.security == .reality {
            guard let publicKey = profile.realityPublicKey?.nilIfBlank else {
                throw XrayConfigBuilderError.missingRealityPublicKey
            }

            settings["realitySettings"] = [
                "serverName": profile.sni?.nilIfBlank ?? profile.host,
                "fingerprint": profile.realityFingerprint?.nilIfBlank ?? "chrome",
                "publicKey": publicKey,
                "shortId": profile.realityShortID?.nilIfBlank ?? "",
                "spiderX": profile.realitySpiderX?.nilIfBlank ?? "/"
            ]
        }

        switch profile.networkType {
        case .tcp:
            break
        case .ws:
            var wsSettings: [String: Any] = [
                "path": profile.path?.nilIfBlank ?? "/"
            ]
            if let host = (profile.transportHost ?? profile.sni)?.nilIfBlank {
                wsSettings["headers"] = [
                    "Host": host
                ]
            }
            settings["wsSettings"] = wsSettings
        case .grpc:
            var grpcSettings: [String: Any] = [
                "serviceName": profile.path?.nilIfBlank ?? ""
            ]
            if let authority = profile.transportHost?.nilIfBlank {
                grpcSettings["authority"] = authority
            }
            settings["grpcSettings"] = grpcSettings
        case .httpupgrade:
            var httpUpgradeSettings: [String: Any] = [
                "path": profile.path?.nilIfBlank ?? "/"
            ]
            if let host = (profile.transportHost ?? profile.sni)?.nilIfBlank {
                httpUpgradeSettings["host"] = host
            }
            settings["httpupgradeSettings"] = httpUpgradeSettings
        }

        return settings
    }

    private func wireGuardEndpoint(for profile: VPNProfile) -> String {
        let host = profile.host.contains(":") && !profile.host.hasPrefix("[")
            ? "[\(profile.host)]"
            : profile.host
        return "\(host):\(profile.port)"
    }
}
