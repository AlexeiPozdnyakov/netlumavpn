import Foundation

/// Rebuilds a `wg-quick` configuration string from a stored WireGuard profile so it can
/// be handed to WireGuardKit's `TunnelConfiguration(fromWgQuickConfig:called:)`. This is
/// the native-WireGuard counterpart to `XrayConfigBuilder` (which emits Xray JSON) and is
/// used by the tunnel extension's `WireGuardTunnelEngine`.
///
/// Note: `wireGuardReserved` is intentionally **not** emitted — `Reserved` is a non-standard
/// (Xray/AmneziaWG) extension that stock `wg-quick`/WireGuardKit does not understand.
struct WireGuardQuickConfigBuilder {
    func makeQuickConfig(for resolvedProfile: ResolvedVPNProfile) throws -> String {
        let profile = resolvedProfile.profile
        let secret = resolvedProfile.secret

        guard let privateKey = secret.wireGuardPrivateKey?.nilIfBlank else {
            throw XrayConfigBuilderError.missingCredential(.wireguard)
        }
        guard let peerPublicKey = profile.wireGuardPeerPublicKey?.nilIfBlank else {
            throw XrayConfigBuilderError.missingWireGuardPeerPublicKey
        }
        guard let addresses = profile.wireGuardLocalAddresses?.compactMap(\.nilIfBlank),
              addresses.isEmpty == false else {
            throw XrayConfigBuilderError.missingWireGuardAddress
        }

        var lines: [String] = ["[Interface]"]
        lines.append("PrivateKey = \(privateKey)")
        lines.append("Address = \(addresses.joined(separator: ", "))")
        if let dnsServers = profile.wireGuardDNSServers?.compactMap(\.nilIfBlank),
           dnsServers.isEmpty == false {
            lines.append("DNS = \(dnsServers.joined(separator: ", "))")
        }
        if let mtu = profile.wireGuardMTU {
            lines.append("MTU = \(mtu)")
        }

        lines.append("")
        lines.append("[Peer]")
        lines.append("PublicKey = \(peerPublicKey)")
        if let preSharedKey = secret.wireGuardPreSharedKey?.nilIfBlank {
            lines.append("PresharedKey = \(preSharedKey)")
        }
        lines.append("Endpoint = \(endpoint(for: profile))")

        let allowedIPs = profile.wireGuardAllowedIPs?.compactMap(\.nilIfBlank)
        let resolvedAllowedIPs = (allowedIPs?.isEmpty == false) ? allowedIPs! : ["0.0.0.0/0", "::/0"]
        lines.append("AllowedIPs = \(resolvedAllowedIPs.joined(separator: ", "))")

        if let keepAlive = profile.wireGuardPersistentKeepAlive {
            lines.append("PersistentKeepalive = \(keepAlive)")
        }

        return lines.joined(separator: "\n")
    }

    private func endpoint(for profile: VPNProfile) -> String {
        let host = profile.host.contains(":") && !profile.host.hasPrefix("[")
            ? "[\(profile.host)]"
            : profile.host
        return "\(host):\(profile.port)"
    }
}
