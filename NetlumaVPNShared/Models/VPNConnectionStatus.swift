import Foundation

enum VPNConnectionStatus: String, CaseIterable, Codable, Equatable, Identifiable {
    case disconnected
    case connecting
    case connected
    case disconnecting
    case failed

    var id: String { rawValue }

    var title: String {
        switch self {
        case .disconnected:
            L10n.string("Disconnected")
        case .connecting:
            L10n.string("Connecting")
        case .connected:
            L10n.string("Connected")
        case .disconnecting:
            L10n.string("Disconnecting")
        case .failed:
            L10n.string("Failed")
        }
    }
}

struct VPNConnectionState: Equatable {
    var status: VPNConnectionStatus
    var connectedDate: Date?

    init(status: VPNConnectionStatus, connectedDate: Date? = nil) {
        self.status = status
        self.connectedDate = connectedDate
    }
}
