import Foundation
import StoreKit

enum PremiumPurchaseOutcome: Equatable {
    case purchased
    case cancelled
    case pending
}

enum PremiumSubscriptionError: LocalizedError {
    case productUnavailable
    case productCatalogEmpty
    case unverifiedTransaction
    case purchasesUnavailable

    var errorDescription: String? {
        switch self {
        case .productUnavailable:
            L10n.string("This subscription is not available right now.")
        case .productCatalogEmpty:
            L10n.string("No App Store subscriptions were returned. Check App Store Connect products or the StoreKit configuration.")
        case .unverifiedTransaction:
            L10n.string("The App Store could not verify this purchase.")
        case .purchasesUnavailable:
            L10n.string("In-app purchases are not available on this device.")
        }
    }
}

@MainActor
protocol PremiumSubscriptionServicing: AnyObject {
    func loadProducts() async throws -> [PremiumSubscriptionPlan]
    func hasActiveSubscription() async -> Bool
    func purchase(productID: String) async throws -> PremiumPurchaseOutcome
    func restorePurchases() async throws -> Bool
    func observeTransactionUpdates(_ handler: @escaping @MainActor (Bool) async -> Void) -> Task<Void, Never>
}

@MainActor
final class StoreKitPremiumSubscriptionService: PremiumSubscriptionServicing {
    private var productsByID: [String: Product] = [:]
    private let productIDs = Set(PremiumProductKind.allCases.map(\.productID))
    private let purchaseAnalyticsReporter: PremiumPurchaseAnalyticsReporting

    init(
        purchaseAnalyticsReporter: PremiumPurchaseAnalyticsReporting = FirebaseTelemetryReporter.shared
    ) {
        self.purchaseAnalyticsReporter = purchaseAnalyticsReporter
    }

    func loadProducts() async throws -> [PremiumSubscriptionPlan] {
        let requestedIDs = PremiumProductKind.allCases.map(\.productID)
        let products = try await Product.products(for: requestedIDs)

        let returnedIDs = Set(products.map(\.id))
        let missingIDs = requestedIDs.filter { !returnedIDs.contains($0) }
        if !missingIDs.isEmpty {
            // StoreKit silently omits IDs it does not recognise. Logging them pinpoints
            // a mismatch between the app's product IDs and the active catalog (the local
            // StoreKit configuration in Debug, or App Store Connect on TestFlight/Release).
            AppLogger.warning(
                "StoreKit returned \(products.count)/\(requestedIDs.count) product(s); missing: \(missingIDs.joined(separator: ", "))",
                category: .app
            )
        }

        guard !products.isEmpty else {
            throw PremiumSubscriptionError.productCatalogEmpty
        }

        productsByID = Dictionary(uniqueKeysWithValues: products.map { ($0.id, $0) })

        var plans: [PremiumSubscriptionPlan] = []
        for product in products {
            guard let plan = await makePlan(for: product) else {
                continue
            }
            plans.append(plan)
        }

        return plans.sorted { $0.kind.sortIndex < $1.kind.sortIndex }
    }

    func hasActiveSubscription() async -> Bool {
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result,
                  productIDs.contains(transaction.productID),
                  transaction.revocationDate == nil else {
                continue
            }

            if let expirationDate = transaction.expirationDate, expirationDate <= Date() {
                continue
            }

            return true
        }

        return false
    }

    func purchase(productID: String) async throws -> PremiumPurchaseOutcome {
        purchaseAnalyticsReporter.logPremiumPurchaseStarted(productID: productID)

        do {
            guard AppStore.canMakePayments else {
                throw PremiumSubscriptionError.purchasesUnavailable
            }

            let product = try await product(for: productID)
            switch try await product.purchase() {
            case .success(let verification):
                let transaction = try verifiedTransaction(from: verification)
                purchaseAnalyticsReporter.logPremiumPurchase(transaction: transaction)
                await transaction.finish()
                return .purchased
            case .userCancelled:
                purchaseAnalyticsReporter.logPremiumPurchaseCancelled(productID: productID)
                return .cancelled
            case .pending:
                purchaseAnalyticsReporter.logPremiumPurchasePending(productID: productID)
                return .pending
            @unknown default:
                purchaseAnalyticsReporter.logPremiumPurchasePending(productID: productID)
                return .pending
            }
        } catch {
            purchaseAnalyticsReporter.logPremiumPurchaseFailed(productID: productID, error: error)
            throw error
        }
    }

    func restorePurchases() async throws -> Bool {
        try await AppStore.sync()
        return await hasActiveSubscription()
    }

    func observeTransactionUpdates(_ handler: @escaping @MainActor (Bool) async -> Void) -> Task<Void, Never> {
        Task { [weak self] in
            for await result in Transaction.updates {
                guard let self else {
                    return
                }

                if case .verified(let transaction) = result {
                    await transaction.finish()
                }

                let isActive = await self.hasActiveSubscription()
                await handler(isActive)
            }
        }
    }

    private func product(for productID: String) async throws -> Product {
        if let product = productsByID[productID] {
            return product
        }

        let products = try await Product.products(for: [productID])
        guard let product = products.first else {
            throw PremiumSubscriptionError.productUnavailable
        }

        productsByID[productID] = product
        return product
    }

    private func makePlan(for product: Product) async -> PremiumSubscriptionPlan? {
        guard product.type == .autoRenewable,
              let kind = PremiumProductKind(productID: product.id) else {
            return nil
        }

        let subscription = product.subscription
        let introductoryOffer = subscription?.introductoryOffer.map { PremiumIntroOffer(storeKitOffer: $0) }
        let isEligibleForIntroOffer: Bool
        if introductoryOffer == nil {
            isEligibleForIntroOffer = false
        } else {
            isEligibleForIntroOffer = await subscription?.isEligibleForIntroOffer ?? false
        }

        return PremiumSubscriptionPlan(
            kind: kind,
            productID: product.id,
            displayName: product.displayName,
            displayPrice: product.displayPrice,
            price: product.price,
            isEligibleForIntroOffer: isEligibleForIntroOffer,
            introductoryOffer: introductoryOffer
        )
    }

    private func verifiedTransaction(
        from verification: VerificationResult<Transaction>
    ) throws -> Transaction {
        switch verification {
        case .verified(let transaction):
            transaction
        case .unverified:
            throw PremiumSubscriptionError.unverifiedTransaction
        }
    }
}

private extension PremiumIntroOffer {
    init(storeKitOffer: Product.SubscriptionOffer) {
        self.init(
            paymentMode: PremiumIntroOfferPaymentMode(storeKitPaymentMode: storeKitOffer.paymentMode),
            periodValue: storeKitOffer.period.value,
            periodUnit: PremiumSubscriptionPeriodUnit(storeKitUnit: storeKitOffer.period.unit),
            periodCount: storeKitOffer.periodCount
        )
    }
}

private extension PremiumIntroOfferPaymentMode {
    init(storeKitPaymentMode: Product.SubscriptionOffer.PaymentMode) {
        switch storeKitPaymentMode {
        case .freeTrial:
            self = .freeTrial
        case .payAsYouGo:
            self = .payAsYouGo
        case .payUpFront:
            self = .payUpFront
        default:
            self = .unknown
        }
    }
}

private extension PremiumSubscriptionPeriodUnit {
    init(storeKitUnit: Product.SubscriptionPeriod.Unit) {
        switch storeKitUnit {
        case .day:
            self = .day
        case .week:
            self = .week
        case .month:
            self = .month
        case .year:
            self = .year
        @unknown default:
            self = .month
        }
    }
}
