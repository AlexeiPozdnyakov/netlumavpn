import Foundation
import Testing
@testable import NetlumaVPN

struct PremiumSubscriptionTests {
    private static var subscriptionsStoreKitURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // NetlumaVPNTests
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("NetlumaVPN")
            .appendingPathComponent("Subscriptions.storekit")
    }

    @Test func debugSchemeInjectsSubscriptionsStoreKitWithPremiumProducts() throws {
        let projectSpecURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("project.yml")

        let storeKitContents = try String(contentsOf: Self.subscriptionsStoreKitURL, encoding: .utf8)
        let projectSpec = try String(contentsOf: projectSpecURL, encoding: .utf8)

        for kind in PremiumProductKind.allCases {
            #expect(storeKitContents.contains(kind.productID))
        }
        // The Debug Run scheme must inject the local StoreKit configuration, otherwise a
        // development build queries the live App Store (no products) and the paywall is empty.
        #expect(projectSpec.contains("storeKitConfiguration: NetlumaVPN/Subscriptions.storekit"))
    }

    /// All three premium products must live in one subscription group, each pointing back
    /// at that group's id — otherwise the paywall cannot resolve a consistent catalog.
    @Test func storeKitConfigurationContainsAllPremiumProductsInOneSubscriptionGroup() throws {
        let data = try Data(contentsOf: Self.subscriptionsStoreKitURL)
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        let groups = try #require(root["subscriptionGroups"] as? [[String: Any]])
        let group = try #require(groups.first)
        let groupID = try #require(group["id"] as? String)
        let subscriptions = try #require(group["subscriptions"] as? [[String: Any]])

        let productIDs = subscriptions.compactMap { $0["productID"] as? String }
        #expect(Set(productIDs) == Set(PremiumProductKind.allCases.map(\.productID)))

        for subscription in subscriptions {
            #expect(subscription["subscriptionGroupID"] as? String == groupID)
            #expect(subscription["type"] as? String == "RecurringSubscription")
        }
    }

    @Test func premiumCatalogUsesAppStoreConnectProductIDsInPaywallOrder() {
        #expect(PremiumProductKind.allCases.map(\.productID) == [
            "com.alekseipozdiakov.NetlumaVPN.premium.weekly",
            "com.alekseipozdiakov.NetlumaVPN.premium.monthly",
            "com.alekseipozdiakov.NetlumaVPN.premium.annual"
        ])
    }

    @Test func emptyStoreKitCatalogHasActionableErrorMessage() {
        #expect(PremiumSubscriptionError.productCatalogEmpty.localizedDescription.contains("No App Store subscriptions"))
    }

    @Test func weeklyPlanShowsEligibleTrialInCopyAndPrimaryAction() {
        let plan = PremiumSubscriptionPlan(
            kind: .weekly,
            displayName: "Weekly Premium",
            displayPrice: "$4.99",
            price: Decimal(4.99),
            isEligibleForIntroOffer: true,
            introductoryOffer: PremiumIntroOffer(
                paymentMode: .freeTrial,
                periodValue: 3,
                periodUnit: .day,
                periodCount: 1
            )
        )

        #expect(plan.badge == "TRIAL")
        #expect(plan.subtitle == "3-day free trial, then $4.99/week")
        #expect(PremiumPaywallPresentation.primaryButtonTitle(for: plan) == "Start Free Trial")
    }

    @Test func weeklyPlanDoesNotMentionTrialWhenIntroOfferIsUnavailable() {
        let plan = PremiumSubscriptionPlan(
            kind: .weekly,
            displayName: "Weekly Premium",
            displayPrice: "$4.99",
            price: Decimal(4.99),
            isEligibleForIntroOffer: false,
            introductoryOffer: PremiumIntroOffer(
                paymentMode: .freeTrial,
                periodValue: 3,
                periodUnit: .day,
                periodCount: 1
            )
        )

        #expect(plan.badge == nil)
        #expect(plan.subtitle == "Billed weekly")
        #expect(PremiumPaywallPresentation.primaryButtonTitle(for: plan) == "Continue")
    }

    @Test func freeAccessModeHidesPaywallsAndPremiumBadges() {
        #expect(PremiumAccessGate.isFreeAccessEnabled)
        #expect(PremiumAccessGate.shouldDisplayPaywalls == false)
        #expect(PremiumAccessGate.globalServerBadgeTitle == "FREE")
        #expect(PremiumAccessGate.globalServerBadgeSystemImage == "globe")
    }

    @Test func freeAccessGateAllowsManagedConnectionsWithoutSubscription() {
        let localProfile = VPNProfile(
            protocolType: .vless,
            host: "local.example.com",
            port: 443,
            security: .tls,
            networkType: .tcp,
            remarks: "Local"
        )
        let managedProfile = VPNProfile(
            protocolType: .vless,
            host: "192.0.2.10",
            port: 443,
            security: .reality,
            networkType: .tcp,
            origin: .netlumaVPNGlobal,
            managedServerID: "netlumavpn-mvp-eu-1",
            remarks: "NetlumaVPN Global"
        )

        #expect(PremiumAccessGate.requiresPremium(
            selectedGlobalServerID: nil,
            selectedProfile: localProfile,
            hasActiveSubscription: false
        ) == false)
        #expect(PremiumAccessGate.requiresPremium(
            selectedGlobalServerID: "netlumavpn-mvp-eu-1",
            selectedProfile: nil,
            hasActiveSubscription: false
        ) == false)
        #expect(PremiumAccessGate.requiresPremium(
            selectedGlobalServerID: nil,
            selectedProfile: managedProfile,
            hasActiveSubscription: false
        ) == false)
        #expect(PremiumAccessGate.requiresPremium(
            selectedGlobalServerID: "netlumavpn-mvp-eu-1",
            selectedProfile: managedProfile,
            hasActiveSubscription: true
        ) == false)
    }
}
