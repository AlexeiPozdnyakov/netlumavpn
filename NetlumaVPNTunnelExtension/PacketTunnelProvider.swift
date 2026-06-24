import Foundation
import NetworkExtension
import WidgetKit

@objc(PacketTunnelProvider)
final class PacketTunnelProvider: NEPacketTunnelProvider {
    private let profileStorage = ProfileStorage()
    private let networkPreferencesStorage = NetworkPreferencesStorage()
    private let sessionStateStorage = SessionStateStorage()
    private var activeEngine: (any PacketTunnelEngine)?

    override func startTunnel(
        options: [String: NSObject]?,
        completionHandler: @escaping (Error?) -> Void
    ) {
        Task {
            do {
                AppLogger.info("Packet tunnel start requested", category: .tunnel)
                let resolvedProfile = try resolvedProfile(from: options)
                AppLogger.info("Resolved selected profile \(AppLogger.safeProfileLabel(resolvedProfile.profile))", category: .tunnel)

                if resolvedProfile.profile.protocolType == .wireguard {
                    // Native WireGuard (WireGuardKit) builds and installs its own network
                    // settings from the config, so we do NOT call setTunnelNetworkSettings here.
                    let engine = WireGuardTunnelEngineFactory.make(provider: self)
                    self.activeEngine = engine
                    try await engine.start(with: resolvedProfile)
                    AppLogger.info("Tunnel network settings applied by WireGuard adapter", category: .tunnel)
                } else {
                    let engine = XrayTunnelEngineFactory.make(packetFlow: packetFlow)
                    let networkPreferences = networkPreferencesStorage.load()
                    AppLogger.info("Tunnel engine default-route mode \(engine.routesDefaultTraffic ? "enabled" : "disabled")", category: .tunnel)

                    let networkSettings = TunnelNetworkSettingsBuilder().makeSettings(
                        routesDefaultTraffic: engine.routesDefaultTraffic,
                        preferences: networkPreferences
                    )
                    try await setTunnelNetworkSettings(networkSettings)
                    AppLogger.info("Tunnel network settings applied", category: .tunnel)

                    self.activeEngine = engine
                    try await engine.start(with: resolvedProfile)
                }
                sessionStateStorage.markConnectionStarted()
                WidgetCenter.shared.reloadAllTimelines()

                AppLogger.info("Packet tunnel started for \(AppLogger.safeProfileLabel(resolvedProfile.profile))", category: .tunnel)
                completionHandler(nil)
            } catch {
                sessionStateStorage.clearConnectionStartedAt()
                WidgetCenter.shared.reloadAllTimelines()
                AppLogger.error(error, message: "Packet tunnel start failed", category: .tunnel)
                completionHandler(error)
            }
        }
    }

    override func stopTunnel(
        with reason: NEProviderStopReason,
        completionHandler: @escaping () -> Void
    ) {
        Task {
            AppLogger.info("Packet tunnel stop requested reason \(reason.rawValue)", category: .tunnel)
            await activeEngine?.stop()
            activeEngine = nil
            sessionStateStorage.clearConnectionStartedAt()
            WidgetCenter.shared.reloadAllTimelines()
            AppLogger.info("Packet tunnel stopped", category: .tunnel)
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

    private func setTunnelNetworkSettings(_ settings: NEPacketTunnelNetworkSettings) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            setTunnelNetworkSettings(settings) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

}
