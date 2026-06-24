import Foundation
import NetworkExtension

enum VPNManagerError: LocalizedError {
    case tunnelProtocolUnavailable
    case managerNotConfigured

    var errorDescription: String? {
        switch self {
        case .tunnelProtocolUnavailable:
            L10n.string("The packet tunnel protocol could not be configured.")
        case .managerNotConfigured:
            L10n.string("The VPN manager is not configured.")
        }
    }
}

@MainActor
protocol VPNManaging: AnyObject {
    func observeConnectionState(_ handler: @escaping @MainActor (VPNConnectionState) -> Void) -> NSObjectProtocol
    func currentConnectionState() async -> VPNConnectionState
    func connect(profile: VPNProfile) async throws -> VPNConnectionState
    func disconnect() async throws -> VPNConnectionState
}

@MainActor
final class VPNManager {
    private let profileStorage: ProfileStorage
    private let networkPreferencesStorage: NetworkPreferencesStorage

    init(
        profileStorage: ProfileStorage = ProfileStorage(),
        networkPreferencesStorage: NetworkPreferencesStorage = NetworkPreferencesStorage()
    ) {
        self.profileStorage = profileStorage
        self.networkPreferencesStorage = networkPreferencesStorage
    }

    func observeConnectionState(_ handler: @escaping @MainActor (VPNConnectionState) -> Void) -> NSObjectProtocol {
        NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor in
                guard let self else {
                    return
                }
                let connectionState: VPNConnectionState
                if let connection = notification.object as? NEVPNConnection {
                    connectionState = connection.netlumaVPNConnectionState
                    if connectionState.status == .disconnected {
                        connection.fetchLastDisconnectError { error in
                            if let error {
                                AppLogger.error(error, message: "VPN last disconnect error", category: .vpn)
                            }
                        }
                    }
                } else {
                    connectionState = await self.currentConnectionState()
                }
                AppLogger.info("VPN status changed to \(connectionState.status.rawValue)", category: .vpn)
                handler(connectionState)
            }
        }
    }

    func observeStatus(_ handler: @escaping @MainActor (VPNConnectionStatus) -> Void) -> NSObjectProtocol {
        observeConnectionState { connectionState in
            handler(connectionState.status)
        }
    }

    func currentConnectionState() async -> VPNConnectionState {
        do {
            let managers = try await loadAllManagers()
            // Either extension's manager may be the live one; report whichever isn't disconnected.
            let active = managers.first { $0.connection.status != .disconnected && $0.connection.status != .invalid }
            return active?.connection.netlumaVPNConnectionState ?? VPNConnectionState(status: .disconnected)
        } catch {
            AppLogger.warning("Could not load VPN status, treating as disconnected", category: .vpn)
            return VPNConnectionState(status: .disconnected)
        }
    }

    func currentStatus() async -> VPNConnectionStatus {
        await currentConnectionState().status
    }

    func connect(profile: VPNProfile) async throws -> VPNConnectionState {
        AppLogger.info("Connect requested for \(AppLogger.safeProfileLabel(profile))", category: .vpn)
        profileStorage.setSelectedProfileID(profile.id)
        let networkPreferences = networkPreferencesStorage.load()
        let resolvedProfile = try profileStorage.resolvedProfile(id: profile.id)
        let requestedAt = Date()
        let startPayloadData = try JSONEncoder().encode(
            TunnelStartPayload(resolvedProfile: resolvedProfile)
        )

        // WireGuard runs in its own extension; proxy protocols in the Xray extension.
        let targetBundleID = AppConstants.providerBundleIdentifier(for: profile.protocolType)
        let managers = try await loadAllManagers()

        // iOS allows only ONE active packet tunnel. Neutralize the OTHER extension's manager (stop it
        // and disable on-demand) so it can't fight or auto-reconnect against the tunnel we're starting.
        for other in managers where providerBundleIdentifier(of: other) != targetBundleID {
            try await deactivate(other)
        }

        let manager = managers.first { providerBundleIdentifier(of: $0) == targetBundleID } ?? NETunnelProviderManager()
        let tunnelProtocol = NETunnelProviderProtocol()
        tunnelProtocol.providerBundleIdentifier = targetBundleID
        tunnelProtocol.serverAddress = profile.displayEndpoint
        tunnelProtocol.providerConfiguration = [
            AppConstants.AppGroupKeys.selectedProfileID: profile.id.uuidString
        ]

        manager.localizedDescription = AppConstants.appName
        manager.protocolConfiguration = tunnelProtocol
        manager.isEnabled = true
        manager.isOnDemandEnabled = networkPreferences.tunnel.isOnDemandEnabled
        manager.onDemandRules = networkPreferences.tunnel.isOnDemandEnabled ? [NEOnDemandRuleConnect()] : []

        try await saveToPreferences(manager)
        try await loadFromPreferences(manager)

        let options: [String: NSObject] = [
            AppConstants.AppGroupKeys.selectedProfileID: profile.id.uuidString as NSString,
            AppConstants.TunnelOptions.startPayload: startPayloadData as NSData
        ]
        do {
            try manager.connection.startVPNTunnel(options: options)
            let state = manager.connection.netlumaVPNConnectionState
            let reportedStatus: VPNConnectionStatus = state.status == .disconnected ? .connecting : state.status
            AppLogger.info("startVPNTunnel accepted with status \(reportedStatus.rawValue)", category: .vpn)
            return VPNConnectionState(
                status: reportedStatus,
                connectedDate: state.connectedDate ?? requestedAt
            )
        } catch {
            AppLogger.error(error, message: "startVPNTunnel failed", category: .vpn)
            throw error
        }
    }

    func disconnect() async throws -> VPNConnectionState {
        AppLogger.info("Disconnect requested", category: .vpn)
        let managers = try await loadAllManagers()
        guard managers.isEmpty == false else {
            throw VPNManagerError.managerNotConfigured
        }
        // Stop whichever extension's tunnel is actually live (there is at most one).
        guard let manager = managers.first(where: { $0.connection.status != .disconnected && $0.connection.status != .invalid }) else {
            return VPNConnectionState(status: .disconnected)
        }
        manager.connection.stopVPNTunnel()
        AppLogger.info("stopVPNTunnel sent", category: .vpn)
        let state = manager.connection.netlumaVPNConnectionState
        let reportedStatus: VPNConnectionStatus = state.status == .connected ? .disconnecting : state.status
        return VPNConnectionState(status: reportedStatus, connectedDate: state.connectedDate)
    }

    private func providerBundleIdentifier(of manager: NETunnelProviderManager) -> String? {
        (manager.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier
    }

    /// Stops a manager belonging to the OTHER extension and disables its on-demand rules so iOS
    /// won't auto-reconnect it while a different protocol's tunnel is starting. (Both managers share
    /// `localizedDescription`, so they must be told apart strictly by `providerBundleIdentifier`.)
    private func deactivate(_ manager: NETunnelProviderManager) async throws {
        let status = manager.connection.status
        if status != .disconnected && status != .invalid {
            manager.connection.stopVPNTunnel()
            AppLogger.info("Stopped other tunnel \(providerBundleIdentifier(of: manager) ?? "?") before switching protocol", category: .vpn)
        }
        if manager.isOnDemandEnabled || manager.isEnabled {
            manager.isOnDemandEnabled = false
            manager.isEnabled = false
            try await saveToPreferences(manager)
        }
    }

    private func loadAllManagers() async throws -> [NETunnelProviderManager] {
        try await withCheckedThrowingContinuation { continuation in
            NETunnelProviderManager.loadAllFromPreferences { managers, error in
                if let error {
                    AppLogger.error(error, message: "loadAllFromPreferences failed", category: .vpn)
                    continuation.resume(throwing: error)
                } else {
                    let list = managers ?? []
                    AppLogger.info("Loaded \(list.count) VPN manager(s)", category: .vpn)
                    for manager in list {
                        let includeAll = manager.protocolConfiguration?.includeAllNetworks ?? false
                        let excludeLocal = manager.protocolConfiguration?.excludeLocalNetworks ?? false
                        AppLogger.info(
                            "VPN manager state isEnabled=\(manager.isEnabled) onDemand=\(manager.isOnDemandEnabled) includeAll=\(includeAll) excludeLocal=\(excludeLocal) status=\(manager.connection.status.rawValue)",
                            category: .vpn
                        )
                    }
                    continuation.resume(returning: list)
                }
            }
        }
    }

    private func saveToPreferences(_ manager: NETunnelProviderManager) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            manager.saveToPreferences { error in
                if let error {
                    AppLogger.error(error, message: "saveToPreferences failed", category: .vpn)
                    continuation.resume(throwing: error)
                } else {
                    AppLogger.info("VPN preferences saved", category: .vpn)
                    continuation.resume()
                }
            }
        }
    }

    private func loadFromPreferences(_ manager: NETunnelProviderManager) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            manager.loadFromPreferences { error in
                if let error {
                    AppLogger.error(error, message: "loadFromPreferences failed", category: .vpn)
                    continuation.resume(throwing: error)
                } else {
                    AppLogger.info("VPN preferences reloaded", category: .vpn)
                    continuation.resume()
                }
            }
        }
    }
}

extension VPNManager: VPNManaging {}

private extension NEVPNConnection {
    var netlumaVPNConnectionState: VPNConnectionState {
        VPNConnectionState(status: status.netlumaVPNStatus, connectedDate: connectedDate)
    }
}

private extension NEVPNStatus {
    var netlumaVPNStatus: VPNConnectionStatus {
        switch self {
        case .invalid, .disconnected:
            .disconnected
        case .connecting, .reasserting:
            .connecting
        case .connected:
            .connected
        case .disconnecting:
            .disconnecting
        @unknown default:
            .failed
        }
    }
}
