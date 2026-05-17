import Foundation

enum AppConstants {
    static let appName = "QuickVPN"
    static let loggingSubsystem = "com.alekseipozdiakov.QuickVPN"
    static let appGroupIdentifier = "group.com.alekseipozdiakov.QuickVPN"
    static let tunnelProviderBundleIdentifier = "com.alekseipozdiakov.QuickVPN.PacketTunnel"

    // Keep this aligned with the Apple Developer Team ID and keychain-access-groups entitlement.
    static let keychainAccessGroup = "6659MLRZ5F.com.alekseipozdiakov.QuickVPN.shared"

    enum AppGroupKeys {
        static let profiles = "profiles.v1"
        static let selectedProfileID = "selectedProfileID.v1"
        static let networkPreferences = "networkPreferences.v1"
        static let logs = "logs.v1"
        static let connectionSessionState = "connectionSessionState.v1"
        static let connectionDisplayState = "connectionDisplayState.v1"
        static let pendingWidgetAction = "pendingWidgetAction.v1"
    }

    enum TunnelOptions {
        static let startPayload = "startPayload.v1"
    }

    enum Keychain {
        static let service = "com.alekseipozdiakov.QuickVPN.profiles"
        static let globalServerDeviceIDAccount = "quickvpn-global-device-id.v1"
    }

    enum Backend {
        static let mobileAPIBaseURL = "https://vpn.netlumavpn.example"
        // Least-privilege mobile key: can list mobile servers and issue/reuse one profile per device.
        // Never use the admin API key in the app binary.
        static let mobileClientKey = ""
        static let mobileTLSCertificateSHA256Base64 = "toR9V8L9iruf0XRwOuYK6d8St0IB+KPMSOQc0e1y7Lw="
    }
}
