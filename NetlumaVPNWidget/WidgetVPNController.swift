import Foundation
import NetworkExtension
import WidgetKit

enum WidgetVPNControllerError: LocalizedError {
    case profileNotFound

    var errorDescription: String? {
        switch self {
        case .profileNotFound:
            L10n.string("Add or select a VPN profile first.")
        }
    }
}

struct WidgetVPNController {
    private static let immediateDisplayStateWindow: TimeInterval = 5

    private let profileStorage: ProfileStorage
    private let networkPreferencesStorage: NetworkPreferencesStorage
    private let sessionStateStorage: SessionStateStorage
    private let displayStateStorage: ConnectionDisplayStateStorage

    init(
        profileStorage: ProfileStorage = ProfileStorage(),
        networkPreferencesStorage: NetworkPreferencesStorage = NetworkPreferencesStorage(),
        sessionStateStorage: SessionStateStorage = SessionStateStorage(),
        displayStateStorage: ConnectionDisplayStateStorage = ConnectionDisplayStateStorage()
    ) {
        self.profileStorage = profileStorage
        self.networkPreferencesStorage = networkPreferencesStorage
        self.sessionStateStorage = sessionStateStorage
        self.displayStateStorage = displayStateStorage
    }

    func currentStatus(prefersCachedDisplayState: Bool = true) async -> VPNConnectionStatus {
        let connectionState = await currentConnectionState(
            prefersCachedDisplayState: prefersCachedDisplayState
        )
        switch connectionState.status {
        case .connecting, .connected:
            sessionStateStorage.markConnectionStarted(
                at: connectionState.connectedDate ?? sessionStateStorage.connectionStartedAt() ?? Date()
            )
        case .disconnected, .failed:
            sessionStateStorage.clearConnectionStartedAt()
        case .disconnecting:
            break
        }
        return connectionState.status
    }

    func currentConnectionState(
        prefersCachedDisplayState: Bool = true
    ) async -> VPNConnectionState {
        let now = Date()
        let displayState = displayStateStorage.state(now: now)
        if prefersCachedDisplayState,
           let displayState,
           now.timeIntervalSince(displayState.updatedAt) <= Self.immediateDisplayStateWindow {
            return displayState.connectionState
        }

        do {
            let manager = try await loadExistingManager()
            let connectionState = manager?.connection.netlumaVPNWidgetConnectionState
                ?? VPNConnectionState(status: .disconnected)
            return resolvedConnectionState(
                connectionState,
                displayState: prefersCachedDisplayState ? displayState : nil
            )
        } catch {
            AppLogger.warning("Widget could not load VPN status", category: .vpn)
            if prefersCachedDisplayState, let displayState {
                return displayState.connectionState
            }
            return VPNConnectionState(status: .disconnected)
        }
    }

    @discardableResult
    func toggleConnection() async throws -> VPNConnectionStatus {
        let status = await currentStatus(prefersCachedDisplayState: false)

        do {
            switch status {
            case .connected, .connecting:
                return try await disconnect()
            case .disconnecting:
                return .disconnecting
            case .disconnected, .failed:
                let profile = try selectedProfile()
                return try await connect(profile: profile)
            }
        } catch {
            markActionFailed()
            throw error
        }
    }

    @discardableResult
    func connectSelectedProfile() async throws -> VPNConnectionStatus {
        do {
            let profile = try selectedProfile()
            return try await connect(profile: profile)
        } catch {
            markActionFailed()
            throw error
        }
    }

    @discardableResult
    func disconnectConnection() async throws -> VPNConnectionStatus {
        try await disconnect()
    }

    private func selectedProfile() throws -> VPNProfile {
        let profiles = profileStorage.loadProfiles()
        guard profiles.isEmpty == false else {
            throw WidgetVPNControllerError.profileNotFound
        }

        if let selectedProfileID = profileStorage.selectedProfileID(),
           let profile = profiles.first(where: { $0.id == selectedProfileID }) {
            return profile
        }

        guard let profile = profiles.first else {
            throw WidgetVPNControllerError.profileNotFound
        }
        profileStorage.setSelectedProfileID(profile.id)
        return profile
    }

    private func markActionFailed() {
        displayStateStorage.save(status: .failed)
        WidgetCenter.shared.reloadAllTimelines()
    }

    private func connect(profile: VPNProfile) async throws -> VPNConnectionStatus {
        AppLogger.info("Widget connect requested for \(AppLogger.safeProfileLabel(profile))", category: .vpn)
        profileStorage.setSelectedProfileID(profile.id)
        let requestedAt = Date()
        displayStateStorage.save(
            status: .connecting,
            connectionStartedAt: requestedAt,
            now: requestedAt
        )
        WidgetCenter.shared.reloadAllTimelines()

        do {
            let resolvedProfile = try profileStorage.resolvedProfile(id: profile.id)
            let startPayloadData = try JSONEncoder().encode(
                TunnelStartPayload(resolvedProfile: resolvedProfile)
            )

            let manager = try await preparedManager(for: profile)
            let currentStatus = manager.connection.status.netlumaVPNWidgetStatus
            if currentStatus == .connected || currentStatus == .connecting || currentStatus == .disconnecting {
                let startedAt = manager.connection.connectedDate
                    ?? sessionStateStorage.connectionStartedAt()
                    ?? requestedAt
                sessionStateStorage.markConnectionStarted(at: startedAt)
                displayStateStorage.save(
                    status: currentStatus,
                    connectionStartedAt: startedAt
                )
                WidgetCenter.shared.reloadAllTimelines()
                return currentStatus
            }

            let options: [String: NSObject] = [
                AppConstants.AppGroupKeys.selectedProfileID: profile.id.uuidString as NSString,
                AppConstants.TunnelOptions.startPayload: startPayloadData as NSData
            ]
            try manager.connection.startVPNTunnel(options: options)

            let state = manager.connection.netlumaVPNWidgetConnectionState
            let status = state.status == .disconnected ? .connecting : state.status
            let startedAt = state.connectedDate ?? requestedAt
            sessionStateStorage.markConnectionStarted(at: startedAt)
            displayStateStorage.save(
                status: status,
                connectionStartedAt: startedAt
            )
            WidgetCenter.shared.reloadAllTimelines()
            return status
        } catch {
            displayStateStorage.save(status: .failed)
            WidgetCenter.shared.reloadAllTimelines()
            throw error
        }
    }

