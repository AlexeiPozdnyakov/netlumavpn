import Foundation
import NetworkExtension
import WidgetKit

/// Packet-tunnel provider for the **WireGuard-only** extension. Its process links wireguard-go (via
/// WireGuardKit) and NOT Xray/SwiftyXrayKit — keeping a single Go runtime per process. Proxy
/// protocols run in the separate `NetlumaVPNTunnelExtension` (Xray). See KNOWN_ISSUES #14.
///
/// The WireGuard adapter installs its own network settings (addresses / DNS / routes from the
/// config), so this provider does NOT call `setTunnelNetworkSettings`.
@objc(PacketTunnelProvider)
final class PacketTunnelProvider: NEPacketTunnelProvider {
    private let profileStorage = ProfileStorage()
    private let sessionStateStorage = SessionStateStorage()
    private var activeEngine: (any PacketTunnelEngine)?

    override func startTunnel(
        options: [String: NSObject]?,
        completionHandler: @escaping (Error?) -> Void
    ) {
        Task {
            do {
                AppLogger.info("WireGuard packet tunnel start requested", category: .tunnel)
                let resolvedProfile = try resolvedProfile(from: options)
                AppLogger.info("Resolved selected profile \(AppLogger.safeProfileLabel(resolvedProfile.profile))", category: .tunnel)

                guard resolvedProfile.profile.protocolType == .wireguard else {
                    // Only WireGuard belongs in this extension; the app routes other protocols to
                    // the Xray extension. Reaching here otherwise is a routing bug.
                    throw WireGuardTunnelEngineError.engineUnavailable
                }

                let engine = WireGuardTunnelEngineFactory.make(provider: self)
                self.activeEngine = engine
                try await engine.start(with: resolvedProfile)

                sessionStateStorage.markConnectionStarted()
                WidgetCenter.shared.reloadAllTimelines()
                AppLogger.info("WireGuard packet tunnel started for \(AppLogger.safeProfileLabel(resolvedProfile.profile))", category: .tunnel)
                completionHandler(nil)
            } catch {
                sessionStateStorage.clearConnectionStartedAt()
                WidgetCenter.shared.reloadAllTimelines()
                AppLogger.error(error, message: "WireGuard packet tunnel start failed", category: .tunnel)
                completionHandler(error)
            }
        }
    }

    override func stopTunnel(
        with reason: NEProviderStopReason,
        completionHandler: @escaping () -> Void
    ) {
        Task {
            AppLogger.info("WireGuard packet tunnel stop requested reason \(reason.rawValue)", category: .tunnel)
            await activeEngine?.stop()
            activeEngine = nil
            sessionStateStorage.clearConnectionStartedAt()
            WidgetCenter.shared.reloadAllTimelines()
            AppLogger.info("WireGuard packet tunnel stopped", category: .tunnel)
            completionHandler()
        }
    }

    private func resolvedProfile(from options: [String: NSObject]?) throws -> ResolvedVPNProfile {
        if let data = options?[AppConstants.TunnelOptions.startPayload] as? Data {
            AppLogger.info("Using tunnel start payload from options", category: .tunnel)
            return try JSONDecoder().decode(TunnelStartPayload.self, from: data).resolvedProfile
        }

        if let data = options?[AppConstants.TunnelOptions.startPayload] as? NSData {
            AppLogger.info("Using tunnel start payload from options", category: .tunnel)
            return try JSONDecoder().decode(TunnelStartPayload.self, from: data as Data).resolvedProfile
        }

        let selectedID = try selectedProfileID(from: options)
        AppLogger.info("Using profile storage fallback for \(AppLogger.safeProfileID(selectedID))", category: .tunnel)
        return try profileStorage.resolvedProfile(id: selectedID)
    }

    private func selectedProfileID(from options: [String: NSObject]?) throws -> UUID {
        if let optionValue = options?[AppConstants.AppGroupKeys.selectedProfileID] as? String,
           let id = UUID(uuidString: optionValue) {
            return id
        }

        if let optionValue = options?[AppConstants.AppGroupKeys.selectedProfileID] as? NSString,
           let id = UUID(uuidString: optionValue as String) {
            return id
        }

        if let tunnelProtocol = protocolConfiguration as? NETunnelProviderProtocol,
           let value = tunnelProtocol.providerConfiguration?[AppConstants.AppGroupKeys.selectedProfileID] as? String,
           let id = UUID(uuidString: value) {
            return id
        }

        if let id = profileStorage.selectedProfileID() {
            return id
        }

        throw ProfileStorageError.profileNotFound
    }
}
