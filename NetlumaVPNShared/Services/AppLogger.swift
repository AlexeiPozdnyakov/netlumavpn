import Foundation
import OSLog

enum AppLogger {
    static func info(_ message: String, category: AppLogCategory) {
        log(message, level: .info, category: category)
    }

    static func warning(_ message: String, category: AppLogCategory) {
        log(message, level: .warning, category: category)
    }

    static func error(_ message: String, category: AppLogCategory) {
        log(message, level: .error, category: category)
    }

    static func error(_ error: Error, message: String, category: AppLogCategory) {
        let nsError = error as NSError
        log(
            "\(message): \(nsError.domain)(\(nsError.code)) \(error.localizedDescription)",
            level: .error,
            category: category
        )
    }

    static func safeProfileLabel(_ profile: VPNProfile) -> String {
        "\(profile.protocolType.rawValue)#\(profile.id.uuidString.prefix(8))"
    }

    static func safeProfileID(_ id: UUID) -> String {
        "#\(id.uuidString.prefix(8))"
    }

    private static func log(
        _ message: String,
        level: AppLogLevel,
        category: AppLogCategory
    ) {
        let logger = Logger(
            subsystem: AppConstants.loggingSubsystem,
            category: category.rawValue
        )

        switch level {
        case .info:
            logger.info("\(message, privacy: .public)")
        case .warning:
            logger.warning("\(message, privacy: .public)")
        case .error:
            logger.error("\(message, privacy: .public)")
        }

        AppLogStore().append(
            AppLogEvent(level: level, category: category, message: message)
        )
    }
}
