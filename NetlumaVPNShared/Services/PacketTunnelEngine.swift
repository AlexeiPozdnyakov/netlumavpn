import Foundation

/// A startable/stoppable tunnel backend. Each packet-tunnel extension holds exactly one:
/// the Xray-based `XrayTunnelEngine` (proxy protocols) in `NetlumaVPNTunnelExtension`, or the
/// native WireGuard engine in `NetlumaVPNWireGuardExtension`.
///
/// It lives in shared code (not in either extension) so both can reference it **without**
/// importing the other extension's Go-based dependency — linking both Xray (Go) and
/// wireguard-go (Go) into one process puts two Go runtimes in it and crashes the extension.
/// See `docs/VPN_TUNNEL.md` and `KNOWN_ISSUES.md` #14.
protocol PacketTunnelEngine: AnyObject {
    func start(with resolvedProfile: ResolvedVPNProfile) async throws
    func stop() async
}
