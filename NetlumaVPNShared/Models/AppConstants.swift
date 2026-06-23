import Foundation

enum AppConstants {
    static let appName = "NetlumaVPN"
    static let loggingSubsystem = "com.alekseipozdiakov.NetlumaVPN"
    static let appGroupIdentifier = "group.com.alekseipozdiakov.NetlumaVPN"
    static let tunnelProviderBundleIdentifier = "com.alekseipozdiakov.NetlumaVPN.PacketTunnel"

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
        static let mobileAPIBaseURL = "https://netlumavpn.example"
        // Least-privilege mobile key: can list mobile servers and issue/reuse one profile per device.
        // Never use the admin API key in the app binary.
        static let mobileClientKey = ""
        static let mobileTLSCertificateSHA256Base64 = ""
    }
}
