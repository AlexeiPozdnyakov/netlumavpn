import Foundation

enum PremiumProductKind: String, CaseIterable, Identifiable {
    case weekly
    case monthly
    case annual

    var id: String { productID }

    var productID: String {
        switch self {
        case .weekly:
            "com.alekseipozdiakov.NetlumaVPN.premium.weekly"
        case .monthly:
            "com.alekseipozdiakov.NetlumaVPN.premium.monthly"
        case .annual:
            "com.alekseipozdiakov.NetlumaVPN.premium.annual"
        }
    }

    var title: String {
        switch self {
        case .weekly:
            L10n.string("Weekly")
        case .monthly:
            L10n.string("Monthly")
        case .annual:
            L10n.string("Yearly")
        }
    }

    var billingSubtitle: String {
        switch self {
        case .weekly:
            L10n.string("Billed weekly")
        case .monthly:
            L10n.string("Flexible plan. Billed every month")
        case .annual:
            L10n.string("Best value for always-on privacy")
        }
    }

    var pricePeriodSuffix: String {
        switch self {
        case .weekly:
            "week"
        case .monthly:
            "month"
        case .annual:
            "year"
        }
    }

    var sortIndex: Int {
        switch self {
        case .weekly:
            0
        case .monthly:
            1
        case .annual:
            2
        }
    }

    init?(productID: String) {
        guard let kind = Self.allCases.first(where: { $0.productID == productID }) else {
            return nil
        }
        self = kind
    }
}

enum PremiumIntroOfferPaymentMode: Equatable {
    case freeTrial
    case payAsYouGo
    case payUpFront
    case unknown
}

enum PremiumSubscriptionPeriodUnit: Equatable {
    case day
    case week
    case month
    case year

    var compoundNoun: String {
        switch self {
        case .day:
            "day"
        case .week:
            "week"
        case .month:
            "month"
        case .year:
            "year"
        }
    }

    func noun(for value: Int) -> String {
        switch self {
        case .day:
            value == 1 ? "day" : "days"
        case .week:
            value == 1 ? "week" : "weeks"
        case .month:
            value == 1 ? "month" : "months"
        case .year:
            value == 1 ? "year" : "years"
        }
    }
}

struct PremiumIntroOffer: Equatable {
    let paymentMode: PremiumIntroOfferPaymentMode
    let periodValue: Int
    let periodUnit: PremiumSubscriptionPeriodUnit
    let periodCount: Int

    var durationText: String {
        let totalValue = max(1, periodValue * max(1, periodCount))
        return "\(totalValue)-\(periodUnit.compoundNoun)"
    }
}

struct PremiumSubscriptionPlan: Identifiable, Equatable {
    let kind: PremiumProductKind
    let productID: String
    let displayName: String
    let displayPrice: String
    let price: Decimal?
    let isEligibleForIntroOffer: Bool
    let introductoryOffer: PremiumIntroOffer?

    init(
        kind: PremiumProductKind,
        productID: String? = nil,
        displayName: String,
        displayPrice: String,
        price: Decimal?,
        isEligibleForIntroOffer: Bool,
        introductoryOffer: PremiumIntroOffer?
    ) {
        self.kind = kind
        self.productID = productID ?? kind.productID
        self.displayName = displayName
        self.displayPrice = displayPrice
        self.price = price
        self.isEligibleForIntroOffer = isEligibleForIntroOffer
        self.introductoryOffer = introductoryOffer
    }

    var id: String { productID }

    var title: String {
        kind.title
    }

    var hasEligibleFreeTrial: Bool {
        isEligibleForIntroOffer && introductoryOffer?.paymentMode == .freeTrial
    }

    var subtitle: String {
        if hasEligibleFreeTrial, let introductoryOffer {
            return "\(introductoryOffer.durationText) \(L10n.string("free trial")), \(L10n.string("then")) \(displayPrice)/\(kind.pricePeriodSuffix)"
        }

        return kind.billingSubtitle
    }

    var badge: String? {
        if hasEligibleFreeTrial {
            return L10n.string("TRIAL")
        }

        switch kind {
        case .annual:
            return L10n.string("BEST")
        case .weekly, .monthly:
            return nil
        }
    }
}

enum PremiumPaywallPresentation {
    static func primaryButtonTitle(for plan: PremiumSubscriptionPlan?) -> String {
        guard plan?.hasEligibleFreeTrial == true else {
            return L10n.string("Continue")
        }

        return L10n.string("Start Free Trial")
    }
}

enum PremiumAccessGate {
    static func requiresPremium(
        selectedGlobalServerID: String?,
        selectedProfile: VPNProfile?,
        hasActiveSubscription: Bool
    ) -> Bool {
        guard !hasActiveSubscription else {
            return false
        }

        return selectedGlobalServerID != nil || selectedProfile?.isNetlumaVPNManaged == true
    }

    /// Whether an in-flight tunnel must be torn down because the user no longer holds the
    /// subscription that authorized a premium (Netluma Global / managed) connection.
    ///
    /// Only live sessions (`.connected` / `.connecting`) are revoked — a `.disconnecting`
    /// or already-down session needs no action, and non-premium (user-imported) sessions
    /// are never gated.
    static func shouldRevokeActiveSession(
        status: VPNConnectionStatus,
        selectedGlobalServerID: String?,
        selectedProfile: VPNProfile?,
        hasActiveSubscription: Bool
    ) -> Bool {
        switch status {
        case .connected, .connecting:
            break
        case .disconnected, .disconnecting, .failed:
            return false
        }

        return requiresPremium(
            selectedGlobalServerID: selectedGlobalServerID,
            selectedProfile: selectedProfile,
            hasActiveSubscription: hasActiveSubscription
        )
    }
}

enum PremiumGatedActionResult: Equatable {
    case proceeded
    case requiresPremium
}
