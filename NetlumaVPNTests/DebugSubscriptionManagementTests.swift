import Foundation
import Testing

/// The Settings screen exposes a *Debug-only* shortcut to the system subscription-management
/// sheet (`manageSubscriptionsSheet`) so a Sandbox / StoreKit-testing tester can cancel or
/// renew a test subscription. These tests verify, by reading the source, that the shortcut
/// exists and — critically — that it is wrapped in `#if DEBUG` so the App Store (Release)
/// binary never ships a "cancel subscription" affordance to real users.
struct DebugSubscriptionManagementTests {
    private static var settingsViewSource: String {
        get throws {
            let url = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent() // NetlumaVPNTests
                .deletingLastPathComponent() // repo root
                .appendingPathComponent("NetlumaVPN")
                .appendingPathComponent("Features")
                .appendingPathComponent("Settings")
                .appendingPathComponent("SettingsView.swift")
            return try String(contentsOf: url, encoding: .utf8)
        }
    }

    /// Tokens that wire up the manage-subscriptions shortcut and must only be compiled in Debug.
    private static let debugOnlyTokens = [
        "manageSubscriptionsSheet",
        "isShowingManageSubscriptions",
        "debugSettings"
    ]

    @Test func settingsViewImportsStoreKitAndPresentsManageSubscriptionsSheet() throws {
        let source = try Self.settingsViewSource

        #expect(source.contains("import StoreKit"))
        #expect(source.contains(".manageSubscriptionsSheet(isPresented:"))
    }

    @Test func manageSubscriptionsShortcutIsCompiledOutOfReleaseBuilds() throws {
        let source = try Self.settingsViewSource
        let lines = source.components(separatedBy: .newlines)

        // Track active `#if` conditions so we know whether a line is inside a `#if DEBUG`
        // region (the file only uses `#if DEBUG`, but the walker handles #else/#elseif/#endif
        // generically so the test stays correct if more conditionals are added later).
        var conditionStack: [Bool] = []
        var gatedTokenHits = 0

        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            if line.hasPrefix("#if") {
                conditionStack.append(line == "#if DEBUG")
                continue
            }
            if line.hasPrefix("#elseif") || line.hasPrefix("#else") {
                if !conditionStack.isEmpty {
                    conditionStack[conditionStack.count - 1] = false
                }
                continue
            }
            if line.hasPrefix("#endif") {
                if !conditionStack.isEmpty {
                    conditionStack.removeLast()
                }
                continue
            }

            let isInsideDebug = conditionStack.contains(true)
            for token in Self.debugOnlyTokens where rawLine.contains(token) {
                gatedTokenHits += 1
                #expect(isInsideDebug, "`\(token)` must live inside a #if DEBUG block in SettingsView.swift")
            }
        }

        // Guard against the walker passing vacuously if the affordance is ever removed/renamed.
        #expect(gatedTokenHits >= Self.debugOnlyTokens.count)
        #expect(conditionStack.isEmpty, "Unbalanced #if/#endif in SettingsView.swift")
    }
}
