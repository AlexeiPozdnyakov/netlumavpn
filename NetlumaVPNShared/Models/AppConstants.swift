import Foundation

enum AppConstants {
    static let appName = "NetlumaVPN"
    static let loggingSubsystem = "com.alekseipozdiakov.NetlumaVPN"
    static let appGroupIdentifier = "group.com.alekseipozdiakov.NetlumaVPN"
    static let tunnelProviderBundleIdentifier = "com.alekseipozdiakov.NetlumaVPN.PacketTunnel"
    // WireGuard runs in a SEPARATE packet-tunnel extension so its Go runtime (wireguard-go) never
    // shares the Xray (Go) process. (The "alekseipozdiakov" stem is intentionally misspelled — see
    // docs/IDENTIFIERS.md — do not "fix" it.)
    static let wireGuardTunnelProviderBundleIdentifier = "com.alekseipozdiakov.NetlumaVPN.WireGuard"

    /// The packet-tunnel extension that should run a given protocol: WireGuard → the dedicated WG
    /// extension; everything else → the Xray extension.
    static func providerBundleIdentifier(for protocolType: VPNProtocolType) -> String {
        protocolType == .wireguard ? wireGuardTunnelProviderBundleIdentifier : tunnelProviderBundleIdentifier
    }

    // Keep this aligned with the Apple Developer Team ID and keychain-access-groups entitlement.
    static let keychainAccessGroup = "6659MLRZ5F.com.alekseipozdiakov.NetlumaVPN.shared"

    enum AppGroupKeys {
        static let profiles = "profiles.v1"
        static let selectedProfileID = "selectedProfileID.v1"
        static let networkPreferences = "networkPreferences.v1"
        static let logs = "logs.v1"
        static let connectionSessionState = "connectionSessionState.v1"
        static let connectionDisplayState = "connectionDisplayState.v1"
    }

    enum TunnelOptions {
        static let startPayload = "startPayload.v1"
    }

    enum Keychain {
        static let service = "com.alekseipozdiakov.NetlumaVPN.profiles"
        static let globalServerDeviceIDAccount = "netlumavpn-global-device-id.v1"
    }

    enum Backend {
        private static let configuration = BackendConfiguration(
            data: Bundle.main.url(forResource: "Backend.local", withExtension: "plist")
                .flatMap { try? Data(contentsOf: $0) }
        )

        static let mobileAPIBaseURL = configuration.mobileAPIBaseURL
        // Only a least-privilege mobile key belongs in the app; never an admin key.
        static let mobileClientKey = configuration.mobileClientKey
        static let mobileTLSCertificateSHA256Base64 = configuration.mobileTLSCertificateSHA256Base64
    }
}
