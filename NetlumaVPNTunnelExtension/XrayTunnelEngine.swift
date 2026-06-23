import Foundation
import NetworkExtension

#if canImport(SwiftyXrayKit)
import SwiftyXrayKit
#endif

enum XrayTunnelEngineError: LocalizedError {
    case invalidGeneratedConfig
    case engineUnavailable
    case configStringEncodingFailed

    var errorDescription: String? {
        switch self {
        case .invalidGeneratedConfig:
            L10n.string("The generated Xray configuration is invalid.")
        case .engineUnavailable:
            L10n.string("The real Xray engine is not linked into this build.")
        case .configStringEncodingFailed:
            L10n.string("The generated Xray configuration could not be converted to text.")
        }
    }
}

protocol XrayTunnelEngine: AnyObject {
    var routesDefaultTraffic: Bool { get }

    func start(with resolvedProfile: ResolvedVPNProfile) async throws
    func stop() async
}

enum XrayTunnelEngineFactory {
    static func make(packetFlow: NEPacketTunnelFlow) -> XrayTunnelEngine {
        #if canImport(SwiftyXrayKit)
        AppLogger.info("Using SwiftyXrayKit tunnel engine", category: .xray)
        return SwiftyXrayTunnelEngine(packetFlow: packetFlow)
        #else
        AppLogger.warning("SwiftyXrayKit is not linked; falling back to mock tunnel engine", category: .xray)
        return MockXrayTunnelEngine()
        #endif
    }
}

#if canImport(SwiftyXrayKit)
final class SwiftyXrayTunnelEngine: XrayTunnelEngine {
    let routesDefaultTraffic = true

    private let packetFlow: NEPacketTunnelFlow
    private let configBuilder: XrayConfigBuilder
    private var xrayTunnel: XRayTunnel?

    init(
        packetFlow: NEPacketTunnelFlow,
        configBuilder: XrayConfigBuilder = XrayConfigBuilder()
    ) {
        self.packetFlow = packetFlow
        self.configBuilder = configBuilder
    }

    func start(with resolvedProfile: ResolvedVPNProfile) async throws {
        AppLogger.info("Real Xray engine start requested for \(AppLogger.safeProfileLabel(resolvedProfile.profile))", category: .xray)

        let configData = try configBuilder.buildConfigData(for: resolvedProfile)
        guard let config = String(data: configData, encoding: .utf8) else {
            throw XrayTunnelEngineError.configStringEncodingFailed
        }

        let runtimeDirectory = try prepareRuntimeDirectory()
        let finalConfigPath = runtimeDirectory.appendingPathComponent("config_final.json")

        let tunnel = XRayTunnel(packetFlow: packetFlow)
        xrayTunnel = tunnel
        try await tunnel.run(
            dataDir: runtimeDirectory,
            config: .json(config),
            finalConfigPath: finalConfigPath
        )

        AppLogger.info("Real Xray engine started", category: .xray)
    }

    func stop() async {
        await xrayTunnel?.stop()
        xrayTunnel = nil
        AppLogger.info("Real Xray engine stopped", category: .xray)
    }

    private func prepareRuntimeDirectory() throws -> URL {
        let directory = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: AppConstants.appGroupIdentifier)?
            .appendingPathComponent("XrayRuntime", isDirectory: true)
        ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("XrayRuntime", isDirectory: true)

        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        return directory
    }
}
#endif

final class MockXrayTunnelEngine: XrayTunnelEngine {
    let routesDefaultTraffic = false

    private let configBuilder: XrayConfigBuilder
    private var generatedConfigData: Data?
    private var isRunning = false

    init(configBuilder: XrayConfigBuilder = XrayConfigBuilder()) {
        self.configBuilder = configBuilder
    }

    func start(with resolvedProfile: ResolvedVPNProfile) async throws {
        AppLogger.info("Mock Xray engine start requested for \(AppLogger.safeProfileLabel(resolvedProfile.profile))", category: .xray)
        let configData = try configBuilder.buildConfigData(for: resolvedProfile)
        guard !configData.isEmpty else {
            AppLogger.error("Generated Xray config is empty", category: .xray)
            throw XrayTunnelEngineError.invalidGeneratedConfig
        }

        _ = try JSONSerialization.jsonObject(with: configData)

        // This mock intentionally does not open sockets or process packets.
        // Replace this class with a bridge to a vetted Xray-core iOS build and a tun adapter.
        generatedConfigData = configData
        isRunning = true
        AppLogger.warning("Mock Xray engine is running without default-route capture; real VPN traffic requires Xray-core plus a TUN adapter", category: .xray)
    }

    func stop() async {
        generatedConfigData = nil
        isRunning = false
        AppLogger.info("Mock Xray engine stopped", category: .xray)
    }
}
