import Foundation

enum VPNConfigurationParserError: LocalizedError {
    case unsupportedScheme
    case unsupportedSecurity(String)
    case invalidURL
    case invalidVMessPayload
    case invalidSingBoxPayload
    case invalidWireGuardValue(String)
    case missingRequiredField(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedScheme:
            L10n.string("Only vless://, vmess://, trojan://, and WireGuard configurations are supported.")
        case .unsupportedSecurity(let value):
            L10n.format("Security '%@' is not supported by this app. Use none, tls, or reality.", value)
        case .invalidURL:
            L10n.string("The configuration link is not valid.")
        case .invalidVMessPayload:
            L10n.string("The VMess configuration payload could not be decoded.")
        case .invalidSingBoxPayload:
            L10n.string("The sing-box JSON configuration could not be decoded.")
        case .invalidWireGuardValue(let field):
            L10n.format("The WireGuard value for %@ is invalid.", field)
        case .missingRequiredField(let field):
            L10n.format("The configuration link is missing %@.", field)
        }
    }
}

struct VPNConfigurationParser {
    func parse(_ rawValue: String) throws -> (VPNProfile, VPNProfileSecret) {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if looksLikeWireGuardConfiguration(trimmed) {
            return try parseWireGuardConfiguration(trimmed)
        }
        if looksLikeJSONConfiguration(trimmed) {
            return try parseSingBoxJSONConfiguration(trimmed)
        }

        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased() else {
            throw VPNConfigurationParserError.invalidURL
        }

        switch scheme {
        case "vless":
            return try parseUserInfoURL(trimmed, protocolType: .vless)
        case "trojan":
            return try parseUserInfoURL(trimmed, protocolType: .trojan)
        case "vmess":
            return try parseVMess(trimmed)
        case "wireguard", "wg":
            return try parseWireGuardURL(trimmed)
        default:
            throw VPNConfigurationParserError.unsupportedScheme
        }
    }

    private func parseSingBoxJSONConfiguration(_ rawValue: String) throws -> (VPNProfile, VPNProfileSecret) {
        guard let data = rawValue.data(using: .utf8),
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let outbounds = root["outbounds"] as? [[String: Any]] else {
            throw VPNConfigurationParserError.invalidSingBoxPayload
        }

        guard let outbound = outbounds.first(where: { singBoxProtocol($0) != nil }) else {
            throw VPNConfigurationParserError.missingRequiredField("proxy outbound")
        }
        guard let protocolType = singBoxProtocol(outbound) else {
            throw VPNConfigurationParserError.missingRequiredField("protocol")
        }
        guard let host = singBoxString(outbound["server"]) else {
            throw VPNConfigurationParserError.missingRequiredField("server")
        }
        guard let port = singBoxInt(outbound["server_port"]) else {
            throw VPNConfigurationParserError.missingRequiredField("server_port")
        }

        let tls = outbound["tls"] as? [String: Any]
        let tlsEnabled = singBoxBool(tls?["enabled"]) ?? false
        let transport = outbound["transport"] as? [String: Any]
        let networkType = parseNetworkType(singBoxString(transport?["type"]))
        let security: VPNTransportSecurity = tlsEnabled ? .tls : .none
        let remarks = singBoxString(outbound["tag"]).flatMap { $0 == "proxy" ? nil : $0 } ?? "\(protocolType.title) \(host)"

        let profile = VPNProfile(
            protocolType: protocolType,
            host: host,
            port: port,
            security: security,
            networkType: networkType,
            sni: singBoxString(tls?["server_name"]),
            transportHost: singBoxTransportHost(for: networkType, transport: transport),
            path: singBoxTransportPath(for: networkType, transport: transport),
            flow: singBoxString(outbound["flow"]),
            tlsFingerprint: security == .tls ? singBoxUTLSFingerprint(tls) : nil,
            tlsALPN: singBoxStringList(tls?["alpn"]),
            remarks: remarks
        )

        switch protocolType {
        case .vless:
            guard let userId = singBoxString(outbound["uuid"]) else {
                throw VPNConfigurationParserError.missingRequiredField("uuid")
            }
            return (profile, VPNProfileSecret(userId: userId))
        case .trojan:
            guard let password = singBoxString(outbound["password"]) else {
                throw VPNConfigurationParserError.missingRequiredField("password")
            }
            return (profile, VPNProfileSecret(password: password))
        case .vmess, .wireguard:
            throw VPNConfigurationParserError.unsupportedScheme
        }
    }

