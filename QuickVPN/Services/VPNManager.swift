import Foundation
import NetworkExtension

enum VPNManagerError: LocalizedError {
    case tunnelProtocolUnavailable
    case managerNotConfigured

    var errorDescription: String? {
        switch self {
        case .tunnelProtocolUnavailable:
            "The packet tunnel protocol could not be configured."
        case .managerNotConfigured:
            "The VPN manager is not configured."
        }
    }
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
                    connectionState = connection.quickVPNConnectionState
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
            let manager = try await loadExistingManager()
            return manager?.connection.quickVPNConnectionState ?? VPNConnectionState(status: .disconnected)
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

        let manager = try await loadOrCreateManager()
        let tunnelProtocol = NETunnelProviderProtocol()
        tunnelProtocol.providerBundleIdentifier = AppConstants.tunnelProviderBundleIdentifier
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
            let state = manager.connection.quickVPNConnectionState
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
        guard let manager = try await loadExistingManager() else {
            throw VPNManagerError.managerNotConfigured
        }
        manager.connection.stopVPNTunnel()
        AppLogger.info("stopVPNTunnel sent", category: .vpn)
        let state = manager.connection.quickVPNConnectionState
        let reportedStatus: VPNConnectionStatus = state.status == .connected ? .disconnecting : state.status
        return VPNConnectionState(status: reportedStatus, connectedDate: state.connectedDate)
    }

    private func loadOrCreateManager() async throws -> NETunnelProviderManager {
        if let existing = try await loadExistingManager() {
            return existing
        }
        return NETunnelProviderManager()
    }

    private func loadExistingManager() async throws -> NETunnelProviderManager? {
        let managers = try await loadAllManagers()
        return managers.first { manager in
            guard let tunnelProtocol = manager.protocolConfiguration as? NETunnelProviderProtocol else {
                return false
            }
            return tunnelProtocol.providerBundleIdentifier == AppConstants.tunnelProviderBundleIdentifier
                || manager.localizedDescription == AppConstants.appName
        }
    }

    private func loadAllManagers() async throws -> [NETunnelProviderManager] {
        try await withCheckedThrowingContinuation { continuation in
            NETunnelProviderManager.loadAllFromPreferences { managers, error in
                if let error {
                    AppLogger.error(error, message: "loadAllFromPreferences failed", category: .vpn)
                    continuation.resume(throwing: error)
                } else {
                    AppLogger.info("Loaded \(managers?.count ?? 0) VPN manager(s)", category: .vpn)
                    continuation.resume(returning: managers ?? [])
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

private extension NEVPNConnection {
    var quickVPNConnectionState: VPNConnectionState {
        VPNConnectionState(status: status.quickVPNStatus, connectedDate: connectedDate)
    }
}

private extension NEVPNStatus {
    var quickVPNStatus: VPNConnectionStatus {
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
