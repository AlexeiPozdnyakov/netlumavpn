import SwiftUI

enum QuickVPNTab: String, CaseIterable, Identifiable {
    case home
    case servers
    case protocols
    case settings

    var id: String { rawValue }

    static var visibleTabs: [QuickVPNTab] {
        [.home, .settings]
    }

    var title: String {
        switch self {
        case .home:
            "Home"
        case .servers:
            "Servers"
        case .protocols:
            "Protocols"
        case .settings:
            "Settings"
        }
    }

    var iconName: String {
        switch self {
        case .home:
            "house"
        case .servers:
            "server.rack"
        case .protocols:
            "shippingbox"
        case .settings:
            "gearshape"
        }
    }
}