    private func parseUserInfoURL(
        _ rawValue: String,
        protocolType: VPNProtocolType
    ) throws -> (VPNProfile, VPNProfileSecret) {
        guard let components = URLComponents(string: rawValue),
              let host = components.host?.nilIfBlank,
              let port = components.port else {
            throw VPNConfigurationParserError.invalidURL
        }

        let query = (components.queryItems ?? []).reduce(into: [String: String]()) { result, item in
            result[item.name.lowercased()] = item.value ?? ""
        }

        let security = try parseSecurity(query["security"])
        let networkType = parseNetworkType(query["type"])
        let remarks = components.percentEncodedFragment
            .flatMap { $0.removingPercentEncoding }?
            .nilIfBlank ?? "\(protocolType.title) \(host)"
        let transportHost = transportHost(for: networkType, query: query)

        let profile = VPNProfile(
            protocolType: protocolType,
            host: host,
            port: port,
            security: security,
            networkType: networkType,
            sni: query["sni"] ?? transportHost,
            transportHost: transportHost,
            path: path(for: networkType, query: query),
            flow: query["flow"],
            tlsFingerprint: security == .tls ? query["fp"] : nil,
            tlsALPN: parseALPN(query["alpn"]),
            realityPublicKey: query["pbk"],
            realityFingerprint: security == .reality ? query["fp"] : nil,
            realityShortID: query["sid"],
            realitySpiderX: query["spx"]?.removingPercentEncoding,
            remarks: remarks
        )

        let user = components.percentEncodedUser?.removingPercentEncoding
        let secret: VPNProfileSecret
        switch protocolType {
        case .vless, .vmess:
            guard let userId = user?.nilIfBlank else {
                throw VPNConfigurationParserError.missingRequiredField("userId")
            }
            secret = VPNProfileSecret(userId: userId)
        case .trojan:
            guard let password = user?.nilIfBlank else {
                throw VPNConfigurationParserError.missingRequiredField("password")
            }
            secret = VPNProfileSecret(password: password)
        case .wireguard:
            throw VPNConfigurationParserError.invalidURL
        }

        return (profile, secret)
    }

    private func parseVMess(_ rawValue: String) throws -> (VPNProfile, VPNProfileSecret) {
        let payload = rawValue.replacingOccurrences(of: "vmess://", with: "")
        guard let data = Data(base64Encoded: payload.base64Padded()) else {
            throw VPNConfigurationParserError.invalidVMessPayload
        }

        let vmess: VMessImportPayload
        do {
            vmess = try JSONDecoder().decode(VMessImportPayload.self, from: data)
        } catch {
            throw VPNConfigurationParserError.invalidVMessPayload
        }

        guard let host = vmess.add.nilIfBlank else {
            throw VPNConfigurationParserError.missingRequiredField("host")
        }
        guard let port = Int(vmess.port) else {
            throw VPNConfigurationParserError.missingRequiredField("port")
        }
        guard let userId = vmess.id.nilIfBlank else {
            throw VPNConfigurationParserError.missingRequiredField("userId")
        }

        let profile = VPNProfile(
            protocolType: .vmess,
            host: host,
            port: port,
            security: try parseSecurity(vmess.tls),
            networkType: parseNetworkType(vmess.net),
            sni: vmess.sni ?? vmess.host,
            transportHost: vmess.host,
            path: vmess.path,
            remarks: vmess.ps.nilIfBlank ?? "VMess \(host)"
        )

        return (profile, VPNProfileSecret(userId: userId))
    }

