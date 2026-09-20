import FirebaseAnalytics
import FirebaseCrashlytics
import FirebaseCore
import Foundation
import StoreKit

struct NetworkErrorContext: Equatable {
    let method: String
    let host: String
    let path: String
    let statusCode: Int?
    let attemptCount: Int

    init(request: URLRequest, statusCode: Int?, attemptCount: Int) {
        method = request.httpMethod?.nilIfBlank ?? "GET"
        host = request.url?.host?.nilIfBlank ?? "unknown"
        path = request.url?.path.nilIfBlank ?? "/"
        self.statusCode = statusCode
        self.attemptCount = max(1, attemptCount)
    }
}

protocol NetworkErrorReporting {
    func recordNetworkError(_ error: Error, context: NetworkErrorContext) async
}

struct NoOpNetworkErrorReporter: NetworkErrorReporting {
    func recordNetworkError(_ error: Error, context: NetworkErrorContext) async {}
}

@MainActor
protocol PremiumPurchaseAnalyticsReporting {
    func logPremiumPurchaseStarted(productID: String)
    func logPremiumPurchaseCancelled(productID: String)
    func logPremiumPurchasePending(productID: String)
    func logPremiumPurchaseFailed(productID: String, error: Error)
    func logPremiumPurchase(transaction: Transaction)
}

@MainActor
struct NoOpPremiumPurchaseAnalyticsReporter: PremiumPurchaseAnalyticsReporting {
    func logPremiumPurchaseStarted(productID: String) {}
    func logPremiumPurchaseCancelled(productID: String) {}
    func logPremiumPurchasePending(productID: String) {}
    func logPremiumPurchaseFailed(productID: String, error: Error) {}
    func logPremiumPurchase(transaction: Transaction) {}
}

final class FirebaseTelemetryReporter: NetworkErrorReporting, PremiumPurchaseAnalyticsReporting {
    static let shared = FirebaseTelemetryReporter()

    private init() {}

    func recordNetworkError(_ error: Error, context: NetworkErrorContext) async {
        guard FirebaseApp.app() != nil else { return }
        let crashlytics = Crashlytics.crashlytics()
        let sanitizedError = Self.networkNSError(from: error, context: context)

        crashlytics.log("network_request_failed method=\(context.method) host=\(context.host) path=\(context.path)")
        crashlytics.record(error: sanitizedError)

        Analytics.logEvent("network_request_failed", parameters: Self.networkAnalyticsParameters(for: context, error: error))
    }

    @MainActor
    func logPremiumPurchaseStarted(productID: String) {
        logPurchaseEvent("premium_purchase_started", productID: productID)
    }

    @MainActor
    func logPremiumPurchaseCancelled(productID: String) {
        logPurchaseEvent("premium_purchase_cancelled", productID: productID)
    }

    @MainActor
    func logPremiumPurchasePending(productID: String) {
        logPurchaseEvent("premium_purchase_pending", productID: productID)
    }

    @MainActor
    func logPremiumPurchaseFailed(productID: String, error: Error) {
        guard FirebaseApp.app() != nil else { return }
        var parameters = Self.purchaseAnalyticsParameters(productID: productID)
        let nsError = error as NSError
        parameters["error_domain"] = nsError.domain
        parameters["error_code"] = nsError.code
        Analytics.logEvent("premium_purchase_failed", parameters: parameters)
    }

    @MainActor
    func logPremiumPurchase(transaction: Transaction) {
        guard FirebaseApp.app() != nil else { return }
        Analytics.logTransaction(transaction)
        logPurchaseEvent("premium_purchase_completed", productID: transaction.productID)
    }

    @MainActor
    private func logPurchaseEvent(_ name: String, productID: String) {
        guard FirebaseApp.app() != nil else { return }
        Analytics.logEvent(name, parameters: Self.purchaseAnalyticsParameters(productID: productID))
    }

    private static func networkNSError(from error: Error, context: NetworkErrorContext) -> NSError {
        let domainAndCode = networkDomainAndCode(from: error, statusCode: context.statusCode)
        var userInfo: [String: Any] = [
            NSLocalizedDescriptionKey: "Network request failed",
            "request_method": context.method,
            "request_host": context.host,
            "request_path": context.path,
            "attempt_count": context.attemptCount
        ]

        if let statusCode = context.statusCode {
            userInfo[NSLocalizedFailureReasonErrorKey] = "HTTP \(statusCode)"
            userInfo["status_code"] = statusCode
        }

        if let urlError = error as? URLError {
            userInfo["url_error_code"] = urlError.code.rawValue
        }

        return NSError(domain: domainAndCode.domain, code: domainAndCode.code, userInfo: userInfo)
    }

    private static func networkDomainAndCode(from error: Error, statusCode: Int?) -> (domain: String, code: Int) {
        if let statusCode {
            return ("com.netlumavpn.examplework.http", statusCode)
        }

        if let urlError = error as? URLError {
            return (NSURLErrorDomain, urlError.code.rawValue)
        }

        let nsError = error as NSError
        return (nsError.domain, nsError.code)
    }

    private static func networkAnalyticsParameters(for context: NetworkErrorContext, error: Error) -> [String: Any] {
        var parameters: [String: Any] = [
            "request_method": context.method,
            "request_host": context.host,
            "request_path": context.path,
            "attempt_count": context.attemptCount
        ]

        if let statusCode = context.statusCode {
            parameters["status_code"] = statusCode
        }

        if let urlError = error as? URLError {
            parameters["url_error_code"] = urlError.code.rawValue
        }

        return parameters
    }

    private static func purchaseAnalyticsParameters(productID: String) -> [String: Any] {
        [
            AnalyticsParameterItemID: productID,
            "product_id": productID
        ]
    }
}
