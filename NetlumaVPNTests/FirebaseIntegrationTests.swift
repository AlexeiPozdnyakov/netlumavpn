import Foundation
import Testing

struct FirebaseIntegrationTests {
    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    @Test func projectSpecLinksFirebaseAnalyticsCrashlyticsAndDSYMUpload() throws {
        let projectSpec = try String(
            contentsOf: Self.repoRoot.appendingPathComponent("project.yml"),
            encoding: .utf8
        )

        #expect(projectSpec.contains("https://github.com/firebase/firebase-ios-sdk.git"))
        #expect(projectSpec.contains("product: FirebaseAnalytics"))
        #expect(projectSpec.contains("product: FirebaseCrashlytics"))
        #expect(projectSpec.contains("firebase-ios-sdk/Crashlytics/run"))
        #expect(projectSpec.contains("GoogleService-Info.plist"))
    }

    @Test func appInitializesFirebaseThroughDelegateWithSwizzlingDisabledForSwiftUI() throws {
        let appSource = try String(
            contentsOf: Self.repoRoot.appendingPathComponent("NetlumaVPN/App/NetlumaVPNApp.swift"),
            encoding: .utf8
        )
        let delegateSource = try String(
            contentsOf: Self.repoRoot.appendingPathComponent("NetlumaVPN/App/AppDelegate.swift"),
            encoding: .utf8
        )
        let appInfoPlist = try NSDictionary(
            contentsOf: Self.repoRoot.appendingPathComponent("NetlumaVPN/Info.plist"),
            error: ()
        )

        #expect(appSource.contains("@UIApplicationDelegateAdaptor(AppDelegate.self)"))
        #expect(delegateSource.contains("FirebaseApp.configure()"))
        #expect(appInfoPlist["FirebaseAppDelegateProxyEnabled"] as? Bool == false)
    }

    @Test func storeKitPurchasesLogVerifiedTransactionsToFirebaseAnalytics() throws {
        let source = try String(
            contentsOf: Self.repoRoot.appendingPathComponent("NetlumaVPN/Services/PremiumSubscriptionService.swift"),
            encoding: .utf8
        )

        let transactionLoggingRange = try #require(source.range(of: "purchaseAnalyticsReporter.logPremiumPurchase(transaction: transaction)"))
        let finishRange = try #require(source.range(of: "await transaction.finish()"))

        #expect(transactionLoggingRange.lowerBound < finishRange.lowerBound)
    }
}
