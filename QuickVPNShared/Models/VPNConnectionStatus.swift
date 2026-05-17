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
            "Disconnected"
        case .connecting:
            "Connecting"
        case .connected:
            "Connected"
        case .disconnecting:
            "Disconnecting"
        case .failed:
            "Failed"
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
