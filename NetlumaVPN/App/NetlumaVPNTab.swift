import SwiftUI

enum NetlumaVPNTab: String, CaseIterable, Identifiable {
    case home
    case settings

    var id: String { rawValue }

    static var visibleTabs: [NetlumaVPNTab] {
        allCases
    }

    var title: String {
        switch self {
        case .home:
            L10n.string("Home")
        case .settings:
            L10n.string("Settings")
        }
    }

    var iconName: String {
        switch self {
        case .home:
            "house"
        case .settings:
            "gearshape"
        }
    }
}
