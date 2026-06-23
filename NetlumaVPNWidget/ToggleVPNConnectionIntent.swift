import AppIntents
import WidgetKit

struct ToggleVPNConnectionIntent: AppIntent {
    static var title: LocalizedStringResource = "Toggle VPN"
    static var description = IntentDescription("Connects or disconnects the selected NetlumaVPN profile.")
    static var openAppWhenRun = false

    func perform() async throws -> some IntentResult {
        do {
            let status = try await WidgetVPNController().toggleConnection()
            AppLogger.info("Widget VPN toggle completed with \(status.rawValue)", category: .vpn)
        } catch {
            AppLogger.error(error, message: "Widget VPN toggle failed", category: .vpn)
        }

        WidgetCenter.shared.reloadAllTimelines()
        return .result()
    }
}

struct ConnectVPNConnectionIntent: AppIntent {
    static var title: LocalizedStringResource = "Connect VPN"
    static var description = IntentDescription("Connects the selected NetlumaVPN profile.")
    static var openAppWhenRun = false

    func perform() async throws -> some IntentResult {
        do {
            let status = try await WidgetVPNController().connectSelectedProfile()
            AppLogger.info("Widget VPN connect completed with \(status.rawValue)", category: .vpn)
        } catch {
            AppLogger.error(error, message: "Widget VPN connect failed", category: .vpn)
        }

        WidgetCenter.shared.reloadAllTimelines()
        return .result()
    }
}

struct DisconnectVPNConnectionIntent: AppIntent {
    static var title: LocalizedStringResource = "Disconnect VPN"
    static var description = IntentDescription("Disconnects the active NetlumaVPN tunnel.")
    static var openAppWhenRun = false

    func perform() async throws -> some IntentResult {
        do {
            let status = try await WidgetVPNController().disconnectConnection()
            AppLogger.info("Widget VPN disconnect completed with \(status.rawValue)", category: .vpn)
        } catch {
            AppLogger.error(error, message: "Widget VPN disconnect failed", category: .vpn)
        }

        WidgetCenter.shared.reloadAllTimelines()
        return .result()
    }
}