    private func preparedManager(for profile: VPNProfile) async throws -> NETunnelProviderManager {
        let manager = try await loadExistingManager() ?? NETunnelProviderManager()
        let networkPreferences = networkPreferencesStorage.load()
        guard manager.needsWidgetConfigurationUpdate(
            profile: profile,
            networkPreferences: networkPreferences
        ) else {
            return manager
        }

        AppLogger.info("Widget configuring VPN manager for \(AppLogger.safeProfileLabel(profile))", category: .vpn)
        configure(manager, profile: profile, networkPreferences: networkPreferences)
        try await saveToPreferences(manager)
        try await loadFromPreferences(manager)
        return manager
    }

    private func configure(
        _ manager: NETunnelProviderManager,
        profile: VPNProfile,
        networkPreferences: NetworkPreferences
    ) {
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
    }

    private func disconnect() async throws -> VPNConnectionStatus {
        AppLogger.info("Widget disconnect requested", category: .vpn)
        displayStateStorage.save(
            status: .disconnecting,
            connectionStartedAt: sessionStateStorage.connectionStartedAt()
        )
        WidgetCenter.shared.reloadAllTimelines()

        let manager: NETunnelProviderManager?
        do {
            manager = try await loadExistingManager()
        } catch {
            displayStateStorage.save(status: .failed)
            WidgetCenter.shared.reloadAllTimelines()
            throw error
        }

        guard let manager else {
            sessionStateStorage.clearConnectionStartedAt()
            displayStateStorage.save(status: .disconnected)
            WidgetCenter.shared.reloadAllTimelines()
            return .disconnected
        }

        manager.connection.stopVPNTunnel()
        sessionStateStorage.clearConnectionStartedAt()
        let status = manager.connection.status.netlumaVPNWidgetStatus
        let reportedStatus: VPNConnectionStatus = status == .connected ? .disconnecting : status
        displayStateStorage.save(
            status: reportedStatus,
            connectionStartedAt: reportedStatus == .disconnecting ? manager.connection.connectedDate : nil
        )
        WidgetCenter.shared.reloadAllTimelines()
        return reportedStatus
    }

    private func resolvedConnectionState(
        _ connectionState: VPNConnectionState,
        displayState: ConnectionDisplayStateStorage.DisplayState?
    ) -> VPNConnectionState {
        guard let displayState else {
            return connectionState
        }

        switch connectionState.status {
        case .connected:
            if displayState.status == .disconnecting {
                return VPNConnectionState(
                    status: .disconnecting,
                    connectedDate: connectionState.connectedDate ?? displayState.connectionStartedAt
                )
            }
            displayStateStorage.clear()
            return connectionState
        case .connecting, .disconnecting:
            return VPNConnectionState(
                status: connectionState.status,
                connectedDate: connectionState.connectedDate ?? displayState.connectionStartedAt
            )
        case .disconnected:
            if displayState.status == .connecting {
                return displayState.connectionState
            }
            displayStateStorage.clear()
            return connectionState
        case .failed:
            displayStateStorage.clear()
            return connectionState
        }
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
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: managers ?? [])
                }
            }
        }
    }

    private func saveToPreferences(_ manager: NETunnelProviderManager) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            manager.saveToPreferences { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    private func loadFromPreferences(_ manager: NETunnelProviderManager) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            manager.loadFromPreferences { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }
}

private extension NETunnelProviderManager {
    func needsWidgetConfigurationUpdate(
        profile: VPNProfile,
        networkPreferences: NetworkPreferences
    ) -> Bool {
        guard let tunnelProtocol = protocolConfiguration as? NETunnelProviderProtocol else {
            return true
        }

        let selectedProfileID = tunnelProtocol.providerConfiguration?[AppConstants.AppGroupKeys.selectedProfileID] as? String
        let wantsOnDemand = networkPreferences.tunnel.isOnDemandEnabled

        if localizedDescription != AppConstants.appName {
            return true
        }
        if tunnelProtocol.providerBundleIdentifier != AppConstants.tunnelProviderBundleIdentifier {
            return true
        }
        if tunnelProtocol.serverAddress != profile.displayEndpoint {
            return true
        }
        if selectedProfileID != profile.id.uuidString {
            return true
        }
        if isEnabled == false || isOnDemandEnabled != wantsOnDemand {
            return true
        }
        if wantsOnDemand {
            return onDemandRules?.isEmpty != false
        }
        return onDemandRules?.isEmpty == false
    }
}

private extension ConnectionDisplayStateStorage.DisplayState {
    var connectionState: VPNConnectionState {
        VPNConnectionState(status: status, connectedDate: connectionStartedAt)
    }
}

private extension NEVPNConnection {
    var netlumaVPNWidgetConnectionState: VPNConnectionState {
        VPNConnectionState(status: status.netlumaVPNWidgetStatus, connectedDate: connectedDate)
    }
}

private extension NEVPNStatus {
    var netlumaVPNWidgetStatus: VPNConnectionStatus {
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
