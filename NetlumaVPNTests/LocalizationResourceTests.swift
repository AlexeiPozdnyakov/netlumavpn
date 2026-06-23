import Foundation
import Testing

@Suite("Localization resources")
struct LocalizationResourceTests {
    @Test("App bundle includes English and Russian localizations")
    func appBundleIncludesSupportedLocalizations() {
        let localizations = Set(Bundle.main.localizations)

        #expect(localizations.contains("en"))
        #expect(localizations.contains("ru"))
    }

    @Test("Important user-facing strings are localized")
    func importantUserFacingStringsAreLocalized() throws {
        #expect(try localized("Settings", locale: "en") == "Settings")
        #expect(try localized("Settings", locale: "ru") == "Настройки")

        #expect(try localized("Add or select a VPN profile first.", locale: "en") == "Add or select a VPN profile first.")
        #expect(try localized("Add or select a VPN profile first.", locale: "ru") == "Добавьте или выберите профиль VPN.")

        #expect(try localized("Terms of Use", locale: "en") == "Terms of Use")
        #expect(try localized("Terms of Use", locale: "ru") == "Условия использования")
    }

    private func localized(_ key: String, locale: String) throws -> String {
        let bundle = try #require(Bundle.main.path(forResource: locale, ofType: "lproj").flatMap(Bundle.init(path:)))
        return NSLocalizedString(key, bundle: bundle, comment: "")
    }
}
