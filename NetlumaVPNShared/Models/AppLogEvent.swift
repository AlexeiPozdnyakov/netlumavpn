import Foundation

enum AppLogLevel: String, CaseIterable, Codable, Identifiable {
    case info
    case warning
    case error

    var id: String { rawValue }

    var title: String {
        switch self {
        case .info:
            L10n.string("Info")
        case .warning:
            L10n.string("Warning")
        case .error:
            L10n.string("Error")
        }
    }
}

enum AppLogCategory: String, CaseIterable, Codable, Identifiable {
    case app
    case vpn
    case tunnel
    case xray
    case storage
    case importConfig

    var id: String { rawValue }
}

struct AppLogEvent: Identifiable, Codable, Equatable {
    var id: UUID
    var date: Date
    var level: AppLogLevel
    var category: AppLogCategory
    var message: String

    init(
        id: UUID = UUID(),
        date: Date = Date(),
        level: AppLogLevel,
        category: AppLogCategory,
        message: String
    ) {
        self.id = id
        self.date = date
        self.level = level
        self.category = category
        self.message = message
    }
}