    private func parseWireGuardConfiguration(_ rawValue: String) throws -> (VPNProfile, VPNProfileSecret) {
        let sections = parseWireGuardSections(rawValue)
        guard let interface = sections["interface"]?.first else {
            throw VPNConfigurationParserError.missingRequiredField("[Interface]")
        }
        guard let peer = sections["peer"]?.first else {
            throw VPNConfigurationParserError.missingRequiredField("[Peer]")
        }
        guard let privateKey = wireGuardValue(interface, "privatekey") else {
            throw VPNConfigurationParserError.missingRequiredField("privateKey")
        }
        guard let peerPublicKey = wireGuardValue(peer, "publickey") else {
            throw VPNConfigurationParserError.missingRequiredField("publicKey")
        }
        guard let endpointValue = wireGuardValue(peer, "endpoint") else {
            throw VPNConfigurationParserError.missingRequiredField("endpoint")
        }

        let endpoint = try parseWireGuardEndpoint(endpointValue)
        let addresses = splitWireGuardList(wireGuardValue(interface, "address"))
        guard addresses.isEmpty == false else {
            throw VPNConfigurationParserError.missingRequiredField("address")
        }

        let profile = VPNProfile(
            protocolType: .wireguard,
            host: endpoint.host,
            port: endpoint.port,
            security: .none,
            networkType: .tcp,
            wireGuardPeerPublicKey: peerPublicKey,
            wireGuardLocalAddresses: addresses,
            wireGuardAllowedIPs: splitWireGuardList(wireGuardValue(peer, "allowedips")),
            wireGuardPersistentKeepAlive: try parseWireGuardInt(
                wireGuardValue(peer, "persistentkeepalive"),
                field: "persistentKeepalive",
                range: 0...Int.max
            ),
            wireGuardMTU: try parseWireGuardInt(
                wireGuardValue(interface, "mtu"),
                field: "MTU",
                range: 576...9000
            ),
            wireGuardReserved: try parseWireGuardReserved(
                wireGuardValue(interface, "reserved") ?? wireGuardValue(peer, "reserved")
            ),
            wireGuardDNSServers: splitWireGuardList(wireGuardValue(interface, "dns")),
            remarks: wireGuardValue(interface, "name") ?? wireGuardValue(peer, "name") ?? "WireGuard \(endpoint.host)"
        )

        return (
            profile,
            VPNProfileSecret(
                wireGuardPrivateKey: privateKey,
                wireGuardPreSharedKey: wireGuardValue(peer, "presharedkey")
            )
        )
    }

    private func parseWireGuardURL(_ rawValue: String) throws -> (VPNProfile, VPNProfileSecret) {
        guard let components = URLComponents(string: rawValue) else {
            throw VPNConfigurationParserError.invalidURL
        }

        let query = (components.queryItems ?? []).reduce(into: [String: String]()) { result, item in
            result[wireGuardKey(item.name)] = item.value ?? ""
        }

        let endpoint: (host: String, port: Int)
        if let endpointValue = wireGuardValue(query, "endpoint") {
            endpoint = try parseWireGuardEndpoint(endpointValue)
        } else if let host = components.host?.nilIfBlank,
                  let port = components.port {
            endpoint = (host, port)
        } else {
            throw VPNConfigurationParserError.missingRequiredField("endpoint")
        }

        guard let privateKey = wireGuardValue(query, "privatekey") ?? wireGuardValue(query, "secretkey") else {
            throw VPNConfigurationParserError.missingRequiredField("privateKey")
        }
        guard let peerPublicKey = wireGuardValue(query, "publickey") ?? components.percentEncodedUser?.removingPercentEncoding?.nilIfBlank else {
            throw VPNConfigurationParserError.missingRequiredField("publicKey")
        }

        let addresses = splitWireGuardList(wireGuardValue(query, "address") ?? wireGuardValue(query, "addresses"))
        guard addresses.isEmpty == false else {
            throw VPNConfigurationParserError.missingRequiredField("address")
        }

        let remarks = components.percentEncodedFragment?
            .removingPercentEncoding?
            .nilIfBlank
        ?? wireGuardValue(query, "name")
        ?? "WireGuard \(endpoint.host)"

        let profile = VPNProfile(
            protocolType: .wireguard,
            host: endpoint.host,
            port: endpoint.port,
            security: .none,
            networkType: .tcp,
            wireGuardPeerPublicKey: peerPublicKey,
            wireGuardLocalAddresses: addresses,
            wireGuardAllowedIPs: splitWireGuardList(wireGuardValue(query, "allowedips")),
            wireGuardPersistentKeepAlive: try parseWireGuardInt(
                wireGuardValue(query, "persistentkeepalive") ?? wireGuardValue(query, "keepalive"),
                field: "persistentKeepalive",
                range: 0...Int.max
            ),
            wireGuardMTU: try parseWireGuardInt(
                wireGuardValue(query, "mtu"),
                field: "MTU",
                range: 576...9000
            ),
            wireGuardReserved: try parseWireGuardReserved(wireGuardValue(query, "reserved")),
            wireGuardDNSServers: splitWireGuardList(wireGuardValue(query, "dns")),
            remarks: remarks
        )

        return (
            profile,
            VPNProfileSecret(
                wireGuardPrivateKey: privateKey,
                wireGuardPreSharedKey: wireGuardValue(query, "presharedkey")
            )
        )
    }

    private func parseSecurity(_ value: String?) throws -> VPNTransportSecurity {
        guard let value = value?.nilIfBlank?.lowercased() else {
            return .none
        }
        guard let security = VPNTransportSecurity(rawValue: value) else {
            AppLogger.warning("Unsupported import security '\(value)'", category: .importConfig)
            throw VPNConfigurationParserError.unsupportedSecurity(value)
        }
        return security
    }

