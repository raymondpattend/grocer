import Foundation
import Observation
import PostHog
import RevenueCat

enum RevenueCatConfig {
    /// RevenueCat traps with a `fatalError` if a Test Store key (`test_…`) is used
    /// in a Release build, so Release (TestFlight / App Store) must use the real
    /// App Store key from the RevenueCat dashboard. Debug keeps the Test Store key.
    #if DEBUG
    static let apiKey = "test_tSaSOTwPRseDzLdzjuGNqrnTOSb"
    #else
    static let apiKey = "appl_qQYLRddYzArxuGvGETeoYPAHlUd"
    #endif
    static let grocerProEntitlementID = "Grocer Pro"

    static let yearlyProductID = "grocer_pro_subscription_annual_1"
    static let quarterlyProductID = "grocer_pro_subscription_quarterly_1"
    static let monthlyProductID = "grocer_pro_subscription_monthly_1"

    private static var didConfigure = false

    static func configure() {
        guard !didConfigure else { return }

        #if DEBUG
        Purchases.logLevel = .debug
        #endif

        Purchases.configure(withAPIKey: apiKey)
        didConfigure = true
    }

    static func hasGrocerPro(_ customerInfo: CustomerInfo?) -> Bool {
        customerInfo?.entitlements.all[grocerProEntitlementID]?.isActive == true
    }
}

struct GrocerProPaywallCopy {
    let headline: String
    let subtitle: String
}

struct GrocerProGroupUpsellCopy {
    let title: String
    let subtitle: String
    let accessibilityLabel: String
}

enum GrocerProPaywallContext {
    case general
    case groupLimit

    fileprivate var metadataKey: String {
        switch self {
        case .general: return "general"
        case .groupLimit: return "group_limit"
        }
    }

    var defaultCopy: GrocerProPaywallCopy {
        switch self {
        case .general:
            return GrocerProPaywallCopy(
                headline: String(localized: "Shop smarter\nwith Grocer Pro"),
                subtitle: String(localized: "Unlimited groups, smarter shopping, history, and more, for the whole family.")
            )
        case .groupLimit:
            return GrocerProPaywallCopy(
                headline: String(localized: "Pro users can make\nunlimited groups"),
                subtitle: String(localized: "Start with 2 groups, upgrade to Pro to make as many as you need.")
            )
        }
    }
}

@Observable
final class SubscriptionStore {
    static let shared = SubscriptionStore()

    private(set) var customerInfo: CustomerInfo?
    private(set) var offerings: Offerings?
    private(set) var currentOffering: Offering?
    private(set) var isLoading = false
    private(set) var isPurchasing = false
    private(set) var isRestoring = false
    var lastErrorMessage: String?

    @ObservationIgnored private var customerInfoTask: Task<Void, Never>?

    var hasGrocerPro: Bool {
        RevenueCatConfig.hasGrocerPro(customerInfo)
    }

    var managementURL: URL? {
        customerInfo?.managementURL
    }

    var displayStatus: String {
        if hasGrocerPro {
            return String(localized: "Active")
        }

        if isLoading && customerInfo == nil {
            return String(localized: "Checking...")
        }

        return String(localized: "Not active")
    }

    var availablePackages: [Package] {
        guard let offering = currentOffering else { return [] }

        let preferred = uniquePackages([
            yearlyPackage(in: offering),
            quarterlyPackage(in: offering),
            monthlyPackage(in: offering),
        ])

        return preferred.isEmpty ? offering.availablePackages : preferred
    }

    func paywallCopy(for context: GrocerProPaywallContext) -> GrocerProPaywallCopy {
        let fallback = context.defaultCopy
        guard let paywallCopy = currentOffering?.metadata["paywall_copy"] as? [String: Any],
              let contextCopy = paywallCopy[context.metadataKey] as? [String: Any] else {
            return fallback
        }

        return GrocerProPaywallCopy(
            headline: nonEmptyString(contextCopy["headline"]) ?? fallback.headline,
            subtitle: nonEmptyString(contextCopy["subtitle"]) ?? fallback.subtitle
        )
    }

    var homeGroupLimitCardCopy: GrocerProGroupUpsellCopy {
        let fallback = GrocerProGroupUpsellCopy(
            title: String(localized: "Upgrade to Grocer Pro"),
            subtitle: String(localized: "Unlimited lists, live activities, and more."),
            accessibilityLabel: String(localized: "Upgrade to Grocer Pro. Create unlimited grocery groups.")
        )
        guard let cardCopy = currentOffering?.metadata["home_group_limit_card"] as? [String: Any] else {
            return fallback
        }

        return GrocerProGroupUpsellCopy(
            title: nonEmptyString(cardCopy["title"]) ?? fallback.title,
            subtitle: nonEmptyString(cardCopy["subtitle"]) ?? fallback.subtitle,
            accessibilityLabel: nonEmptyString(cardCopy["accessibility_label"]) ?? fallback.accessibilityLabel
        )
    }

