import Foundation
import NetworkExtension

#if canImport(WireGuardKit)
import WireGuardKit
#endif

enum WireGuardTunnelEngineError: LocalizedError {
    case engineUnavailable

    var errorDescription: String? {
        switch self {
        case .engineUnavailable:
            L10n.string("The WireGuard engine is not linked into this build.")
        }
    }
}

/// ⚠️ DO NOT link WireGuardKit/wireguard-go into this extension. It already statically links
/// **Xray (Go)** via SwiftyXrayKit, and adding **wireguard-go (Go)** puts *two Go runtimes* in one
/// process — they conflict and the extension crashes at launch with `NEVPNConnectionError.pluginFailed`
/// for **every** protocol (VLESS/Trojan included), not just WireGuard. Verified 2026-06-24, then
/// reverted. The viable path for native WireGuard is a **single** Go engine that handles all protocols
/// (e.g. sing-box, which the backend already uses) instead of Xray. Until then `canImport(WireGuardKit)`
/// is false and this returns the clear-error engine below. See docs/VPN_TUNNEL.md + KNOWN_ISSUES.md #14.
enum WireGuardTunnelEngineFactory {
    static func make(provider: NEPacketTunnelProvider) -> any PacketTunnelEngine {
        #if canImport(WireGuardKit)
        AppLogger.info("Using native WireGuard tunnel engine", category: .tunnel)
        return WireGuardTunnelEngine(provider: provider)
        #else
        AppLogger.warning("WireGuardKit is not linked; WireGuard profiles cannot start", category: .tunnel)
        return UnavailableWireGuardTunnelEngine()
        #endif
    }
}

#if canImport(WireGuardKit)
/// Runs a WireGuard profile through Apple's native userspace WireGuard (wireguard-go via
/// WireGuardKit). Unlike the Xray path, the `WireGuardAdapter` builds and installs the
/// `NEPacketTunnelNetworkSettings` itself (addresses / DNS / routes from the config), so the
/// provider must **not** call `setTunnelNetworkSettings` for WireGuard.
///
/// This is the fix for the "connects then dies with NEVPNConnectionError 12 (pluginFailed)"
/// crash: routing WireGuard through Xray + tun2socks ran two userspace netstacks and blew the
/// packet-tunnel memory limit. A single native stack stays within budget.
final class WireGuardTunnelEngine: PacketTunnelEngine {
    private let adapter: WireGuardAdapter

    init(provider: NEPacketTunnelProvider) {
        self.adapter = WireGuardAdapter(with: provider) { level, message in
            // wireguard-go diagnostics. Does not contain keys; endpoint host may appear, which
            // is consistent with how the rest of the app logs hosts.
            switch level {
            case .verbose:
                AppLogger.info("WireGuard backend: \(message)", category: .tunnel)
            case .error:
                AppLogger.error("WireGuard backend: \(message)", category: .tunnel)
            }
        }
    }

    func start(with resolvedProfile: ResolvedVPNProfile) async throws {
        AppLogger.info("Native WireGuard engine start requested for \(AppLogger.safeProfileLabel(resolvedProfile.profile))", category: .tunnel)

        let tunnelConfiguration = try Self.makeTunnelConfiguration(from: resolvedProfile)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            adapter.start(tunnelConfiguration: tunnelConfiguration) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }

        AppLogger.info("Native WireGuard engine started", category: .tunnel)
    }

    /// Builds a WireGuardKit `TunnelConfiguration` from the stored profile/secret using only the
    /// library's public model types. (The `wg-quick` string parser lives in the app target of
    /// wireguard-apple, not the `WireGuardKit` library, so it isn't available to import.)
    private static func makeTunnelConfiguration(from resolvedProfile: ResolvedVPNProfile) throws -> TunnelConfiguration {
        let profile = resolvedProfile.profile
        let secret = resolvedProfile.secret

        guard let privateKeyString = secret.wireGuardPrivateKey?.nilIfBlank,
              let privateKey = PrivateKey(base64Key: privateKeyString) else {
            throw XrayConfigBuilderError.missingCredential(.wireguard)
        }
        guard let peerPublicKeyString = profile.wireGuardPeerPublicKey?.nilIfBlank,
              let peerPublicKey = PublicKey(base64Key: peerPublicKeyString) else {
            throw XrayConfigBuilderError.missingWireGuardPeerPublicKey
        }

        var interface = InterfaceConfiguration(privateKey: privateKey)
        interface.addresses = (profile.wireGuardLocalAddresses ?? []).compactMap(IPAddressRange.init(from:))
        guard interface.addresses.isEmpty == false else {
            throw XrayConfigBuilderError.missingWireGuardAddress
        }
        interface.dns = (profile.wireGuardDNSServers ?? []).compactMap(DNSServer.init(from:))
        if let mtu = profile.wireGuardMTU {
            interface.mtu = UInt16(clamping: mtu)
        }

        var peer = PeerConfiguration(publicKey: peerPublicKey)
        if let preSharedKeyString = secret.wireGuardPreSharedKey?.nilIfBlank {
            peer.preSharedKey = PreSharedKey(base64Key: preSharedKeyString)
        }
        peer.endpoint = Endpoint(from: Self.endpointString(for: profile))
        let allowedIPStrings = (profile.wireGuardAllowedIPs?.isEmpty == false)
            ? profile.wireGuardAllowedIPs!
            : ["0.0.0.0/0", "::/0"]
        peer.allowedIPs = allowedIPStrings.compactMap(IPAddressRange.init(from:))
        if let keepAlive = profile.wireGuardPersistentKeepAlive {
            peer.persistentKeepAlive = UInt16(clamping: keepAlive)
        }

        return TunnelConfiguration(name: profile.remarks, interface: interface, peers: [peer])
    }

    private static func endpointString(for profile: VPNProfile) -> String {
        let host = profile.host.contains(":") && !profile.host.hasPrefix("[")
            ? "[\(profile.host)]"
            : profile.host
        return "\(host):\(profile.port)"
    }

    func stop() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            adapter.stop { _ in
                continuation.resume()
            }
        }
        AppLogger.info("Native WireGuard engine stopped", category: .tunnel)
    }
}
#endif

/// Fallback used when WireGuardKit is not linked. Fails fast with a clear message instead of
/// silently routing nothing (or falling back to the crashing Xray path).
final class UnavailableWireGuardTunnelEngine: PacketTunnelEngine {
    func start(with resolvedProfile: ResolvedVPNProfile) async throws {
        throw WireGuardTunnelEngineError.engineUnavailable
    }

    func stop() async {}
}