    private func parseNetworkType(_ value: String?) -> VPNNetworkType {
        switch value?.nilIfBlank?.lowercased() {
        case "ws", "websocket":
            .ws
        case "grpc":
            .grpc
        case "httpupgrade", "http_upgrade":
            .httpupgrade
        case "raw", "tcp":
            .tcp
        default:
            .tcp
        }
    }

    private func path(
        for networkType: VPNNetworkType,
        query: [String: String]
    ) -> String? {
        switch networkType {
        case .grpc:
            (query["servicename"] ?? query["path"])?.removingPercentEncoding
        case .tcp, .ws, .httpupgrade:
            query["path"]?.removingPercentEncoding
        }
    }

    private func transportHost(
        for networkType: VPNNetworkType,
        query: [String: String]
    ) -> String? {
        switch networkType {
        case .grpc:
            query["authority"] ?? query["host"]
        case .ws, .httpupgrade:
            query["host"]
        case .tcp:
            nil
        }
    }

    private func parseALPN(_ value: String?) -> [String]? {
        let values = value?
            .removingPercentEncoding?
            .split(separator: ",")
            .compactMap { String($0).nilIfBlank }

        return values?.isEmpty == false ? values : nil
    }

    private func looksLikeWireGuardConfiguration(_ value: String) -> Bool {
        value.localizedCaseInsensitiveContains("[Interface]")
        && value.localizedCaseInsensitiveContains("[Peer]")
    }

    private func looksLikeJSONConfiguration(_ value: String) -> Bool {
        value.hasPrefix("{")
    }

    private func singBoxProtocol(_ outbound: [String: Any]) -> VPNProtocolType? {
        switch singBoxString(outbound["type"])?.lowercased() {
        case "vless":
            .vless
        case "trojan":
            .trojan
        default:
            nil
        }
    }

    private func singBoxTransportPath(for networkType: VPNNetworkType, transport: [String: Any]?) -> String? {
        switch networkType {
        case .grpc:
            singBoxString(transport?["service_name"]) ?? singBoxString(transport?["path"])
        case .tcp, .ws, .httpupgrade:
            singBoxString(transport?["path"])
        }
    }

    private func singBoxTransportHost(for networkType: VPNNetworkType, transport: [String: Any]?) -> String? {
        switch networkType {
        case .grpc:
            singBoxString(transport?["authority"]) ?? singBoxHeader(transport?["headers"], name: "host")
        case .ws, .httpupgrade:
            singBoxHeader(transport?["headers"], name: "host") ?? singBoxString(transport?["host"])
        case .tcp:
            nil
        }
    }

    private func singBoxHeader(_ value: Any?, name: String) -> String? {
        guard let headers = value as? [String: Any] else {
            return nil
        }
        let lowercasedName = name.lowercased()
        guard let match = headers.first(where: { $0.key.lowercased() == lowercasedName })?.value else {
            return nil
        }
        return singBoxString(match)
    }

    private func singBoxUTLSFingerprint(_ tls: [String: Any]?) -> String? {
        guard let utls = tls?["utls"] as? [String: Any],
              singBoxBool(utls["enabled"]) != false else {
            return nil
        }
        return singBoxString(utls["fingerprint"])
    }

    private func singBoxStringList(_ value: Any?) -> [String]? {
        if let values = value as? [String] {
            let normalized = values.compactMap(\.nilIfBlank)
            return normalized.isEmpty ? nil : normalized
        }
        if let values = value as? [Any] {
            let normalized = values.compactMap(singBoxString)
            return normalized.isEmpty ? nil : normalized
        }
        return singBoxString(value).map { [$0] }
    }

    private func singBoxString(_ value: Any?) -> String? {
        switch value {
        case let value as String:
            value.nilIfBlank
        case let value as [String]:
            value.first?.nilIfBlank
        case let value as [Any]:
            value.compactMap(singBoxString).first
        default:
            nil
        }
    }

    private func singBoxInt(_ value: Any?) -> Int? {
        switch value {
        case let value as Int:
            value
        case let value as Double:
            Int(value)
        case let value as String:
            Int(value)
        default:
            nil
        }
    }

    private func singBoxBool(_ value: Any?) -> Bool? {
        switch value {
        case let value as Bool:
            value
        case let value as String:
            ["true", "1", "yes"].contains(value.lowercased())
        default:
            nil
        }
    }