    @MainActor
    func start() {
        guard customerInfoTask == nil else { return }

        customerInfoTask = Task { [weak self] in
            for await customerInfo in Purchases.shared.customerInfoStream {
                self?.update(with: customerInfo)
            }
        }

        Task {
            await refresh()
        }
    }

    @MainActor
    func refresh() async {
        isLoading = true
        defer { isLoading = false }

        do {
            async let customerInfo = Purchases.shared.customerInfo()
            async let offerings = Purchases.shared.offerings()

            let (latestCustomerInfo, latestOfferings) = try await (customerInfo, offerings)
            update(with: latestCustomerInfo)
            self.offerings = latestOfferings
            currentOffering = latestOfferings.current
        } catch {
            recordFailure(error)
        }
    }

    @MainActor
    func purchase(_ package: Package) async {
        guard !isPurchasing else { return }

        isPurchasing = true
        defer { isPurchasing = false }

        do {
            let result = try await Purchases.shared.purchase(package: package)
            update(with: result.customerInfo)
            if !result.userCancelled {
                PostHogSDK.shared.capture("subscription_purchased", properties: [
                    "product_id": package.storeProduct.productIdentifier,
                    "package_identifier": package.identifier,
                    "price": package.storeProduct.localizedPriceString,
                ])
            }
        } catch {
            recordFailure(error)
        }
    }

    @MainActor
    func restorePurchases() async {
        guard !isRestoring else { return }

        isRestoring = true
        defer { isRestoring = false }

        do {
            let restoredCustomerInfo = try await Purchases.shared.restorePurchases()
            update(with: restoredCustomerInfo)
            PostHogSDK.shared.capture("purchases_restored", properties: [
                "has_active_entitlement": RevenueCatConfig.hasGrocerPro(restoredCustomerInfo),
            ])
        } catch {
            recordFailure(error)
        }
    }

    @MainActor
    func update(with customerInfo: CustomerInfo) {
        self.customerInfo = customerInfo
        if RevenueCatConfig.hasGrocerPro(customerInfo) {
            lastErrorMessage = nil
        }
    }

    @MainActor
    func recordFailure(_ error: Error) {
        guard !Self.isCancellation(error) else { return }

        let message = Self.userFacingMessage(for: error)
        lastErrorMessage = message
        print("[RevenueCat] \(message) \(error)")
    }

    @MainActor
    func clearError() {
        lastErrorMessage = nil
    }

    private func yearlyPackage(in offering: Offering) -> Package? {
        offering.annual
            ?? offering.package(identifier: RevenueCatConfig.yearlyProductID)
            ?? package(in: offering, productID: RevenueCatConfig.yearlyProductID)
    }

    private func quarterlyPackage(in offering: Offering) -> Package? {
        offering.threeMonth
            ?? offering.package(identifier: RevenueCatConfig.quarterlyProductID)
            ?? package(in: offering, productID: RevenueCatConfig.quarterlyProductID)
    }

    private func monthlyPackage(in offering: Offering) -> Package? {
        offering.monthly
            ?? offering.package(identifier: RevenueCatConfig.monthlyProductID)
            ?? package(in: offering, productID: RevenueCatConfig.monthlyProductID)
    }

    private func package(in offering: Offering, productID: String) -> Package? {
        offering.availablePackages.first { $0.storeProduct.productIdentifier == productID }
    }

    private func uniquePackages(_ packages: [Package?]) -> [Package] {
        var seen = Set<String>()

        return packages.compactMap { package in
            guard let package, !seen.contains(package.identifier) else { return nil }
            seen.insert(package.identifier)
            return package
        }
    }

    private func nonEmptyString(_ value: Any?) -> String? {
        guard let string = value as? String,
              !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return string
    }

    private static func isCancellation(_ error: Error) -> Bool {
        errorCode(for: error) == .purchaseCancelledError
    }

    private static func errorCode(for error: Error) -> RevenueCat.ErrorCode? {
        if let code = error as? RevenueCat.ErrorCode {
            return code
        }

        let nsError = error as NSError
        return RevenueCat.ErrorCode(rawValue: nsError.code)
    }

    private static func userFacingMessage(for error: Error) -> String {
        guard let code = errorCode(for: error) else {
            return error.localizedDescription
        }

        switch code {
        case .networkError, .offlineConnectionError:
            return String(localized: "Check your connection and try again.")
        case .purchaseNotAllowedError:
            return String(localized: "Purchases are not allowed on this device.")
        case .purchaseInvalidError:
            return String(localized: "The purchase could not be completed. Check the payment method and try again.")
        case .productNotAvailableForPurchaseError:
            return String(localized: "This product is not available for purchase yet.")
        case .productAlreadyPurchasedError:
            return String(localized: "This purchase is already active. Try Restore Purchases if access is missing.")
        case .invalidCredentialsError, .configurationError:
            return String(localized: "RevenueCat is not configured correctly. Check the API key and dashboard setup.")
        case .storeProblemError:
            return String(localized: "The App Store could not complete the request. Try again in a moment.")
        case .paymentPendingError:
            return String(localized: "The payment is pending. Access will update after Apple approves it.")
        default:
            return code.description
        }
    }
}