    private func parseWireGuardSections(_ rawValue: String) -> [String: [[String: String]]] {
        var sections: [String: [[String: String]]] = [:]
        var currentName: String?
        var currentValues: [String: String] = [:]

        func commitCurrentSection() {
            guard let currentName else {
                return
            }
            sections[currentName, default: []].append(currentValues)
        }

        for rawLine in rawValue.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.isEmpty == false,
                  line.hasPrefix("#") == false,
                  line.hasPrefix(";") == false else {
                continue
            }

            if line.hasPrefix("[") && line.hasSuffix("]") {
                commitCurrentSection()
                currentName = wireGuardKey(String(line.dropFirst().dropLast()))
                currentValues = [:]
                continue
            }

            guard currentName != nil,
                  let separatorIndex = line.firstIndex(of: "=") else {
                continue
            }

            let key = wireGuardKey(String(line[..<separatorIndex]))
            let value = String(line[line.index(after: separatorIndex)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            currentValues[key] = value
        }

        commitCurrentSection()
        return sections
    }

    private func wireGuardValue(_ values: [String: String], _ key: String) -> String? {
        values[wireGuardKey(key)]?.nilIfBlank
    }

    private func wireGuardKey(_ value: String) -> String {
        value
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
            .lowercased()
    }

    private func splitWireGuardList(_ value: String?) -> [String] {
        let decodedValue = value?.removingPercentEncoding ?? value
        return decodedValue?
            .split(separator: ",")
            .compactMap { String($0).nilIfBlank } ?? []
    }

    private func parseWireGuardEndpoint(_ value: String) throws -> (host: String, port: Int) {
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let host: String
        let portString: String

        if trimmedValue.hasPrefix("[") {
            guard let closingBracket = trimmedValue.firstIndex(of: "]") else {
                throw VPNConfigurationParserError.invalidWireGuardValue("endpoint")
            }

            host = String(trimmedValue[trimmedValue.index(after: trimmedValue.startIndex)..<closingBracket])
            let remainder = trimmedValue[trimmedValue.index(after: closingBracket)...]
            guard remainder.hasPrefix(":") else {
                throw VPNConfigurationParserError.invalidWireGuardValue("endpoint")
            }
            portString = String(remainder.dropFirst())
        } else {
            guard let separatorIndex = trimmedValue.lastIndex(of: ":") else {
                throw VPNConfigurationParserError.invalidWireGuardValue("endpoint")
            }

            host = String(trimmedValue[..<separatorIndex])
            portString = String(trimmedValue[trimmedValue.index(after: separatorIndex)...])
        }

        guard let normalizedHost = host.nilIfBlank,
              let port = Int(portString),
              (1...65535).contains(port) else {
            throw VPNConfigurationParserError.invalidWireGuardValue("endpoint")
        }

        return (normalizedHost, port)
    }

    private func parseWireGuardInt(
        _ value: String?,
        field: String,
        range: ClosedRange<Int>
    ) throws -> Int? {
        guard let value = value?.nilIfBlank else {
            return nil
        }
        guard let intValue = Int(value), range.contains(intValue) else {
            throw VPNConfigurationParserError.invalidWireGuardValue(field)
        }
        return intValue
    }

    private func parseWireGuardReserved(_ value: String?) throws -> [Int]? {
        let values = splitWireGuardList(value)
        guard values.isEmpty == false else {
            return nil
        }

        let bytes = values.compactMap(Int.init)
        guard bytes.count == values.count,
              bytes.allSatisfy({ (0...255).contains($0) }) else {
            throw VPNConfigurationParserError.invalidWireGuardValue("reserved")
        }
        return bytes
    }
}

private struct VMessImportPayload: Decodable {
    var ps: String
    var add: String
    var port: String
    var id: String
    var net: String
    var host: String?
    var path: String?
    var tls: String
    var sni: String?

    enum CodingKeys: String, CodingKey {
        case ps
        case add
        case port
        case id
        case net
        case host
        case path
        case tls
        case sni
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ps = try container.decodeIfPresent(String.self, forKey: .ps) ?? ""
        add = try container.decodeIfPresent(String.self, forKey: .add) ?? ""
        port = try container.decodeIfPresent(String.self, forKey: .port) ?? ""
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? ""
        net = try container.decodeIfPresent(String.self, forKey: .net) ?? "tcp"
        host = try container.decodeIfPresent(String.self, forKey: .host)
        path = try container.decodeIfPresent(String.self, forKey: .path)
        tls = try container.decodeIfPresent(String.self, forKey: .tls) ?? "none"
        sni = try container.decodeIfPresent(String.self, forKey: .sni)
    }
}

private extension String {
    func base64Padded() -> String {
        var value = replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = value.count % 4
        if padding > 0 {
            value.append(String(repeating: "=", count: 4 - padding))
        }
        return value
    }
}
